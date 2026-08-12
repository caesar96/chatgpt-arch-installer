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
- Optionally enables native system window decorations on Linux

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

Download this repository, then run the installer from the repository directory:

```bash
chmod +x install-codex-app.sh
./install-codex-app.sh
```

The installer asks whether ChatGPT should use native system window decorations:

```text
Use native system window decorations for ChatGPT? [y/N]:
```

Answer `y` to enable the optional patch. The patch is applied after the
application payload is installed and after every `chatgpt update`. Answering
Enter or `n` leaves ChatGPT's default decorations unchanged. The preference is
stored in `~/.config/chatgpt/install.conf`.

Use an option to skip the prompt:

```bash
./install-codex-app.sh --native-window-decoration --directory "$HOME/Apps/chatgpt-linux"
./install-codex-app.sh --no-native-window-decoration --directory "$HOME/Apps/chatgpt-linux"
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

The command is installed at `~/.local/bin/chatgpt`. If the terminal reports `chatgpt: command not found`, add the user-local binary directory to the current shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add the same line to `~/.bashrc` or `~/.zshrc` to make it persistent for future terminal sessions. The desktop menu launcher uses an absolute path and does not depend on `PATH`.

Update the local installation:

```bash
chatgpt update
```

Override the stored preference for a particular update:

```bash
chatgpt update --native-window-decoration
chatgpt update --no-native-window-decoration
```

The override is saved and becomes the preference used by later updates.

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
  patch-native-decoration.py  Optional native-decoration patch, when enabled

~/.local/bin/chatgpt      Open and update command
~/.local/bin/patch-native-decoration.py  Patch helper for update overrides
~/.config/chatgpt/install.conf
~/.local/share/applications/chatgpt-local.desktop
```

The installer does not write to `/usr`, `/opt`, `/etc`, or system package databases.

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
- The native-decoration option requires `python3` and is matched to the
  packaged ChatGPT bundle; if an update changes the relevant Electron code,
  the installer refuses to apply an unsafe patch.
- The desktop launcher uses the chosen installation path, so moving the application directory manually requires reinstalling or updating the launcher configuration.

## License

This installer is provided under the MIT License. The ChatGPT/Codex application and its bundled components remain property of their respective copyright holders.
