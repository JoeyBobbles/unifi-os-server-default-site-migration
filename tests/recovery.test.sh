#!/usr/bin/env bash
set -euo pipefail
source ./unifi-os-server-default-site-migration.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
OS_VERSION=9.9.9 NETWORK_VERSION=9.9.9 MONGO_DB=ace
TARGET_ID=222222222222222222222222 OLD_ID=111111111111111111111111
RECOVERY_FILE=$work/recovery
make_evidence() {
  cat > "$RECOVERY_FILE" <<DATA
checkpoint_id=synthetic-checkpoint
checkpoint_sha256=$(printf '%064d' 0)
created_utc=$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)
restored_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
os_version=$OS_VERSION
network_version=$NETWORK_VERSION
database=ace
target_id=$TARGET_ID
old_id=$OLD_ID
scope=full-destination-recovery
restore_verified=yes
isolation_verified=yes
procedure_sha256=$(sha256sum RECOVERY.md | cut -d' ' -f1)
DATA
  chmod 600 "$RECOVERY_FILE"
}
expect_failure() { if (recovery_prerequisites); then echo 'expected rejection'; exit 1; fi; }
expect_failure
make_evidence
recovery_prerequisites
chmod 644 "$RECOVERY_FILE"; expect_failure
make_evidence; sed -i 's/restore_verified=yes/restore_verified=no/' "$RECOVERY_FILE"; expect_failure
make_evidence; sed -i 's/database=ace/database=other/' "$RECOVERY_FILE"; expect_failure
make_evidence; echo 'restore_verified=yes' >> "$RECOVERY_FILE"; expect_failure
make_evidence; sed -i 's/created_utc=.*/created_utc=2000-01-01T00:00:00Z/' "$RECOVERY_FILE"; expect_failure
make_evidence; sed -i 's/procedure_sha256=.*/procedure_sha256=invalid/' "$RECOVERY_FILE"; expect_failure
printf '8 recovery tests passed\n'
