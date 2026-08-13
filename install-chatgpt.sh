#!/bin/sh
set -eu

ENTRYPOINT_PATH=$(readlink -f "$0")
SOURCE_ROOT=$(CDPATH= cd -- "$(dirname -- "$ENTRYPOINT_PATH")" && pwd -P)
export CHATGPT_ENTRYPOINT=$ENTRYPOINT_PATH
export CHATGPT_SOURCE_ROOT=$SOURCE_ROOT

# The shared core contains both the initial-install operations and the public
# chatgpt command implementation. This entrypoint exposes only installation.
. "$SOURCE_ROOT/lib/chatgpt-core.sh"
chatgpt_install_main "$@"
