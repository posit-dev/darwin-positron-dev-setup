#!/usr/bin/env bash
#
# setup-darwin.sh — Configure a macOS machine for Positron development.
#
# Run interactively by a developer on a fresh Mac. Asks before doing anything
# slow or impactful, and is idempotent so it's safe to re-run.
#
# Usage:
#   ./setup-darwin.sh          run the setup steps
#   ./setup-darwin.sh --undo   revert what a previous run installed/created
#
# --undo only reverses things THIS script actually did (tracked in a manifest);
# it never touches pre-existing packages or checkouts, and it does not revert
# Homebrew update/upgrade. Generated SSH keys are deliberately left in place too,
# since the matching public key may already be registered on GitHub.
#
set -euo pipefail

# Where to clone Positron from. Cloned over SSH (into a developer-chosen folder
# under ~/), so it relies on configure_ssh_key having registered a key first.
POSITRON_URL="${SETUP_POSITRON_URL:-git@github.com:posit-dev/positron.git}"

# Repos that Positron core developers work on. clone_positron offers to clone
# each — over SSH, sharing POSITRON_URL's host/owner — into a folder under ~/.
CORE_REPOS=(
  positron
  positron-codicons
  positron-builds
  positron-website
  positron-wiki
)

# Homebrew formulae (CLI tools/libraries) installed as build dependencies. GUI
# apps go through --cask instead. Compilers and git come from the Xcode Command
# Line Tools, and Python comes via pyenv, so none of those appear here. Maintain
# this list as Positron's build requirements change — one formula per line for
# easy diffs.
FORMULAE=(
  git-lfs
  cmake
  pkg-config
  libsodium
  cairo
  pango
  libpng
  jpeg
  giflib
)

# Homebrew casks (GUI apps) installed as dependencies. Visual Studio Code is
# handled by its own optional step, so it isn't listed here. NOTE: on the stock
# macOS bash 3.2, expanding an empty array with "${CASKS[@]}" under `set -u`
# aborts with "unbound variable", so any loop over this must be guarded with
# `[ "${#CASKS[@]}" -gt 0 ]` first.
CASKS=(
  google-chrome
  docker-desktop
)

# Node.js version installed via fnm (see install_node). Pinned here so it's easy
# to bump in one place as Positron's supported Node moves.
NODE_VERSION="22.22.1"

# Python version installed via pyenv (see install_python). Pinned here so it's
# easy to bump in one place as Positron's supported Python moves.
PYTHON_VERSION="3.12.12"

# Login shell wiring. Later steps (e.g. install_python) write their shell init
# into $SHELL_RC and use $LOGIN_SHELL to pick the right init syntax.
LOGIN_SHELL="zsh"
SHELL_RC="$HOME/.zshrc"

# Manifest of what this run actually created/installed, so `--undo` can revert
# precisely without disturbing anything that pre-existed. Lives under macOS's
# Application Support directory, where persistent app state belongs. Override
# with SETUP_STATE_DIR if you need to.
STATE_DIR="${SETUP_STATE_DIR:-$HOME/Library/Application Support/darwin-positron-dev-setup}"
MANIFEST="$STATE_DIR/manifest"

# --- helpers ----------------------------------------------------------------

# ACCENT/CYAN/RESET: ANSI codes used to color banners and prompts (yellow, to
# signal "action needed"; cyan to make URLs stand out). Only populated when
# stderr is a terminal, so piped/logged output stays free of escape codes.
if [ -t 2 ]; then
  ACCENT=$'\033[33m'
  CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  ACCENT=""
  CYAN=""
  RESET=""
fi

# log <message>: progress line on stderr, prefixed with [setup].
log() {
  printf '[setup] %s\n' "$*" >&2
}

# banner <title>: blank line + full-width rule + title, on stderr, in the accent
# color. Used to set off each interactive prompt so it's easy to spot. The rule
# uses the box-drawing character U+2500 and spans the terminal width (falling
# back to 40).
banner() {
  local width line
  width=$(tput cols 2>/dev/null) || width=40
  [ -n "$width" ] || width=40
  line=$(printf '─%.0s' $(seq 1 "$width"))
  printf '\n' >&2
  printf '%s%s%s\n' "$ACCENT" "$line" "$RESET" >&2
  printf '%s%s%s\n' "$ACCENT" "$1" "$RESET" >&2
}

# boxed_notice <line>...: print the given lines inside a bold box (box-drawing
# characters) on stderr, in the accent color, sized to the longest line. Used for
# the final "log out and back in" reminder so it can't be missed in the scroll.
boxed_notice() {
  local bold="" line width=0 rule pad
  if [ -t 2 ]; then bold=$'\033[1m'; fi
  for line in "$@"; do
    [ "${#line}" -gt "$width" ] && width=${#line}
  done
  rule=$(printf '═%.0s' $(seq 1 $((width + 2))))
  printf '\n' >&2
  printf '%s%s╔%s╗%s\n' "$bold" "$ACCENT" "$rule" "$RESET" >&2
  for line in "$@"; do
    pad=$((width - ${#line}))
    printf '%s%s║ %s%*s ║%s\n' "$bold" "$ACCENT" "$line" "$pad" "" "$RESET" >&2
  done
  printf '%s%s╚%s╝%s\n' "$bold" "$ACCENT" "$rule" "$RESET" >&2
  printf '\n' >&2
}

# have <command>: true if <command> is on PATH.
have() {
  command -v "$1" >/dev/null 2>&1
}

# formula_installed <formula>: true if the Homebrew formula is installed. Assumes
# brew is on PATH (guard with `have brew` if that isn't yet guaranteed).
formula_installed() {
  brew list --formula --versions "$1" >/dev/null 2>&1
}

# cask_installed <cask>: true if the Homebrew cask is installed. Assumes brew is
# on PATH (guard with `have brew` if that isn't yet guaranteed).
cask_installed() {
  brew list --cask --versions "$1" >/dev/null 2>&1
}

# record <line>: append an action record to the manifest so --undo can reverse
# it later. Creates the state dir on first use.
record() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" >>"$MANIFEST"
}

# confirm <prompt>: ask a yes/no question, defaulting to Yes so the developer can
# hit ENTER to proceed through the steps. Reads from the terminal (/dev/tty)
# rather than stdin, so the prompt still works when the script is piped in via
# `curl ... | bash` (where stdin is the script itself).
confirm() {
  local prompt="$1" reply=""
  printf '%s%s [Y/n] %s' "$ACCENT" "$prompt" "$RESET" >&2
  read -r reply </dev/tty 2>/dev/null || reply=""
  case "$reply" in
    [Nn] | [Nn][Oo]) return 1 ;;
    *) return 0 ;;
  esac
}

# ask <prompt> <varname>: read a line from the terminal into the named variable,
# re-asking until it's non-empty. Like confirm(), reads /dev/tty so it works
# when the script is piped in via `curl ... | bash`.
ask() {
  local prompt="$1" __var="$2" reply=""
  while [ -z "$reply" ]; do
    printf '%s%s: %s' "$ACCENT" "$prompt" "$RESET" >&2
    read -r reply </dev/tty 2>/dev/null || reply=""
  done
  printf -v "$__var" '%s' "$reply"
}

# ask_default <prompt> <varname> <default>: like ask(), but shows <default> in
# brackets and accepts it when the developer just hits ENTER. If <default> is
# empty this behaves like ask() (re-asks until non-empty), so it works both for
# confirming an existing value and for filling in a missing one.
ask_default() {
  local prompt="$1" __var="$2" default="$3" reply=""
  while :; do
    if [ -n "$default" ]; then
      printf '%s%s [%s]: %s' "$ACCENT" "$prompt" "$default" "$RESET" >&2
    else
      printf '%s%s: %s' "$ACCENT" "$prompt" "$RESET" >&2
    fi
    read -r reply </dev/tty 2>/dev/null || reply=""
    [ -z "$reply" ] && reply="$default"
    [ -n "$reply" ] && break
  done
  printf -v "$__var" '%s' "$reply"
}

# clip_copy <text>: copy <text> to the macOS clipboard via pbcopy (which ships
# with macOS). Returns non-zero if pbcopy is somehow unavailable so callers can
# fall back gracefully.
clip_copy() {
  if have pbcopy; then
    printf '%s' "$1" | pbcopy
  else
    return 1
  fi
}

# add_shell_init <tag> <line>...: append a marker-delimited block of shell-init
# lines to $SHELL_RC so a tool (fnm, pyenv, ...) loads in future interactive
# shells. Idempotent by <tag>, and recorded for --undo, which removes the block
# by its markers. <tag> names the tool so blocks are individually identifiable.
add_shell_init() {
  local tag="$1"; shift
  local rc="$SHELL_RC"
  if [ -f "$rc" ] && grep -q "darwin-positron-dev-setup: $tag" "$rc"; then
    log "$tag shell init already present in $rc; skipping."
    return 0
  fi
  log "adding $tag shell init to $rc ..."
  {
    printf '\n# >>> darwin-positron-dev-setup: %s >>>\n' "$tag"
    printf '%s\n' "$@"
    printf '# <<< darwin-positron-dev-setup: %s <<<\n' "$tag"
  } >>"$rc"
  record "shellinit $rc"
}

# --- steps ------------------------------------------------------------------

# install_homebrew: ensure Homebrew is installed and on PATH, both for the rest
# of this run and for future shells. This runs first because the official
# installer also installs the Xcode Command Line Tools (git, clang, headers) if
# they're missing — and does so headlessly via `softwareupdate`, rather than the
# `xcode-select --install` GUI dialog (which opens behind the terminal, unseen).
# That makes it the effective entry point for the whole toolchain, and it puts
# git on PATH in time for the oh-my-zsh step that follows.
#
# Like the Command Line Tools, Homebrew and its shell wiring are foundational and
# shared with other tooling, so this step records nothing: `--undo` leaves brew
# (and the `brew shellenv` line it adds to your shell rc) in place. Individual
# formulae installed later are recorded and reversed on their own.
install_homebrew() {
  banner "Homebrew"

  if have brew; then
    log "Homebrew already installed ($(brew --prefix)); skipping."
    return 0
  fi

  # A prior install may be present but not yet on PATH — common on Apple silicon,
  # where brew lives in /opt/homebrew and isn't on the default PATH.
  local brew_bin=""
  if [ -x /opt/homebrew/bin/brew ]; then
    brew_bin=/opt/homebrew/bin/brew
  elif [ -x /usr/local/bin/brew ]; then
    brew_bin=/usr/local/bin/brew
  fi

  if [ -z "$brew_bin" ]; then
    if ! confirm "Install Homebrew (also installs the Xcode Command Line Tools if needed)?"; then
      log "Skipping Homebrew — later steps that install packages will fail without it."
      return 0
    fi

    # Redirect the installer's stdin from /dev/tty so its RETURN/sudo prompts
    # work even when this script itself was piped in via `curl ... | bash`.
    log "Running the official Homebrew installer; follow its prompts ..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty

    if [ -x /opt/homebrew/bin/brew ]; then
      brew_bin=/opt/homebrew/bin/brew
    elif [ -x /usr/local/bin/brew ]; then
      brew_bin=/usr/local/bin/brew
    else
      log "Homebrew install did not produce a brew binary in /opt/homebrew or /usr/local; aborting."
      exit 1
    fi
  fi

  # Put brew on PATH for the remainder of this run ...
  eval "$("$brew_bin" shellenv)"

  # ... and for future shells, by wiring it into the shell rc if not already
  # there (idempotent, so re-running the setup won't duplicate the line).
  if [ -f "$SHELL_RC" ] && grep -qF "$brew_bin shellenv" "$SHELL_RC"; then
    log "brew shellenv already wired into $SHELL_RC."
  else
    printf '\neval "$(%s shellenv)"\n' "$brew_bin" >>"$SHELL_RC"
    log "Added brew shellenv to $SHELL_RC."
  fi

  log "Homebrew ready ($("$brew_bin" --prefix))."
}

# install_deps: install the build/runtime dependencies from FORMULAE via
# Homebrew. Assumes install_homebrew has already put brew on PATH. brew is
# idempotent — already-installed formulae are reported and left as-is — and must
# never run under sudo (Homebrew refuses to run as root), so it runs as the
# invoking user.
install_deps() {
  banner "Install Dependencies"

  if ! confirm "Do you want to install package dependencies?"; then
    log "skipping package dependency install."
    return 0
  fi

  # Note which formulae aren't installed yet, so --undo removes only those and
  # leaves anything that was already present alone.
  local formula new=()
  for formula in "${FORMULAE[@]}"; do
    formula_installed "$formula" || new+=("$formula")
  done

  log "installing package dependencies (${#FORMULAE[@]} formulae)..."
  brew install "${FORMULAE[@]}"

  for formula in "${new[@]:-}"; do
    [ -n "$formula" ] && record "formula $formula"
  done
  log "package dependencies installed."
}

# install_oh_my_zsh: optionally install the oh-my-zsh framework on top of zsh.
# macOS already uses zsh as the default login shell, so there's no shell to
# switch — this just offers the framework as an optional enhancement. Idempotent:
# skips if ~/.oh-my-zsh already exists. Runs the official installer unattended so
# it doesn't try to chsh or exec a login zsh (which would hijack this script).
# The installer creates ~/.zshrc from its template, backing up any existing one
# to ~/.zshrc.pre-oh-my-zsh. Recorded for --undo, which removes ~/.oh-my-zsh and
# restores the backup. curl is not installed here (it ships with macOS).
install_oh_my_zsh() {
  banner "oh-my-zsh"

  if [ -d "$HOME/.oh-my-zsh" ]; then
    log "oh-my-zsh already installed ($HOME/.oh-my-zsh); skipping."
    return 0
  fi

  if ! confirm "zsh is already the default shell on macOS. Install oh-my-zsh on top of it?"; then
    log "skipping oh-my-zsh install."
    return 0
  fi

  log "installing oh-my-zsh ..."
  # --unattended sets CHSH=no and RUNZSH=no: don't touch the login shell (zsh is
  # already the macOS default) and don't drop into a new zsh at the end.
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  record "omz"

  # The installer replaces ~/.zshrc with its template, sweeping the `brew
  # shellenv` line install_homebrew added into ~/.zshrc.pre-oh-my-zsh. Re-add it
  # to the new ~/.zshrc so future shells still find Homebrew (and thus git, node,
  # ...) on PATH. Guarded so it's a no-op if brew isn't installed or the line
  # somehow survived.
  if have brew && ! grep -qF "brew shellenv" "$SHELL_RC" 2>/dev/null; then
    printf '\neval "$(%s shellenv)"\n' "$(command -v brew)" >>"$SHELL_RC"
    log "re-added brew shellenv to $SHELL_RC (the oh-my-zsh installer replaced it)."
  fi

  log "oh-my-zsh installed."
}

# configure_zsh_prompt: append a custom PROMPT as a shell-init block of ~/.zshrc.
# Runs right after install_oh_my_zsh so the block lands after oh-my-zsh's own
# config (which sets the theme's prompt), letting our PROMPT win. The later
# tool-init blocks (fnm, pyenv) are appended below it but don't touch PROMPT, so
# it stays the effective prompt. The prompt uses oh-my-zsh helpers ($fg,
# git_prompt_info), so we only add it when oh-my-zsh is present; otherwise the
# developer manages their own prompt. Idempotent and undo-aware via
# add_shell_init.
configure_zsh_prompt() {
  [ -d "$HOME/.oh-my-zsh" ] || return 0
  banner "Configure Zsh Prompt"
  if ! confirm "Set a custom zsh prompt?"; then
    log "skipping custom zsh prompt."
    return 0
  fi
  add_shell_init "zsh-prompt" \
    'PROMPT='\''[%m]%{$fg_bold[green]%}%p %{$fg[cyan]%}[%~]%{$reset_color%} $(git_prompt_info)%{$fg_bold[blue]%}% %{$reset_color%}'\'''
  log "custom zsh prompt written to $SHELL_RC."
}

# install_node: install fnm (Fast Node Manager) and the pinned Node.js
# ($NODE_VERSION), then set it as the default. fnm is the current recommendation
# for managing Node versions. Idempotent — skips the fnm install and the version
# install if they're already present. Relies on the LOGIN_SHELL/SHELL_RC globals
# set at the top of the script.
install_node() {
  banner "Install Node.js"

  if ! confirm "Install Node.js $NODE_VERSION via fnm?"; then
    log "skipping Node.js install."
    return 0
  fi

  # fnm itself, into ~/.fnm (both the binary and, via $FNM_DIR, the installed
  # Node versions, so --undo can remove everything by deleting one directory).
  # --skip-shell so we control the shell wiring ourselves (via add_shell_init),
  # consistent with pyenv. curl and unzip, which fnm's installer needs, ship
  # with macOS, so there's nothing to install first.
  local fnm_dir="$HOME/.fnm"
  if [ -x "$fnm_dir/fnm" ]; then
    log "fnm already installed ($fnm_dir); skipping."
  else
    log "installing fnm into $fnm_dir ..."
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$fnm_dir" --skip-shell
    record "fnm-root $fnm_dir"
  fi

  # Make fnm usable for the rest of this script.
  export PATH="$fnm_dir:$PATH"
  export FNM_DIR="$fnm_dir"

  # Wire fnm into future interactive shells now, before the (network-dependent)
  # version install below. Under `set -e` a failed `fnm install` would abort the
  # script, and if the wiring came afterward we'd leave the binary on disk but
  # off PATH — fnm unusable in new shells. The `[ -d "$FNM_DIR" ]` guard mirrors
  # fnm's own installer so the block is a no-op if the dir is ever removed.
  add_shell_init fnm \
    'export FNM_DIR="$HOME/.fnm"' \
    'if [ -d "$FNM_DIR" ]; then' \
    '  export PATH="$FNM_DIR:$PATH"' \
    "  eval \"\$(fnm env --use-on-cd --shell $LOGIN_SHELL)\"" \
    'fi'

  # Install the pinned Node version (idempotent).
  if fnm list 2>/dev/null | grep -q "v$NODE_VERSION"; then
    log "Node.js $NODE_VERSION already installed via fnm; skipping."
  else
    log "installing Node.js $NODE_VERSION with fnm..."
    fnm install "$NODE_VERSION"
    record "fnm-version $NODE_VERSION"
  fi
  fnm default "$NODE_VERSION"
  log "fnm default Node.js set to $NODE_VERSION."
}

# install_python: install pyenv and build the pinned CPython ($PYTHON_VERSION),
# then set it as the global version. Positron needs Python both to build against
# and to run against, and pyenv lets the developer manage/switch versions
# cleanly. Idempotent — skips the pyenv clone and the version build if they're
# already present.
install_python() {
  banner "Install Python"

  if ! confirm "Install Python $PYTHON_VERSION via pyenv?"; then
    log "skipping Python install."
    return 0
  fi

  # Homebrew formulae that pyenv links against when compiling CPython from source
  # (pyenv's macOS "suggested build environment"). python-build auto-detects
  # these Homebrew packages and wires in the right build flags. Only the ones not
  # already present are recorded, so --undo removes just what we added.
  local build_deps=(
    openssl@3 readline sqlite xz zlib tcl-tk
  )
  local formula new=()
  for formula in "${build_deps[@]}"; do
    formula_installed "$formula" || new+=("$formula")
  done
  if [ "${#new[@]}" -gt 0 ]; then
    log "installing ${#new[@]} pyenv build dependencies..."
    brew install "${build_deps[@]}"
    for formula in "${new[@]}"; do record "formula $formula"; done
  fi

  # pyenv itself, into ~/.pyenv (so --undo can remove it by deleting one dir).
  local pyenv_root="$HOME/.pyenv"
  if [ -d "$pyenv_root/.git" ]; then
    log "pyenv already installed ($pyenv_root); skipping clone."
  else
    log "installing pyenv into $pyenv_root ..."
    git clone --depth 1 https://github.com/pyenv/pyenv.git "$pyenv_root"
    record "pyenv-root $pyenv_root"
  fi

  # Make pyenv usable for the rest of this script.
  export PYENV_ROOT="$pyenv_root"
  export PATH="$PYENV_ROOT/bin:$PATH"

  # Build the pinned version. pyenv would skip an existing build itself, but the
  # explicit check keeps the log clean and avoids a needless rebuild.
  if pyenv versions --bare 2>/dev/null | grep -qx "$PYTHON_VERSION"; then
    log "Python $PYTHON_VERSION already installed via pyenv; skipping build."
  else
    log "building Python $PYTHON_VERSION with pyenv (this can take a few minutes)..."
    pyenv install "$PYTHON_VERSION"
    record "pyenv-version $PYTHON_VERSION"
  fi
  pyenv global "$PYTHON_VERSION"
  log "pyenv global Python set to $PYTHON_VERSION."

  # Wire pyenv into future interactive shells.
  add_shell_init pyenv \
    'export PYENV_ROOT="$HOME/.pyenv"' \
    '[ -d "$PYENV_ROOT/bin" ] && export PATH="$PYENV_ROOT/bin:$PATH"' \
    "eval \"\$(pyenv init - $LOGIN_SHELL)\""
}

# configure_ssh_key: ensure an ed25519 SSH key pair exists. Idempotent — if
# ~/.ssh/id_ed25519 is already there, leaves it alone. Otherwise generates one
# non-interactively (no passphrase), labelled with the git email if set. Then
# shows the public key, copies it to the clipboard, and points the developer at
# GitHub to register it.
configure_ssh_key() {
  local key="$HOME/.ssh/id_ed25519" comment pub

  banner "Setup SSH Keys"
  if [ -f "$key" ]; then
    log "SSH key already exists ($key); skipping generation."
  else
    log "generating an ed25519 SSH key ($key)..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    comment="$(git config --global user.email || true)"
    ssh-keygen -t ed25519 -f "$key" -N "" -C "$comment"
    log "SSH key created."
  fi

  pub="$(cat "${key}.pub")"
  printf '\n' >&2
  printf 'Your public SSH key (%s.pub):\n\n' "$key" >&2
  printf '%s\n\n' "$pub" >&2
  if clip_copy "$pub"; then
    printf 'It has been copied to your clipboard.\n' >&2
  fi
  printf '%sAdd it to GitHub here: %s%shttps://github.com/settings/ssh/new%s\n\n' "$ACCENT" "$RESET" "$CYAN" "$RESET" >&2
  while ! confirm "Have you added your SSH key to GitHub?"; do
    printf '%sWell, do it! Add your SSH key to GitHub, then confirm.%s\n' "$ACCENT" "$RESET" >&2
  done
}

# configure_git_identity: ensure git knows who's authoring commits. Always walks
# the developer through both fields, pre-filling any value that's already set so
# ENTER keeps it. This is the one place we ask the developer for personal info.
configure_git_identity() {
  local cur_name cur_email name email
  cur_name="$(git config --global user.name || true)"
  cur_email="$(git config --global user.email || true)"

  banner "Setup Git Identity"
  log "setting your git identity (used to author your commits)..."

  # Prompt for both, showing any existing value as the default. Only set (and
  # record for undo) fields that actually change, so we never unset or clobber an
  # identity the developer already had, and re-running is a no-op.
  ask_default "Your Git user.name" name "$cur_name"
  if [ "$name" != "$cur_name" ]; then
    git config --global user.name "$name"
    [ -z "$cur_name" ] && record "git-name"
  fi
  ask_default "Your Git user.email" email "$cur_email"
  if [ "$email" != "$cur_email" ]; then
    git config --global user.email "$email"
    [ -z "$cur_email" ] && record "git-email"
  fi
  log "git identity set to $name <$email>."
}

# install_vscode: optionally install the latest stable Visual Studio Code via
# Homebrew cask. Idempotent — skips if the cask is already installed. Recorded
# for --undo only when we newly install it.
install_vscode() {
  banner "Install Visual Studio Code"

  if ! confirm "Install Visual Studio Code?"; then
    log "skipping Visual Studio Code install."
    return 0
  fi

  if cask_installed visual-studio-code; then
    log "Visual Studio Code already installed; skipping."
    return 0
  fi

  log "installing Visual Studio Code (cask) ..."
  brew install --cask visual-studio-code
  record "cask visual-studio-code"
  log "Visual Studio Code installed."
}

# positron_parent_dir: prompt for a folder under ~/ (e.g. "Work" or "Code"),
# create it if missing (recorded for --undo), and echo it. Shared by the clone
# and fork paths, which put each repo checkout directly inside it.
positron_parent_dir() {
  local folder parent
  ask "Which folder under ~/ should the repos go in? (e.g. Work, Code)" folder
  parent="$HOME/$folder"
  if [ ! -d "$parent" ]; then
    log "creating $parent ..."
    mkdir -p "$parent"
    record "mkdir $parent"
  fi
  printf '%s\n' "$parent"
}

# clone_repo <url> <dest>: clone <url> into <dest> over SSH, unless a checkout is
# already there. Idempotent and recorded for --undo.
clone_repo() {
  local url="$1" dest="$2"
  if [ -d "$dest/.git" ]; then
    log "already cloned at $dest; skipping."
    return 0
  fi
  if [ -e "$dest" ]; then
    log "WARNING: $dest exists but isn't a git checkout; skipping."
    return 0
  fi
  log "cloning $url into $dest ..."
  git clone "$url" "$dest"
  record "clone $dest"
}

# clone_or_fork_positron: the final interactive step. Positron core developers
# clone the repos directly; community contributors fork first. Hands off to the
# matching function below.
clone_or_fork_positron() {
  banner "Clone or Fork Positron"
  log "Positron core developers can clone the repos directly; the community should fork."
  if confirm "Are you a Positron core developer? (No forks Positron to your account instead)"; then
    clone_positron
  else
    fork_positron
  fi
}

# clone_positron: for Positron core developers. Offers (one Y/n per repo) to clone
# each of the repos core developers work on ($CORE_REPOS) into a chosen folder
# under ~/. Repo URLs share POSITRON_URL's host/owner, so SETUP_POSITRON_URL
# overrides them all. Runs after configure_ssh_key so the SSH clones authenticate.
clone_positron() {
  banner "Clone Positron repos"

  local parent base name
  parent="$(positron_parent_dir)"
  base="${POSITRON_URL%/*}"   # e.g. git@github.com:posit-dev

  for name in "${CORE_REPOS[@]}"; do
    if confirm "Clone $name?"; then
      clone_repo "$base/$name.git" "$parent/$name"
    else
      log "skipping $name."
    fi
  done
  log "done. Your Positron repos are under $parent."
}

# fork_positron: for community contributors without push access. Points the
# developer at GitHub to create their own fork in the browser, then clones that
# fork over SSH (as origin) and adds the canonical repo as an `upstream` remote so
# they can pull updates. The fork on GitHub is left in place on --undo, like
# generated SSH keys.
fork_positron() {
  banner "Fork Positron"

  local slug repo user fork_page fork_url parent dest

  # Derive owner/repo and the browser "create fork" URL from POSITRON_URL, e.g.
  # git@github.com:posit-dev/positron.git -> posit-dev/positron.
  slug="${POSITRON_URL#*:}"; slug="${slug%.git}"
  repo="${slug##*/}"
  fork_page="https://github.com/$slug/fork"

  printf '\n' >&2
  printf '%sFork Positron on GitHub first: %s%s%s%s\n\n' "$ACCENT" "$RESET" "$CYAN" "$fork_page" "$RESET" >&2
  if clip_copy "$fork_page"; then
    printf 'That URL has been copied to your clipboard.\n' >&2
  fi
  while ! confirm "Have you created your fork on GitHub?"; do
    printf '%sGo create your fork at the URL above, then confirm.%s\n' "$ACCENT" "$RESET" >&2
  done

  ask "Your GitHub username (the owner of the fork)" user
  fork_url="git@github.com:$user/$repo.git"

  parent="$(positron_parent_dir)"
  dest="$parent/$repo"
  clone_repo "$fork_url" "$dest"

  # Wire up the canonical repo as `upstream` so the developer can pull updates
  # (idempotent; only when we have a checkout that doesn't already have it).
  if [ -d "$dest/.git" ] && ! git -C "$dest" remote | grep -qx upstream; then
    log "adding '$POSITRON_URL' as the 'upstream' remote ..."
    git -C "$dest" remote add upstream "$POSITRON_URL"
  fi
  log "forked. Your checkout is at $dest (origin = your fork, upstream = $slug)."

  # Point community contributors at where to go next.
  printf '\n' >&2
  printf '%sGetting started as a community contributor:%s\n' "$ACCENT" "$RESET" >&2
  printf '  Positron:     %s%s%s\n' "$CYAN" "https://github.com/$slug" "$RESET" >&2
  printf '  Contributing: %s%s%s\n\n' "$CYAN" "https://github.com/$slug/blob/main/CONTRIBUTING.md" "$RESET" >&2
}

# final_notice: the last thing main() does — a prominent boxed reminder that the
# shell-init/PATH changes (Homebrew, fnm, pyenv) apply to new shells. macOS
# already uses zsh as the login shell (no chsh), so there's no need to log out or
# reboot: sourcing ~/.zshrc — or opening a new terminal — is enough.
final_notice() {
  boxed_notice \
    "Setup complete!" \
    "" \
    "Load your new PATH and shell changes with:" \
    "    source ~/.zshrc" \
    "" \
    "(or just open a new terminal window.)"
}

# undo: reverse everything recorded in the manifest, then delete it. Only touches
# what this script created/installed; leaves pre-existing state untouched. Does
# not revert Homebrew updates/upgrades, and — like the Command Line Tools and
# generated SSH keys — leaves Homebrew itself in place.
undo() {
  banner "Undo macOS Positron Dev Setup"
  if [ ! -f "$MANIFEST" ]; then
    log "no manifest found ($MANIFEST); nothing to undo."
    return 0
  fi

  # --undo is a fresh, non-interactive run that hasn't sourced ~/.zshrc, and on
  # Apple silicon brew lives in /opt/homebrew, off the default PATH — so put it on
  # PATH for the uninstall steps below. If brew isn't installed, the formula/cask
  # removals simply no-op.
  if ! have brew; then
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi

  local line dir ver file name formulae=() casks=() dirs=()
  while IFS= read -r line; do
    case "$line" in
      "formula "*) formulae+=("${line#formula }") ;;
      "cask "*) casks+=("${line#cask }") ;;
      "mkdir "*) dirs+=("${line#mkdir }") ;;
      "omz")
        log "removing oh-my-zsh ..."
        rm -rf "$HOME/.oh-my-zsh"
        if [ -f "$HOME/.zshrc.pre-oh-my-zsh" ]; then
          log "restoring pre-oh-my-zsh ~/.zshrc ..."
          mv -f "$HOME/.zshrc.pre-oh-my-zsh" "$HOME/.zshrc"
        fi
        ;;
      "git-name")
        log "unsetting git user.name ..."
        git config --global --unset user.name || true
        ;;
      "git-email")
        log "unsetting git user.email ..."
        git config --global --unset user.email || true
        ;;
      "pyenv-version "*)
        ver="${line#pyenv-version }"
        log "uninstalling pyenv Python $ver ..."
        PYENV_ROOT="$HOME/.pyenv" PATH="$HOME/.pyenv/bin:$PATH" \
          pyenv uninstall -f "$ver" 2>/dev/null || true
        ;;
      "pyenv-root "*)
        dir="${line#pyenv-root }"
        log "removing pyenv ($dir) ..."
        rm -rf "$dir"
        ;;
      "fnm-version "*)
        ver="${line#fnm-version }"
        log "uninstalling Node.js $ver ..."
        FNM_DIR="$HOME/.fnm" PATH="$HOME/.fnm:$PATH" \
          fnm uninstall "$ver" 2>/dev/null || true
        ;;
      "fnm-root "*)
        dir="${line#fnm-root }"
        log "removing fnm ($dir) ..."
        rm -rf "$dir"
        ;;
      "shellinit "*)
        file="${line#shellinit }"
        log "removing our shell init from $file ..."
        # BSD sed (macOS) requires an explicit backup suffix after -i; '' means
        # edit in place with no backup.
        sed -i '' '/# >>> darwin-positron-dev-setup: /,/# <<< darwin-positron-dev-setup: /d' "$file" 2>/dev/null || true
        ;;
      "clone "*)
        dir="${line#clone }"
        log "removing cloned repo $dir ..."
        rm -rf "$dir"
        ;;
    esac
  done <"$MANIFEST"

  # Uninstall the formulae/casks we installed. Per item so one with a remaining
  # dependent doesn't block the rest, and never under sudo. Homebrew stays; brew
  # autoremove then drops any now-unused dependencies we pulled in.
  if [ "${#formulae[@]}" -gt 0 ]; then
    for name in "${formulae[@]}"; do
      log "uninstalling formula $name ..."
      brew uninstall --formula "$name" 2>/dev/null || true
    done
  fi
  if [ "${#casks[@]}" -gt 0 ]; then
    for name in "${casks[@]}"; do
      log "uninstalling cask $name ..."
      brew uninstall --cask "$name" 2>/dev/null || true
    done
  fi
  if [ "${#formulae[@]}" -gt 0 ] || [ "${#casks[@]}" -gt 0 ]; then
    log "removing now-unused Homebrew dependencies ..."
    brew autoremove 2>/dev/null || true
  fi

  # Remove folders we created, last, so any checkouts inside them (removed above)
  # are already gone. rmdir only deletes empty dirs, so a folder the developer
  # later put other work in is left untouched.
  for dir in "${dirs[@]:-}"; do
    [ -n "$dir" ] || continue
    rmdir "$dir" 2>/dev/null && log "removed $dir" || true
  done

  rm -f "$MANIFEST"
  rmdir "$STATE_DIR" 2>/dev/null || true
  log "undo complete."
}

# --- main -------------------------------------------------------------------

main() {
  banner "macOS Positron Dev Setup"
  # Homebrew first: its installer headlessly installs the Command Line Tools
  # (git, clang, headers) if missing, putting git on PATH for oh-my-zsh next.
  install_homebrew
  # oh-my-zsh replaces ~/.zshrc, so install_homebrew's `brew shellenv` line is
  # re-added inside install_oh_my_zsh afterward. fnm (install_node) wires itself
  # in later, so its block lands after the oh-my-zsh template and survives.
  install_oh_my_zsh
  configure_zsh_prompt
  install_deps
  install_node
  install_python
  # Identity before the SSH key, so the key is labelled with the git email.
  configure_git_identity
  configure_ssh_key
  install_vscode
  clone_or_fork_positron
  final_notice
}

case "${1:-}" in
  ""|--setup) main ;;
  --undo) undo ;;
  -h|--help) printf 'usage: %s [--undo]\n' "$0" ;;
  *) printf 'unknown option: %s\nusage: %s [--undo]\n' "$1" "$0" >&2; exit 2 ;;
esac
