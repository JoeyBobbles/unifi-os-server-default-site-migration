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

STEP=start
JOURNAL=""
log_event() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) phase=$STEP level=$1 $2"
  printf '%s\n' "$line"
  if [[ -n $JOURNAL ]]; then
    if ! { printf '%s\n' "$line" >> "$JOURNAL" && sync -f "$JOURNAL"; }; then
      printf 'Cannot persist journal; stop and follow RECOVERY.md.\n' >&2
      exit 1
    fi
  fi
}
say()  { printf '%s\n' "$*"; }
ok()   { log_event OK "$*"; }
warn() { log_event WARN "$*"; }
fail() { log_event FAIL "$*"; exit 1; }
step() { STEP="$*"; log_event PHASE "started"; }

# Require one persistent private state directory per destination. An existing
# journal is never overwritten, removed or automatically resumed.
open_journal() {
  [[ $STATE_DIR == /* && -d $STATE_DIR && ! -L $STATE_DIR &&
     $(stat -c %u "$STATE_DIR") == "$(id -u)" && $(stat -c %a "$STATE_DIR") == 700 ]] || fail "State directory must be absolute, private (700), owned by you and not a symlink."
  [[ ! -L $STATE_DIR/lock ]] || fail "Unsafe lock path."
  exec {LOCK_FD}>"$STATE_DIR/lock" || fail "Cannot open migration lock."
  flock -n "$LOCK_FD" || fail "Another migration is active."
  [[ ! -e $STATE_DIR/journal && ! -L $STATE_DIR/journal ]] || fail "Existing migration journal: investigate completion or recovery; never blindly rerun."
  (umask 077; set -C; : > "$STATE_DIR/journal") || fail "Cannot create a new journal."
  JOURNAL="$STATE_DIR/journal"
  log_event CONTEXT "target=$TARGET_ID old=$OLD_ID database=$MONGO_DB"
}

on_exit() {
  local status=$?
  if [[ -n $JOURNAL && $status != 0 ]]; then
    log_event STOP "status=$status outcome=uncertain follow=RECOVERY.md"
  fi
}
trap on_exit EXIT
trap 'warn "Interrupted; database outcome may be uncertain. Follow RECOVERY.md."; exit 130' INT
trap 'warn "Terminated; database outcome may be uncertain. Follow RECOVERY.md."; exit 143' TERM
trap 'warn "Session lost; database outcome may be uncertain. Follow RECOVERY.md."; exit 129' HUP

# Confirmations always come from the controlling terminal, never piped stdin.
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

# Read attestation as data, never source it or evaluate its values.
recovery_prerequisites() {
  [[ -n ${RECOVERY_FILE:-} && -f $RECOVERY_FILE && ! -L $RECOVERY_FILE ]] || fail "A private recovery attestation is required; see RECOVERY.md."
  [[ $(stat -c %u "$RECOVERY_FILE") == "$(id -u)" && $(stat -c %a "$RECOVERY_FILE") == 600 ]] || fail "Recovery attestation must be owned by you with mode 600."
  local key value count=0 created=0 restored=0 now procedure
  declare -A evidence=()
  while IFS='=' read -r key value || [[ -n $key ]]; do
    case "$key" in
      checkpoint_id|checkpoint_sha256|created_utc|restored_utc|os_version|network_version|database|target_id|old_id|scope|restore_verified|isolation_verified|procedure_sha256) ;;
      *) fail "Unknown recovery attestation field." ;;
    esac
    [[ -n $value && ! -v evidence[$key] ]] || fail "Missing or duplicate recovery attestation value."
    evidence[$key]="$value"
    count=$((count + 1))
  done < "$RECOVERY_FILE"
  [[ $count == 13 ]] || fail "Incomplete recovery attestation."
  [[ ${evidence[checkpoint_id]} =~ ^[A-Za-z0-9_.:-]+$ &&
     ${evidence[checkpoint_sha256]} =~ ^[0-9a-f]{64}$ ]] || fail "Invalid checkpoint identity/integrity evidence."
  [[ ${evidence[restore_verified]} == yes && ${evidence[isolation_verified]} == yes &&
     ${evidence[scope]} == full-destination-recovery ]] || fail "Restore rehearsal and isolation must be verified."
  [[ ${evidence[os_version]} == "$OS_VERSION" && ${evidence[network_version]} == "$NETWORK_VERSION" &&
     ${evidence[database]} == "$MONGO_DB" && ${evidence[target_id]} == "$TARGET_ID" &&
     ${evidence[old_id]} == "$OLD_ID" ]] || fail "Recovery evidence does not match this migration."
  [[ ${evidence[created_utc]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ &&
     ${evidence[restored_utc]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "Use UTC checkpoint/rehearsal timestamps."
  created=$(date -u -d "${evidence[created_utc]}" +%s) || fail "Invalid checkpoint time."
  restored=$(date -u -d "${evidence[restored_utc]}" +%s) || fail "Invalid restore time."
  now=$(date -u +%s)
  (( created <= restored && restored <= now && now - created <= 86400 )) || fail "Recovery checkpoint expired or rehearsal time invalid."
  procedure=$(sha256sum "$SCRIPT_DIR/RECOVERY.md") || fail "Recovery procedure unavailable."
  [[ ${evidence[procedure_sha256]} == "${procedure%% *}" ]] || fail "Recovery procedure checksum does not match."
  ok "Restore-tested recovery checkpoint attested for this migration."
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
