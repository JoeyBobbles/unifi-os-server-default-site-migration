#!/usr/bin/env bash
set -euo pipefail
source ./unifi-os-server-default-site-migration.sh
CONTAINER=synthetic-container
HOST_VERSION=9.9.9
CONTAINER_VERSION=9.9.9
PACKAGE_VERSION=8.8.8
APP_VERSION="" APP_MODEL=""
read_host_os_version() { printf '%s\n' "$HOST_VERSION"; }
in_container() {
  if [[ $1 == printenv ]]; then
    case "$2" in
      UOS_SERVER_VERSION) printf '%s\n' "$CONTAINER_VERSION" ;;
      APP_MODEL) printf '%s\n' "$APP_MODEL" ;;
      APP_VERSION) printf '%s\n' "$APP_VERSION" ;;
      *) return 1 ;;
    esac
  else printf '%s\n' "$PACKAGE_VERSION"; fi
}
mongo_js() { echo 'UOS CAP mongo=9.9.9 transactions=unavailable'; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 1 ]]
grep -q 'host and running container agree): 9.9.9' "$work/output"
grep -q 'UniFi Network version (package metadata): 8.8.8' "$work/output"
HOST_VERSION="" CONTAINER_VERSION=""
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && -z $OS_VERSION && $NETWORK_VERSION == 8.8.8 ]]
grep -q 'UniFi OS Server version unavailable' "$work/output"
HOST_VERSION=9.9.9 CONTAINER_VERSION=9.9.9 PACKAGE_VERSION=unknown
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && $OS_VERSION == 9.9.9 && -z $NETWORK_VERSION ]]
grep -q 'UniFi Network version unavailable' "$work/output"
HOST_VERSION="" CONTAINER_VERSION=""
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && -z $OS_VERSION && -z $NETWORK_VERSION ]]
HOST_VERSION=9.9.9 CONTAINER_VERSION=9.9.8 PACKAGE_VERSION=8.8.8
if (find_versions > "$work/output"); then echo 'Expected version mismatch rejection'; exit 1; fi
CONTAINER_VERSION=""
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 1 && $OS_VERSION == 9.9.9 ]]
grep -q 'host installer configuration): 9.9.9' "$work/output"
HOST_VERSION="" CONTAINER_VERSION=9.9.9
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 1 && $OS_VERSION == 9.9.9 ]]
grep -q 'running container environment): 9.9.9' "$work/output"
HOST_VERSION=$'9.9.9\n9.9.9'
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && -z $OS_VERSION ]]
grep -q 'Malformed or ambiguous' "$work/output"
HOST_VERSION="" CONTAINER_VERSION="" APP_MODEL=UOSSERVER APP_VERSION=7.7.7
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 1 && $OS_VERSION == 7.7.7 ]]
grep -q 'running container environment): 7.7.7' "$work/output"
HOST_VERSION=7.7.7
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 1 && $OS_VERSION == 7.7.7 ]]
HOST_VERSION=7.7.6
if (find_versions > "$work/output"); then echo 'Expected host/APP_VERSION disagreement'; exit 1; fi
HOST_VERSION="" APP_MODEL=OTHER_APPLICATION
if (find_versions > "$work/output"); then echo 'Expected model rejection'; exit 1; fi
APP_MODEL=UOSSERVER CONTAINER_VERSION=7.7.6
if (find_versions > "$work/output"); then echo 'Expected legacy/modern version disagreement'; exit 1; fi
CONTAINER_VERSION="" APP_VERSION=malformed
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && -z $OS_VERSION ]]
printf '14 version diagnostic tests passed\n'
