# ChatGPT Linux Installer

A user-level installer for the official OpenAI ChatGPT/Codex Linux `.deb` package.

The package is currently distributed as an `amd64` Debian package. This installer extracts the package directly instead of installing it with `dpkg` or `apt`, so the application stays self-contained in a directory chosen by the user.

## Features

- Interactive installation directory selection
- No `sudo`, root access, or global package installation
- Downloads the latest official `.deb` package
- Extracts the application payload locally
- Checks architecture, host tools, GUI libraries, and bundled runtime binaries
- Creates a user-level `chatgpt` command
- Makes `chatgpt` open the current terminal directory as a project
- Makes `chatgpt update` update the local application
- Preserves the local application profile and login data during updates
- Creates a user-level desktop launcher
- Leaves an existing system or user `codex` CLI installation unchanged

## Requirements

The installer currently targets:

- 64-bit x86 Linux (`x86_64` / `amd64`)
- A graphical desktop session
- A user-writable installation directory
- Network access to download the package

The installer checks for these host tools:

`curl`, `ar`, `tar`, `xz`, `mktemp`, `ldd`, `ldconfig`, `awk`, `readlink`, `xdg-open`, and `xdg-mime`.

It also checks the GUI libraries required by the Electron application and verifies the dynamic dependencies of the bundled Electron and Codex executables. On CachyOS, these are normally provided by the standard desktop and multimedia packages.

The desktop app includes its own Codex runtime. A separate `codex` command is not required for the desktop app. If an existing `codex` CLI is detected, the installer reports it and does not modify it.

## Installation

Download this repository or copy `install-codex-app.sh`, then run:

```bash
chmod +x install-codex-app.sh
./install-codex-app.sh
```

The script asks where to install the application. Press Enter to accept the default:

```text
~/Apps/chatgpt-linux
```

You can also provide a directory directly:

```bash
./install-codex-app.sh --directory "$HOME/Apps/chatgpt-linux"
```

Run the dependency check without downloading or installing anything:

```bash
./install-codex-app.sh --check
```

## Usage After Installation

Open ChatGPT in the current terminal directory:

```bash
chatgpt
```

This is intended to behave like `code .`: it uses the desktop app's `--open-project` option.

Update the local installation:

```bash
chatgpt update
```

ChatGPT must be closed before updating. The update downloads the latest package, validates it, replaces only the application payload, and keeps the local profile directory.

Show command help:

```bash
chatgpt --help
```

## Files Created

The installer creates these user-level files:

```text
<chosen-directory>/
  usr/                    Extracted application payload
  user-data/              Electron profile and session data
  run-chatgpt              Local application launcher

~/.local/bin/chatgpt      Open and update command
~/.config/chatgpt/install.conf
~/.local/share/applications/chatgpt-local.desktop
```

The installer does not write to `/usr`, `/opt`, `/etc`, or system package databases.

## Live ISO Testing

On a CachyOS live ISO, install or copy the script and run the dependency check first:

```bash
./install-codex-app.sh --check
```

If it reports missing tools or libraries, install the corresponding packages in the live session and run the check again. The live environment is temporary, so the installation and login profile will disappear after reboot unless the environment has persistence.

## Package Source

The installer downloads the latest package from the official OpenAI CDN:

```text
https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
```

The Debian package's installation scripts are intentionally not executed. This avoids automatic repository, AppArmor, and system-level package configuration.

## Limitations

- Only `amd64` / `x86_64` is supported by the current package URL.
- Host GUI libraries are still required; the application payload is self-contained, not a complete Linux system image.
- The updater requires ChatGPT to be closed.
- The desktop launcher uses the chosen installation path, so moving the application directory manually requires reinstalling or updating the launcher configuration.

## License

This installer is provided under the MIT License. The ChatGPT/Codex application and its bundled components remain property of their respective copyright holders.
