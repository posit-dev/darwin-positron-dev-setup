#!/usr/bin/env bash
#
# setup.sh — Top-level entry point for Positron dev-machine setup on macOS.
#
# Verifies we're on macOS and invokes setup-darwin.sh. Any arguments are
# forwarded to it.
#
set -euo pipefail

# Directory this script lives in, so the sibling script resolves regardless of
# cwd. When piped straight into bash (`curl ... | bash`) there is no file on
# disk, so BASH_SOURCE is unset; fall back to "." (the cwd) in that case rather
# than tripping `set -u`. run_darwin then finds no sibling and downloads it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"

# Base URL for fetching the sibling script when this dispatcher is piped straight
# into bash (e.g. `curl ... | bash`) on a fresh Mac. In that case there is no
# checkout on disk, so setup-darwin.sh has to be downloaded. Override with
# SETUP_BASE_URL to test a fork or branch.
BASE_URL="${SETUP_BASE_URL:-https://raw.githubusercontent.com/posit-dev/darwin-positron-dev-setup/main}"

die() {
  printf '[setup] error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[setup] %s\n' "$*" >&2
}

# fetch <url>: write the contents of <url> to stdout using whatever HTTP client
# is available. curl ships with macOS, so it's our bootstrap tool before the rest
# of the toolchain exists.
fetch() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    die "need curl or wget to download $url"
  fi
}

# run_darwin [args...]: run setup-darwin.sh. Prefer the sibling file from a local
# checkout; otherwise download it (we were piped in via curl/wget).
run_darwin() {
  local script="$SCRIPT_DIR/setup-darwin.sh"

  if [ -f "$script" ]; then
    exec "$script" "$@"
  fi

  # No checkout on disk: fetch the script and run it via process substitution, so
  # bash reads the script from a file (not stdin). That leaves stdin alone and
  # the script's interactive prompts still read /dev/tty.
  local url="$BASE_URL/setup-darwin.sh"
  log "no local checkout; fetching $url ..."
  exec bash <(fetch "$url") "$@"
}

main() {
  [ "$(uname -s)" = "Darwin" ] || die "this setup only supports macOS (uname is '$(uname -s)')."
  run_darwin "$@"
}

main "$@"
