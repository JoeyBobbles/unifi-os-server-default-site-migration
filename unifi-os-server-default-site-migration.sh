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
validate_state_directory() {
  [[ $STATE_DIR == /* && -d $STATE_DIR && ! -L $STATE_DIR &&
     $(stat -c %u "$STATE_DIR") == "$(id -u)" && $(stat -c %a "$STATE_DIR") == 700 ]] || fail "State directory must be absolute, private (700), owned by you and not a symlink."
}

open_journal() {
  validate_state_directory
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
  (cd /tmp && sudo -n -N -H -u "$SVC_USER" XDG_RUNTIME_DIR="/run/user/$SVC_UID" podman --remote=false "$@" </dev/null)
}

in_container() { as_svc exec "$CONTAINER" "$@"; }

mongo_js() {
  local retry_args=()
  [[ $MONGO_CLIENT != */mongosh ]] || retry_args=(--retryWrites=false)
  in_container "$MONGO_CLIENT" "${retry_args[@]}" --norc --quiet --host localhost --port "$MONGO_PORT" "$MONGO_DB" --eval "$1"
}

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------

check_basics() {
  [[ $(uname -s) == Linux ]] || fail "Linux is required."
  case $(uname -m) in x86_64|aarch64) ;; *) fail "Unsupported architecture." ;; esac
  (( BASH_VERSINFO[0] >= 5 )) || fail "Bash 5 or newer is required."
  [[ -r $SCRIPT_DIR/migration.js && -r $SCRIPT_DIR/RECOVERY.md ]] || fail "Keep the reviewed script, migration.js and RECOVERY.md together."
  local cmd
  for cmd in sudo systemctl id awk grep stat sed tail head uname cat dirname podman date sha256sum sync flock; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
  done
  sudo -n -N true </dev/null || fail "Authenticate with sudo -v before running this script."
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
  MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongosh$' | head -n1 || true)
  [[ -n $MONGO_CLIENT ]] || MONGO_CLIENT=$(printf '%s\n' "$found" | grep '/mongo$' | head -n1 || true)
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
database_phase() {
  local action="$1" out program line status=0
  program=$(cat "$SCRIPT_DIR/migration.js") || fail "Cannot read migration.js."
  out=$(mongo_js "var target = '$TARGET_ID'; var oldIdentity = '${OLD_ID:-}'; var action = '$action';
$program" 2>/dev/null) || status=$?
  while IFS= read -r line; do
    [[ $line == 'UOS '* ]] && log_event DB "$line"
  done <<< "$out"
  (( status == 0 )) || fail "Mongo process failed; outcome may be uncertain. Follow RECOVERY.md."
  [[ $(printf '%s\n' "$out" | grep -c '^UOS READY$') == 1 && $out != *'UOS FAIL '* ]] || fail "Database phase rejected; investigate before proceeding."
  if [[ $action == check ]]; then
    local pattern='UOS PLAN target=([0-9a-f]{24}) old=([0-9a-f]{24}) '
    [[ $out =~ $pattern ]] || fail "Missing validated migration identities."
    TARGET_ID="${BASH_REMATCH[1]}"; OLD_ID="${BASH_REMATCH[2]}"
  fi
}

restart_service() {
  step restart
  warn "Restarting all applications in UniFi OS Server."
  sudo -n systemctl restart "$UNIT" </dev/null >/dev/null 2>&1 || fail "Service restart failed. Follow RECOVERY.md."
  local start=$SECONDS out
  while (( SECONDS - start < 600 )); do
    if service_running; then
      out=$(mongo_js 'if(db.runCommand({ping:1}).ok===1) print("UOS PING");' 2>/dev/null) || out=""
      if [[ $out == *'UOS PING'* ]]; then ok "Service active and Mongo responds."; return 0; fi
    fi
    sleep 2
  done
  fail "Service/database restart timed out. Follow RECOVERY.md."
}

execute_migration() {
  (( VERSIONS_KNOWN )) || fail "Unknown versions block execution."
  recovery_prerequisites
  ask "Type the selected imported site ObjectId ($TARGET_ID): "
  [[ $ANSWER == "$TARGET_ID" ]] || fail "Site confirmation did not match."
  ask "Type DELETE EMPTY DEFAULT to authorise irreversible deletion and both restarts: "
  [[ $ANSWER == 'DELETE EMPTY DEFAULT' ]] || fail "Destructive confirmation did not match."
  ask "Type RESTORE VERIFIED to attest the checkpoint was restored and destination remains isolated and unchanged: "
  [[ $ANSWER == 'RESTORE VERIFIED' ]] || fail "Recovery confirmation did not match."
  open_journal
  step revalidate
  database_phase check
  # No writes have occurred yet; recheck checkpoint age after operator prompts.
  recovery_prerequisites
  step flags
  database_phase flags
  restart_service
  step cleanup
  database_phase cleanup
  restart_service
  step verify
  database_phase verify
  step complete
  ok "Migration complete; verify imported configuration in the UI before ending isolation."
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
  say "Usage: bash $0 --check [--site OBJECT_ID] [--state-dir DIRECTORY] [--recovery FILE]"
  say "       bash $0 --execute --site OBJECT_ID --state-dir DIRECTORY --recovery FILE"
}

main() {
  TARGET_ID=""; OLD_ID=""; STATE_DIR=""; RECOVERY_FILE=""
  local mode=check mode_set=0 selected=""
  local site_set=0 state_set=0 recovery_set=0
  while (( $# )); do
    case "$1" in
      --check|--execute)
        (( mode_set == 0 )) || fail "Specify one mode only."
        mode="${1#--}"; mode_set=1; shift ;;
      --site|--state-dir|--recovery)
        (( $# >= 2 )) && [[ -n $2 && $2 != --* ]] || fail "Option requires a value."
        case "$1" in
          --site) (( site_set == 0 )) || fail "Duplicate site selection."; site_set=1; TARGET_ID="$2" ;;
          --state-dir) (( state_set == 0 )) || fail "Duplicate state directory."; state_set=1; STATE_DIR="$2" ;;
          --recovery) (( recovery_set == 0 )) || fail "Duplicate recovery attestation."; recovery_set=1; RECOVERY_FILE="$2" ;;
        esac
        shift 2 ;;
      --help|-h) usage; return 0 ;;
      *) usage; fail "Unknown option." ;;
    esac
  done
  [[ -z $TARGET_ID || $TARGET_ID =~ ^[0-9a-f]{24}$ ]] || fail "Select a lowercase 24-digit hexadecimal ObjectId."
  selected="$TARGET_ID"
  if [[ $mode == execute ]]; then
    [[ -n $TARGET_ID && -n $STATE_DIR && -n $RECOVERY_FILE ]] || fail "Execution requires site, state directory and recovery attestation."
  fi
  [[ -z $STATE_DIR ]] || validate_state_directory
  step discovery
  check_basics
  find_service_unit
  find_service_user
  find_container
  find_mongo
  find_versions
  if [[ -n $STATE_DIR && ( -e $STATE_DIR/journal || -L $STATE_DIR/journal ) ]]; then
    [[ $mode == check && -f $STATE_DIR/journal && ! -L $STATE_DIR/journal ]] || fail "Existing migration journal; execution blocked."
    local context pattern='target=([0-9a-f]{24}) old=([0-9a-f]{24}) database=([A-Za-z0-9_-]+)$'
    context=$(head -n1 "$STATE_DIR/journal")
    [[ $context =~ $pattern ]] || fail "Invalid journal context."
    TARGET_ID="${BASH_REMATCH[1]}"; OLD_ID="${BASH_REMATCH[2]}"
    [[ ${BASH_REMATCH[3]} == "$MONGO_DB" && ( -z $selected || $selected == "$TARGET_ID" ) ]] || fail "Journal does not match selected migration."
    grep -q 'phase=complete level=OK Migration complete;' "$STATE_DIR/journal" || fail "Interrupted/failed migration journal; follow RECOVERY.md."
    step verify
    database_phase verify
    ok "Previously completed migration verified; no changes performed."
    return 0
  fi
  step preflight
  database_phase check
  if [[ $mode == check ]]; then
    if [[ -n $RECOVERY_FILE ]]; then recovery_prerequisites; else warn "Execution prerequisite missing: restore-tested recovery attestation (RECOVERY.md)."; fi
    [[ -n $STATE_DIR ]] || warn "Execution prerequisite missing: persistent private state directory."
    ok "Read-only preflight passed; no database writes, journals or service restarts performed."
    return 0
  fi
  execute_migration
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
