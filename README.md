# ChatGPT Linux Installer

A user-level installer for the official OpenAI ChatGPT/Codex Linux `.deb`
package, intended for Arch-based distributions such as CachyOS.

The installer extracts the official `amd64` Debian package directly. It does
not use `dpkg`, `apt`, AUR build scripts, `sudo`, or system package databases.

## Features

- Installs the application into a user-selected directory.
- Provides one public `chatgpt` command for launching and managing the app.
- Preserves the local profile and authentication data during updates.
- Supports `chatgpt update`, `check-update`, `patches`, and `uninstall`.
- Adds a user-level `chatgpt.desktop` launcher matching the package name.
- Optionally enables native Linux window decorations.
- Provides a themed `Help -> Check for Updates...` workflow.
- Keeps all optional patches outside the downloaded `app.asar`.

## Requirements

The current package and installer target `x86_64` / `amd64` Linux with a
graphical desktop session, network access, and a user-writable installation
directory.

The installer checks for the host tools needed for extraction, dependency
inspection, desktop integration, and updates, including `curl`, `ar`, `tar`,
`xz`, `ldd`, `ldconfig`, `awk`, `readlink`, `ln`, `xdg-open`, and `xdg-mime`.
It also checks the GUI libraries required by Electron and the bundled Codex
runtime. Native window decorations additionally require `python3`.

## Installation

Run the bootstrap installer from this repository:

```bash
chmod +x install-chatgpt.sh
./install-chatgpt.sh
```

The default installation directory is:

```text
~/Apps/chatgpt-linux
```

You can select a directory explicitly or run the dependency check without
downloading anything:

```bash
./install-chatgpt.sh --directory "$HOME/Apps/chatgpt-linux"
./install-chatgpt.sh --check
```

Native window decorations can be selected non-interactively:

```bash
./install-chatgpt.sh --native-window-decoration --directory "$HOME/Apps/chatgpt-linux"
./install-chatgpt.sh --no-native-window-decoration --directory "$HOME/Apps/chatgpt-linux"
```

`install-chatgpt.sh` is only the initial installation entrypoint. After
installation, all normal operations belong to the `chatgpt` command.
Interactive installer output highlights important paths and commands; set
`NO_COLOR=1` to disable ANSI colors.

## Usage

```bash
chatgpt                         # Open the current directory as a project
chatgpt [APP_OPTIONS...]        # Launch with app arguments
chatgpt update                  # Download and install the latest version
chatgpt check-update            # Check package metadata only
chatgpt patches status          # Show enabled patches
chatgpt uninstall               # Remove the app but preserve user data
chatgpt uninstall --no-preserve-data
chatgpt --help
```

The command is installed as a symlink at `~/.local/bin/chatgpt`. If that
directory is not already in `PATH`, add it for the current shell and then to
your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Update preferences can be overridden for one update and are then saved:

```bash
chatgpt update --native-window-decoration
chatgpt update --no-native-window-decoration
```

## Patch management

```bash
chatgpt patches list
chatgpt patches status
chatgpt patches enable update-menu
chatgpt patches disable native-window-decorations
chatgpt --no-patches
```

The two bundled patches are:

- `update-menu`: adds the update and native-decoration actions to the Help
  menu and performs lightweight startup update checks, throttled to once per
  hour.
- `native-window-decorations`: records the native-decoration capability. The
  stable implementation remains the verified exact-match ASAR patch.

Patches are loaded through `NODE_OPTIONS` before the app's first real
`require('electron')`. A patch with an invalid manifest, incompatible version,
or startup exception is skipped with a warning so it cannot make the app
unlaunchable.

## Update flow

`Help -> Check for Updates...` first checks HTTP metadata and only the beginning
of the Debian package. It uses the saved `ETag` and HTTP Range requests, so the
full package is not downloaded during a normal check.

When an update is accepted, the full package is downloaded with progress while
ChatGPT remains open. Before the replacement, the package is extracted, its
runtime dependencies are validated, and the selected native-decoration patch
is tested against the new `app.asar` in an isolated staging directory. The
transactional replacement then happens while the current process is still
running; existing processes keep their already-loaded code, and the next
launch uses the new payload. The app reports every enabled patch as compatible
or incompatible. Incompatible patches can be disabled explicitly before
continuing, and the app then offers `Restart Now` or `Later`.

The update state and temporary package are stored inside the selected
installation directory under `state/` and `update-cache/`. A staged update is
kept there until the replacement completes. Automatic checks
are limited to once per hour because they run during application startup, but
they only request package metadata rather than downloading the full package.
If a previous successful check already found a newer version, that cached
result is shown on startup even while the network check is throttled. Failed
network checks do not advance the successful-check timestamp.

The native-decoration toggle still uses a short-lived helper and records its
lifecycle in `state/update-from-menu.log` and
`state/update-from-menu.status` (`running`, `success`, or `failed:*`). On
Linux that helper is launched as a transient `systemd --user` service so it is
not terminated with the desktop application's process group; a detached
fallback is used when a user service manager is unavailable.

## Installed layout

The installed tree deliberately uses semantic names:

```text
<chosen-directory>/
  usr/                                  Downloaded application payload
  bin/chatgpt                            Public CLI and lifecycle command
  bin/chatgpt-launcher                   Electron process launcher
  lib/chatgpt-core.sh                    Shared shell implementation
  runtime/patch-loader.js                External patch loader
  runtime/chatgpt-update-from-menu.sh    Menu update helper
  runtime/chatgpt-toggle-native-decorations.sh
  runtime/chatgpt-native-window-decorations.py
  patches/update-menu/
  patches/native-window-decorations/
  state/
  update-cache/                         Downloaded package and staged updates

~/.local/bin/chatgpt                      Symlink to bin/chatgpt
~/.config/chatgpt/settings.conf           Installation settings
~/.config/chatgpt/user-data/              Electron profile and session data
~/.local/share/applications/chatgpt.desktop
```

`settings.conf` stores the installation root, native-decoration preference,
enabled patches, and installed package version. The installer intentionally
does not contain compatibility code for older layouts.

When replacing an older personal installation, run its existing
`chatgpt uninstall` first, preserving the profile and configuration. Before
running the new bootstrap, rename the preserved configuration file:

```bash
config_directory="${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt"
mv "$config_directory/install.conf" "$config_directory/settings.conf"
```

If that older installation stored the profile inside its application
directory, move it to the new user-data location before reinstalling:

```bash
old_installation="$HOME/Apps/ChatGPT"
mkdir -p "$config_directory"
mv "$old_installation/user-data" "$config_directory/user-data"
```

The new installer will rewrite `settings.conf` with the current patch names
and package version after installation. If `settings.conf` already exists,
only the profile move is needed.

The default uninstall preserves `~/.config/chatgpt/user-data`, `~/.codex`,
and the ChatGPT configuration directory. The explicit
`--no-preserve-data` option removes those data paths as well.

Because the profile is stored outside the application root, choosing a
different installation directory on a later install does not require moving
the ChatGPT session or user data.

The desktop entry is named `chatgpt.desktop`, matching the official `.deb`.
The application icon is read from the extracted package payload.

## Package source and safety model

The package is downloaded from the official OpenAI CDN:

```text
https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
```

The installer validates the package name, architecture, Debian metadata,
required payload files, and dynamic dependencies before replacing an existing
payload. Payload replacement is transactional: if extraction, support-file
installation, or the native-decoration patch fails, the previous payload is
restored and temporary package files are removed. Preserved user data is not
part of the replacement transaction. Debian maintainer scripts are never
executed.

The native-decoration patch uses exact byte matches, version/hash-specific
backups, a lock, and atomic writes. If the packaged code no longer matches the
verified build, the patch refuses to modify the ASAR archive.

## Limitations

- Only the currently published `amd64` package URL is supported.
- Host GUI libraries are still required; the payload is not a complete system
  image.
- ChatGPT must be closed before replacing application files.
- Native decorations are tied to the verified packaged application build.
- Moving the selected installation directory manually requires reinstalling
  or recreating the `~/.local/bin/chatgpt` symlink.

## License

This installer is provided under the MIT License. The ChatGPT/Codex
application and its bundled components remain property of their respective
copyright holders.
