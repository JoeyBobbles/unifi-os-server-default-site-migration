# UniFi OS Server Default Site Migration

Promote an imported site to the internal Default site on self-hosted Linux
UniFi OS Server. This fork hardens the
[original project](https://github.com/tcptyler/unifi-os-server-default-site-migration)
with read-only checks, strict selection, recovery prerequisites and guarded writes.

**Experimental and unsupported by Ubiquiti.** Direct database edits can lose
configuration or break after an update. Automated tests use synthetic data; they
do not establish compatibility with a real installation. Complete the isolated
restore rehearsal and [controlled test plan](TESTING.md) before authorising writes.

## Requirements

- Linux with systemd, Bash 5+, GNU coreutils, util-linux `flock`, and local rootless
  Podman on x86-64 or ARM64, and noninteractive `sudo` access after authentication.
- Exactly one identifiable running `uosserver` service/container and its non-root
  service account. A root supervisor may use the dedicated `uosserver` account.
- Local MongoDB and `mongo` or `mongosh` in the container. Custom authentication,
  remote databases, alternate database searches and ambiguous discovery are refused.
- One system site (`super`), one existing Default and one imported site. The
  existing Default must have **zero device associations**, including offline or
  unadopted records. The imported site must contain configuration records.
- Site identities must be ObjectIds, names unique and flags in the expected state.
  All top-level `site_id` references must identify an existing site, as strings or
  ObjectIds. Unknown collections referencing the existing Default block execution.
  The upstream retention policy is preserved for `admin_activity_log`, `alert`,
  `time_machine_infrastructure_snapshot`, `apgroup` and
  `ssl_inspection_certificate`. Their records and original site references remain
  unchanged and are reported explicitly.
- A quiet maintenance window and an already isolated destination that cannot
  contact managed devices or the source controller. No imports, UI changes,
  concurrent administrators, updates or scheduled configuration changes.

## Read-only validation

Review and save the repository locally. Keep the Bash script, `migration.js` and
`RECOVERY.md` together. Do not pipe downloaded code into a shell or paste the
original here-document wrapper. Run as an administrator with sudo access:

```bash
sudo -v
bash unifi-os-server-default-site-migration.sh --check
```

The report enumerates site ObjectIds and internal names, identifies Default and
the candidate, describes the planned operations, reports versions and Mongo
transaction capability, and lists validation failures. To verify a specific site,
replace the synthetic ObjectId below with the imported site's reported identity:

```bash
bash unifi-os-server-default-site-migration.sh --check \
  --site 222222222222222222222222
```

No mode defaults to execution: omitting a mode also runs read-only checks. `--check`
never issues database writes, creates a journal/lock or restarts services. It uses
sudo's no-update option when available. When unavailable (including some
`sudo-rs` implementations), it warns that sudo may refresh its local authentication
cache. Normal system auditing and vendor/runtime logging can also occur when
commands or reads are performed.

Exit status `0` means the read-only topology/schema checks passed (or an existing
completed journal was verified). It is **not authorisation to migrate**: missing
recovery/state-directory prerequisites and unknown versions are reported as
warnings. Failed schema/topology checks or an explicitly supplied invalid recovery
attestation return nonzero. Unknown application versions always block execution.
OS Server discovery reads `APP_VERSION` with `APP_MODEL=UOSSERVER` or legacy
`UOS_SERVER_VERSION` from the running container, plus the legacy version key in
`/var/lib/uosserver/server.conf`. Conflicting values or an unexpected model stop
validation. A generic
container image version is not used as an application version. Detected version
numbers alone do not establish compatibility.

## Recovery and authorised execution

Follow [RECOVERY.md](RECOVERY.md) to establish and actually restore-test the exact
checkpoint. A site export alone is insufficient. Prepare the private attestation
and a persistent private directory outside the checkout, owned by the invoking
account with mode `700`. Use the **same directory and operator for every attempt
on this destination**, including read-only checks; never bypass a journal with a
new directory. Do not use `/tmp` for operational recovery evidence or journals.

After creating those private files, validate them without writing database state:

```bash
bash unifi-os-server-default-site-migration.sh --check \
  --site 222222222222222222222222 \
  --state-dir "$MIGRATION_STATE_DIR" --recovery "$RECOVERY_ATTESTATION"
```

Set the shell variables locally to absolute paths outside the repository. They
must refer to the existing directory and the attestation file (mode `600`). After
explicit authorisation for the destructive maintenance procedure only:

```bash
bash unifi-os-server-default-site-migration.sh --execute \
  --site 222222222222222222222222 \
  --state-dir "$MIGRATION_STATE_DIR" --recovery "$RECOVERY_ATTESTATION"
```

Execution requires three keyboard confirmations: the exact imported ObjectId,
`DELETE EMPTY DEFAULT`, and `RESTORE VERIFIED`. Piped input cannot confirm them.
A new journal is persisted before any database change. An existing journal blocks
execution even if it describes a successful run. Use `--check` with that same state
directory to verify completed runs; interrupted/failed journals require recovery.
A single Default without a journal is recognised conservatively as already Default
or a missing import, never treated as proof of a successful past migration.

## Changes and boundaries

The original discovery helpers and flag/restart/delete/rename sequence are retained
where appropriate. Database validation and scoped operations live in `migration.js`
so the actual Mongo program can be tested independently. Execution:

1. Revalidates topology and recovery evidence after confirmations and locking.
2. Removes the existing Default's protection flags and sets them on the imported
   site with expected-state filters and checked, journaled acknowledgements.
3. Restarts UniFi OS Server and checks service state and Mongo availability.
4. Deletes only snapshot-identified existing Default records in `setting`,
   `networkconf`, `wlanconf`, `wlangroup`, `usergroup`, `radiusprofile`, `dpigroup`
   and `privilege`. Each deletion is scoped to its identity and site reference,
   checked individually and preceded by validation. Unknown references are refused; recognised activity history is retained.
5. Deletes the old site, renames the imported site's internal name to `default`,
   restarts again and verifies the final topology.

Both restarts affect **all applications** on UniFi OS Server. Global Multi-Site
Management settings are left to the operator through the UI. This script never
changes inform addresses or adopts, forgets, provisions or moves devices, and
never connects to a source controller.

The migration remains **non-atomic**. Expected-state filters reduce races but cannot
exclude application writes between checks. Reference checks cover top-level
`site_id`, not every possible undocumented relationship. Strict checks may reject
valid installations with other history references or schema differences. Retention exceptions apply only to the five explicitly listed
collections referencing this migration's existing Default identity; other orphan
references remain errors. These exceptions restore the upstream retention policy,
not a claim of vendor-supported compatibility. Blocked scheduled tasks produce a
limited read-only summary of recognised actions, boolean flags and target counts. They remain blocked; the
summary does not authorise removal or retention. Investigate schema differences; do not expand deletion
lists or remove guards without review and isolated tests. Read scans may be slow on
large databases. Mongo transactions are reported but not used; they cannot cover
the intervening service restart. There is no automatic rollback or resume.

Mongo shell startup files are disabled, and mongosh automatic write retries are
disabled. Legacy ObjectId representations are validated explicitly.

Logs contain UTC time, phase, validation results, scoped operation counters,
restart results, failures and final status. Execution appends them to the private
`journal` and flushes it before proceeding. A forced termination may leave only a
phase marker; treat all unacknowledged writes as uncertain. Keep logs, backups,
attestations and exports local and out of version control. Raw database errors,
complete documents, descriptions and credentials are not printed.

## Development and verification

Read [AUDIT.md](AUDIT.md) for the original risks, [RECOVERY.md](RECOVERY.md) for
restore requirements and [TESTING.md](TESTING.md) for reproducible tests and the
separately authorised destructive procedure. Node.js 18+ and Python 3 are required
only for development tests; the migration adds no host language runtime dependency.

## Credits

Original implementation by the upstream project. Based on the Ubiquiti Community
Wiki guide [Changing the Default Site in UniFi](https://ubntwiki.com/guides/changing_the_default_site_in_unifi),
which credits @ckd in the unofficial Ubiquiti Discord. The guide targets standalone
UniFi Network; the original script adapts it for UniFi OS Server and rootless Podman.
Existing upstream attribution is retained.

Not affiliated with or endorsed by Ubiquiti Inc. UniFi is a trademark of Ubiquiti Inc.
