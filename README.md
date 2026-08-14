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
- Optionally enables native Linux/KDE window decorations through external
  runtime injection, without modifying `app.asar`.
- Keeps the application menu inside the window as Electron's native Linux
  menu by default.
- Optionally exports the Electron application menu to KDE Plasma's Global Menu
  through a separate, opt-in `global-menu` patch.
- Provides themed `Help -> Check for Updates...` and native-decoration toggle
  items.
- Treats the downloaded application, including `app.asar`, as immutable vendor
  code. All patches live in the installed launcher/runtime layer.

## Requirements

The current package and installer target `x86_64` / `amd64` Linux with a
graphical desktop session, network access, and a user-writable installation
directory.

The installer checks for the host tools needed for extraction, dependency
inspection, desktop integration, and updates, including `curl`, `ar`, `tar`,
`xz`, `ldd`, `ldconfig`, `awk`, `readlink`, `ln`, `xdg-open`, and `xdg-mime`.
It also checks the GUI libraries required by Electron and the bundled Codex
runtime. Native window decorations do not require Python or system services.
The optional Global Menu patch uses a GLib DBusMenu exporter backed by
`libdbusmenu-glib`; KDE Plasma's Global Menu registrar must be available in
the session. It also requires Python GObject introspection with Dbusmenu 0.4.
The GTK `appmenu-gtk-module` is not required by ChatGPT's exporter; it is only
useful for other GTK applications.
The launcher sets Electron's `ELECTRON_FORCE_WINDOW_MENU_BAR=1` by default, so
the native application menu remains inside the ChatGPT window instead of being
registered with Plasma's Global Menu. The `global-menu` patch is disabled by
default; enable it with `chatgpt patches enable global-menu`.

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
chatgpt --debug                 # Launch with patch diagnostics enabled
chatgpt patches status          # Show enabled patches
chatgpt patches enable global-menu
chatgpt decorations enable      # Enable native window decorations
chatgpt decorations disable     # Disable native window decorations
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
chatgpt patches enable native-window-decorations
chatgpt patches enable mac-layout
chatgpt patches disable native-window-decorations
chatgpt --no-patches
```

The bundled external patches are:

- `global-menu`: exports ChatGPT's native Electron application menu to KDE
  Plasma's Global Menu through the system `libdbusmenu-glib` implementation.
  It keeps the menu synchronized and forwards menu activation back to
  Electron. It is intended for X11/XWayland sessions; explicit native
  Wayland launches are not supported by this exporter.
- `update-menu`: adds `Help -> Check for Updates...` and performs lightweight
  startup update checks.
- `native-window-decorations`: a complete native-decoration package. Its `index.js`
  coordinates the two parts below:
  - `window-decoration.js` intercepts Electron's `BrowserWindow` module before
    the vendor application receives it. It removes hidden title-bar options,
    forces `frame: true` for normal top-level windows, and ignores
    `setTitleBarOverlay`. When the Global Menu is disabled, it also preserves
    Electron's native in-window menu against the vendor's Linux `removeMenu()`
    call. Transparent, modal, parented, and utility windows are left unchanged.
  - `window-decoration-menu.js` adds the Help item and invokes the shared
    external helper to persist the preference and relaunch the app.
- `mac-layout`: selects the renderer's existing native/macOS-style chrome path
  on Linux without pretending the operating system is macOS. It uses
  Electron's external `addScriptToEvaluateOnNewDocument` hook; it does not
  edit `app.asar` or replace the vendor preload. When native window decorations
  are enabled, the loader applies this patch only while `global-menu` is also
  enabled; otherwise the renderer chrome would cover Electron's native
  in-window menu.

Patches are loaded through `NODE_OPTIONS` before the app's first real
`require('electron')`. The loader exposes an invariant-safe Electron module
proxy so the external decoration patch can replace `BrowserWindow` without
touching vendor files. A patch with an invalid manifest or startup exception
is skipped with a warning so it cannot make the app unlaunchable. Use
`chatgpt --debug` to write runtime diagnostics to
`<installation>/state/patch-diagnostic.log`.

## Update flow

`Help -> Check for Updates...` first checks HTTP metadata and only the beginning
of the Debian package. It uses the saved `ETag` and HTTP Range requests, so the
full package is not downloaded during a normal check.

When an update is accepted, the full package is downloaded with progress while
ChatGPT remains open. Before the replacement, the package is extracted and
its runtime dependencies are validated in an isolated staging directory. The
transactional replacement then installs the new vendor payload and external
runtime together; no file inside the vendor `app.asar` is unpacked, patched, or
repacked. The app reports every enabled patch as compatible or incompatible,
then offers `Restart Now` or `Later`.

The update state and temporary package are stored inside the selected
installation directory under `state/` and `update-cache/`. A staged update is
kept there until the replacement completes. Automatic checks
are limited to once per hour because they run during application startup, but
they only request package metadata rather than downloading the full package.
If a previous successful check already found a newer version, that cached
result is shown on startup even while the network check is throttled. Failed
network checks do not advance the successful-check timestamp.

The native-decoration toggle saves its preference in `settings.conf`, waits for
the current app process to exit, runs the shared `chatgpt decorations` command,
and relaunches through `bin/chatgpt-launcher`. The external injection is
therefore still present after the restart. Updating the vendor payload does not
require a post-update repatching step.

## Installed layout

The installed tree deliberately uses semantic names:

```text
<chosen-directory>/
  usr/                                  Downloaded application payload
  bin/chatgpt                            Public CLI and lifecycle command
  bin/chatgpt-launcher                   Electron process launcher
  lib/chatgpt-core.sh                    Shared shell implementation
  runtime/patch-loader.js                External patch loader
  runtime/settings.js                    Persistent runtime settings reader
  runtime/chatgpt-toggle-window-decorations.sh
                                        Native-decoration menu helper
  patches/update-menu/
  patches/native-window-decorations/
    index.js                            Patch entrypoint
    window-decoration.js                Electron window interception
    window-decoration-menu.js           Help menu integration
  patches/mac-layout/
    manifest.json                       Patch metadata
    index.js                            Renderer layout hook
  patches/global-menu/
    manifest.json                       Patch metadata
    index.js                            Electron menu bridge
  runtime/chatgpt-global-menu.py        GLib DBusMenu exporter
  state/
  update-cache/                         Downloaded package and staged updates

~/.local/bin/chatgpt                      Symlink to bin/chatgpt
~/.config/chatgpt/settings.conf           Installation settings
~/.config/chatgpt/user-data/              Electron profile and session data
~/.local/share/applications/chatgpt.desktop
```

`settings.conf` stores only installation state: the installation root, the
`use_system_window_decorations` preference, enabled patches, and installed
package version. Session and profile data live under `user-data/`, while Codex
data remains under `~/.codex`. The old `native_decorations` key is read as a
compatibility fallback and is written alongside the canonical setting so an
existing personal installation continues to work.

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
payload. Payload replacement is transactional: if extraction or support-file
installation fails, the previous payload is restored and temporary package
files are removed. Preserved user data is not part of the replacement
transaction. Debian maintainer scripts are never executed. The vendor payload,
including `app.asar`, is never modified by this project.

## Limitations

- Only the currently published `amd64` package URL is supported.
- Host GUI libraries are still required; the payload is not a complete system
  image.
- ChatGPT must be closed before replacing application files.
- Native decorations depend on the external Electron interception remaining
  compatible with the bundled runtime; failures fall back to the original
  window behavior and are visible with `chatgpt --debug`. The vendor `app.asar`
  is intentionally never modified.
- Moving the selected installation directory manually requires reinstalling
  or recreating the `~/.local/bin/chatgpt` symlink.

## License

This installer is provided under the MIT License. The ChatGPT/Codex
application and its bundled components remain property of their respective
copyright holders.
