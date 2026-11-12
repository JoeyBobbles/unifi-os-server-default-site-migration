# Recovery prerequisite and stop procedure

Direct database edits are unsupported. A checkpoint is acceptable only after an
isolated restoration of that exact checkpoint has demonstrated recovery of both
sites, the imported configuration and administrative access on the same software
versions. A backup file's existence or checksum alone is insufficient.

## Establish a checkpoint before authorising writes

1. Isolate the destination and rehearsal instance from managed devices and the
   source controller. Arrange a maintenance window; stop imports, UI edits,
   scheduled jobs and other administrators' changes. Preserve console access.
2. Record the destination software versions, database name, both site ObjectIds,
   configuration counts and expected networks/WiFi/settings using read-only
   inspection. Keep this material private, outside the repository.
3. Obtain a destination recovery checkpoint using a backup facility supported by
   the installed application, or an independently validated, application-consistent
   whole-host/VM recovery process. Include all required application data, container
   storage, ownership, service configuration and encryption material. This project
   supplies no custom database dump mechanism and never overwrites backups.
4. Restore that exact checkpoint to a separate, isolated disposable instance on
   the same versions. Confirm administrative access, both original sites, imported
   settings, networks and WiFi configuration. Compare private before/after counts
   and representative values. Device connectivity must remain blocked throughout.
5. Record checkpoint identity, integrity evidence, UTC checkpoint and successful
   restoration times, scope and the tested restoration steps in a private runbook.
   Ensure the runbook and checkpoint are accessible independently of the affected
   server. Rehearse loss of the application UI as well as a normal UI restore.
6. With the destination still unchanged, prepare a private recovery attestation as
   below. It expires 24 hours after checkpoint creation. Any subsequent changes
   invalidate the attestation even within that period; create and rehearse a new
   checkpoint. Have this procedure available during the migration.

Ubiquiti distinguishes system configuration backups, Network backups and individual
site exports. Availability and coverage depend on the installed product/version;
verify them in the installed UI and the
[official backup documentation](https://help.ui.com/hc/en-us/articles/360008976393-Backups-and-Migration-in-UniFi).
An individual site export is not a full destination recovery checkpoint. A Network
backup may omit OS settings, other applications and historical data; a configuration
backup may omit recordings or other bulk data. Do not assume a cloud-console backup
workflow exists on every self-hosted installation. If recovery of the destination
cannot be demonstrated, do not execute this script.

## Private recovery attestation format

Create a regular file owned by the invoking account with mode `600`, outside the
repository. Each key must occur exactly once, with no extra lines. Values below
are placeholders to replace locally; never commit the completed file.

```text
checkpoint_id=CHECKPOINT_REFERENCE
checkpoint_sha256=SHA256_OF_CHECKPOINT_OR_IMMUTABLE_CHECKPOINT_MANIFEST
created_utc=UTC_TIMESTAMP
restored_utc=UTC_TIMESTAMP
os_version=DETECTED_VERSION
network_version=DETECTED_VERSION
database=DETECTED_DATABASE
target_id=IMPORTED_OBJECT_ID
old_id=EXISTING_DEFAULT_OBJECT_ID
scope=full-destination-recovery
restore_verified=yes
isolation_verified=yes
procedure_sha256=SHA256_OF_THIS_RECOVERY_DOCUMENT
```

Use UTC timestamps such as `YYYY-MM-DDTHH:MM:SSZ`. Compute the procedure checksum
with `sha256sum RECOVERY.md`. The checkpoint checksum describes the archive or a
private immutable snapshot manifest, not a fabricated dummy file. This attestation
is an operator assertion backed by a rehearsal/runbook, not automated proof of
restore quality. The script does not open, upload or copy the checkpoint.

## On any failure or interruption

1. Stop. Do not rerun, remove the journal, issue ad hoc flag repairs or use a new
   state directory to bypass the guard. A missing acknowledgement may mean a write
   committed. Preserve the local journal and terminal transcript privately.
2. Keep device and source connectivity blocked. Inspect only read-only state.
   Record the last phase and compare both site identities and reference counts
   with the private baseline. If service restart failed, retain diagnostic logs
   privately; do not print credentials or whole documents into shared reports.
3. Follow the exact independently rehearsed runbook to restore the destination.
   If the UI is unavailable, use the rehearsed host/VM recovery route. Restore all
   necessary components consistently; do not restore selected collections by guess.
4. Verify the restored pre-migration topology, imported configuration and admin
   access. Validate the restored service and application before ending isolation.
5. Archive the failed journal and evidence only after successful recovery and
   investigation. A fresh attempt requires a fresh checkpoint, successful rehearsal
   and explicit authorisation. This project performs no automatic rollback/resume.

## Atomicity limitation

MongoDB [multi-document transactions](https://www.mongodb.com/docs/manual/data-modeling/enforce-consistency/transactions/)
require a replica set or sharded deployment. Standalone MongoDB does not support
them. Discovery reports possible capability, but this script deliberately uses no
untested transaction path. Transactions also cannot cover the intervening service
restart. Each individual write is guarded and acknowledged; the migration as a
whole remains non-atomic and can require full restoration.
