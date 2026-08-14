#!/bin/sh
set -eu

APP_ROOT=$1
APP_PID=$2
CLI_PATH=$3
ACTION=$4

case "$ACTION" in
  enable|disable) ;;
  *)
    printf 'chatgpt: invalid window decoration action: %s\n' "$ACTION" >&2
    exit 2
    ;;
esac

state_directory=$APP_ROOT/state
mkdir -p "$state_directory"
log_file=$state_directory/native-decoration-menu.log

while kill -0 "$APP_PID" 2>/dev/null; do
  sleep 0.1
done

if "$CLI_PATH" decorations "$ACTION" >"$log_file" 2>&1; then
  printf 'Native window decorations %s.\n' "$ACTION" >>"$log_file"
else
  printf 'chatgpt: could not %s native window decorations\n' "$ACTION" >>"$log_file"
  exit 1
fi

if [ -x "$APP_ROOT/bin/chatgpt-launcher" ]; then
  exec "$APP_ROOT/bin/chatgpt-launcher"
fi
if [ -x "$CLI_PATH" ]; then
  exec "$CLI_PATH"
fi

printf 'chatgpt: no launcher was found after changing native window decorations\n' >>"$log_file"
exit 1
