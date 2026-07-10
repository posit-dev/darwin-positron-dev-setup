# darwin-positron-dev-setup

Scripts to configure a fresh macOS machine for [Positron](https://positron.posit.co)
development.

Supports macOS on Apple silicon.

## Quick start

Run the setup script using `curl`:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/posit-dev/darwin-positron-dev-setup/main/setup.sh)"
```

This downloads the script in full before running it, so a dropped connection can't
leave you executing a half-downloaded script.

That single command installs everything you need for Positron development on macOS.
The only things it asks you are personal (your name and email, for git). The scripts
are idempotent, so re-running is safe.

## What it does

- Installs [Homebrew](https://brew.sh) if it isn't already present, and wires it
  into your shell environment. This runs first because the Homebrew installer
  also installs the Xcode Command Line Tools (git, compilers, and headers) when
  they're missing — headlessly, without the `xcode-select --install` GUI dialog.
  If Homebrew is already installed, offers to update it and upgrade its packages.
- Optionally installs [oh-my-zsh](https://ohmyz.sh) on top of Zsh (the default
  shell on macOS).
- If oh-my-zsh is installed, optionally sets a custom shell prompt.
- Installs the Homebrew formulae Positron needs to build.
- Installs Node.js via [fnm](https://github.com/Schniz/fnm) and sets it as the
  default.
- Installs Python via [uv](https://docs.astral.sh/uv/) and makes it your default
  `python`/`python3`.
- Configures your git identity, prompting for your name and email (pre-filling
  anything that's already set).
- Generates an ed25519 SSH key (if you don't already have one), shows it, copies
  it to your clipboard with `pbcopy`, and points you at GitHub to register it.
- Offers GUI apps via Homebrew cask, one Y/n prompt each (currently Google Chrome).
- Optionally installs Visual Studio Code.
- Sets up Positron under a folder you choose under `~/`, asking whether you're a
  Positron core developer:
  - **Core developers** get a Y/n prompt to clone each of the core repos
    (`positron`, `positron-codicons`, `positron-builds`, `positron-website`,
    `positron-wiki`).
  - **Community contributors** are pointed to GitHub to fork Positron, then have
    their fork cloned with the canonical repo added as an `upstream` remote, and
    are shown links to [Positron](https://github.com/posit-dev/positron) and its
    [contributing guide](https://github.com/posit-dev/positron/blob/main/CONTRIBUTING.md)
    to get started.

  Existing checkouts are left alone.
- Finishes by reminding you to open a new terminal (or run `source ~/.zshrc`) so
  the new PATH and shell changes take effect.
