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
- Installs an app-local `installer` backend and a user-level `chatgpt` wrapper
- Preserves the local application profile and login data during updates
- Creates a user-level desktop launcher
- Leaves an existing system or user `codex` CLI installation unchanged
- Optionally enables native system window decorations on Linux
- Keeps optional patches outside the downloaded `app.asar`
- Adds a themed `Help -> Check for Updates...` workflow without closing the app during the check
- Checks for updates after launch without downloading the full package

## Requirements

The installer currently targets:

- 64-bit x86 Linux (`x86_64` / `amd64`)
- A graphical desktop session
- A user-writable installation directory
- Network access to download the package

The installer checks for these host tools:

`curl`, `ar`, `tar`, `xz`, `mktemp`, `ldd`, `ldconfig`, `awk`, `sort`, `sed`, `tr`, `readlink`, `cat`, `date`, `dd`, `wc`, `xdg-open`, and `xdg-mime`.

It also checks the GUI libraries required by the Electron application and verifies the dynamic dependencies of the bundled Electron and Codex executables. On CachyOS, these are normally provided by the standard desktop and multimedia packages.

The desktop app includes its own Codex runtime. A separate `codex` command is not required for the desktop app. If an existing `codex` CLI is detected, the installer reports it and does not modify it.

Native window decorations additionally require `python3`. New installations enable the `update-ui` patch by default; `native-decoration` remains optional.

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

Answer `y` to enable the optional patch. The installer stores external patch
modules outside `app.asar` and enables them at launch. It also retains the
verified exact-match ASAR patch as a fallback for native decorations, because
Electron does not guarantee that a main-process preload can replace every
application import. Answering Enter or `n` leaves ChatGPT unchanged.

The update menu patch is enabled for every new installation independently of
this preference. It adds the update and native-decoration controls to the
application menu while keeping the downloaded application payload unchanged.

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

The installed `chatgpt` command is a small wrapper around the app-local
`<chosen-directory>/installer` script. This keeps updates and patch management
bound to the selected installation instead of depending on the repository
remaining in place.

### `chatgpt` Wrapper Behavior

The wrapper reads the installation root from `~/.config/chatgpt/install.conf`
and reads the enabled patch list and native-decoration preference from the
same file. It then routes commands as follows:

| Invocation | Behavior |
| --- | --- |
| `chatgpt` | Launches ChatGPT with `--open-project "$PWD"`. |
| `chatgpt [APP_OPTIONS...]` | Launches ChatGPT with the supplied Electron/app arguments. |
| `chatgpt update [OPTIONS...]` | Runs the app-local installer backend and replaces the application payload after ChatGPT is closed. |
| `chatgpt check-update` | Checks remote package metadata without downloading the full `.deb`. |
| `chatgpt patches ...` | Lists, reports, enables, or disables external patches. |
| `chatgpt --no-patches [APP_OPTIONS...]` | Launches once without loading external patches. |
| `chatgpt --help` | Shows the installed command help through the app-local backend. |

For a normal launch, the wrapper exports the selected patch configuration and
preloads `external/runtime/patch-loader.js` through `NODE_OPTIONS`. Update and
patch-management commands do not preload the Electron patches; they execute
the app-local `installer` script directly. This prevents the management
commands from modifying their own behavior through the UI patch.

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

Manage external patches:

```bash
chatgpt patches list
chatgpt patches status
chatgpt patches enable update-ui
chatgpt patches disable native-decoration
chatgpt --no-patches
```

`--no-patches` disables external patches for that launch only.

### External Patch System

Patches live outside the downloaded `app.asar` under:

```text
<chosen-directory>/external/patches/<patch-name>/
  manifest.json
  main.js
```

The loader runs once, before the application's first real
`require('electron')`, and invokes each enabled patch in the order listed in
`patches=` in `install.conf`. For every patch it validates:

- The patch name contains only lowercase letters, digits, and hyphens.
- The manifest `id`, `entry`, and API version are valid.
- The installed ChatGPT compatibility version is listed in
  `applicationVersions`, when that field is present.
- The installed Electron compatibility version is listed in
  `electronVersions`, when that field is present.

If a patch is missing, malformed, incompatible, or throws during startup, the
loader emits a warning and skips that patch. It does not make ChatGPT
unlaunchable. A patch can therefore be disabled or removed independently of
the downloaded application payload.

#### `update-ui`

`update-ui` modifies the native Electron application menu and adds:

- `Help -> Check for Updates...`
- `Help -> Enable Native Window Decorations` or `Disable Native Window Decorations`

The update item starts the app-local `installer check-update` command. That
command sends a conditional `HEAD` request using the saved `ETag`, then reads
only the beginning of the Debian package with an HTTP Range request. It parses
the small `control` archive and compares its `Version` with
`package_version` in `install.conf`. It does not download the full package,
replace files, or close ChatGPT during this phase.

The patch also starts a quiet update check a few seconds after ChatGPT opens.
Automatic checks are limited to once every 24 hours, ignore network errors, and
show a dialog only when a newer version is found. Manual checks from the Help
menu are immediate and still report the up-to-date or error state.

The patch displays themed child windows parented to the main ChatGPT window.
The progress window and result window are centered against the main window,
stay above it, and follow the system light/dark appearance. An available
update is offered as `Update Now` or `Later`; `Update Now` downloads the full
package with progress and then starts `external/runtime/update-from-menu.sh`.

#### `native-decoration`

`native-decoration` is an external compatibility marker for the native
decoration feature. The actual stable behavior is implemented by the verified
exact-match `patch-native-decoration.py` ASAR patch because there is no stable
Electron main-process plugin API for replacing the relevant application
imports.

Enabling or disabling this patch applies or restores the exact ASAR patch,
updates `native_decorations=1|0` in `install.conf`, and requires a restart.
The ASAR helper creates a version/hash-specific backup, refuses unknown or
partially patched bundles, and uses atomic writes. If an update cannot apply
the patch safely, the installer restores the previous application payload.

ChatGPT must be closed before updating. The command-line update downloads the latest package, validates it, replaces only the application payload, and keeps the local profile directory.

### Menu Update Flow

`Help -> Check for Updates...` follows this sequence:

1. Opens a progress window parented to and centered on the ChatGPT window.
2. Sends a conditional metadata request and reads only the package header/control data while ChatGPT remains open.
3. Reports that ChatGPT is up to date without closing the app, or shows the installed and available versions.
4. Offers `Update Now` and `Later` when an update is available.
5. On `Update Now`, opens a download progress window and downloads the full package in HTTP Range chunks.
6. After the progress reaches 100%, closes ChatGPT, installs the package, and relaunches the app normally.

The progress and result windows use native Electron child-window behavior, stay above the main window, and use the current light/dark system appearance. `Later` only closes the result window; it does not install anything.

The update metadata is stored under `<chosen-directory>/state/update-check.meta`.
The full package is stored under `<chosen-directory>/update-cache` only after
`Update Now` is selected. It is removed after a successful installation or when
the downloaded package is no longer newer. Keep enough free space for the
downloaded package and temporary extraction.

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
  installer               App-local installer/update backend
  external/runtime/patch-loader.js
  external/runtime/update-from-menu.sh
  external/runtime/toggle-native-decoration.sh
  external/patches/native-decoration/manifest.json
  external/patches/native-decoration/main.js
  external/patches/update-ui/manifest.json
  external/patches/update-ui/main.js
  update-cache/          Full package during an accepted update
  state/                  Update metadata, status, and logs
  patch-native-decoration.py  Verified ASAR fallback, when enabled

~/.local/bin/chatgpt      Open and update command
~/.local/bin/patch-native-decoration.py  ASAR fallback patch helper
~/.config/chatgpt/install.conf
~/.local/share/applications/chatgpt-local.desktop
```

`install.conf` records the selected installation root, the native-decoration
preference, enabled patches, and the installed Debian package version. The
installer does not modify `~/.codex/auth.json`; that file remains available to
the bundled Codex runtime and preserves the existing authenticated session.

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
- The installation backend requires ChatGPT to be closed while replacing the payload; the menu checker and downloader keep ChatGPT open until the download reaches 100%.
- The native-decoration option requires `python3` and is matched to the
  packaged ChatGPT bundle; if an update changes the relevant Electron code,
  the installer refuses to apply an unsafe patch.
- The external native-decoration module is intentionally passive for now; the
  verified exact-match ASAR patch remains the implementation because Electron
  does not provide a stable external main-process plugin API.
- Enabling `update-ui` adds `Help -> Check for Updates...` and a throttled
  startup check. Checks use `ETag`, HTTP Range, and Debian control metadata, so
  they do not download the full package. Selecting `Update Now` downloads the
  package with a progress dialog, then closes, updates, and relaunches ChatGPT.
  The menu patch is supported only for the application/Electron versions in its
  manifest.
- New installations enable `update-ui` by default so the update and decoration
  controls are available immediately; `native-decoration` remains opt-in.
- The current patch manifests are verified for ChatGPT/Electron compatibility
  identifier `42.3.0`; the Debian package version is read from package metadata
  and is not hardcoded in the updater.
- The desktop launcher uses the chosen installation path, so moving the application directory manually requires reinstalling or updating the launcher configuration.

## License

This installer is provided under the MIT License. The ChatGPT/Codex application and its bundled components remain property of their respective copyright holders.
