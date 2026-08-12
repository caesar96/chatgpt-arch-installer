#!/bin/sh
set -eu

PACKAGE_URL=${CHATGPT_PACKAGE_URL:-https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb}
PACKAGE_NAME=chatgpt_amd64.deb
CONFIG_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt/install.conf
DESKTOP_FILE=${XDG_DATA_HOME:-$HOME/.local/share}/applications/chatgpt-local.desktop
COMMAND_PATH=$HOME/.local/bin/chatgpt
DEFAULT_ROOT=$HOME/Apps/chatgpt-linux

die() {
  printf 'chatgpt: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: install-codex-app.sh [DIRECTORY]' \
    '       install-codex-app.sh --directory DIRECTORY' \
    '       install-codex-app.sh --check' \
    '' \
    'Install the ChatGPT/Codex desktop app locally from the latest amd64 DEB.' \
    'No root privileges or system package installation are required.'
}

chatgpt_usage() {
  printf '%s\n' \
    'Usage: chatgpt [update]' \
    '  chatgpt         Open ChatGPT in the current terminal directory' \
    '  chatgpt update  Download and install the latest app version'
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
}

check_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "this package is amd64, but the current architecture is $(uname -m)" ;;
  esac
}

require_host_tools() {
  missing_tools=
  for tool in curl ar tar xz mktemp ldd ldconfig awk readlink cp chmod mkdir mv dirname basename id uname pwd rm ls xdg-open xdg-mime; do
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
    'exec "$APP_ROOT/usr/lib/chatgpt/ChatGPT" \' \
    '  --user-data-dir="$APP_ROOT/user-data" \' \
    '  "$@"' > "$launcher_path"
  chmod u+x "$launcher_path"
}

write_config() {
  config_directory=$(dirname -- "$CONFIG_FILE")
  mkdir -p "$config_directory"
  config_temporary="$CONFIG_FILE.$$"
  printf '%s\n' "$APP_ROOT" > "$config_temporary"
  chmod 600 "$config_temporary"
  mv -f "$config_temporary" "$CONFIG_FILE"
}

write_command_copy() {
  command_directory=$(dirname -- "$COMMAND_PATH")
  mkdir -p "$command_directory"
  command_temporary="$COMMAND_PATH.$$"
  cp "$SELF_PATH" "$command_temporary"
  chmod u+x "$command_temporary"
  mv -f "$command_temporary" "$COMMAND_PATH"
}

write_desktop_entry() {
  desktop_directory=$(dirname -- "$DESKTOP_FILE")
  mkdir -p "$desktop_directory"
  printf '%s\n' \
    '[Desktop Entry]' \
    'Name=ChatGPT' \
    'Comment=ChatGPT by OpenAI' \
    'GenericName=AI assistant' \
    "Exec=\"$APP_ROOT/run-chatgpt\" %U" \
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
  temporary_root=$(mktemp -d "$APP_ROOT/.install.XXXXXXXX") \
    || die "cannot create a temporary directory inside $APP_ROOT"
  PACKAGE_PATH="$temporary_root/$PACKAGE_NAME"
  EXTRACTED_PATH="$temporary_root/extracted"

  cleanup() {
    rm -rf "$temporary_root"
  }
  trap cleanup EXIT INT TERM

  printf '%s\n' 'Downloading latest ChatGPT package...'
  curl --fail --location --retry 3 --retry-delay 2 --progress-bar \
    --output "$PACKAGE_PATH" "$PACKAGE_URL" \
    || die 'download failed'

  archive_members=$(ar t "$PACKAGE_PATH" 2>/dev/null || true)
  CONTROL_ARCHIVE=
  DATA_ARCHIVE=
  for archive_member in $archive_members; do
    case "$archive_member" in
      control.tar.xz|control.tar.gz) CONTROL_ARCHIVE=$archive_member ;;
      data.tar.xz|data.tar.gz) DATA_ARCHIVE=$archive_member ;;
    esac
  done
  [ -n "$CONTROL_ARCHIVE" ] || die 'downloaded package has no supported control archive'
  [ -n "$DATA_ARCHIVE" ] || die 'downloaded package has no supported data archive'

  control=$(extract_control) || die 'could not read package metadata'
  package_name=$(printf '%s\n' "$control" | awk -F': *' '$1 == "Package" {print $2; exit}')
  package_architecture=$(printf '%s\n' "$control" | awk -F': *' '$1 == "Architecture" {print $2; exit}')
  package_version=$(printf '%s\n' "$control" | awk -F': *' '$1 == "Version" {print $2; exit}')
  [ "$package_name" = chatgpt ] || die "unexpected package: ${package_name:-unknown}"
  [ "$package_architecture" = amd64 ] || die "unexpected package architecture: ${package_architecture:-unknown}"
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

  backup_usr="$temporary_root/original-usr"
  if [ -e "$APP_ROOT/usr" ]; then
    mv "$APP_ROOT/usr" "$backup_usr" \
      || die 'could not prepare the current installation for replacement'
  fi
  if ! mv "$EXTRACTED_PATH/usr" "$APP_ROOT/usr"; then
    [ ! -e "$backup_usr" ] || mv "$backup_usr" "$APP_ROOT/usr" || true
    die 'could not install the downloaded application files'
  fi
  rm -rf "$APP_ROOT/etc" "$APP_ROOT/var"
  [ ! -e "$EXTRACTED_PATH/etc" ] || cp -a "$EXTRACTED_PATH/etc" "$APP_ROOT/etc"
  [ ! -e "$EXTRACTED_PATH/var" ] || cp -a "$EXTRACTED_PATH/var" "$APP_ROOT/var"
  mkdir -p "$APP_ROOT/user-data"
  launcher_temporary="$temporary_root/run-chatgpt"
  write_run_launcher "$launcher_temporary"
  mv -f "$launcher_temporary" "$APP_ROOT/run-chatgpt"
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
  resolve_install_root "$1"
  prepare_install_root
  install_payload
  finish_install
}

update_app() {
  check_architecture
  require_host_tools || exit 1
  check_host_libraries || exit 1
  check_desktop_helpers || exit 1
  load_configured_root
  is_running_at "$APP_ROOT" && die 'close ChatGPT before updating it'
  install_payload
  finish_install
}

run_chatgpt() {
  load_configured_root
  case "${1-}" in
    '')
      exec "$APP_ROOT/run-chatgpt" --open-project "$PWD"
      ;;
    update)
      shift
      [ "$#" -eq 0 ] || die 'usage: chatgpt update'
      update_app
      ;;
    --help|-h)
      chatgpt_usage
      ;;
    *)
      exec "$APP_ROOT/run-chatgpt" "$@"
      ;;
  esac
}

resolve_self_path

if [ "${0##*/}" = chatgpt ]; then
  run_chatgpt "$@"
  exit 0
fi

case "${1-}" in
  --help|-h)
    usage
    ;;
  --check)
    [ "$#" -eq 1 ] || die 'usage: install-codex-app.sh --check'
    check_architecture
    require_host_tools || exit 1
    check_host_libraries || exit 1
    check_desktop_helpers || exit 1
    printf '%s\n' 'Host checks passed. The downloaded DEB will be checked again after extraction.'
    ;;
  --directory)
    [ "$#" -eq 2 ] || die 'usage: install-codex-app.sh --directory DIRECTORY'
    install_app "$2"
    ;;
  '')
    printf 'Install directory [%s]: ' "$DEFAULT_ROOT"
    IFS= read -r selected_root || exit 1
    [ -n "$selected_root" ] || selected_root=$DEFAULT_ROOT
    install_app "$selected_root"
    ;;
  *)
    [ "$#" -eq 1 ] || die 'provide one directory, or use --help'
    install_app "$1"
    ;;
esac
