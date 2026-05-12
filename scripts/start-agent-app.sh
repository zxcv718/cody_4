#!/usr/bin/env bash
set -euo pipefail

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_UPLOAD_DIR="${AGENT_UPLOAD_DIR:-$AGENT_HOME/upload_files}"
AGENT_KEY_PATH="${AGENT_KEY_PATH:-$AGENT_HOME/api_keys/t_secret.key}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
APP_USER="${APP_USER:-agent-admin}"
APP_PATH="${APP_PATH:-$AGENT_HOME/agent-app}"

run_app() {
  env \
    AGENT_HOME="$AGENT_HOME" \
    AGENT_PORT="$AGENT_PORT" \
    AGENT_UPLOAD_DIR="$AGENT_UPLOAD_DIR" \
    AGENT_KEY_PATH="$AGENT_KEY_PATH" \
    AGENT_LOG_DIR="$AGENT_LOG_DIR" \
    "$APP_PATH"
}

if [ "$(id -un)" = "$APP_USER" ]; then
  run_app
else
  exec sudo -u "$APP_USER" env \
    AGENT_HOME="$AGENT_HOME" \
    AGENT_PORT="$AGENT_PORT" \
    AGENT_UPLOAD_DIR="$AGENT_UPLOAD_DIR" \
    AGENT_KEY_PATH="$AGENT_KEY_PATH" \
    AGENT_LOG_DIR="$AGENT_LOG_DIR" \
    "$APP_PATH"
fi
