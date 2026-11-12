# Reproducible validation and controlled test plan

## Automated tests (no controller required)

From the repository root, with Bash 5+, ShellCheck, Node.js 18+, Python 3 and the
standard Linux tools used by the script:

```bash
bash -n unifi-os-server-default-site-migration.sh
shellcheck unifi-os-server-default-site-migration.sh tests/*.sh
node --check migration.js
node tests/migration.test.js
bash tests/environment.test.sh
bash tests/versions.test.sh
bash tests/sudo.test.sh
bash tests/recovery.test.sh
bash tests/journal.test.sh
python3 tests/execution.test.py
```

The database tests execute the actual `migration.js` with synthetic Mongo methods,
ObjectIds and collections. The Bash orchestration tests replace all infrastructure
calls; they cannot restart a real service or access a controller. Recovery/journal
tests create disposable local files and remove them. These are simulation tests,
not a real Mongo integration test, backup validation or vendor compatibility claim.

Coverage includes successful read-only validation and promotion, missing/additional
sites, invalid selections, duplicate flags/names, protected system identities,
string/ObjectId device associations, missing imported configuration, orphan and
unsupported references, unknown Default references, invalid cleanup identities,
retained activity history (including completed verification), rejected unrelated
history orphans, legacy and modern ObjectId conversion, shell startup/retry options,
version/capability discovery failures, recovery evidence rejection, exclusive
locking, partially moved flags, per-write exceptions and unacknowledged writes,
nonzero Mongo process exits despite a success marker, both restart failures,
final verification failure, TERM and forced termination, blocked partial reruns and
read-only verification of completed runs. Success cases compare retained imported
and global records to the synthetic baseline.

When adding tests, use synthetic names and dummy data only. Before each commit,
run applicable checks, inspect the entire staged diff with `git diff --cached`,
and scan additions for private identifiers, addresses, paths and secrets. Stage
only the files for that change. Never commit runtime evidence or backup material.

## Initial read-only destination inspection

This phase may be performed without authorising migration writes. Review the local
code first. Preserve the source controller and managed devices untouched.

1. Confirm Linux, architecture, systemd, Bash, sudo and local rootless Podman.
2. Authenticate separately and run:

   ```bash
   sudo -v
   bash unifi-os-server-default-site-migration.sh --check
   bash unifi-os-server-default-site-migration.sh --check --site 222222222222222222222222
   ```

   Replace the synthetic identity with the candidate from the first report. Keep
   output private; do not commit it. A missing prerequisite is a stop condition for
   live execution, not a reason to bypass discovery.
3. Independently compare the candidate ObjectId and internal name with the imported
   configuration using authorised local read-only inspection and the destination UI.
   Confirm exactly one system site, one protected Default and one imported candidate.
   Verify existing Default device associations are zero and imported networks,
   wireless configuration and settings are present. Review all collection references;
   unknown or unsupported schema states must be investigated without writes.
4. Confirm the plan deletes only the existing Default's configuration and site,
   while preserving the imported identity and its records. Record private counts
   per collection, identities, flags and representative configuration values.
5. Identify the exact OS Server, Network, Mongo and shell versions independently.
   Version discovery currently uses the container OCI version label and Network's
   package metadata; missing or misleading metadata needs investigation. Do not
   invent a version or pass an override to enable execution.
6. Establish the checkpoint and perform the isolated restore rehearsal described
   in [RECOVERY.md](RECOVERY.md). Restoration is a separate, authorised lab action;
   read-only preflight does not prove a checkpoint can restore anything.
7. Validate the private attestation using `--check --site ... --state-dir ...
   --recovery ...`. Confirm isolation and the quiet maintenance window. Stop here
   until explicit destructive-test authorisation has been granted.

Development validation passed 86 synthetic cases: 44 Mongo-program cases, eight
environment cases, four version diagnostic cases, five sudo compatibility cases,
eight recovery cases, five journal cases and 12 Bash execution cases. Bash syntax checks, ShellCheck and JavaScript
syntax checks also passed.

Simulation tests establish neither real installation topology nor recovery quality.
Live compatibility requires the separately authorised verification below.

## Proposed destructive testing — explicit approval required

**Do not execute this section merely because the automated tests pass.** Obtain
approval naming the isolated disposable destination and scenarios to be tested.
This project has not executed the procedure below. No test instance may contact
managed devices or the source controller; establish and verify that isolation
before starting. Use synthetic sites/configuration wherever possible. Do not
change production firewall/network settings, device state or inform addresses.

Prepare a private runbook with the exact installed-version restore steps, console
access, an independent checkpoint copy and baseline evidence. Rehearse complete
restoration first. Keep a private state directory and attestation outside the
checkout. Use the same directory for all rerun checks on that instance. Reset the
lab from the verified baseline between scenarios; archive evidence after recovery,
then establish fresh recovery evidence for the next attempt. Do not clear a journal
in order to force a rerun of a partially modified database.

The normal authorised invocation is:

```bash
bash unifi-os-server-default-site-migration.sh --execute \
  --site 222222222222222222222222 \
  --state-dir "$MIGRATION_STATE_DIR" --recovery "$RECOVERY_ATTESTATION"
```

Replace the synthetic site identity and set both variables to private absolute
paths. Review the site and the two destructive/recovery confirmations at the TTY.
No unattended confirmation flags or production connection steps are provided.

| Scenario | Controlled action | Required evidence and result |
| --- | --- | --- |
| Successful promotion | Run once from the verified isolated baseline. | Journal reaches complete; old site/configuration references absent; retained activity history unchanged; target keeps its ObjectId and configuration; one user site named/flagged Default; system/global/unrelated records unchanged; both restarts healthy; UI configuration comparison passes. |
| Database write failure | In an approved lab-only instrumented copy, inject failure before each flag write and each cleanup operation; repeat with a response lost after a committed write. Never add fault injection switches to the operational script. | First uncertain/failed operation stops subsequent work; no success status; preserve phase/outcome evidence and database state. Test invalid/missing acknowledgement formats too. |
| Service restart failure | In the lab wrapper, make the first restart fail, then in a fresh run make the second fail. Separately simulate a service that starts but whose database never answers. | Nonzero result; cleanup never follows a failed first restart; second failure never reports complete. Real timeout path is bounded at 600 seconds after systemctl returns. |
| Interrupted migration | Terminate the lab process after old flags are removed, during cleanup, and after final writes but before final acknowledgement; cover TERM and forced termination. | Durable journal remains; no automatic rollback or resume; exact database state inspected privately. An already running command might finish despite interruption. |
| Rerun after partial completion | Invoke execute with the same state directory; also invoke check. | Both stop on the incomplete journal, even if an initial topology looks valid. No additional writes/restarts. Removing the journal or changing directories is prohibited. |
| Rerun after completion | Invoke execute again, then check with the same state directory. | Execute refuses; check verifies the final database state read-only. Changed topology invalidates completion. Without a journal, already-Default topology is reported conservatively. |
| Recovery | Apply the exact rehearsed runbook to each failed state, including loss of the application UI. | Both original sites and imported configuration restored; counts/representative values/admin access match baseline; service healthy; isolation retained; evidence archived privately. |

Fault instrumentation must be reviewed separately before execution. Start with the
existing synthetic harness, then use a disposable real Mongo/application instance
to validate actual shell result formats, acknowledged journaled writes, restarted
application behaviour and undocumented schema differences. No custom backup or
automatic rollback implementation is part of this test plan.

## Acceptance and outstanding evidence

Automated checks passing are necessary. Before claiming installation compatibility,
retain private evidence of real schema inspection, accurate version discovery,
zero existing Default device associations, a successful exact-checkpoint restore,
each approved fault scenario and final UI/configuration comparisons. If any check
fails, preserve the journal and follow recovery; do not broaden deletion scope to
make the run pass. Record generic conclusions only in public documentation.
