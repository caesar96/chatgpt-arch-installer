#!/bin/sh
set -eu

PACKAGE_URL=${CHATGPT_PACKAGE_URL:-https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb}
PACKAGE_NAME=chatgpt_amd64.deb
CONFIG_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt/install.conf
DESKTOP_FILE=${XDG_DATA_HOME:-$HOME/.local/share}/applications/chatgpt-local.desktop
COMMAND_PATH=$HOME/.local/bin/chatgpt
DEFAULT_ROOT=$HOME/Apps/chatgpt-linux
NATIVE_DECORATION_PATCH=patch-native-decoration.py
NATIVE_DECORATION_OVERRIDE=
PATCHES=
INSTALLED_PACKAGE_VERSION=

die() {
  printf 'chatgpt: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: install-codex-app.sh [DIRECTORY]' \
    '       install-codex-app.sh --directory DIRECTORY' \
    '       install-codex-app.sh --native-window-decoration [DIRECTORY]' \
    '       install-codex-app.sh --no-native-window-decoration [DIRECTORY]' \
    '       install-codex-app.sh --check' \
    '' \
    'Install the ChatGPT/Codex desktop app locally from the latest amd64 DEB.' \
    'No root privileges or system package installation are required.' \
    'The installer can optionally enable native system window decorations.'
}

chatgpt_usage() {
  printf '%s\n' \
    'Usage: chatgpt [--no-patches] [update [DECORATION_OPTION]]' \
    '  chatgpt         Open ChatGPT in the current terminal directory' \
    '  chatgpt update  Download and install the latest app version' \
    '  chatgpt patches [list|status|enable NAME|disable NAME]' \
    '  chatgpt --no-patches  Launch once without external patches' \
    '  DECORATION_OPTION: --native-window-decoration or --no-native-window-decoration' \
    '  NAME: native-decoration or update-ui'
}

resolve_self_path() {
  SELF_PATH=$0
  case "$SELF_PATH" in
    */*) ;;
    *)
      resolved_path=$(command -v -- "$SELF_PATH" 2>/dev/null || true)
      [ -n "$resolved_path" ] || resolved_path=$SELF_PATH
      SELF_PATH=$resolved_path
      ;;
  esac
  case "$SELF_PATH" in
    /*) ;;
    *) SELF_PATH=$(CDPATH= cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)/$(basename -- "$SELF_PATH") ;;
  esac
  [ -f "$SELF_PATH" ] || die "installer script cannot be found at $SELF_PATH"
  INSTALLER_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$SELF_PATH")" && pwd -P) \
    || die 'cannot determine the installer directory'
}

check_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "this package is amd64, but the current architecture is $(uname -m)" ;;
  esac
}

require_host_tools() {
  missing_tools=
  for tool in curl ar tar xz mktemp ldd ldconfig awk sort sed readlink cp chmod mkdir mv dirname basename id uname pwd rm ls xdg-open xdg-mime; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools="$missing_tools $tool"
    fi
  done
  if [ -n "$missing_tools" ]; then
    printf 'chatgpt: missing host tools:%s\n' "$missing_tools" >&2
    printf '%s\n' 'Install the corresponding CachyOS/Arch packages, then rerun this script.' >&2
    return 1
  fi
}

set_native_decoration_override() {
  requested_value=$1
  if [ -n "$NATIVE_DECORATION_OVERRIDE" ] && [ "$NATIVE_DECORATION_OVERRIDE" != "$requested_value" ]; then
    die 'conflicting native decoration options'
  fi
  NATIVE_DECORATION_OVERRIDE=$requested_value
}

parse_native_decoration_option() {
  case "$1" in
    --native-window-decoration)
      set_native_decoration_override 1
      return 0
      ;;
    --no-native-window-decoration)
      set_native_decoration_override 0
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ask_native_decoration_preference() {
  if [ -n "$NATIVE_DECORATION_OVERRIDE" ]; then
    NATIVE_DECORATIONS=$NATIVE_DECORATION_OVERRIDE
    return 0
  fi
  NATIVE_DECORATIONS=0
  printf '%s' 'Use native system window decorations for ChatGPT? [y/N]: '
  IFS= read -r native_decoration_answer \
    || die 'could not read native decoration preference'
  case "$native_decoration_answer" in
    y|Y|yes|Yes|YES) NATIVE_DECORATIONS=1 ;;
  esac
}

require_native_decoration_tools() {
  [ "$NATIVE_DECORATIONS" -eq 0 ] && return 0
  command -v python3 >/dev/null 2>&1 \
    || die 'native window decorations require python3'
  if [ -r "$INSTALLER_DIRECTORY/$NATIVE_DECORATION_PATCH" ]; then
    return 0
  fi
  if [ -n "${APP_ROOT-}" ] && [ -r "$APP_ROOT/$NATIVE_DECORATION_PATCH" ]; then
    return 0
  fi
  die "native decoration patch script is missing: $NATIVE_DECORATION_PATCH"
}

check_host_libraries() {
  library_cache=$(ldconfig -p 2>/dev/null || true)
  missing_libraries=
  required_libraries='libgtk-3.so.0 libnotify.so.4 libnss3.so libatk-bridge-2.0.so.0 libatk-1.0.so.0 libatspi.so.0 libdrm.so.2 libgbm.so.1 libxcb-dri3.so.0 libasound.so.2 libcairo.so.2 libcups.so.2 libdbus-1.so.3 libexpat.so.1 libgcc_s.so.1 libgdk_pixbuf-2.0.so.0 libGL.so.1 libglib-2.0.so.0 libgraphite2.so.3 libnspr4.so libpango-1.0.so.0 libssl.so.3 libstdc++.so.6 libudev.so.1 libusb-1.0.so.0 libX11.so.6 libX11-xcb.so.1 libxcb.so.1 libXcomposite.so.1 libXdamage.so.1 libXext.so.6 libXfixes.so.3 libxkbcommon.so.0 libXrandr.so.2'

  for required_library in $required_libraries; do
    if ! printf '%s\n' "$library_cache" | awk -v lib="$required_library" '$1 == lib && /x86-64/ {found=1} END {exit !found}'; then
      missing_libraries="$missing_libraries $required_library"
    fi
  done

  if [ -n "$missing_libraries" ]; then
    printf 'chatgpt: missing host libraries:%s\n' "$missing_libraries" >&2
    printf '%s\n' 'The app payload is local, but these GUI libraries must exist on the host.' >&2
    return 1
  fi
}

check_desktop_helpers() {
  for helper in gio kioclient6 kioclient trash; do
    command -v "$helper" >/dev/null 2>&1 && return 0
  done
  printf '%s\n' 'chatgpt: missing desktop trash helper (gio, kioclient6, kioclient, or trash)' >&2
  printf '%s\n' 'The app may still launch, but delete-to-trash integration will be unavailable.' >&2
  return 1
}

check_binary_dependencies() {
  binary=$1
  ldd_status=0
  ldd_output=$(ldd "$binary" 2>&1) || ldd_status=$?
  missing_from_ldd=$(printf '%s\n' "$ldd_output" | awk '/not found/ {print $1}')
  if [ -n "$missing_from_ldd" ]; then
    printf 'chatgpt: %s is missing dynamic libraries:%s\n' "$binary" "$missing_from_ldd" >&2
    return 1
  fi
  if [ "$ldd_status" -ne 0 ]; then
    case "$ldd_output" in
      *'not a dynamic executable'*|*'statically linked'*) ;;
      *)
        printf 'chatgpt: could not inspect dependencies of %s:\n%s\n' "$binary" "$ldd_output" >&2
        return 1
        ;;
    esac
  fi
}

check_runtime_dependencies_at() {
  runtime_root=$1
  missing_binaries=
  for runtime_binary in \
    "$runtime_root/usr/lib/chatgpt/ChatGPT" \
    "$runtime_root/usr/lib/chatgpt/browser_crashpad_handler" \
    "$runtime_root/usr/lib/chatgpt/resources/codex" \
    "$runtime_root/usr/lib/chatgpt/resources/codex-code-mode-host" \
    "$runtime_root/usr/lib/chatgpt/resources/cua_node/bin/node"; do
    if [ ! -x "$runtime_binary" ]; then
      missing_binaries="$missing_binaries $runtime_binary"
    else
      check_binary_dependencies "$runtime_binary" || return 1
    fi
  done
  if [ -n "$missing_binaries" ]; then
    printf 'chatgpt: missing bundled runtime files:%s\n' "$missing_binaries" >&2
    return 1
  fi
}

expand_directory() {
  expanded=$1
  case "$expanded" in
    '~') expanded=$HOME ;;
    '~/'*) expanded=$HOME/${expanded#\~/} ;;
  esac
  printf '%s\n' "$expanded"
}

resolve_install_root() {
  requested_root=$(expand_directory "$1")
  case "$requested_root" in
    /*) ;;
    *) die "installation directory must be absolute: $requested_root" ;;
  esac

  if [ "$(id -u)" -eq 0 ]; then
    die 'do not run this installer as root; it is designed for user-level installation'
  fi
  if [ -e "$requested_root" ]; then
    [ -d "$requested_root" ] || die "installation path is not a directory: $requested_root"
  else
    mkdir -p "$requested_root" || die "cannot create installation directory: $requested_root"
  fi

  APP_ROOT=$(CDPATH= cd -- "$requested_root" && pwd -P) \
    || die "cannot access installation directory: $requested_root"
  case "$APP_ROOT" in
    /|"$HOME") die "refusing to use $APP_ROOT as the application root" ;;
  esac
}

directory_has_content() {
  for candidate in "$APP_ROOT"/* "$APP_ROOT"/.[!.]* "$APP_ROOT"/..?*; do
    [ -e "$candidate" ] || continue
    return 0
  done
  return 1
}

is_running_at() {
  executable=$1/usr/lib/chatgpt/ChatGPT
  for process_dir in /proc/[0-9]*; do
    [ -e "$process_dir/exe" ] || continue
    process_executable=$(readlink "$process_dir/exe" 2>/dev/null || true)
    [ "$process_executable" != "$executable" ] || return 0
  done
  return 1
}

prepare_install_root() {
  existing_payload=0
  if [ -x "$APP_ROOT/run-chatgpt" ] && [ -e "$APP_ROOT/usr/lib/chatgpt/ChatGPT" ]; then
    existing_payload=1
  fi

  if [ "$existing_payload" -eq 1 ]; then
    is_running_at "$APP_ROOT" && die 'close ChatGPT before installing or updating it'
  else
    if directory_has_content; then
      die "installation directory is not empty: $APP_ROOT"
    fi
  fi
}

extract_control() {
  case "$CONTROL_ARCHIVE" in
    *.tar.xz) ar p "$PACKAGE_PATH" "$CONTROL_ARCHIVE" | tar -xOJf - ./control ;;
    *.tar.gz) ar p "$PACKAGE_PATH" "$CONTROL_ARCHIVE" | tar -xzOf - ./control ;;
    *) die "unsupported control archive: $CONTROL_ARCHIVE" ;;
  esac
}

read_package_metadata() {
  PACKAGE_PATH=$1
  archive_members=$(ar t "$PACKAGE_PATH" 2>/dev/null || true)
  CONTROL_ARCHIVE=
  DATA_ARCHIVE=
  for archive_member in $archive_members; do
    case "$archive_member" in
      control.tar.xz|control.tar.gz) CONTROL_ARCHIVE=$archive_member ;;
      data.tar.xz|data.tar.gz) DATA_ARCHIVE=$archive_member ;;
    esac
  done
  [ -n "$CONTROL_ARCHIVE" ] || die 'package has no supported control archive'
  [ -n "$DATA_ARCHIVE" ] || die 'package has no supported data archive'

  control=$(extract_control) || die 'could not read package metadata'
  package_name=$(printf '%s\n' "$control" | awk -F': *' '$1 == "Package" {print $2; exit}')
  package_architecture=$(printf '%s\n' "$control" | awk -F': *' '$1 == "Architecture" {print $2; exit}')
  package_version=$(printf '%s\n' "$control" | awk -F': *' '$1 == "Version" {print $2; exit}')
  [ "$package_name" = chatgpt ] || die "unexpected package: ${package_name:-unknown}"
  [ "$package_architecture" = amd64 ] || die "unexpected package architecture: ${package_architecture:-unknown}"
  [ -n "$package_version" ] || die 'package has no version'
}

download_latest_package() {
  package_destination=$1
  quiet_download=${2-}
  if [ "$quiet_download" = quiet ]; then
    curl --fail --location --retry 3 --retry-delay 2 --silent --show-error \
      --output "$package_destination" "$PACKAGE_URL"
  else
    curl --fail --location --retry 3 --retry-delay 2 --progress-bar \
      --output "$package_destination" "$PACKAGE_URL"
  fi
}

version_is_newer() {
  candidate_version=$1
  installed_version=$2
  [ -n "$candidate_version" ] || return 1
  [ -n "$installed_version" ] || return 0
  [ "$candidate_version" != "$installed_version" ] || return 1
  newest_version=$(printf '%s\n%s\n' "$candidate_version" "$installed_version" | sort -V | awk 'END {print}')
  [ "$newest_version" = "$candidate_version" ]
}

extract_data() {
  case "$DATA_ARCHIVE" in
    *.tar.xz) ar p "$PACKAGE_PATH" "$DATA_ARCHIVE" | tar -xJf - -C "$EXTRACTED_PATH" ;;
    *.tar.gz) ar p "$PACKAGE_PATH" "$DATA_ARCHIVE" | tar -xzf - -C "$EXTRACTED_PATH" ;;
    *) die "unsupported data archive: $DATA_ARCHIVE" ;;
  esac
}

make_runtime_executables() {
  runtime_root=$1
  for runtime_binary in \
    "$runtime_root/usr/lib/chatgpt/ChatGPT" \
    "$runtime_root/usr/lib/chatgpt/browser_crashpad_handler" \
    "$runtime_root/usr/lib/chatgpt/codex-launcher" \
    "$runtime_root/usr/lib/chatgpt/resources/codex" \
    "$runtime_root/usr/lib/chatgpt/resources/codex-code-mode-host" \
    "$runtime_root/usr/lib/chatgpt/resources/cua_node/bin/node" \
    "$runtime_root/usr/lib/chatgpt/resources/cua_node/bin/node_repl"; do
    [ ! -e "$runtime_binary" ] || chmod u+x "$runtime_binary"
  done
}

write_run_launcher() {
  launcher_path=$1
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' \
    'export CHATGPT_APP_ROOT="$APP_ROOT"' \
    'if [ -r "$APP_ROOT/usr/lib/chatgpt/version" ]; then export CHATGPT_APP_VERSION=$(awk "NR==1 {print; exit}" "$APP_ROOT/usr/lib/chatgpt/version"); fi' \
    'CONFIG_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt/install.conf' \
    'if [ -r "$CONFIG_FILE" ]; then export CHATGPT_PATCHES=$(awk -F= '\''$1 == "patches" {print $2; exit}'\'' "$CONFIG_FILE"); fi' \
    'if [ -r "$CONFIG_FILE" ]; then export CHATGPT_NATIVE_DECORATIONS=$(awk -F= '\''$1 == "native_decorations" {print $2; exit}'\'' "$CONFIG_FILE"); fi' \
    'if [ "${CHATGPT_NO_PATCHES-0}" != 1 ] && [ -n "${CHATGPT_PATCHES-}" ]; then' \
    '  export CHATGPT_PATCH_ROOT="$APP_ROOT/external"' \
    '  export NODE_OPTIONS="${NODE_OPTIONS-} --require=$APP_ROOT/external/runtime/patch-loader.js"' \
    'fi' \
    'exec "$APP_ROOT/usr/lib/chatgpt/ChatGPT" \' \
    '  --user-data-dir="$APP_ROOT/user-data" \' \
    '  "$@"' > "$launcher_path"
  chmod u+x "$launcher_path"
}

set_patch_enabled() {
  patch_id=$1
  requested_state=$2
  case "$patch_id" in
    native-decoration|update-ui) ;;
    *) die "unknown patch: $patch_id" ;;
  esac

  case "$requested_state" in
    enable)
      case ",$PATCHES," in *,"$patch_id",*) ;; *) PATCHES=${PATCHES:+$PATCHES,}$patch_id ;; esac
      ;;
    disable)
      PATCHES=$(printf '%s' ",$PATCHES," | awk -v p=",$patch_id," '{gsub(p,","); gsub(/^,|,$/,""); gsub(/,,+/,","); print}')
      ;;
  esac

  if [ "$patch_id" = native-decoration ]; then
    if [ "$requested_state" = enable ]; then
      require_native_decoration_tools
      python3 "$APP_ROOT/$NATIVE_DECORATION_PATCH" --apply \
        || die 'native decoration patch could not be applied; restart ChatGPT after fixing the reported build issue'
      NATIVE_DECORATIONS=1
    else
      python3 "$APP_ROOT/$NATIVE_DECORATION_PATCH" --restore \
        || die 'native decoration patch could not be restored'
      NATIVE_DECORATIONS=0
    fi
  fi
  write_config
  printf 'Patch %s %sd. Restart ChatGPT for the change to take effect.\n' "$patch_id" "$requested_state"
}

write_installed_cli() {
  cli_source="$INSTALLER_DIRECTORY/templates/chatgpt"
  if [ ! -r "$cli_source" ]; then
    cli_source="$APP_ROOT/external/templates/chatgpt"
  fi
  [ -r "$cli_source" ] || die "installed CLI template is missing: $cli_source"
  cli_temporary="$APP_ROOT/cli.$$"
  cli_root=$(printf '%s' "$APP_ROOT" | sed "s/'/'\\\\''/g" | sed 's/[\\&|]/\\&/g')
  sed "s|__CHATGPT_APP_ROOT__|$cli_root|" "$cli_source" > "$cli_temporary"
  chmod u+x "$cli_temporary"
  mv -f "$cli_temporary" "$COMMAND_PATH"
}

copy_external_files() {
  external_source="$INSTALLER_DIRECTORY"
  if [ ! -r "$external_source/runtime/patch-loader.js" ]; then
    external_source="$APP_ROOT/external"
  fi
  external_temporary="$APP_ROOT/.external.$$"
  rm -rf "$external_temporary"
  mkdir -p "$external_temporary/runtime" "$external_temporary/patches" "$external_temporary/templates"
  cp "$external_source/runtime/patch-loader.js" "$external_temporary/runtime/patch-loader.js"
  cp "$external_source/runtime/update-from-menu.sh" "$external_temporary/runtime/update-from-menu.sh"
  cp "$external_source/runtime/toggle-native-decoration.sh" "$external_temporary/runtime/toggle-native-decoration.sh"
  cp "$external_source/patch-native-decoration.py" "$external_temporary/patch-native-decoration.py"
  cp -a "$external_source/patches/native-decoration" "$external_temporary/patches/"
  cp -a "$external_source/patches/update-ui" "$external_temporary/patches/"
  cp "$external_source/templates/chatgpt" "$external_temporary/templates/chatgpt"
  chmod 644 "$external_temporary/runtime/patch-loader.js" "$external_temporary/patches"/*/*.js "$external_temporary/patches"/*/*.json
  chmod 755 "$external_temporary/patch-native-decoration.py"
  chmod 755 "$external_temporary/runtime/update-from-menu.sh"
  chmod 755 "$external_temporary/runtime/toggle-native-decoration.sh"
  if [ -e "$APP_ROOT/external" ]; then
    mv "$APP_ROOT/external" "$backup_external" \
      || die 'could not back up the existing external patch files'
  fi
  if ! mv "$external_temporary" "$APP_ROOT/external"; then
    rm -rf "$external_temporary"
    [ ! -e "$backup_external" ] || mv "$backup_external" "$APP_ROOT/external" || true
    die 'could not install the external patch files'
  fi
  external_replaced=1
}

write_native_decoration_patch() {
  patch_source=
  if [ -r "$INSTALLER_DIRECTORY/$NATIVE_DECORATION_PATCH" ]; then
    patch_source=$INSTALLER_DIRECTORY/$NATIVE_DECORATION_PATCH
  elif [ -r "$APP_ROOT/external/$NATIVE_DECORATION_PATCH" ]; then
    patch_source=$APP_ROOT/external/$NATIVE_DECORATION_PATCH
  elif [ -r "$APP_ROOT/$NATIVE_DECORATION_PATCH" ]; then
    patch_source=$APP_ROOT/$NATIVE_DECORATION_PATCH
  fi
  if [ -z "$patch_source" ]; then
    printf 'chatgpt: native decoration patch script is missing: %s\n' "$NATIVE_DECORATION_PATCH" >&2
    return 1
  fi

  patch_temporary="$APP_ROOT/$NATIVE_DECORATION_PATCH.$$"
  if ! cp "$patch_source" "$patch_temporary"; then
    printf '%s\n' 'chatgpt: could not install the native decoration patch script' >&2
    return 1
  fi
  chmod u+x "$patch_temporary"
  mv -f "$patch_temporary" "$APP_ROOT/$NATIVE_DECORATION_PATCH"
}

apply_native_decoration_patch() {
  [ "$NATIVE_DECORATIONS" -eq 1 ] || return 0
  python3 "$APP_ROOT/$NATIVE_DECORATION_PATCH" --apply || return 1
  printf '%s\n' 'Native system window decorations enabled.'
}

write_config() {
  config_directory=$(dirname -- "$CONFIG_FILE")
  mkdir -p "$config_directory"
  config_temporary="$CONFIG_FILE.$$"
  printf '%s\n' "$APP_ROOT" "native_decorations=$NATIVE_DECORATIONS" "patches=$PATCHES" "package_version=${INSTALLED_PACKAGE_VERSION-}" > "$config_temporary"
  chmod 600 "$config_temporary"
  mv -f "$config_temporary" "$CONFIG_FILE"
}

write_command_copy() {
  command_directory=$(dirname -- "$COMMAND_PATH")
  mkdir -p "$command_directory"
  write_installed_cli
  installer_temporary="$APP_ROOT/installer.$$"
  cp "$SELF_PATH" "$installer_temporary"
  chmod u+x "$installer_temporary"
  mv -f "$installer_temporary" "$APP_ROOT/installer"
  patch_source="$INSTALLER_DIRECTORY/$NATIVE_DECORATION_PATCH"
  if [ -r "$patch_source" ]; then
    patch_destination="$command_directory/$NATIVE_DECORATION_PATCH"
    if [ "$patch_source" != "$patch_destination" ]; then
      patch_command_temporary="$patch_destination.$$"
      cp "$patch_source" "$patch_command_temporary"
      chmod u+x "$patch_command_temporary"
      mv -f "$patch_command_temporary" "$patch_destination"
    fi
  fi
}

write_desktop_entry() {
  desktop_directory=$(dirname -- "$DESKTOP_FILE")
  mkdir -p "$desktop_directory"
  printf '%s\n' \
    '[Desktop Entry]' \
    'Name=ChatGPT' \
    'Comment=ChatGPT by OpenAI' \
    'GenericName=AI assistant' \
    "Exec=\"$COMMAND_PATH\" %U" \
    "Icon=$APP_ROOT/usr/share/pixmaps/chatgpt.png" \
    'Type=Application' \
    'Terminal=false' \
    'StartupNotify=true' \
    'Categories=Utility;Development;' \
    'MimeType=x-scheme-handler/codex;text/csv;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.openxmlformats-officedocument.presentationml.presentation;text/tab-separated-values;application/vnd.ms-excel;application/vnd.ms-excel.sheet.macroEnabled.12;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;' > "$DESKTOP_FILE"
  chmod 644 "$DESKTOP_FILE"

  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$DESKTOP_FILE" || die "generated desktop entry is invalid: $DESKTOP_FILE"
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_directory" >/dev/null 2>&1 || true
  fi
  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default "$(basename -- "$DESKTOP_FILE")" x-scheme-handler/codex >/dev/null 2>&1 || true
  fi
}

report_command_path() {
  case ":${PATH:-}:" in
    *":$HOME/.local/bin:"*)
      printf '%s\n' 'The `chatgpt` command is available in the current PATH.'
      ;;
    *)
      printf '%s\n' \
        "The command was installed at $COMMAND_PATH, but $HOME/.local/bin is not in the current PATH." \
        'For this terminal session, run:' \
        '  export PATH="$HOME/.local/bin:$PATH"' \
        'Add that export to ~/.bashrc or ~/.zshrc to make it persistent.'
      ;;
  esac
}

install_payload() {
  supplied_package=${1-}
  temporary_root=$(mktemp -d "$APP_ROOT/.install.XXXXXXXX") \
    || die "cannot create a temporary directory inside $APP_ROOT"
  EXTRACTED_PATH="$temporary_root/extracted"
  backup_usr="$temporary_root/original-usr"
  backup_external="$temporary_root/original-external"
  payload_replaced=0
  external_replaced=0
  payload_install_succeeded=0

  rollback_payload() {
    if [ "$external_replaced" -eq 1 ]; then
      failed_external="$temporary_root/failed-external"
      if [ -e "$APP_ROOT/external" ]; then
        mv "$APP_ROOT/external" "$failed_external" || true
      fi
      if [ -e "$backup_external" ]; then
        mv "$backup_external" "$APP_ROOT/external" || true
      fi
      external_replaced=0
    fi
    if [ "$payload_replaced" -eq 1 ]; then
      failed_usr="$temporary_root/failed-usr"
      if [ -e "$APP_ROOT/usr" ]; then
        mv "$APP_ROOT/usr" "$failed_usr" || true
      fi
      if [ -e "$backup_usr" ]; then
        mv "$backup_usr" "$APP_ROOT/usr" || true
      fi
      payload_replaced=0
    fi
  }

  cleanup() {
    if [ "$payload_install_succeeded" -ne 1 ]; then
      rollback_payload
    fi
    rm -rf "$temporary_root"
  }
  trap cleanup EXIT INT TERM

  if [ -n "$supplied_package" ]; then
    PACKAGE_PATH=$supplied_package
    [ -r "$PACKAGE_PATH" ] || die "package file is not readable: $PACKAGE_PATH"
  else
    PACKAGE_PATH="$temporary_root/$PACKAGE_NAME"
    printf '%s\n' 'Downloading latest ChatGPT package...'
    download_latest_package "$PACKAGE_PATH" || die 'download failed'
  fi

  read_package_metadata "$PACKAGE_PATH"
  INSTALLED_PACKAGE_VERSION=$package_version
  printf 'Package: %s %s\n' "$package_name" "$package_version"

  mkdir "$EXTRACTED_PATH"
  extract_data || die 'could not extract the package'
  make_runtime_executables "$EXTRACTED_PATH"
  check_runtime_dependencies_at "$EXTRACTED_PATH" \
    || die 'the downloaded package cannot run with the current host libraries'
  [ -x "$EXTRACTED_PATH/usr/lib/chatgpt/ChatGPT" ] \
    || die 'downloaded package does not contain the ChatGPT executable'
  [ -f "$EXTRACTED_PATH/usr/share/pixmaps/chatgpt.png" ] \
    || die 'downloaded package does not contain the application icon'

  if [ -e "$APP_ROOT/usr" ]; then
    mv "$APP_ROOT/usr" "$backup_usr" \
      || die 'could not prepare the current installation for replacement'
  fi
  if ! mv "$EXTRACTED_PATH/usr" "$APP_ROOT/usr"; then
    [ ! -e "$backup_usr" ] || mv "$backup_usr" "$APP_ROOT/usr" || true
    die 'could not install the downloaded application files'
  fi
  payload_replaced=1
  rm -rf "$APP_ROOT/etc" "$APP_ROOT/var"
  [ ! -e "$EXTRACTED_PATH/etc" ] || cp -a "$EXTRACTED_PATH/etc" "$APP_ROOT/etc"
  [ ! -e "$EXTRACTED_PATH/var" ] || cp -a "$EXTRACTED_PATH/var" "$APP_ROOT/var"
  mkdir -p "$APP_ROOT/user-data"
  copy_external_files
  write_native_decoration_patch || die 'could not install the native decoration patch helper'
  launcher_temporary="$temporary_root/run-chatgpt"
  write_run_launcher "$launcher_temporary"
  mv -f "$launcher_temporary" "$APP_ROOT/run-chatgpt"
  if [ "$NATIVE_DECORATIONS" -eq 1 ]; then
    if ! write_native_decoration_patch || ! apply_native_decoration_patch; then
      rollback_payload
      die 'could not apply the native window decoration patch; the previous payload was restored'
    fi
  fi
  printf 'Application payload installed in %s.\n' "$APP_ROOT"
}

load_configured_root() {
  [ -r "$CONFIG_FILE" ] || die 'not configured; run install-codex-app.sh first'
  IFS= read -r APP_ROOT < "$CONFIG_FILE" || true
  [ -n "${APP_ROOT-}" ] || die "installation directory is empty in $CONFIG_FILE"
  case "$APP_ROOT" in
    /*) ;;
    *) die "installation directory must be absolute: $APP_ROOT" ;;
  esac
  [ -x "$APP_ROOT/run-chatgpt" ] || die "launcher not found in $APP_ROOT"
  NATIVE_DECORATIONS=$(awk -F= '$1 == "native_decorations" {print $2; exit}' "$CONFIG_FILE")
  NATIVE_DECORATIONS=${NATIVE_DECORATIONS:-0}
  case "$NATIVE_DECORATIONS" in
    0|1) ;;
    *) die "invalid native decoration setting in $CONFIG_FILE" ;;
  esac
  PATCHES=$(awk -F= '$1 == "patches" {print $2; exit}' "$CONFIG_FILE")
  INSTALLED_PACKAGE_VERSION=$(awk -F= '$1 == "package_version" {print $2; exit}' "$CONFIG_FILE")
  if [ -z "$INSTALLED_PACKAGE_VERSION" ] \
    && [ -r "$APP_ROOT/usr/lib/chatgpt/resources/linux-package-metadata.json" ]; then
    INSTALLED_PACKAGE_VERSION=$(awk -F'"' '$2 == "version" {print $4; exit}' \
      "$APP_ROOT/usr/lib/chatgpt/resources/linux-package-metadata.json")
  fi
  patches_setting=$(awk -F= '$1 == "patches" {print "present"; exit}' "$CONFIG_FILE")
  if [ -z "$patches_setting" ]; then
    PATCHES=update-ui
    if [ "$NATIVE_DECORATIONS" -eq 1 ]; then
      PATCHES=$PATCHES,native-decoration
    elif [ -x "$APP_ROOT/$NATIVE_DECORATION_PATCH" ] && command -v python3 >/dev/null 2>&1; then
      native_patch_status=$(python3 "$APP_ROOT/$NATIVE_DECORATION_PATCH" --status 2>/dev/null || true)
      case "$native_patch_status" in
        *'Native decoration patch: applied'*)
          NATIVE_DECORATIONS=1
          PATCHES=$PATCHES,native-decoration
          ;;
      esac
    fi
  fi
}

finish_install() {
  write_config
  write_command_copy
  write_desktop_entry
  printf '%s\n' \
    '' \
    "Installed ChatGPT/Codex locally in $APP_ROOT" \
    "Command: $COMMAND_PATH" \
    'Run `chatgpt` to open the current directory, or `chatgpt update` to update.'
  report_command_path
  if command -v codex >/dev/null 2>&1; then
    printf '%s\n' 'Existing codex CLI detected and left unchanged; the desktop app uses its bundled runtime.'
  else
    printf '%s\n' 'No system codex CLI detected; this does not block the desktop app because its runtime is bundled.'
  fi
}

install_app() {
  check_architecture
  require_host_tools || exit 1
  check_host_libraries || exit 1
  check_desktop_helpers || exit 1
  ask_native_decoration_preference
  PATCHES=update-ui
  [ "$NATIVE_DECORATIONS" -eq 0 ] || PATCHES=$PATCHES,native-decoration
  resolve_install_root "$1"
  require_native_decoration_tools
  prepare_install_root
  install_payload
  finish_install
  payload_install_succeeded=1
}

update_app() {
  check_architecture
  require_host_tools || exit 1
  check_host_libraries || exit 1
  check_desktop_helpers || exit 1
  load_configured_root
  if [ -n "$NATIVE_DECORATION_OVERRIDE" ]; then
    NATIVE_DECORATIONS=$NATIVE_DECORATION_OVERRIDE
    if [ "$NATIVE_DECORATIONS" -eq 1 ]; then
      case ",$PATCHES," in *,native-decoration,*) ;; *) PATCHES=${PATCHES:+$PATCHES,}native-decoration ;; esac
    else
      PATCHES=$(printf '%s' ",$PATCHES," | awk -v p=",native-decoration," '{gsub(p,""); gsub(/^,|,$/,""); gsub(/,,+/,","); print}')
    fi
  fi
  require_native_decoration_tools
  is_running_at "$APP_ROOT" && die 'close ChatGPT before updating it'
  install_payload
  finish_install
  payload_install_succeeded=1
}

check_update_app() {
  check_architecture
  require_host_tools || exit 1

  update_cache_directory=$APP_ROOT/update-cache
  mkdir -p "$update_cache_directory" \
    || die "cannot create update cache: $update_cache_directory"
  package_temporary="$update_cache_directory/$PACKAGE_NAME.$$"
  package_cached="$update_cache_directory/$PACKAGE_NAME"
  cleanup_update_package() {
    [ -z "${package_temporary-}" ] || rm -f "$package_temporary"
  }
  trap cleanup_update_package EXIT INT TERM

  download_latest_package "$package_temporary" quiet \
    || die 'download failed'
  read_package_metadata "$package_temporary"
  if version_is_newer "$package_version" "$INSTALLED_PACKAGE_VERSION"; then
    mv -f "$package_temporary" "$package_cached" \
      || die 'could not save the downloaded update'
    package_temporary=
    printf '%s\n' 'status=update-available'
    printf 'installed-version=%s\n' "${INSTALLED_PACKAGE_VERSION:-unknown}"
    printf 'available-version=%s\n' "$package_version"
    printf 'package-path=%s\n' "$package_cached"
  else
    rm -f "$package_temporary" "$package_cached"
    package_temporary=
    printf '%s\n' 'status=up-to-date'
    printf 'installed-version=%s\n' "${INSTALLED_PACKAGE_VERSION:-unknown}"
    printf 'available-version=%s\n' "$package_version"
  fi
}

install_package_app() {
  package_path=$1
  check_architecture
  require_host_tools || exit 1
  check_host_libraries || exit 1
  check_desktop_helpers || exit 1
  require_native_decoration_tools
  is_running_at "$APP_ROOT" && die 'close ChatGPT before updating it'
  install_payload "$package_path"
  finish_install
  payload_install_succeeded=1
}

run_chatgpt() {
  NO_PATCHES=0
  if [ "$#" -gt 0 ]; then
    case "$1" in
      --no-patches) NO_PATCHES=1; shift ;;
      --native-window-decoration|--no-native-window-decoration)
        parse_native_decoration_option "$1"
        shift
        ;;
    esac
  fi
  load_configured_root
  export CHATGPT_PATCHES=$PATCHES
  export CHATGPT_APP_ROOT=$APP_ROOT
  case "${1-}" in
    '')
      [ -z "$NATIVE_DECORATION_OVERRIDE" ] \
        || die 'decoration options can only be used with `chatgpt update`'
       if [ "$NO_PATCHES" -eq 1 ]; then export CHATGPT_NO_PATCHES=1; fi
       export CHATGPT_PATCHES=$PATCHES
       export CHATGPT_APP_ROOT=$APP_ROOT
       exec "$APP_ROOT/run-chatgpt" --open-project "$PWD"
      ;;
    update)
      shift
      while [ "$#" -gt 0 ]; do
        parse_native_decoration_option "$1" \
          || die 'usage: chatgpt update [--native-window-decoration|--no-native-window-decoration]'
        shift
      done
      update_app
      ;;
    check-update)
      [ "$#" -eq 1 ] || die 'usage: chatgpt check-update'
      check_update_app
      ;;
    install-package)
      [ "$#" -eq 2 ] || die 'usage: chatgpt install-package PACKAGE'
      install_package_app "$2"
      ;;
    patches)
      [ "$NO_PATCHES" -eq 0 ] || die '--no-patches cannot be used with patch management'
      shift
      case "${1-}" in
        list) printf '%s\n' 'native-decoration' 'update-ui' ;;
        status) printf 'Enabled patches: %s\n' "${PATCHES:-none}" ;;
         enable|disable)
           [ "$#" -eq 2 ] || die 'usage: chatgpt patches enable|disable NAME'
           set_patch_enabled "$2" "$1"
           ;;
        *) die 'usage: chatgpt patches list|status|enable NAME|disable NAME' ;;
      esac
      ;;
    --help|-h)
      chatgpt_usage
      ;;
    --native-window-decoration|--no-native-window-decoration)
      die 'decoration options can only be used with `chatgpt update`'
      ;;
    *)
      [ -z "$NATIVE_DECORATION_OVERRIDE" ] \
        || die 'decoration options can only be used with `chatgpt update`'
      exec "$APP_ROOT/run-chatgpt" "$@"
      ;;
  esac
}

resolve_self_path

INSTALLER_ACTION=install
INSTALL_DIRECTORY=

parse_installer_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        [ "$INSTALLER_ACTION" = install ] || die 'conflicting installer options'
        INSTALLER_ACTION=help
        ;;
      --check)
        [ "$INSTALLER_ACTION" = install ] || die 'conflicting installer options'
        INSTALLER_ACTION=check
        ;;
      --native-window-decoration|--no-native-window-decoration)
        [ "$INSTALLER_ACTION" = install ] || die 'conflicting installer options'
        parse_native_decoration_option "$1"
        ;;
      --directory)
        [ "$INSTALLER_ACTION" = install ] || die 'conflicting installer options'
        shift
        [ "$#" -gt 0 ] || die 'missing directory after --directory'
        [ -z "$INSTALL_DIRECTORY" ] || die 'installation directory was specified more than once'
        INSTALL_DIRECTORY=$1
        ;;
      --)
        shift
        [ "$#" -eq 1 ] || die 'provide one directory after --'
        [ -z "$INSTALL_DIRECTORY" ] || die 'installation directory was specified more than once'
        INSTALL_DIRECTORY=$1
        ;;
      -*)
        die "unknown installer option: $1"
        ;;
      *)
        [ "$INSTALLER_ACTION" = install ] || die 'conflicting installer options'
        [ -z "$INSTALL_DIRECTORY" ] || die 'installation directory was specified more than once'
        INSTALL_DIRECTORY=$1
        ;;
    esac
    shift
  done
}

if [ "${0##*/}" = chatgpt ] || [ "${0##*/}" = installer ]; then
  run_chatgpt "$@"
  exit 0
fi

parse_installer_arguments "$@"

case "$INSTALLER_ACTION" in
  help)
    usage
    ;;
  check)
    check_architecture
    require_host_tools || exit 1
    check_host_libraries || exit 1
    check_desktop_helpers || exit 1
    printf '%s\n' 'Host checks passed. The downloaded DEB will be checked again after extraction.'
    ;;
  install)
    if [ -n "$INSTALL_DIRECTORY" ]; then
      install_app "$INSTALL_DIRECTORY"
    else
      printf 'Install directory [%s]: ' "$DEFAULT_ROOT"
      IFS= read -r selected_root || exit 1
      [ -n "$selected_root" ] || selected_root=$DEFAULT_ROOT
      install_app "$selected_root"
    fi
esac
