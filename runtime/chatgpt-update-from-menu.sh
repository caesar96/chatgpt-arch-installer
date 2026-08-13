#!/bin/sh
set -eu

APP_ROOT=$1
PARENT_PID=$2
CLI_PATH=${3-}
CLI_PATH=${CLI_PATH:-$APP_ROOT/bin/chatgpt}
PACKAGE_PATH=${4-}

parent_is_running() {
  [ -r "/proc/$PARENT_PID/stat" ] || return 1
  parent_state=$(awk '{print $3}' "/proc/$PARENT_PID/stat")
  [ "$parent_state" != Z ]
}

parent_is_chatgpt() {
  expected_executable=$(readlink -f "$APP_ROOT/usr/lib/chatgpt/ChatGPT" 2>/dev/null || true)
  actual_executable=$(readlink -f "/proc/$PARENT_PID/exe" 2>/dev/null || true)
  [ -n "$expected_executable" ] && [ "$actual_executable" = "$expected_executable" ]
}

app_is_running() {
  expected_executable=$(readlink -f "$APP_ROOT/usr/lib/chatgpt/ChatGPT" 2>/dev/null || true)
  [ -n "$expected_executable" ] || return 1
  for process_dir in /proc/[0-9]*; do
    [ -e "$process_dir/exe" ] || continue
    actual_executable=$(readlink -f "$process_dir/exe" 2>/dev/null || true)
    [ "$actual_executable" = "$expected_executable" ] && return 0
  done
  return 1
}

stop_app_processes() {
  expected_executable=$(readlink -f "$APP_ROOT/usr/lib/chatgpt/ChatGPT" 2>/dev/null || true)
  [ -n "$expected_executable" ] || return 0
  for process_dir in /proc/[0-9]*; do
    [ -e "$process_dir/exe" ] || continue
    actual_executable=$(readlink -f "$process_dir/exe" 2>/dev/null || true)
    [ "$actual_executable" = "$expected_executable" ] || continue
    process_id=${process_dir##*/}
    kill -TERM "$process_id" 2>/dev/null || true
  done
}

state_directory=$APP_ROOT/state
mkdir -p "$state_directory" 2>/dev/null || true
update_log=$state_directory/update-from-menu.log
temporary_log=$update_log.$$

relaunch_app() {
  if [ -x "$APP_ROOT/bin/chatgpt-launcher" ]; then
    exec "$APP_ROOT/bin/chatgpt-launcher"
  fi
  if [ -n "$CLI_PATH" ] && [ -x "$CLI_PATH" ]; then
    exec "$CLI_PATH"
  fi
  return 1
}

record_failure() {
  update_status=$1
  failure_message=${2-}
  if [ -n "$failure_message" ]; then
    printf '%s\n' "$failure_message" > "$temporary_log" 2>/dev/null || true
  fi
  mv -f "$temporary_log" "$update_log" 2>/dev/null || true
  printf 'failed:%s\n' "$update_status" > "$state_directory/update-from-menu.status" 2>/dev/null || true
  if command -v notify-send >/dev/null 2>&1; then
    notify-send 'ChatGPT update failed' "See $update_log" >/dev/null 2>&1 || true
  fi
  if relaunch_app; then
    exit 0
  fi
  exit "$update_status"
}

wait_for_app_exit() {
  wait_ticks=0
  while parent_is_running || app_is_running; do
    if [ "$wait_ticks" -ge 4 ]; then
      if parent_is_running; then
        parent_is_chatgpt || return 1
        kill -TERM "$PARENT_PID" 2>/dev/null || true
      fi
      stop_app_processes
    fi
    if [ "$wait_ticks" -ge 32 ]; then
      return 1
    fi
    sleep 0.25
    wait_ticks=$((wait_ticks + 1))
  done
}

if ! wait_for_app_exit; then
  record_failure 1 'ChatGPT could not be closed cleanly before the update started.'
fi

if [ -n "$PACKAGE_PATH" ]; then
  if "$APP_ROOT/bin/chatgpt" install-package "$PACKAGE_PATH" >"$temporary_log" 2>&1; then
    update_status=0
  else
    update_status=$?
  fi
else
  if "$APP_ROOT/bin/chatgpt" update >"$temporary_log" 2>&1; then
    update_status=0
  else
    update_status=$?
  fi
fi

if [ "$update_status" -eq 0 ]; then
  [ -z "$PACKAGE_PATH" ] || rm -f "$PACKAGE_PATH"
  mv -f "$temporary_log" "$update_log" 2>/dev/null || true
  printf '%s\n' 'success' > "$state_directory/update-from-menu.status" 2>/dev/null || true
  if relaunch_app; then
    exit 0
  fi
  record_failure 1 'ChatGPT was updated, but could not be relaunched.'
fi
record_failure "$update_status"
