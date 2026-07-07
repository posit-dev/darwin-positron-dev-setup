# darwin-positron-dev-setup

Scripts to configure a fresh macOS machine for [Positron](https://positron.posit.co)
development.

Supports macOS on both Apple silicon and Intel.

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

## Undoing the setup

Each run records what it actually installed or created in a per-machine manifest
(`~/Library/Application Support/darwin-positron-dev-setup/manifest`), and `--undo` reverses exactly
that. Pass it through the same one-liner — note the extra `setup` word, which is a
placeholder that has to be there (with `bash -c`, the first word after the script
becomes `$0`, so `--undo` alone would be swallowed and a normal setup would run
instead):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/posit-dev/darwin-positron-dev-setup/main/setup.sh)" setup --undo
```

`--undo` only reverses things a run on *this* machine recorded; it never touches
packages or checkouts that were already there, and it does not revert Homebrew
updates. Generated SSH keys (and any GitHub fork you created) are deliberately left
in place, since they may already be in use.

## What it does

- Installs the Xcode Command Line Tools (git, compilers, and headers) if they
  aren't already present — this runs first, since later steps need git.
- Installs [Homebrew](https://brew.sh) if it isn't already present, and wires it
  into your shell environment.
- Optionally updates and upgrades installed Homebrew packages.
- Installs all package dependencies.
- Optionally installs [oh-my-zsh](https://ohmyz.sh) on top of Zsh (the default
  shell on macOS).
- Installs Node.js via [fnm](https://github.com/Schniz/fnm) and sets it as the
  default.
- Installs Python via [pyenv](https://github.com/pyenv/pyenv) and sets it as the
  global version.
- Generates an ed25519 SSH key (if you don't already have one), shows it, copies
  it to your clipboard with `pbcopy`, and points you at GitHub to register it.
- Configures your git identity, prompting for your name and email (pre-filling
  anything that's already set).
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
- Optionally installs Visual Studio Code.
- Optionally enables Remote Login so the machine accepts incoming SSH connections
  (e.g. for VS Code Remote - SSH).
- If you're using oh-my-zsh, sets a custom shell prompt.

## Configuration

Override these with environment variables if you need to:

| Variable          | Default                                                        | What it controls                          |
| ----------------- | ------------------------------------------------------------- | ----------------------------------------- |
| `SETUP_REPO_URL`  | `https://github.com/posit-dev/darwin-positron-dev-setup.git`  | Repo cloned by the setup.                 |
| `SETUP_CLONE_DIR` | `~/darwin-positron-dev-setup`                                  | Where the repo is cloned.                 |
