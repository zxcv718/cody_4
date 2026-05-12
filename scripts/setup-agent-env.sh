#!/usr/bin/env bash
set -euo pipefail

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
APP_PORT="${APP_PORT:-15034}"
APP_USER="agent-admin"
DEV_USER="agent-dev"
TEST_USER="agent-test"
COMMON_GROUP="agent-common"
CORE_GROUP="agent-core"
LOG_DIR="/var/log/agent-app"
KEY_FILE="$AGENT_HOME/api_keys/t_secret.key"
APP_TARGET="$AGENT_HOME/agent-app"
MONITOR_TARGET="$AGENT_HOME/bin/monitor.sh"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
APP_SOURCE="${APP_SOURCE:-$REPO_ROOT/agent-app}"
MONITOR_SOURCE="${MONITOR_SOURCE:-$REPO_ROOT/monitor.sh}"

log() {
  printf '\n==> %s\n' "$1"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo on the Ubuntu VM."
    exit 1
  fi
}

install_packages() {
  log "Installing required packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server ufw acl cron procps iproute2
  systemctl enable --now ssh
  systemctl enable --now cron
}

configure_ssh() {
  log "Configuring SSH on port 20022 and disabling root login"
  install -d -m 755 /etc/ssh/sshd_config.d
  tee /etc/ssh/sshd_config.d/99-agent.conf >/dev/null <<EOF
Port 20022
PermitRootLogin no
EOF
  /usr/sbin/sshd -t
  # Ubuntu 24.04 can start sshd through ssh.socket, which keeps port 22 open
  # even when sshd_config says Port 20022. Run ssh.service directly instead.
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl enable ssh.service >/dev/null
  systemctl restart ssh.service
}

configure_ufw() {
  log "Configuring UFW inbound policy"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 20022/tcp
  ufw allow "$APP_PORT/tcp"
  ufw --force enable
}

ensure_group() {
  local group_name="$1"
  if ! getent group "$group_name" >/dev/null; then
    groupadd "$group_name"
  fi
}

ensure_user() {
  local user_name="$1"
  if ! id -u "$user_name" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user_name"
  fi
}

configure_users_and_groups() {
  log "Creating users and groups"
  ensure_group "$COMMON_GROUP"
  ensure_group "$CORE_GROUP"

  ensure_user "$APP_USER"
  ensure_user "$DEV_USER"
  ensure_user "$TEST_USER"

  usermod -aG "$COMMON_GROUP,$CORE_GROUP" "$APP_USER"
  usermod -aG "$COMMON_GROUP,$CORE_GROUP" "$DEV_USER"
  usermod -aG "$COMMON_GROUP" "$TEST_USER"
}

configure_directories() {
  log "Creating directories, permissions, and ACLs"
  install -d "$AGENT_HOME"
  install -d "$AGENT_HOME/upload_files"
  install -d "$AGENT_HOME/api_keys"
  install -d "$AGENT_HOME/bin"
  install -d "$LOG_DIR"

  chown "$APP_USER:$CORE_GROUP" "$AGENT_HOME"
  chown "$APP_USER:$COMMON_GROUP" "$AGENT_HOME/upload_files"
  chown "$APP_USER:$CORE_GROUP" "$AGENT_HOME/api_keys"
  chown "$DEV_USER:$CORE_GROUP" "$AGENT_HOME/bin"
  chown "$APP_USER:$CORE_GROUP" "$LOG_DIR"

  chmod 2750 "$AGENT_HOME"
  chmod 2770 "$AGENT_HOME/upload_files"
  chmod 2770 "$AGENT_HOME/api_keys"
  chmod 2770 "$AGENT_HOME/bin"
  chmod 2770 "$LOG_DIR"

  setfacl -m "g:$COMMON_GROUP:--x" "/home/$APP_USER"
  setfacl -m "g:$COMMON_GROUP:--x" "$AGENT_HOME"
  setfacl -m "g:$CORE_GROUP:r-x" "$AGENT_HOME"

  setfacl -m "g:$COMMON_GROUP:rwx" "$AGENT_HOME/upload_files"
  setfacl -d -m "g:$COMMON_GROUP:rwx" "$AGENT_HOME/upload_files"

  setfacl -m "g:$CORE_GROUP:rwx" "$AGENT_HOME/api_keys"
  setfacl -d -m "g:$CORE_GROUP:rwx" "$AGENT_HOME/api_keys"

  setfacl -m "g:$CORE_GROUP:rwx" "$AGENT_HOME/bin"
  setfacl -d -m "g:$CORE_GROUP:rwx" "$AGENT_HOME/bin"

  setfacl -m "g:$CORE_GROUP:rwx" "$LOG_DIR"
  setfacl -d -m "g:$CORE_GROUP:rwx" "$LOG_DIR"
}

install_agent_files() {
  log "Installing agent app, key file, and monitor.sh"

  if [ ! -f "$APP_SOURCE" ]; then
    echo "agent-app binary not found: $APP_SOURCE"
    exit 1
  fi

  if [ ! -f "$MONITOR_SOURCE" ]; then
    echo "monitor.sh not found: $MONITOR_SOURCE"
    exit 1
  fi

  install -o "$APP_USER" -g "$CORE_GROUP" -m 750 "$APP_SOURCE" "$APP_TARGET"
  install -o "$DEV_USER" -g "$CORE_GROUP" -m 750 "$MONITOR_SOURCE" "$MONITOR_TARGET"

  printf 'agent_api_key_test\n' > "$KEY_FILE"
  chown "$APP_USER:$CORE_GROUP" "$KEY_FILE"
  chmod 660 "$KEY_FILE"
}

register_cron() {
  local tmp_cron
  local cron_line

  log "Registering agent-admin cron job"
  tmp_cron=$(mktemp)
  cron_line="* * * * * AGENT_HOME=$AGENT_HOME $MONITOR_TARGET >/tmp/agent-monitor-cron.out 2>/tmp/agent-monitor-cron.err"

  crontab -u "$APP_USER" -l 2>/dev/null | grep -Fv "$MONITOR_TARGET" > "$tmp_cron" || true
  printf '%s\n' "$cron_line" >> "$tmp_cron"
  crontab -u "$APP_USER" "$tmp_cron"
  rm -f "$tmp_cron"
}

print_next_steps() {
  cat <<EOF

Setup complete.

Start the app:
  sudo -u $APP_USER env \\
    AGENT_HOME=$AGENT_HOME \\
    AGENT_PORT=$APP_PORT \\
    AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files \\
    AGENT_KEY_PATH=$KEY_FILE \\
    AGENT_LOG_DIR=$LOG_DIR \\
    $APP_TARGET

Run the monitor manually after the app is ready:
  sudo -u $APP_USER env AGENT_HOME=$AGENT_HOME $MONITOR_TARGET

Run verification:
  sudo $REPO_ROOT/scripts/verify-agent-env.sh
EOF
}

main() {
  require_root
  install_packages
  configure_ssh
  configure_ufw
  configure_users_and_groups
  configure_directories
  install_agent_files
  register_cron
  print_next_steps
}

main "$@"
