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
  (cd /tmp && sudo -n -H -u "$SVC_USER" XDG_RUNTIME_DIR="/run/user/$SVC_UID" podman --remote=false "$@" </dev/null)
}

in_container() { as_svc exec "$CONTAINER" "$@"; }

mongo_js() {
  in_container "$MONGO_CLIENT" --norc --quiet --host localhost --port "$MONGO_PORT" "$MONGO_DB" --eval "$1"
}

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------

check_basics() {
  [[ $(uname -s) == Linux ]] || fail "Linux is required."
  case $(uname -m) in x86_64|aarch64) ;; *) fail "Unsupported architecture." ;; esac
  local cmd
  for cmd in sudo systemctl id awk grep stat sed tail head uname cat dirname podman; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
  done
  sudo -n true </dev/null || fail "Authenticate with sudo -v before running this script."
  ok "sudo access confirmed."
}

service_running() {
  [[ $(systemctl show "$UNIT" -p ActiveState --value 2>/dev/null) == active &&
     $(systemctl show "$UNIT" -p SubState --value 2>/dev/null) == running ]]
}

find_service_unit() {
  local units
  units=$(systemctl list-unit-files 'uosserver*.service' --no-legend 2>/dev/null \
    | awk '$1 !~ /-updater/ {print $1}') || fail "Cannot enumerate service units."
  [[ $(count_lines "$units") == 1 ]] || fail "Expected one UniFi OS Server unit."
  UNIT="$units"
  service_running || fail "UniFi OS Server is not running."
  ok "UniFi OS Server service active."
}

find_service_user() {
  local configured
  configured=$(systemctl show "$UNIT" -p User --value 2>/dev/null) || fail "Cannot inspect service account."
  # Some installations have a root supervisor and a dedicated container account.
  SVC_USER="${configured:-uosserver}"
  [[ $SVC_USER != root ]] || SVC_USER=uosserver
  [[ $SVC_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "Unsupported service account."
  SVC_UID=$(id -u "$SVC_USER" 2>/dev/null) || fail "Service account not found."
  [[ $SVC_UID != 0 && -d /run/user/$SVC_UID &&
     $(stat -c %u "/run/user/$SVC_UID") == "$SVC_UID" ]] || fail "Unsupported rootless runtime directory."
  [[ $(as_svc info --format '{{.Host.Security.Rootless}}' 2>/dev/null) == true ]] || fail "Rootless Podman is required."
  ok "Local rootless Podman connectivity verified."
}

find_container() {
  local rows names pick
  rows=$(as_svc ps --format "{{.Names}}\t{{.Image}}" 2>&1) || fail "Podman container enumeration failed."
  names=$(printf '%s\n' "$rows" | awk 'NF {print $1}')
  [[ $(count_lines "$names") -gt 0 ]] || fail "No running containers found."
  pick=$(printf '%s\n' "$rows" | awk 'NF && $2 ~ /(^|\/)uosserver([:@]|$)/ {print $1}')
  [[ $(count_lines "$pick") == 1 ]] || fail "Expected one identifiable UniFi OS Server container."
  CONTAINER="$pick"
  ok "UniFi OS Server container identified."
}

find_mongo() {
  local found props value
  found=$(in_container which mongosh mongo 2>/dev/null || true)
  MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongo$' | head -n1 || true)
  [[ -n $MONGO_CLIENT ]] || MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongosh$' | head -n1 || true)
  [[ -n $MONGO_CLIENT ]] || fail "No mongo or mongosh client found inside $CONTAINER."

  # The UniFi Network app's own settings name its database and port.
  MONGO_PORT="27117"; MONGO_DB="ace"
  props=$(in_container cat /usr/lib/unifi/data/system.properties 2>/dev/null) || fail "Cannot read Network database settings."
  if printf '%s\n' "$props" | grep -Eq '^[[:space:]]*(db\.mongo\.(uri|host|port|user|password)|unifi\.db\.(uri|host|user|password))[[:space:]]*='; then
    fail "Custom database connectivity is unsupported."
  fi
  if [[ -n $props ]]; then
    value=$(printf '%s\n' "$props" | sed -n 's/^[[:space:]]*unifi\.db\.port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | tail -n1)
    [[ -n $value ]] && MONGO_PORT="$value"
    value=$(printf '%s\n' "$props" | sed -n 's/^[[:space:]]*unifi\.db\.name[[:space:]]*=[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' | tail -n1)
    [[ -n $value ]] && MONGO_DB="$value"
    if printf '%s\n' "$props" | grep -Eq '^[[:space:]]*db\.mongo\.local[[:space:]]*=[[:space:]]*false'; then
      fail "This install uses an external MongoDB (db.mongo.local=false). Not supported by this script."
    fi
  fi

  [[ $MONGO_PORT =~ ^[0-9]{1,5}$ && $MONGO_PORT -gt 0 && $MONGO_PORT -le 65535 ]] || fail "Invalid Mongo port."
  local out
  out=$(mongo_js 'if (db.runCommand({ping:1}).ok === 1) print("UOSDB " + db.getName());' 2>/dev/null) || fail "Mongo connection failed."
  [[ $out == *"UOSDB $MONGO_DB"* ]] || fail "Could not open the Network database."
  ok "Mongo: $MONGO_CLIENT, port $MONGO_PORT, database $MONGO_DB"
}

# Version sources are read only; no server executable is invoked for discovery.
find_versions() {
  OS_VERSION=$(as_svc inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$CONTAINER" 2>/dev/null || true)
  # Package query syntax must reach dpkg-query literally.
  # shellcheck disable=SC2016
  NETWORK_VERSION=$(in_container dpkg-query -W '-f=${Version}' unifi 2>/dev/null || true)
  VERSIONS_KNOWN=1
  local version
  for version in "$OS_VERSION" "$NETWORK_VERSION"; do
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([+~:._a-zA-Z0-9-]*)?$ ]] || VERSIONS_KNOWN=0
  done
  if (( VERSIONS_KNOWN )); then
    ok "Versions: UniFi OS Server $OS_VERSION; UniFi Network $NETWORK_VERSION"
    warn "Versions are informational; schema checks and a restore rehearsal are required."
  else
    warn "Unknown application version; execution is blocked. Verify image labels and Network package metadata."
  fi
  local out
  out=$(mongo_js 'var r=db.adminCommand({isMaster:1}); var b=db.adminCommand({buildInfo:1}); if(r.ok===1 && b.ok===1 && /^[0-9.]+$/.test(b.version)) print("UOS CAP mongo="+b.version+" transactions="+((r.setName || r.msg==="isdbgrid") && r.logicalSessionTimeoutMinutes!==undefined ? "possible-unvalidated" : "unavailable"));' 2>/dev/null) || fail "Cannot inspect Mongo capabilities."
  [[ $out == *"UOS CAP "* ]] || fail "Unsupported Mongo capability response."
  printf '%s\n' "$out" | grep '^UOS CAP '
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
  find_versions
  step "Preflight (read only)"
  validate_sites
  ok "Preflight passed. No database writes or service restarts performed."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
