#!/usr/bin/env bash
# =============================================================================
# UniFi OS Server: make an imported site the default site
#
# Run the reviewed local script with --check first. See README.md.
#
# NOT SUPPORTED BY UBIQUITI. Direct database edits may break with updates.
# Use at your own risk.
#
# Method: Ubiquiti Community Wiki, "Changing the Default Site in UniFi"
# https://ubntwiki.com/guides/changing_the_default_site_in_unifi
# =============================================================================

set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ----------------------------------------------------------------------------
# Output and input
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; exit 1; }
step() { STEP="$*"; printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }

# The script itself arrives on stdin (the pasted block), so every answer is
# read from the keyboard (/dev/tty), never from stdin.
ask() {
  local answer=""
  printf '%s' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || fail "Could not read from the keyboard."
  ANSWER="$answer"
}

ask_yn() {
  while true; do
    ask "$1 (y/n): "
    case "$ANSWER" in
      y|Y|yes|Yes|YES) return 0 ;;
      n|N|no|No|NO)    return 1 ;;
    esac
    say "Please answer y or n."
  done
}

# Counts non-empty lines.
count_lines() { printf '%s' "$1" | grep -c . || true; }

STEP="start"
trap 'printf "\n"; warn "Stopped by user during: $STEP"; exit 130' INT

# ----------------------------------------------------------------------------
# Container and Mongo access
# ----------------------------------------------------------------------------

# Rootless podman runs as the service account. sudo -u fails from a directory
# that account cannot read ("cannot chdir ... Permission denied"), so always
# run from /tmp.
as_svc() {
  (cd /tmp && sudo -u "$SVC_USER" XDG_RUNTIME_DIR="/run/user/$SVC_UID" podman "$@" </dev/null)
}

in_container() { as_svc exec "$CONTAINER" "$@"; }

mongo_js() {
  in_container "$MONGO_CLIENT" --quiet --port "$MONGO_PORT" "$MONGO_DB" --eval "$1"
}

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------

check_basics() {
  :
  local cmd
  for cmd in sudo systemctl ps getent id awk grep; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
  done
  sudo -n true </dev/null || fail "Authenticate with sudo -v before running this script."
  ok "sudo access confirmed."
}

service_running() {
  local out
  out=$(systemctl status "$UNIT" --no-pager 2>/dev/null </dev/null)
  [[ $out == *"active (running)"* ]]
}

find_service_unit() {
  local units files
  units=$(systemctl list-unit-files 'uosserver*.service' --no-legend 2>/dev/null </dev/null \
    | awk '{print $1}' | grep -v -- '-updater' || true)
  if [[ $(count_lines "$units") -eq 1 ]]; then
    UNIT="${units%.service}"
  elif printf '%s\n' "$units" | grep -qx 'uosserver.service'; then
    UNIT="uosserver"
  else
    # Fallback: any unit that starts the UniFi OS Server binary.
    files=$(grep -l '/var/lib/uosserver/bin/uosserver-service' \
      /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service 2>/dev/null \
      | grep -v -- '-updater' | head -n1 || true)
    [[ -n $files ]] || fail "No UniFi OS Server systemd unit found. Is UniFi OS Server installed on this machine?"
    UNIT=$(basename "$files" .service)
  fi
  service_running || fail "$UNIT is not active (running). Check: systemctl status $UNIT --no-pager"
  ok "Service unit: $UNIT (active, running)"
}

find_service_user() {
  local owners owner candidates
  # ps provides account ownership; no process selection or signalling occurs.
  # shellcheck disable=SC2009
  owners=$(ps -eo user,pid,comm | grep -Ei 'podman|conmon|catatonit' \
    | awk '{print $1}' | grep -vx root | sort -u || true)
  candidates=$(getent passwd </dev/null | grep -Ei 'unifi|uos' | cut -d: -f1 || true)
  SVC_USER=""

  if [[ $(count_lines "$owners") -eq 1 ]]; then
    owner="${owners%+}"
    if [[ $owner =~ ^[0-9]+$ ]]; then
      # ps printed a numeric UID instead of a name.
      SVC_USER=$(getent passwd "$owner" </dev/null | cut -d: -f1 || true)
    else
      # ps may truncate long names, e.g. "uosserv+".
      local match
      match=$(printf '%s\n' "$candidates" | awk -v o="$owner" 'index($0, o) == 1')
      [[ $(count_lines "$match") -eq 1 ]] && SVC_USER="$match"
    fi
  fi
  if [[ -z $SVC_USER ]] && printf '%s\n' "$candidates" | grep -qx 'uosserver'; then
    SVC_USER="uosserver"
  fi
  [[ -n $SVC_USER ]] || fail "Could not find the account that runs the UniFi OS Server containers."

  SVC_UID=$(id -u "$SVC_USER" 2>/dev/null) || fail "Could not get the UID of $SVC_USER."
  ls -d "/run/user/$SVC_UID" >/dev/null 2>&1 || fail "Runtime directory /run/user/$SVC_UID does not exist."
  ok "Service account: $SVC_USER (UID $SVC_UID)"
}

find_container() {
  local rows names pick
  rows=$(as_svc ps --format "{{.Names}}\t{{.Image}}" 2>&1) || { say "$rows"; fail "podman ps failed as $SVC_USER."; }
  names=$(printf '%s\n' "$rows" | awk 'NF {print $1}')
  [[ $(count_lines "$names") -gt 0 ]] || fail "No running containers found for $SVC_USER."

  pick=$(printf '%s\n' "$rows" | awk 'NF && $2 ~ /uosserver/ {print $1}')
  if [[ $(count_lines "$pick") -ne 1 ]]; then
    if printf '%s\n' "$names" | grep -qx 'uosserver'; then
      pick="uosserver"
    elif [[ $(count_lines "$names") -eq 1 ]]; then
      pick="$names"
    else
      say "$rows"
      fail "Could not tell which container is UniFi OS Server."
    fi
  fi
  CONTAINER="$pick"
  CONTAINER_IMAGE=$(printf '%s\n' "$rows" | awk -v c="$CONTAINER" '$1 == c {print $2; exit}')
  ok "Container: $CONTAINER (${CONTAINER_IMAGE:-image unknown})"
}

find_mongo() {
  local found props value
  found=$(in_container which mongosh mongo 2>/dev/null || true)
  MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongo$' | head -n1 || true)
  [[ -n $MONGO_CLIENT ]] || MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongosh$' | head -n1 || true)
  [[ -n $MONGO_CLIENT ]] || fail "No mongo or mongosh client found inside $CONTAINER."

  # The UniFi Network app's own settings name its database and port.
  MONGO_PORT="27117"; MONGO_DB="ace"
  props=$(in_container cat /usr/lib/unifi/data/system.properties 2>/dev/null || true)
  if [[ -n $props ]]; then
    value=$(printf '%s\n' "$props" | sed -n 's/^[[:space:]]*unifi\.db\.port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | tail -n1)
    [[ -n $value ]] && MONGO_PORT="$value"
    value=$(printf '%s\n' "$props" | sed -n 's/^[[:space:]]*unifi\.db\.name[[:space:]]*=[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | tail -n1)
    [[ -n $value ]] && MONGO_DB="$value"
    if printf '%s\n' "$props" | grep -Eq '^[[:space:]]*db\.mongo\.local[[:space:]]*=[[:space:]]*false'; then
      fail "This install uses an external MongoDB (db.mongo.local=false). Not supported by this script."
    fi
  fi

  local out
  out=$(mongo_js 'print("UOSDB " + db.getName())' 2>&1)
  [[ $out == *"UOSDB $MONGO_DB"* ]] || { say "$out"; fail "Could not open database $MONGO_DB on port $MONGO_PORT."; }
  ok "Mongo: $MONGO_CLIENT, port $MONGO_PORT, database $MONGO_DB"
}

# ----------------------------------------------------------------------------
# Read-only validation. The Mongo program prints only identifiers and counters.
# ----------------------------------------------------------------------------
validate_sites() {
  local out
  out=$(mongo_js "var target = '$TARGET_ID'; var action = 'check';
$(cat "$SCRIPT_DIR/migration.js")" 2>/dev/null) || fail "Database validation failed; no changes made."
  printf '%s\n' "$out" | grep '^UOS ' || true
  [[ $(printf '%s\n' "$out" | grep -c '^UOS READY$') == 1 ]] || fail "Preflight rejected the database state."
}

usage() {
  say "Usage: bash $0 --check [--site OBJECT_ID]"
}

main() {
  TARGET_ID=""
  while (( $# )); do
    case "$1" in
      --check) shift ;;
      --site) (( $# >= 2 )) || fail "--site requires an ObjectId."; TARGET_ID="$2"; shift 2 ;;
      --help|-h) usage; return 0 ;;
      *) usage; fail "Unknown option." ;;
    esac
  done
  [[ -z $TARGET_ID || $TARGET_ID =~ ^[0-9a-f]{24}$ ]] || fail "Select a lowercase 24-digit hexadecimal ObjectId."
  step "Discovery (read only)"
  check_basics
  find_service_unit
  find_service_user
  find_container
  find_mongo
  step "Preflight (read only)"
  validate_sites
  ok "Preflight passed. No database writes or service restarts performed."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
