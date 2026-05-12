#!/usr/bin/env bash
set -euo pipefail

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
APP_PORT="${APP_PORT:-15034}"
LOG_DIR="/var/log/agent-app"
MONITOR_PATH="$AGENT_HOME/bin/monitor.sh"

run() {
  printf '\n$ %s\n' "$*"
  "$@"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo so all verification commands can read system state."
    exit 1
  fi
}

main() {
  require_root

  run /usr/sbin/sshd -T
  run ss -tulnp
  run ufw status verbose

  run id agent-admin
  run id agent-dev
  run id agent-test

  run ls -ld "$AGENT_HOME"
  run ls -ld "$AGENT_HOME/upload_files"
  run ls -ld "$AGENT_HOME/api_keys"
  run ls -ld "$AGENT_HOME/bin"
  run ls -ld "$LOG_DIR"

  run getfacl "$AGENT_HOME/upload_files"
  run getfacl "$AGENT_HOME/api_keys"
  run getfacl "$AGENT_HOME/bin"
  run getfacl "$LOG_DIR"

  run sudo -u agent-test test ! -r "$AGENT_HOME/api_keys/t_secret.key"
  run sudo -u agent-test test ! -x "$AGENT_HOME/bin"
  run sudo -u agent-test test ! -w "$LOG_DIR"

  run ss -ltnp
  run sudo -u agent-admin env AGENT_HOME="$AGENT_HOME" "$MONITOR_PATH"
  run tail -n 10 "$LOG_DIR/monitor.log"
  run crontab -u agent-admin -l

  printf '\nVerification commands completed. Review the output for port %s, Agent READY evidence, and monitor.log growth after cron runs.\n' "$APP_PORT"
}

main "$@"
