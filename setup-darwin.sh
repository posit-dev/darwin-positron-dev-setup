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

# --- steps ------------------------------------------------------------------

# install_homebrew: ensure Homebrew is installed and on PATH, both for the rest
# of this run and for future shells. The official installer also bootstraps the
# Xcode Command Line Tools (clang, git, headers) if they're missing, so this is
# the effective entry point for the whole toolchain.
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
  log "oh-my-zsh installed."
}

# --- main -------------------------------------------------------------------

main() {
  banner "macOS Positron Dev Setup"
  # oh-my-zsh first: its installer replaces ~/.zshrc, so it must run before any
  # step that writes to it (install_homebrew wires in `brew shellenv`).
  install_oh_my_zsh
  install_homebrew
  install_deps
}

main "$@"
