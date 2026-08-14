#!/bin/sh
set -eu

PACKAGE_URL=${CHATGPT_PACKAGE_URL:-https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb}
PACKAGE_NAME=chatgpt_amd64.deb
AUTOMATIC_UPDATE_INTERVAL=3600
METADATA_RANGE_INITIAL_END=65535
METADATA_RANGE_MAX_END=4194303
FULL_DOWNLOAD_CHUNK_SIZE=16777216
CONFIG_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt/settings.conf
CONFIG_DIRECTORY=${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt
USER_DATA_DIRECTORY=$CONFIG_DIRECTORY/user-data
DESKTOP_FILE=${XDG_DATA_HOME:-$HOME/.local/share}/applications/chatgpt.desktop
MIME_APPS_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list
COMMAND_PATH=$HOME/.local/bin/chatgpt
CODEX_DIRECTORY=$HOME/.codex
DEFAULT_ROOT=$HOME/Apps/chatgpt-linux
NATIVE_DECORATION_OVERRIDE=
PATCHES=
INSTALLED_PACKAGE_VERSION=
CONFIG_READ_FILE=
CHATGPT_SOURCE_ROOT=${CHATGPT_SOURCE_ROOT-}
CHATGPT_ENTRYPOINT=${CHATGPT_ENTRYPOINT-}
COLOR_RESET=
COLOR_BOLD=
COLOR_GREEN=
COLOR_CYAN=
COLOR_YELLOW=
COLOR_RED=

if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
  COLOR_RESET=$(printf '\033[0m')
  COLOR_BOLD=$(printf '\033[1m')
  COLOR_GREEN=$(printf '\033[32m')
  COLOR_CYAN=$(printf '\033[36m')
  COLOR_YELLOW=$(printf '\033[33m')
  COLOR_RED=$(printf '\033[31m')
fi

die() {
  printf 'chatgpt: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: install-chatgpt.sh [DIRECTORY]' \
    '       install-chatgpt.sh --directory DIRECTORY' \
    '       install-chatgpt.sh --native-window-decoration [DIRECTORY]' \
    '       install-chatgpt.sh --no-native-window-decoration [DIRECTORY]' \
    '       install-chatgpt.sh --check' \
    '' \
    'Install the ChatGPT/Codex desktop app locally from the latest amd64 DEB.' \
    'No root privileges or system package installation are required.' \
    'The installer can optionally enable native system window decorations.'
}

chatgpt_usage() {
  printf '%s\n' \
    'Usage: chatgpt [--debug] [--no-patches] [update [DECORATION_OPTION]]' \
    '  chatgpt         Open ChatGPT in the current terminal directory' \
    '  chatgpt update  Download and install the latest app version' \
    '  chatgpt check-update  Check remote package metadata' \
    '  chatgpt uninstall [--no-preserve-data]  Remove the local installation' \
    '  chatgpt patches [list|status|enable NAME|disable NAME]' \
    '  chatgpt decorations [enable|disable]  Toggle native window decorations' \
    '  chatgpt --debug  Launch with external patch diagnostics enabled' \
    '  chatgpt --no-patches  Launch once without external patches' \
    '  DECORATION_OPTION: --native-window-decoration or --no-native-window-decoration' \
    '  NAME: global-menu, mac-layout, native-window-decorations, or update-menu'
}

resolve_self_path() {
  SELF_PATH=${CHATGPT_ENTRYPOINT:-$0}
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
  [ -f "$SELF_PATH" ] || die "entrypoint cannot be found at $SELF_PATH"
  if [ -n "$CHATGPT_SOURCE_ROOT" ]; then
    SOURCE_DIRECTORY=$CHATGPT_SOURCE_ROOT
  else
    SOURCE_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$SELF_PATH")" && pwd -P) \
      || die 'cannot determine the source directory'
  fi
}

check_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "this package is amd64, but the current architecture is $(uname -m)" ;;
  esac
}

require_host_tools() {
  missing_tools=
  for tool in curl ar tar xz mktemp ldd ldconfig awk sort sed tr readlink cp chmod mkdir mv ln dirname basename id uname pwd rm rmdir ls cat date dd wc xdg-open xdg-mime; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_tools="$missing_tools $tool"
    fi
  done
  if [ -n "$missing_tools" ]; then
    printf '%schatgpt: missing host tools:%s%s\n' "$COLOR_RED" "$missing_tools" "$COLOR_RESET" >&2
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

canonical_patch_id() {
  printf '%s\n' "$1"
}

normalize_patch_list() {
  normalized_patches=
  old_ifs=$IFS
  IFS=,
  for requested_patch in $PATCHES; do
    IFS=$old_ifs
    [ -n "$requested_patch" ] || continue
    normalized_patch=$(canonical_patch_id "$requested_patch")
    case ",$normalized_patches," in
      *,"$normalized_patch",*) ;;
      *) normalized_patches=${normalized_patches:+$normalized_patches,}$normalized_patch ;;
    esac
    IFS=,
  done
  IFS=$old_ifs
  PATCHES=$normalized_patches
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

check_global_menu_support() {
  command -v python3 >/dev/null 2>&1 \
    || die 'global-menu requires python3'
  if ! python3 -c "import gi; gi.require_version('Dbusmenu', '0.4'); from gi.repository import Dbusmenu, Gio, GLib" \
    >/dev/null 2>&1; then
    die 'global-menu requires Python GObject introspection for Dbusmenu 0.4'
  fi
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
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
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
  if [ -x "$APP_ROOT/bin/chatgpt-launcher" ] \
    && [ -e "$APP_ROOT/usr/lib/chatgpt/ChatGPT" ]; then
    existing_payload=1
  fi

  if [ "$existing_payload" -eq 1 ]; then
    if is_running_at "$APP_ROOT"; then
      die 'close ChatGPT before installing or updating it'
    fi
    if [ -e "$APP_ROOT/user-data" ] || [ -L "$APP_ROOT/user-data" ]; then
      die "this installation stores user data inside $APP_ROOT; run chatgpt uninstall, then move $APP_ROOT/user-data to $USER_DATA_DIRECTORY before reinstalling"
    fi
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

read_header_value() {
  header_file=$1
  requested_header=$2
  awk -v requested="$requested_header" '
    BEGIN { requested=tolower(requested); value="" }
    /^[[:space:]]*[^:]+:/ {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      separator=index(line, ":")
      name=tolower(substr(line, 1, separator - 1))
      if (name == requested) {
        value=substr(line, separator + 1)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*\r$/, "", value)
      }
    }
    END { print value }
  ' "$header_file"
}

read_http_status() {
  awk '/^HTTP\/[0-9.]+[[:space:]]/ { status=$2 } END { print status }' "$1"
}

read_content_range_parts() {
  content_range=$1
  case "$content_range" in
    bytes\ [0-9]*-[0-9]*/[0-9]*) ;;
    *) return 1 ;;
  esac
  content_range=${content_range#bytes }
  range_start=${content_range%%-*}
  range_tail=${content_range#*-}
  range_end=${range_tail%%/*}
  range_total=${range_tail#*/}
  case "$range_start:$range_end:$range_total" in
    *[!0-9:]*|:*|*::*) return 1 ;;
  esac
}

fetch_package_headers() {
  update_headers_file=$1
  rm -f "$update_headers_file"
  if [ -n "${UPDATE_IF_NONE_MATCH-}" ]; then
    curl --fail --silent --show-error --location --head \
      --retry 3 --retry-delay 2 --connect-timeout 20 \
      --dump-header "$update_headers_file" --output /dev/null \
      -H "If-None-Match: $UPDATE_IF_NONE_MATCH" "$PACKAGE_URL" || return 1
  else
    curl --fail --silent --show-error --location --head \
      --retry 3 --retry-delay 2 --connect-timeout 20 \
      --dump-header "$update_headers_file" --output /dev/null \
      "$PACKAGE_URL" || return 1
  fi
  update_http_status=$(read_http_status "$update_headers_file")
  update_remote_etag=$(read_header_value "$update_headers_file" etag)
  update_remote_last_modified=$(read_header_value "$update_headers_file" last-modified)
  update_remote_content_length=$(read_header_value "$update_headers_file" content-length)
  update_remote_accept_ranges=$(read_header_value "$update_headers_file" accept-ranges)
}

fetch_package_range_bounds() {
  partial_file=$1
  range_headers_file=$2
  range_start_requested=$3
  range_end_requested=$4
  rm -f "$partial_file" "$range_headers_file"
  if [ -n "${RANGE_EXPECTED_ETAG-}" ]; then
    curl --fail --silent --show-error --location \
      --retry 3 --retry-delay 2 --connect-timeout 20 \
      --range "$range_start_requested-$range_end_requested" \
      --max-filesize "$((range_end_requested - range_start_requested + 1))" \
      --dump-header "$range_headers_file" --output "$partial_file" \
      -H "If-Match: $RANGE_EXPECTED_ETAG" "$PACKAGE_URL" || return 1
  else
    curl --fail --silent --show-error --location \
      --retry 3 --retry-delay 2 --connect-timeout 20 \
      --range "$range_start_requested-$range_end_requested" \
      --max-filesize "$((range_end_requested - range_start_requested + 1))" \
      --dump-header "$range_headers_file" --output "$partial_file" \
      "$PACKAGE_URL" || return 1
  fi
  range_http_status=$(read_http_status "$range_headers_file")
  [ "$range_http_status" = 206 ] || return 1
  range_content_range=$(read_header_value "$range_headers_file" content-range)
  read_content_range_parts "$range_content_range" || return 1
  range_response_etag=$(read_header_value "$range_headers_file" etag)
  if [ -n "${RANGE_EXPECTED_ETAG-}" ] && [ "$range_response_etag" != "$RANGE_EXPECTED_ETAG" ]; then
    return 1
  fi
  [ "$range_start" -eq "$range_start_requested" ] || return 1
  [ "$range_end" -le "$range_end_requested" ] || return 1
  partial_bytes=$(wc -c < "$partial_file")
  expected_partial_bytes=$((range_end - range_start + 1))
  [ "$partial_bytes" -eq "$expected_partial_bytes" ] || return 1
}

fetch_package_range() {
  fetch_package_range_bounds "$1" "$2" 0 "$3"
}

parse_control_from_partial() {
  partial_file=$1
  partial_bytes=$(wc -c < "$partial_file")
  [ "$partial_bytes" -ge 8 ] || return 2
  archive_magic=$(dd if="$partial_file" bs=1 count=7 2>/dev/null || true)
  [ "$archive_magic" = '!<arch>' ] || return 1

  archive_offset=8
  while :; do
    if [ "$archive_offset" -gt "$partial_bytes" ]; then
      return 2
    fi
    if [ $((archive_offset + 60)) -gt "$partial_bytes" ]; then
      return 2
    fi

    member_name=$(dd if="$partial_file" bs=1 skip="$archive_offset" count=16 2>/dev/null \
      | sed 's/[[:space:]]*$//; s|/$||' | tr -d '\r')
    member_size_text=$(dd if="$partial_file" bs=1 skip=$((archive_offset + 48)) count=10 2>/dev/null \
      | tr -d '[:space:]')
    case "$member_size_text" in
      ''|*[!0-9]*) return 1 ;;
    esac
    member_size=$((member_size_text + 0))
    member_start=$((archive_offset + 60))
    member_end=$((member_start + member_size))
    if [ "$member_end" -gt "$partial_bytes" ]; then
      return 2
    fi

    case "$member_name" in
      control.tar.xz|control.tar.gz)
        control_archive_file=$partial_file.control
        rm -f "$control_archive_file"
        dd if="$partial_file" bs=1 skip="$member_start" count="$member_size" \
          of="$control_archive_file" 2>/dev/null || return 1
        if [ "$member_name" = control.tar.xz ]; then
          control_text=$(tar -xOJf "$control_archive_file" ./control 2>/dev/null) || {
            rm -f "$control_archive_file"
            return 1
          }
        else
          control_text=$(tar -xzOf "$control_archive_file" ./control 2>/dev/null) || {
            rm -f "$control_archive_file"
            return 1
          }
        fi
        rm -f "$control_archive_file"
        metadata_package_name=$(printf '%s\n' "$control_text" | awk -F': *' '$1 == "Package" {print $2; exit}')
        metadata_package_architecture=$(printf '%s\n' "$control_text" | awk -F': *' '$1 == "Architecture" {print $2; exit}')
        metadata_package_version=$(printf '%s\n' "$control_text" | awk -F': *' '$1 == "Version" {print $2; exit}')
        [ "$metadata_package_name" = chatgpt ] || return 1
        [ "$metadata_package_architecture" = amd64 ] || return 1
        [ -n "$metadata_package_version" ] || return 1
        return 0
        ;;
    esac

    archive_offset=$member_end
    if [ $((archive_offset % 2)) -ne 0 ]; then
      archive_offset=$((archive_offset + 1))
    fi
  done
}

read_package_metadata_from_remote() {
  partial_file=$1
  range_headers_file=$2
  RANGE_EXPECTED_ETAG=${update_remote_etag-}
  if ! fetch_package_range "$partial_file" "$range_headers_file" "$METADATA_RANGE_INITIAL_END"; then
    return 1
  fi
  if parse_control_from_partial "$partial_file"; then
    return 0
  else
    parse_metadata_status=$?
  fi
  [ "$parse_metadata_status" -eq 2 ] || return 1
  [ "$METADATA_RANGE_MAX_END" -gt "$METADATA_RANGE_INITIAL_END" ] || return 1
  if ! fetch_package_range "$partial_file" "$range_headers_file" "$METADATA_RANGE_MAX_END"; then
    return 1
  fi
  parse_control_from_partial "$partial_file"
}

write_update_check_state() {
  update_state_directory=$1
  update_state_file=$2
  update_state_temporary=$update_state_file.$$
  mkdir -p "$update_state_directory" || return 1
  printf '%s\n' \
    "url=$PACKAGE_URL" \
    "etag=${update_remote_etag-}" \
    "last-modified=${update_remote_last_modified-}" \
    "content-length=${update_remote_content_length-}" \
    "available-version=${metadata_package_version-}" \
    "checked-at=${update_check_now-}" > "$update_state_temporary" || return 1
  chmod 600 "$update_state_temporary"
  mv -f "$update_state_temporary" "$update_state_file"
}

read_state_value() {
  state_file=$1
  requested_key=$2
  awk -F= -v requested="$requested_key" '$1 == requested {print substr($0, index($0, "=") + 1); exit}' "$state_file" 2>/dev/null || true
}

download_update_package() {
  check_architecture
  require_host_tools || exit 1
  update_cache_directory=$APP_ROOT/update-cache
  mkdir -p "$update_cache_directory" \
    || die "cannot create update cache: $update_cache_directory"
  package_temporary="$update_cache_directory/$PACKAGE_NAME.$$"
  package_cached="$update_cache_directory/$PACKAGE_NAME"
  download_chunk="$package_temporary.chunk"
  download_headers="$package_temporary.headers"
  download_head_headers="$package_temporary.head"
  cleanup_download() {
    [ -z "${package_temporary-}" ] || rm -f "$package_temporary"
    rm -f "$download_chunk" "$download_headers" "$download_head_headers"
  }
  trap cleanup_download EXIT INT TERM
  rm -f "$package_cached"

  UPDATE_IF_NONE_MATCH=
  fetch_package_headers "$download_head_headers" || die 'could not read the latest package headers'
  [ "$update_http_status" = 200 ] || die "package server returned HTTP $update_http_status"
  if [ -n "${DOWNLOAD_EXPECTED_ETAG-}" ] \
    && [ "$update_remote_etag" != "$DOWNLOAD_EXPECTED_ETAG" ]; then
    die 'the update changed before its download started'
  fi
  case "${update_remote_content_length-}" in
    ''|*[!0-9]*) die 'latest package has no valid content length' ;;
  esac
  download_total=$update_remote_content_length
  [ "$download_total" -gt 0 ] || die 'latest package is empty'
  RANGE_EXPECTED_ETAG=${update_remote_etag-}
  : > "$package_temporary"
  downloaded_bytes=0
  printf '%s\n' 'status=downloading' 'progress=0'
  while [ "$downloaded_bytes" -lt "$download_total" ]; do
    download_range_start=$downloaded_bytes
    download_range_end=$((download_range_start + FULL_DOWNLOAD_CHUNK_SIZE - 1))
    [ "$download_range_end" -lt "$download_total" ] || download_range_end=$((download_total - 1))
    fetch_package_range_bounds "$download_chunk" "$download_headers" \
      "$download_range_start" "$download_range_end" \
      || die "could not download package bytes $download_range_start-$download_range_end"
    [ "$range_total" -eq "$download_total" ] || die 'package size changed during download'
    download_chunk_etag=$(read_header_value "$download_headers" etag)
    if [ -n "$update_remote_etag" ] && [ "$download_chunk_etag" != "$update_remote_etag" ]; then
      die 'package changed during download'
    fi
    cat "$download_chunk" >> "$package_temporary" \
      || die 'could not assemble downloaded package'
    downloaded_bytes=$((downloaded_bytes + partial_bytes))
    download_progress=$((downloaded_bytes * 100 / download_total))
    printf 'progress=%s\n' "$download_progress"
  done
  [ "$downloaded_bytes" -eq "$download_total" ] || die 'downloaded package has an unexpected size'
  PACKAGE_PATH=$package_temporary
  read_package_metadata "$PACKAGE_PATH"
  if ! version_is_newer "$package_version" "$INSTALLED_PACKAGE_VERSION"; then
    rm -f "$package_temporary" "$package_cached"
    printf '%s\n' 'status=up-to-date' \
      "installed-version=${INSTALLED_PACKAGE_VERSION:-unknown}" \
      "available-version=$package_version"
    exit 0
  fi
  mv -f "$package_temporary" "$package_cached" \
    || die 'could not save the downloaded update'
  package_temporary=
  printf '%s\n' 'Preparing the update before closing ChatGPT...'
  stage_update_package "$package_cached" \
    || die 'could not prepare the downloaded update'
  emit_patch_report "$STAGED_ROOT/payload/patch-report"
  printf '%s\n' 'status=ready' \
    "installed-version=${INSTALLED_PACKAGE_VERSION:-unknown}" \
    "available-version=$package_version" \
    "package-path=$package_cached" \
    "staging-path=$STAGED_ROOT" \
    "runtime-version=$(awk 'NR == 1 {print; exit}' "$STAGED_ROOT/payload/usr/lib/chatgpt/version")"
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
    'APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)' \
    'export CHATGPT_APP_ROOT="$APP_ROOT"' \
    'if [ -r "$APP_ROOT/usr/lib/chatgpt/version" ]; then export CHATGPT_APP_VERSION=$(awk "NR==1 {print; exit}" "$APP_ROOT/usr/lib/chatgpt/version"); fi' \
    'CONFIG_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt/settings.conf' \
    'export CHATGPT_CONFIG_FILE="$CONFIG_FILE"' \
    'USER_DATA_DIRECTORY=${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt/user-data' \
    'mkdir -p "$USER_DATA_DIRECTORY"' \
    'if [ -r "$CONFIG_FILE" ]; then export CHATGPT_PATCHES=$(awk -F= '\''$1 == "patches" {print $2; exit}'\'' "$CONFIG_FILE"); fi' \
    'case ",${CHATGPT_PATCHES-}," in' \
    '  *,global-menu,*) unset ELECTRON_FORCE_WINDOW_MENU_BAR ;;' \
    '  *) export ELECTRON_FORCE_WINDOW_MENU_BAR=1 ;;' \
    'esac' \
    'if [ "${CHATGPT_DEBUG-0}" = 1 ]; then export CHATGPT_PATCH_DIAGNOSTIC="$APP_ROOT/state/patch-diagnostic.log"; fi' \
    'if [ "${CHATGPT_NO_PATCHES-0}" != 1 ] && [ -n "${CHATGPT_PATCHES-}" ]; then' \
    '  export CHATGPT_PATCH_ROOT="$APP_ROOT"' \
    '  export NODE_OPTIONS="${NODE_OPTIONS-} --require=$APP_ROOT/runtime/patch-loader.js"' \
    'fi' \
    'if [ "$#" -gt 0 ] && [ "$1" = "$APP_ROOT/usr/lib/chatgpt/resources/app.asar" ]; then shift; fi' \
    'exec "$APP_ROOT/usr/lib/chatgpt/ChatGPT" \' \
    '  --user-data-dir="$USER_DATA_DIRECTORY" \' \
    '  "$@"' > "$launcher_path"
  chmod u+x "$launcher_path"
}

set_patch_enabled() {
  patch_id=$(canonical_patch_id "$1")
  requested_state=$2
  case "$patch_id" in
    global-menu|mac-layout|native-window-decorations|update-menu) ;;
    *) die "unknown patch: $patch_id" ;;
  esac

  case "$requested_state" in
    enable)
      if [ "$patch_id" = global-menu ]; then
        check_global_menu_support
      fi
      case ",$PATCHES," in *,"$patch_id",*) ;; *) PATCHES=${PATCHES:+$PATCHES,}$patch_id ;; esac
      ;;
    disable)
      PATCHES=$(printf '%s' ",$PATCHES," | awk -v p=",$patch_id," '{gsub(p,","); gsub(/^,|,$/,""); gsub(/,,+/,","); print}')
      ;;
  esac

  if [ "$patch_id" = native-window-decorations ]; then
    if [ "$requested_state" = enable ]; then
      NATIVE_DECORATIONS=1
    else
      NATIVE_DECORATIONS=0
    fi
  fi
  write_config
  printf 'Patch %s %sd. Restart ChatGPT for the change to take effect.\n' "$patch_id" "$requested_state"
}

set_native_decorations() {
  decoration_state=$1
  case "$decoration_state" in
    enable)
      NATIVE_DECORATIONS=1
      ;;
    disable)
      NATIVE_DECORATIONS=0
      ;;
    *)
      die 'usage: chatgpt decorations enable|disable'
      ;;
  esac
  case ",$PATCHES," in
    *,native-window-decorations,*) ;;
    *) PATCHES=${PATCHES:+$PATCHES,}native-window-decorations ;;
  esac
  normalize_patch_list
  write_config
  printf 'Native window decorations %sd. Restart ChatGPT for the change to take effect.\n' "$decoration_state"
}

copy_support_files() {
  support_source="$SOURCE_DIRECTORY"
  if [ ! -r "$support_source/lib/chatgpt-core.sh" ]; then
    support_source="$APP_ROOT"
  fi
  for support_file in \
    "$support_source/lib/chatgpt-core.sh" \
    "$support_source/bin/chatgpt" \
    "$support_source/runtime/patch-loader.js" \
    "$support_source/runtime/settings.js" \
    "$support_source/runtime/chatgpt-toggle-window-decorations.sh" \
    "$support_source/runtime/chatgpt-global-menu.py"; do
    [ -r "$support_file" ] || die "required ChatGPT support file is missing: $support_file"
  done

  support_temporary="$APP_ROOT/.support.$$"
  rm -rf "$support_temporary"
  mkdir -p "$support_temporary/bin" "$support_temporary/lib" "$support_temporary/runtime" "$support_temporary/patches"
  cp "$support_source/lib/chatgpt-core.sh" "$support_temporary/lib/chatgpt-core.sh"
  cp "$support_source/bin/chatgpt" "$support_temporary/bin/chatgpt"
  cp "$support_source/runtime/patch-loader.js" "$support_temporary/runtime/patch-loader.js"
  cp "$support_source/runtime/settings.js" "$support_temporary/runtime/settings.js"
  cp "$support_source/runtime/chatgpt-toggle-window-decorations.sh" "$support_temporary/runtime/chatgpt-toggle-window-decorations.sh"
  cp "$support_source/runtime/chatgpt-global-menu.py" "$support_temporary/runtime/chatgpt-global-menu.py"
  cp -a "$support_source/patches/global-menu" "$support_temporary/patches/"
  cp -a "$support_source/patches/update-menu" "$support_temporary/patches/"
  cp -a "$support_source/patches/native-window-decorations" "$support_temporary/patches/"
  cp -a "$support_source/patches/mac-layout" "$support_temporary/patches/"
  chmod 644 "$support_temporary/lib/chatgpt-core.sh" "$support_temporary/runtime/patch-loader.js" "$support_temporary/runtime/settings.js" "$support_temporary/patches"/*/*.js "$support_temporary/patches"/*/*.json
  chmod 755 "$support_temporary/runtime/chatgpt-toggle-window-decorations.sh"
  chmod 755 "$support_temporary/runtime/chatgpt-global-menu.py"
  chmod 755 "$support_temporary/bin/chatgpt"

  backup_support="$temporary_root/original-support"
  if [ -e "$APP_ROOT/bin" ] || [ -e "$APP_ROOT/lib" ] || [ -e "$APP_ROOT/runtime" ] || [ -e "$APP_ROOT/patches" ]; then
    mkdir -p "$backup_support"
    support_replaced=1
    for support_directory in bin lib runtime patches; do
      if [ -e "$APP_ROOT/$support_directory" ]; then
        mv "$APP_ROOT/$support_directory" "$backup_support/$support_directory" \
          || die "could not back up existing $support_directory files"
        support_backup_list="$support_backup_list $support_directory"
      fi
    done
  fi
  support_replaced=1
  for support_directory in bin lib runtime patches; do
    mv "$support_temporary/$support_directory" "$APP_ROOT/$support_directory" \
      || die "could not install $support_directory files"
    support_installed_list="$support_installed_list $support_directory"
  done
  rmdir "$support_temporary" 2>/dev/null || true
}

write_command_link() {
  command_directory=$(dirname -- "$COMMAND_PATH")
  mkdir -p "$command_directory"
  if [ -e "$COMMAND_PATH" ] || [ -L "$COMMAND_PATH" ]; then
    command_target=$(readlink -f "$COMMAND_PATH" 2>/dev/null || true)
    if [ ! -L "$COMMAND_PATH" ] || [ "$command_target" != "$APP_ROOT/bin/chatgpt" ]; then
      die "refusing to replace an existing command: $COMMAND_PATH"
    fi
  fi
  command_temporary="$COMMAND_PATH.$$"
  if ! ln -s "$APP_ROOT/bin/chatgpt" "$command_temporary"; then
    die "could not prepare the ChatGPT command link: $COMMAND_PATH"
  fi
  if ! mv -f "$command_temporary" "$COMMAND_PATH"; then
    rm -f "$command_temporary"
    die "could not install the ChatGPT command link: $COMMAND_PATH"
  fi
}

patch_manifest_path() {
  patch_id=$1
  if [ -r "$SOURCE_DIRECTORY/patches/$patch_id/manifest.json" ]; then
    printf '%s\n' "$SOURCE_DIRECTORY/patches/$patch_id/manifest.json"
  elif [ -r "$APP_ROOT/patches/$patch_id/manifest.json" ]; then
    printf '%s\n' "$APP_ROOT/patches/$patch_id/manifest.json"
  else
    return 1
  fi
}

manifest_supports_version() {
  manifest_file=$1
  manifest_key=$2
  candidate_version=$3
  manifest_versions=$(sed -n "/\"$manifest_key\"[[:space:]]*:/,/]/p" "$manifest_file")
  [ -z "$manifest_versions" ] || printf '%s\n' "$manifest_versions" | awk -v version="$candidate_version" '
    index($0, "\"" version "\"") { found=1 }
    END { exit !found }
  '
}

record_patch_report() {
  report_file=$1
  report_id=$2
  report_name=$3
  report_status=$4
  report_detail=$5
  report_detail=$(printf '%s' "$report_detail" | tr '\n|' '  ')
  printf '%s|%s|%s|%s\n' \
    "$report_id" "$report_name" "$report_status" "$report_detail" >> "$report_file"
}

check_candidate_patch_compatibility() {
  prepared_root=$1
  report_file=$prepared_root/patch-report
  candidate_version=$(awk 'NR == 1 {print; exit}' "$prepared_root/usr/lib/chatgpt/version" 2>/dev/null || true)
  : > "$report_file"
  PREPARED_HAS_INCOMPATIBLE_PATCH=0

  for patch_id in $(printf '%s' "$PATCHES" | tr ',' ' '); do
    [ -n "$patch_id" ] || continue
    manifest_file=$(patch_manifest_path "$patch_id" 2>/dev/null || true)
    if [ -z "$manifest_file" ]; then
      record_patch_report "$report_file" "$patch_id" "$patch_id" incompatible 'patch manifest is missing'
      PREPARED_HAS_INCOMPATIBLE_PATCH=1
      continue
    fi
    patch_name=$(awk -F'"' '/"name"[[:space:]]*:/ {print $4; exit}' "$manifest_file")
    patch_name=${patch_name:-$patch_id}
    manifest_id=$(awk -F'"' '/"id"[[:space:]]*:/ {print $4; exit}' "$manifest_file")
    if [ "$manifest_id" != "$patch_id" ]; then
      record_patch_report "$report_file" "$patch_id" "$patch_name" incompatible 'patch manifest id does not match its directory'
      PREPARED_HAS_INCOMPATIBLE_PATCH=1
      continue
    fi
    if ! manifest_supports_version "$manifest_file" applicationVersions "$candidate_version"; then
      record_patch_report "$report_file" "$patch_id" "$patch_name" incompatible "unsupported ChatGPT runtime $candidate_version"
      PREPARED_HAS_INCOMPATIBLE_PATCH=1
      continue
    fi
    if ! manifest_supports_version "$manifest_file" electronVersions "$candidate_version"; then
      record_patch_report "$report_file" "$patch_id" "$patch_name" incompatible "unsupported Electron runtime $candidate_version"
      PREPARED_HAS_INCOMPATIBLE_PATCH=1
      continue
    fi

    record_patch_report "$report_file" "$patch_id" "$patch_name" compatible "supported by ChatGPT runtime $candidate_version"
  done

  if [ "$PREPARED_HAS_INCOMPATIBLE_PATCH" -eq 1 ] && [ "${PREPARE_ALLOW_INCOMPATIBLE-0}" != 1 ]; then
    first_incompatible=$(awk -F'|' '$3 == "incompatible" {print $4; exit}' "$report_file")
    die "the downloaded package is incompatible with an enabled patch: ${first_incompatible:-unknown reason}"
  fi
}

emit_patch_report() {
  report_file=$1
  report_index=0
  [ -r "$report_file" ] || return 0
  while IFS='|' read -r report_id report_name report_status report_detail; do
    [ -n "$report_id" ] || continue
    report_index=$((report_index + 1))
    printf 'patch-report-%s=%s|%s|%s|%s\n' \
      "$report_index" "$report_id" "$report_name" "$report_status" "$report_detail"
  done < "$report_file"
}

disable_patch() {
  disabled_patch=$1
  PATCHES=$(printf '%s' ",${PATCHES-}," | awk -v p=",$disabled_patch," '{gsub(p,","); gsub(/^,|,$/,""); gsub(/,,+/,","); print}')
}

disable_incompatible_staged_patches() {
  report_file=$1
  while IFS='|' read -r report_id report_name report_status report_detail; do
    [ "$report_status" = incompatible ] || continue
    report_id=$(canonical_patch_id "$report_id")
    disable_patch "$report_id"
    [ "$report_id" = native-window-decorations ] || continue
    NATIVE_DECORATIONS=0
  done < "$report_file"
}

write_config() {
  config_directory=$(dirname -- "$CONFIG_FILE")
  mkdir -p "$config_directory"
  config_temporary="$CONFIG_FILE.$$"
  if [ "$NATIVE_DECORATIONS" -eq 1 ]; then
    use_system_window_decorations=true
  else
    use_system_window_decorations=false
  fi
  printf '%s\n' \
    "$APP_ROOT" \
    "use_system_window_decorations=$use_system_window_decorations" \
    "native_decorations=$NATIVE_DECORATIONS" \
    "patches=$PATCHES" \
    "package_version=${INSTALLED_PACKAGE_VERSION-}" > "$config_temporary"
  chmod 600 "$config_temporary"
  mv -f "$config_temporary" "$CONFIG_FILE"
}

write_desktop_entry() {
  desktop_directory=$(dirname -- "$DESKTOP_FILE")
  mkdir -p "$desktop_directory"
  desktop_temporary="$desktop_directory/.chatgpt.$$.desktop"
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
    'Categories=Utility;' \
    'MimeType=x-scheme-handler/codex;text/csv;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.openxmlformats-officedocument.presentationml.presentation;text/tab-separated-values;application/vnd.ms-excel;application/vnd.ms-excel.sheet.macroEnabled.12;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;' > "$desktop_temporary" \
    || { rm -f "$desktop_temporary"; die "could not prepare the desktop entry: $DESKTOP_FILE"; }
  chmod 644 "$desktop_temporary" \
    || { rm -f "$desktop_temporary"; die "could not set desktop entry permissions: $DESKTOP_FILE"; }

  if command -v desktop-file-validate >/dev/null 2>&1; then
    if ! desktop-file-validate "$desktop_temporary"; then
      rm -f "$desktop_temporary"
      die "generated desktop entry is invalid: $DESKTOP_FILE"
    fi
  fi
  if ! mv -f "$desktop_temporary" "$DESKTOP_FILE"; then
    rm -f "$desktop_temporary"
    die "could not install the desktop entry: $DESKTOP_FILE"
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
        "The command was installed at ${COLOR_CYAN}$COMMAND_PATH${COLOR_RESET}, but $HOME/.local/bin is not in the current PATH." \
        'For this terminal session, run:' \
        "  ${COLOR_YELLOW}export PATH=\"\$HOME/.local/bin:\$PATH\"${COLOR_RESET}" \
        'Add that export to ~/.bashrc or ~/.zshrc to make it persistent.'
      ;;
  esac
}

install_prepared_payload() {
  prepared_root=$1
  temporary_root=$(mktemp -d "$APP_ROOT/.install.XXXXXXXX") \
    || die "cannot create a temporary directory inside $APP_ROOT"
  backup_usr="$temporary_root/original-usr"
  backup_etc="$temporary_root/original-etc"
  backup_var="$temporary_root/original-var"
  backup_support="$temporary_root/original-support"
  payload_replaced=0
  support_replaced=0
  etc_backup_created=0
  var_backup_created=0
  etc_payload_created=0
  var_payload_created=0
  support_backup_list=
  support_installed_list=
  state_existed=0
  payload_install_succeeded=0

  if [ -e "$APP_ROOT/state" ] || [ -L "$APP_ROOT/state" ]; then
    state_existed=1
  fi

  rollback_payload() {
    if [ "$support_replaced" -eq 1 ]; then
      failed_support="$temporary_root/failed-support"
      [ -z "$support_installed_list" ] || mkdir -p "$failed_support"
      for support_directory in $support_installed_list; do
        if [ -e "$APP_ROOT/$support_directory" ]; then
          mv "$APP_ROOT/$support_directory" "$failed_support/$support_directory" || true
        fi
      done
      for support_directory in $support_backup_list; do
        if [ -e "$backup_support/$support_directory" ]; then
          mv "$backup_support/$support_directory" "$APP_ROOT/$support_directory" || true
        fi
      done
      support_replaced=0
    fi
    if [ "$payload_replaced" -eq 1 ]; then
      failed_etc="$temporary_root/failed-etc"
      if [ "$etc_payload_created" -eq 1 ] && [ -e "$APP_ROOT/etc" ]; then
        mv "$APP_ROOT/etc" "$failed_etc" || true
      fi
      if [ "$etc_backup_created" -eq 1 ] && [ -e "$backup_etc" ]; then
        mv "$backup_etc" "$APP_ROOT/etc" || true
      fi
      failed_var="$temporary_root/failed-var"
      if [ "$var_payload_created" -eq 1 ] && [ -e "$APP_ROOT/var" ]; then
        mv "$APP_ROOT/var" "$failed_var" || true
      fi
      if [ "$var_backup_created" -eq 1 ] && [ -e "$backup_var" ]; then
        mv "$backup_var" "$APP_ROOT/var" || true
      fi
      failed_usr="$temporary_root/failed-usr"
      if [ -e "$APP_ROOT/usr" ]; then
        mv "$APP_ROOT/usr" "$failed_usr" || true
      fi
      if [ -e "$backup_usr" ]; then
        mv "$backup_usr" "$APP_ROOT/usr" || true
      fi
      payload_replaced=0
    fi
    if [ "$state_existed" -eq 0 ]; then
      rm -rf "$APP_ROOT/state"
    fi
  }

  cleanup() {
    if [ "$payload_install_succeeded" -ne 1 ]; then
      rollback_payload
    fi
    rm -rf "$temporary_root"
  }
  trap cleanup EXIT INT TERM

  [ -d "$prepared_root" ] || die "prepared payload is missing: $prepared_root"
  [ -x "$prepared_root/usr/lib/chatgpt/ChatGPT" ] \
    || die 'prepared payload does not contain the ChatGPT executable'
  [ -f "$prepared_root/usr/share/pixmaps/chatgpt.png" ] \
    || die 'prepared payload does not contain the application icon'

  if [ -e "$APP_ROOT/usr" ]; then
    mv "$APP_ROOT/usr" "$backup_usr" \
      || die 'could not prepare the current installation for replacement'
  fi
  payload_replaced=1
  mv "$prepared_root/usr" "$APP_ROOT/usr" \
    || die 'could not install the downloaded application files'
  if [ -e "$APP_ROOT/etc" ]; then
    mv "$APP_ROOT/etc" "$backup_etc" \
      || die 'could not prepare the current etc files for replacement'
    etc_backup_created=1
  fi
  if [ -e "$APP_ROOT/var" ]; then
    mv "$APP_ROOT/var" "$backup_var" \
      || die 'could not prepare the current var files for replacement'
    var_backup_created=1
  fi
  if [ -e "$prepared_root/etc" ]; then
    etc_payload_created=1
    cp -a "$prepared_root/etc" "$APP_ROOT/etc" \
      || die 'could not install the downloaded etc files'
  fi
  if [ -e "$prepared_root/var" ]; then
    var_payload_created=1
    cp -a "$prepared_root/var" "$APP_ROOT/var" \
      || die 'could not install the downloaded var files'
  fi
  copy_support_files
  launcher_temporary="$temporary_root/chatgpt-launcher"
  write_run_launcher "$launcher_temporary"
  mv -f "$launcher_temporary" "$APP_ROOT/bin/chatgpt-launcher"
  printf 'Application payload installed in %s.\n' "$APP_ROOT"
}

prepare_package_payload() {
  package_path=$1
  prepared_root=$2
  PACKAGE_PATH=$package_path
  [ -r "$PACKAGE_PATH" ] || die "package file is not readable: $PACKAGE_PATH"
  read_package_metadata "$PACKAGE_PATH"
  printf 'Package: %s %s\n' "$package_name" "$package_version"
  mkdir -p "$prepared_root"
  EXTRACTED_PATH="$prepared_root/payload"
  mkdir "$EXTRACTED_PATH"
  extract_data || die 'could not extract the package'
  make_runtime_executables "$EXTRACTED_PATH"
  check_runtime_dependencies_at "$EXTRACTED_PATH" \
    || die 'the downloaded package cannot run with the current host libraries'
  [ -x "$EXTRACTED_PATH/usr/lib/chatgpt/ChatGPT" ] \
    || die 'downloaded package does not contain the ChatGPT executable'
  [ -f "$EXTRACTED_PATH/usr/share/pixmaps/chatgpt.png" ] \
    || die 'downloaded package does not contain the application icon'
  PREPARE_ALLOW_INCOMPATIBLE=${PREPARE_ALLOW_INCOMPATIBLE:-0}
  check_candidate_patch_compatibility "$EXTRACTED_PATH"
  PREPARED_PACKAGE_VERSION=$package_version
}

install_payload() {
  supplied_package=${1-}
  preparation_root=$(mktemp -d "$APP_ROOT/.install.XXXXXXXX") \
    || die "cannot create a temporary directory inside $APP_ROOT"
  if [ -n "$supplied_package" ]; then
    package_path=$supplied_package
  else
    package_path="$preparation_root/$PACKAGE_NAME"
    printf '%s\n' 'Downloading latest ChatGPT package...'
    download_latest_package "$package_path" || die 'download failed'
  fi
  PREPARE_ALLOW_INCOMPATIBLE=0
  prepare_package_payload "$package_path" "$preparation_root"
  INSTALLED_PACKAGE_VERSION=$PREPARED_PACKAGE_VERSION
  install_prepared_payload "$preparation_root/payload"
  rm -rf "$preparation_root"
}

stage_update_package() {
  package_path=$1
  staging_root=$(mktemp -d "$APP_ROOT/update-cache/staging.XXXXXXXX") \
    || die "cannot create update staging directory inside $APP_ROOT"
  PREPARE_ALLOW_INCOMPATIBLE=1
  if ( \
    prepare_package_payload "$package_path" "$staging_root" && \
    printf '%s\n' \
      "package-version=$PREPARED_PACKAGE_VERSION" \
      "native-decorations=$NATIVE_DECORATIONS" \
      "patches=$PATCHES" > "$staging_root/metadata" \
  ); then
    PREPARE_ALLOW_INCOMPATIBLE=0
    STAGED_ROOT=$staging_root
    return 0
  fi
  PREPARE_ALLOW_INCOMPATIBLE=0
  rm -rf "$staging_root"
  return 1
}

install_staged_app() {
  staging_root=$1
  allow_incompatible=${2-}
  check_architecture
  require_host_tools || exit 1
  check_desktop_helpers || exit 1
  [ -d "$staging_root" ] || die "update staging directory is missing: $staging_root"
  case "$staging_root" in
    "$APP_ROOT/update-cache/"*) ;;
    *) die "refusing to install a staging directory outside the update cache: $staging_root" ;;
  esac
  [ -r "$staging_root/metadata" ] || die 'update staging metadata is missing'
  staged_report_file=$staging_root/payload/patch-report
  [ -r "$staged_report_file" ] || die 'update staging patch report is missing'
  staged_package_version=$(awk -F= '$1 == "package-version" {print $2; exit}' "$staging_root/metadata")
  staged_native_decorations=$(awk -F= '$1 == "native-decorations" {print $2; exit}' "$staging_root/metadata")
  [ -n "$staged_package_version" ] || die 'update staging metadata has no package version'
  [ "$staged_native_decorations" = "$NATIVE_DECORATIONS" ] \
    || die 'the staged update was prepared with different native decoration settings'
  if [ "$allow_incompatible" = --allow-incompatible-patches ]; then
    disable_incompatible_staged_patches "$staged_report_file"
  elif awk -F'|' '$3 == "incompatible" {found=1} END {exit !found}' "$staged_report_file" 2>/dev/null; then
    die 'the staged update contains incompatible enabled patches; confirm installation without them'
  fi
  version_is_newer "$staged_package_version" "$INSTALLED_PACKAGE_VERSION" \
    || die 'the staged update is not newer than the installed package'
  [ -d "$staging_root/payload" ] || die 'staged update payload is missing'
  INSTALLED_PACKAGE_VERSION=$staged_package_version
  install_prepared_payload "$staging_root/payload"
}

load_configured_root() {
  load_mode=${1-}
  CONFIG_READ_FILE=$CONFIG_FILE
  [ -r "$CONFIG_READ_FILE" ] || die 'not configured; run install-chatgpt.sh first'
  IFS= read -r APP_ROOT < "$CONFIG_READ_FILE" || true
  [ -n "${APP_ROOT-}" ] || die "installation directory is empty in $CONFIG_FILE"
  case "$APP_ROOT" in
    /*) ;;
    *) die "installation directory must be absolute: $APP_ROOT" ;;
  esac
  if [ "$load_mode" != uninstall ]; then
    [ -x "$APP_ROOT/bin/chatgpt-launcher" ] || die "ChatGPT launcher not found in $APP_ROOT"
  fi
  [ "$load_mode" = uninstall ] && return 0
  configured_window_decorations=$(awk -F= '$1 == "use_system_window_decorations" {print $2; exit}' "$CONFIG_READ_FILE")
  if [ -n "$configured_window_decorations" ]; then
    case "$configured_window_decorations" in
      true|yes|on|1) NATIVE_DECORATIONS=1 ;;
      false|no|off|0) NATIVE_DECORATIONS=0 ;;
      *) die "invalid system window decoration setting in $CONFIG_FILE" ;;
    esac
  else
    NATIVE_DECORATIONS=$(awk -F= '$1 == "native_decorations" {print $2; exit}' "$CONFIG_READ_FILE")
    NATIVE_DECORATIONS=${NATIVE_DECORATIONS:-0}
    case "$NATIVE_DECORATIONS" in
      0|1) ;;
      *) die "invalid native decoration setting in $CONFIG_FILE" ;;
    esac
  fi
  PATCHES=$(awk -F= '$1 == "patches" {print $2; exit}' "$CONFIG_READ_FILE")
  INSTALLED_PACKAGE_VERSION=$(awk -F= '$1 == "package_version" {print $2; exit}' "$CONFIG_READ_FILE")
  if [ -z "$INSTALLED_PACKAGE_VERSION" ] \
    && [ -r "$APP_ROOT/usr/lib/chatgpt/resources/linux-package-metadata.json" ]; then
    INSTALLED_PACKAGE_VERSION=$(awk -F'"' '$2 == "version" {print $4; exit}' \
      "$APP_ROOT/usr/lib/chatgpt/resources/linux-package-metadata.json")
  fi
  patches_setting=$(awk -F= '$1 == "patches" {print "present"; exit}' "$CONFIG_READ_FILE")
  if [ -z "$patches_setting" ]; then
    PATCHES=update-menu,native-window-decorations,mac-layout
  fi
  normalize_patch_list
}

validate_uninstall_root() {
  case "$APP_ROOT" in
    /|"$HOME"|'') die "refusing to uninstall application root: ${APP_ROOT:-empty}" ;;
    "$CODEX_DIRECTORY"|"$CONFIG_DIRECTORY") die "refusing to uninstall a user data directory: $APP_ROOT" ;;
  esac
  case "$APP_ROOT/" in
    "$CODEX_DIRECTORY"/*|"$CONFIG_DIRECTORY"/*) die "refusing to uninstall an application inside a user data directory: $APP_ROOT" ;;
  esac
  [ -d "$APP_ROOT" ] || die "installation directory does not exist: $APP_ROOT"
  resolved_root=$(CDPATH= cd -- "$APP_ROOT" && pwd -P) \
    || die "cannot access installation directory: $APP_ROOT"
  [ "$resolved_root" = "$APP_ROOT" ] \
    || die "refusing to uninstall a symbolic-link installation directory: $APP_ROOT"
}

remove_installation_artifacts() {
  rm -rf \
    "$APP_ROOT/usr" \
    "$APP_ROOT/etc" \
    "$APP_ROOT/var" \
    "$APP_ROOT/bin" \
    "$APP_ROOT/lib" \
    "$APP_ROOT/runtime" \
    "$APP_ROOT/patches" \
    "$APP_ROOT/state" \
    "$APP_ROOT/update-cache"
  rm -f \
    "$APP_ROOT/.chatgpt-install.lock"
  for temporary_path in \
    "$APP_ROOT"/.install.* \
    "$APP_ROOT"/.support.* \
    "$APP_ROOT"/cli.* \
    "$APP_ROOT"/chatgpt-launcher.*; do
    [ -e "$temporary_path" ] || [ -L "$temporary_path" ] || continue
    rm -rf "$temporary_path"
  done
}

remove_user_launchers() {
  command_target=$(readlink -f "$COMMAND_PATH" 2>/dev/null || true)
  if [ "$command_target" = "$APP_ROOT/bin/chatgpt" ]; then
    rm -f "$COMMAND_PATH"
  fi
  rm -f "$DESKTOP_FILE"
  if [ -f "$MIME_APPS_FILE" ] && [ ! -L "$MIME_APPS_FILE" ]; then
    mime_apps_temporary="$MIME_APPS_FILE.$$"
    mime_apps_removed=0
    while IFS= read -r mime_apps_line || [ -n "$mime_apps_line" ]; do
      case "$mime_apps_line" in
        'x-scheme-handler/codex=chatgpt.desktop'|'x-scheme-handler/codex=chatgpt.desktop;')
          mime_apps_removed=1
          ;;
        *) printf '%s\n' "$mime_apps_line" ;;
      esac
    done < "$MIME_APPS_FILE" > "$mime_apps_temporary"
    if [ "$mime_apps_removed" -eq 1 ]; then
      chmod --reference="$MIME_APPS_FILE" "$mime_apps_temporary" 2>/dev/null || true
      mv -f "$mime_apps_temporary" "$MIME_APPS_FILE"
    else
      rm -f "$mime_apps_temporary"
    fi
  fi
  desktop_directory=$(dirname -- "$DESKTOP_FILE")
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_directory" >/dev/null 2>&1 || true
  fi
}

remove_preserved_data() {
  rm -rf -- "$APP_ROOT/user-data" "$CODEX_DIRECTORY" "$CONFIG_DIRECTORY"
}

uninstall_app() {
  preserve_data=1
  case "${1-}" in
    '') ;;
    --no-preserve-data) preserve_data=0 ;;
    *) die 'usage: chatgpt uninstall [--no-preserve-data]' ;;
  esac

  [ "$(id -u)" -ne 0 ] || die 'do not run `chatgpt uninstall` as root'
  for uninstall_path in \
    "$HOME" \
    "$CONFIG_DIRECTORY" \
    "$MIME_APPS_FILE" \
    "$DESKTOP_FILE" \
    "$COMMAND_PATH" \
    "$CODEX_DIRECTORY"; do
    case "$uninstall_path" in
      /*) ;;
      *) die "uninstall path must be absolute: $uninstall_path" ;;
    esac
  done
  validate_uninstall_root
  if is_running_at "$APP_ROOT"; then
    die 'close ChatGPT before uninstalling it'
  fi
  remove_user_launchers
  remove_installation_artifacts
  if [ "$preserve_data" -eq 0 ]; then
    remove_preserved_data
  fi

  if directory_has_content; then
    printf '%s\n' "Uninstalled ChatGPT files from $APP_ROOT."
    printf '%s\n' "The installation directory was kept because it contains unrecognized files: $APP_ROOT"
  else
    rmdir "$APP_ROOT" 2>/dev/null || true
    printf '%s\n' "Uninstalled ChatGPT from $APP_ROOT."
  fi
  if [ "$preserve_data" -eq 1 ]; then
    printf '%s\n' 'Preserved ChatGPT profile data, ~/.codex, and ~/.config/chatgpt.'
  else
    printf '%s\n' 'Removed ChatGPT profile data, ~/.codex, and the ChatGPT configuration file.'
  fi
}

finish_install() {
  write_config
  mkdir -p "$USER_DATA_DIRECTORY" \
    || die "could not create ChatGPT user data directory: $USER_DATA_DIRECTORY"
  chmod 700 "$USER_DATA_DIRECTORY" \
    || die "could not secure ChatGPT user data directory: $USER_DATA_DIRECTORY"
  write_command_link
  write_desktop_entry
  printf '%s\n' \
    '' \
    "${COLOR_GREEN}${COLOR_BOLD}Installed ChatGPT/Codex locally${COLOR_RESET} in ${COLOR_CYAN}$APP_ROOT${COLOR_RESET}" \
    "Command: ${COLOR_CYAN}$COMMAND_PATH${COLOR_RESET}" \
    "Run ${COLOR_YELLOW}${COLOR_BOLD}chatgpt${COLOR_RESET} to open the current directory, or ${COLOR_YELLOW}${COLOR_BOLD}chatgpt update${COLOR_RESET} to update."
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
  PATCHES=update-menu,native-window-decorations,mac-layout
  resolve_install_root "$1"
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
  case ",$PATCHES," in
    *,native-window-decorations,*) ;;
    *) PATCHES=${PATCHES:+$PATCHES,}native-window-decorations ;;
  esac
  normalize_patch_list
  if [ -n "$NATIVE_DECORATION_OVERRIDE" ]; then
    NATIVE_DECORATIONS=$NATIVE_DECORATION_OVERRIDE
  fi
  if is_running_at "$APP_ROOT"; then
    die 'close ChatGPT before updating it'
  fi
  install_payload
  finish_install
  payload_install_succeeded=1
}

check_update_app() {
  check_mode=${1-manual}
  [ "$check_mode" = manual ] || [ "$check_mode" = startup ] \
    || die 'usage: chatgpt check-update [manual|startup]'
  check_architecture
  require_host_tools || exit 1
  update_state_directory=$APP_ROOT/state
  mkdir -p "$update_state_directory" \
    || die "cannot create update state directory: $update_state_directory"
  update_state_file=$update_state_directory/update-check.meta
  update_headers_file=$update_state_directory/update-check.headers.$$
  update_partial_file=$update_state_directory/update-check.partial.$$
  cleanup_update_check() {
    rm -f "$update_headers_file" "$update_partial_file" "$update_partial_file.control"
  }
  trap cleanup_update_check EXIT INT TERM

  update_check_now=$(date +%s)
  last_checked=$(read_state_value "$update_state_file" checked-at)
  stored_url=$(read_state_value "$update_state_file" url)
  stored_etag=$(read_state_value "$update_state_file" etag)
  stored_available_version=$(read_state_value "$update_state_file" available-version)
  stored_content_length=$(read_state_value "$update_state_file" content-length)
  case "$last_checked" in
    ''|*[!0-9]*) last_checked=0 ;;
  esac
  if [ "$check_mode" = startup ] && [ "$stored_url" = "$PACKAGE_URL" ] \
    && [ $((update_check_now - last_checked)) -lt "$AUTOMATIC_UPDATE_INTERVAL" ]; then
    if version_is_newer "$stored_available_version" "$INSTALLED_PACKAGE_VERSION"; then
      printf '%s\n' 'status=update-available'
      printf 'installed-version=%s\n' "${INSTALLED_PACKAGE_VERSION:-unknown}"
      printf 'available-version=%s\n' "$stored_available_version"
      printf 'etag=%s\n' "$stored_etag"
      printf 'content-length=%s\n' "$stored_content_length"
      return 0
    fi
    printf '%s\n' 'status=throttled'
    return 0
  fi

  UPDATE_IF_NONE_MATCH=
  if [ "$stored_url" = "$PACKAGE_URL" ]; then
    UPDATE_IF_NONE_MATCH=$stored_etag
  fi
  fetch_package_headers "$update_headers_file" || die 'update metadata request failed'
  if [ "$update_http_status" = 304 ] \
    && [ "$stored_url" = "$PACKAGE_URL" ] \
    && [ -n "$stored_available_version" ]; then
    metadata_package_version=$stored_available_version
  else
    read_package_metadata_from_remote "$update_partial_file" "$update_headers_file" \
      || die 'could not read package metadata without downloading the full package'
  fi
  [ -n "${update_remote_etag-}" ] || update_remote_etag=$stored_etag
  [ -n "${update_remote_last_modified-}" ] || update_remote_last_modified=$(read_state_value "$update_state_file" last-modified)
  [ -n "${update_remote_content_length-}" ] || update_remote_content_length=$(read_state_value "$update_state_file" content-length)
  write_update_check_state "$update_state_directory" "$update_state_file" \
    || die 'could not save update check state'
  rm -f "$APP_ROOT/update-cache/$PACKAGE_NAME"
  if version_is_newer "$metadata_package_version" "$INSTALLED_PACKAGE_VERSION"; then
    printf '%s\n' 'status=update-available'
    printf 'installed-version=%s\n' "${INSTALLED_PACKAGE_VERSION:-unknown}"
    printf 'available-version=%s\n' "$metadata_package_version"
    printf 'etag=%s\n' "${update_remote_etag-}"
    printf 'content-length=%s\n' "${update_remote_content_length-}"
  else
    printf '%s\n' 'status=up-to-date'
    printf 'installed-version=%s\n' "${INSTALLED_PACKAGE_VERSION:-unknown}"
    printf 'available-version=%s\n' "$metadata_package_version"
  fi
}

install_package_app() {
  package_path=$1
  check_architecture
  require_host_tools || exit 1
  check_host_libraries || exit 1
  check_desktop_helpers || exit 1
  if is_running_at "$APP_ROOT"; then
    die 'close ChatGPT before updating it'
  fi
  install_payload "$package_path"
  finish_install
  payload_install_succeeded=1
}

chatgpt_cli_main() {
  resolve_self_path
  NO_PATCHES=0
  DEBUG=0
  if [ "$#" -gt 0 ]; then
    case "$1" in
      --no-patches) NO_PATCHES=1; shift ;;
      --debug) DEBUG=1; shift ;;
      --native-window-decoration|--no-native-window-decoration)
        parse_native_decoration_option "$1"
        shift
        ;;
    esac
  fi
  case "${1-}" in
    uninstall) load_configured_root uninstall ;;
    *) load_configured_root ;;
  esac
  export CHATGPT_PATCHES=$PATCHES
  export CHATGPT_APP_ROOT=$APP_ROOT
  if [ "$DEBUG" -eq 1 ]; then export CHATGPT_DEBUG=1; fi
  case "${1-}" in
    '')
      [ -z "$NATIVE_DECORATION_OVERRIDE" ] \
        || die 'decoration options can only be used with `chatgpt update`'
       if [ "$NO_PATCHES" -eq 1 ]; then export CHATGPT_NO_PATCHES=1; fi
       export CHATGPT_PATCHES=$PATCHES
       export CHATGPT_APP_ROOT=$APP_ROOT
       exec "$APP_ROOT/bin/chatgpt-launcher" --open-project "$PWD"
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
      [ "$#" -le 2 ] || die 'usage: chatgpt check-update [manual|startup]'
      check_update_app "${2-manual}"
      ;;
    uninstall)
      [ "$#" -le 2 ] || die 'usage: chatgpt uninstall [--no-preserve-data]'
      uninstall_app "${2-}"
      ;;
    download-update)
      [ "$#" -le 2 ] || die 'usage: chatgpt download-update [ETAG]'
      DOWNLOAD_EXPECTED_ETAG=${2-}
      download_update_package
      ;;
    install-package)
      [ "$#" -eq 2 ] || die 'usage: chatgpt install-package PACKAGE'
      install_package_app "$2"
      ;;
    install-staged)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
        || die 'usage: chatgpt install-staged STAGING_DIRECTORY [--allow-incompatible-patches]'
      install_staged_app "$2" "${3-}"
      finish_install
      payload_install_succeeded=1
      rm -rf "$2" "$APP_ROOT/update-cache/$PACKAGE_NAME"
      ;;
    patches)
      [ "$NO_PATCHES" -eq 0 ] || die '--no-patches cannot be used with patch management'
      shift
      case "${1-}" in
        list) printf '%s\n' 'global-menu' 'mac-layout' 'native-window-decorations' 'update-menu' ;;
        status) printf 'Enabled patches: %s\n' "${PATCHES:-none}" ;;
         enable|disable)
           [ "$#" -eq 2 ] || die 'usage: chatgpt patches enable|disable NAME'
           set_patch_enabled "$2" "$1"
           ;;
        *) die 'usage: chatgpt patches list|status|enable NAME|disable NAME' ;;
      esac
      ;;
    decorations)
      [ "$NO_PATCHES" -eq 0 ] || die '--no-patches cannot be used with decoration management'
      [ "$#" -eq 2 ] || die 'usage: chatgpt decorations enable|disable'
      set_native_decorations "$2"
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
      exec "$APP_ROOT/bin/chatgpt-launcher" "$@"
      ;;
  esac
}

parse_install_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        [ "$INSTALL_ACTION" = install ] || die 'conflicting installation options'
        INSTALL_ACTION=help
        ;;
      --check)
        [ "$INSTALL_ACTION" = install ] || die 'conflicting installation options'
        INSTALL_ACTION=check
        ;;
      --native-window-decoration|--no-native-window-decoration)
        [ "$INSTALL_ACTION" = install ] || die 'conflicting installation options'
        parse_native_decoration_option "$1"
        ;;
      --directory)
        [ "$INSTALL_ACTION" = install ] || die 'conflicting installation options'
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
        die "unknown installation option: $1"
        ;;
      *)
        [ "$INSTALL_ACTION" = install ] || die 'conflicting installation options'
        [ -z "$INSTALL_DIRECTORY" ] || die 'installation directory was specified more than once'
        INSTALL_DIRECTORY=$1
        ;;
    esac
    shift
  done
}

chatgpt_install_main() {
  resolve_self_path
  INSTALL_ACTION=install
  INSTALL_DIRECTORY=
  parse_install_arguments "$@"

  case "$INSTALL_ACTION" in
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
}
