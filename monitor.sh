#!/usr/bin/env bash
set -uo pipefail

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
APP_PATH="${APP_PATH:-$AGENT_HOME/agent-app}"
APP_USER="${APP_USER:-agent-admin}"
APP_PORT="${APP_PORT:-15034}"
LOG_FILE="${LOG_FILE:-/var/log/agent-app/monitor.log}"
DISK_PATH="${DISK_PATH:-/}"
CPU_SAMPLE_INTERVAL="${CPU_SAMPLE_INTERVAL:-1}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"
MAX_LOG_FILES="${MAX_LOG_FILES:-10}"

PID=""
CPU="0"
MEM="0"
DISK_USED="0"

print_header() {
  echo "====== SYSTEM MONITOR RESULT ======"
  echo
}

fail_health_check() {
  echo "$1"
  exit 1
}

find_app_pid() {
  local pid

  pid=$(pgrep -u "$APP_USER" -f "$APP_PATH" 2>/dev/null | paste -sd, - || true)

  if [ -z "$pid" ]; then
    pid=$(pgrep -u "$APP_USER" -x "$(basename "$APP_PATH")" 2>/dev/null | paste -sd, - || true)
  fi

  printf '%s' "$pid"
}

check_process() {
  PID=$(find_app_pid)

  echo "[HEALTH CHECK]"
  if [ -z "$PID" ]; then
    fail_health_check "Checking process '$APP_PATH'... [FAIL]"
  fi

  echo "Checking process '$APP_PATH'... [OK] (PID: $PID)"
}

check_port() {
  if ! command -v ss >/dev/null 2>&1; then
    fail_health_check "Checking port $APP_PORT... [FAIL] (ss command not found)"
  fi

  if ! ss -H -ltn "sport = :$APP_PORT" 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])$APP_PORT$"; then
    fail_health_check "Checking port $APP_PORT... [FAIL]"
  fi

  echo "Checking port $APP_PORT... [OK]"
  echo
}

check_firewall() {
  local ufw_active="false"
  local firewalld_active="false"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet ufw 2>/dev/null; then
      ufw_active="true"
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
      firewalld_active="true"
    fi
  fi

  if [ "$ufw_active" = "false" ] && command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | awk 'NR == 1 {print tolower($0)}' | grep -q "active"; then
      ufw_active="true"
    fi
  fi

  if [ "$ufw_active" = "false" ] && [ -r /etc/ufw/ufw.conf ]; then
    if awk -F= 'tolower($1) == "enabled" && tolower($2) == "yes" {found = 1} END {exit !found}' /etc/ufw/ufw.conf; then
      ufw_active="true"
    fi
  fi

  if [ "$ufw_active" = "false" ] && [ "$firewalld_active" = "false" ]; then
    echo "[WARNING] Firewall is not active"
  fi
}

collect_cpu_usage() {
  local idle1
  local idle2
  local total1
  local total2

  read -r idle1 total1 < <(
    awk 'NR == 1 {
      idle = $5 + $6
      total = 0
      for (i = 2; i <= NF; i++) total += $i
      print idle, total
      exit
    }' /proc/stat
  )

  sleep "$CPU_SAMPLE_INTERVAL"

  read -r idle2 total2 < <(
    awk 'NR == 1 {
      idle = $5 + $6
      total = 0
      for (i = 2; i <= NF; i++) total += $i
      print idle, total
      exit
    }' /proc/stat
  )

  awk -v idle_delta="$((idle2 - idle1))" -v total_delta="$((total2 - total1))" \
    'BEGIN {
      if (total_delta <= 0) {
        printf "0.0"
      } else {
        printf "%.1f", ((total_delta - idle_delta) / total_delta) * 100
      }
    }'
}

collect_memory_usage() {
  awk '
    /^MemTotal:/ { total = $2 }
    /^MemAvailable:/ { available = $2 }
    END {
      if (total <= 0) {
        printf "0.0"
      } else {
        printf "%.1f", ((total - available) / total) * 100
      }
    }
  ' /proc/meminfo
}

collect_resources() {
  CPU=$(collect_cpu_usage)
  MEM=$(collect_memory_usage)
  CPU="${CPU:-0}"
  MEM="${MEM:-0}"
  DISK_USED=$(
    df -P "$DISK_PATH" 2>/dev/null |
      awk 'NR == 2 && $2 > 0 {printf "%.1f", ($3 / $2) * 100}'
  )
  DISK_USED="${DISK_USED:-0}"
}

print_resources() {
  echo "[RESOURCE MONITORING]"
  echo "CPU Usage : ${CPU}%"
  echo "MEM Usage : ${MEM}%"
  echo "DISK Used  : ${DISK_USED}%"
  echo
}

is_greater_than() {
  awk "BEGIN { exit !($1 > $2) }"
}

print_threshold_warnings() {
  if is_greater_than "$CPU" 20; then
    echo "[WARNING] CPU threshold exceeded (${CPU}% > 20%)"
  fi

  if is_greater_than "$MEM" 10; then
    echo "[WARNING] MEM threshold exceeded (${MEM}% > 10%)"
  fi

  if is_greater_than "$DISK_USED" 80; then
    echo "[WARNING] DISK_USED threshold exceeded (${DISK_USED}% > 80%)"
  fi
}

rotate_logs() {
  local incoming_size="${1:-0}"
  local last_index
  local size
  local i

  if [ "$MAX_LOG_FILES" -lt 2 ]; then
    return 0
  fi

  if [ ! -f "$LOG_FILE" ]; then
    return 0
  fi

  size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$incoming_size" -gt 0 ]; then
    if [ $((size + incoming_size)) -le "$MAX_LOG_SIZE" ]; then
      return 0
    fi
  else
    if [ "$size" -lt "$MAX_LOG_SIZE" ]; then
      return 0
    fi
  fi

  last_index=$((MAX_LOG_FILES - 1))
  if ! rm -f "${LOG_FILE}.${last_index}"; then
    return 1
  fi

  for ((i = last_index - 1; i >= 1; i--)); do
    if [ -f "${LOG_FILE}.${i}" ]; then
      if ! mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"; then
        return 1
      fi
    fi
  done

  if ! mv "$LOG_FILE" "${LOG_FILE}.1"; then
    return 1
  fi
}

append_log() {
  local log_line
  local log_line_size
  local timestamp

  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  log_line=$(printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%' \
    "$timestamp" "$PID" "$CPU" "$MEM" "$DISK_USED")
  log_line_size=$(printf '%s\n' "$log_line" | wc -c)

  if ! rotate_logs "$log_line_size"; then
    echo "[ERROR] Cannot rotate log file: $LOG_FILE"
    exit 1
  fi

  if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "[ERROR] Cannot write log file: $LOG_FILE"
    exit 1
  fi

  if ! printf '%s\n' "$log_line" >> "$LOG_FILE"; then
    echo "[ERROR] Cannot append to log file: $LOG_FILE"
    exit 1
  fi

  echo
  echo "[INFO] Log appended: $LOG_FILE"
}

main() {
  print_header
  check_process
  check_port
  check_firewall
  collect_resources
  print_resources
  print_threshold_warnings
  append_log
}

main "$@"
