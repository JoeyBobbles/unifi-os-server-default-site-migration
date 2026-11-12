#!/usr/bin/env bash
set -euo pipefail
source ./unifi-os-server-default-site-migration.sh
fail() { printf 'rejected: %s\n' "$*" >&2; exit 1; }
ok() { :; }
warn() { :; }
# All system and container interactions below are replaced with synthetic replies.
TARGET_ID=222222222222222222222222
# This test exercises discovery only; sudo execution is tested separately.
# shellcheck disable=SC2032
systemctl() {
  case "$*" in
    list-unit-files*) printf '%s\n' "${UNITS:-uosserver.service enabled}" ;;
    *ActiveState*) echo active ;;
    *SubState*) echo running ;;
  esac
}
find_service_unit
if (UNITS=$'uosserver.service enabled\nuosserver-other.service enabled'; find_service_unit); then exit 1; fi
as_svc() {
  case "$1" in
    ps) printf '%s\n' "${ROWS:-application localhost/uosserver:synthetic}" ;;
    inspect) echo 9.9.9 ;;
    *) return 1 ;;
  esac
}
find_container
if (ROWS='unrelated localhost/other:synthetic'; find_container); then exit 1; fi
if (ROWS=$'first localhost/uosserver:synthetic\nsecond localhost/uosserver:synthetic'; find_container); then exit 1; fi
in_container() { echo 9.9.9; }
mongo_js() { echo 'UOS CAP mongo=9.9.9 transactions=unavailable'; }
find_versions
[[ $VERSIONS_KNOWN == 1 ]]
in_container() { echo unknown; }
find_versions
[[ $VERSIONS_KNOWN == 0 ]]
mongo_js() { echo 'incompatible'; }
if (find_versions); then exit 1; fi
# Restore the real argument builder after the discovery mocks above.
source ./unifi-os-server-default-site-migration.sh
# Only inspect constructed argv; no shell client is launched.
in_container() { printf '%s\n' "$*"; }
MONGO_CLIENT=/usr/bin/mongosh MONGO_PORT=27117 MONGO_DB=ace
args=$(mongo_js 'synthetic-read')
[[ $args == *'--retryWrites=false'* && $args == *'--norc'* ]]
MONGO_CLIENT=/usr/bin/mongo
args=$(mongo_js 'synthetic-read')
[[ $args != *'--retryWrites'* && $args == *'--norc'* ]]
printf '8 environment tests passed\n'
