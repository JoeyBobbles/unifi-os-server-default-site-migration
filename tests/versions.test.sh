#!/usr/bin/env bash
set -euo pipefail
source ./unifi-os-server-default-site-migration.sh
CONTAINER=synthetic-container
IMAGE_VERSION=9.9.9
PACKAGE_VERSION=8.8.8
as_svc() { printf '%s\n' "$IMAGE_VERSION"; }
in_container() { printf '%s\n' "$PACKAGE_VERSION"; }
mongo_js() { echo 'UOS CAP mongo=9.9.9 transactions=unavailable'; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 1 ]]
grep -q 'UniFi OS Server version (container OCI label): 9.9.9' "$work/output"
grep -q 'UniFi Network version (package metadata): 8.8.8' "$work/output"
IMAGE_VERSION='<no value>'
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && -z $OS_VERSION && $NETWORK_VERSION == 8.8.8 ]]
grep -q 'UniFi OS Server version unavailable' "$work/output"
grep -q 'UniFi Network version (package metadata): 8.8.8' "$work/output"
IMAGE_VERSION=9.9.9 PACKAGE_VERSION=unknown
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && $OS_VERSION == 9.9.9 && -z $NETWORK_VERSION ]]
grep -q 'UniFi Network version unavailable' "$work/output"
IMAGE_VERSION=unknown
find_versions > "$work/output"
[[ $VERSIONS_KNOWN == 0 && -z $OS_VERSION && -z $NETWORK_VERSION ]]
grep -q 'execution is blocked' "$work/output"
printf '4 version diagnostic tests passed\n'
