# Original implementation safety audit

Scope: the original Bash script before hardening. This is a source review;
no migration or live database experiment was performed.

## Persistent state changes

1. `sudo -v` refreshes the local authentication timestamp.
2. An update removes `attr_hidden_id` and `attr_no_delete` from the existing
   Default site, then a separate update adds them to the selected site.
3. A systemd restart restarts every application in UniFi OS Server; applications
   may write database state during shutdown and startup.
4. Eight separate `deleteMany` calls remove existing Default configuration from
   `setting`, `networkconf`, `wlanconf`, `wlangroup`, `usergroup`, `radiusprofile`,
   `dpigroup` and `privilege`. A separate call deletes the site document.
5. Another update renames the imported site to `default`.
6. An optional update disables Multi-Site Management in `super_mgmt`.
7. A second service restart applies these changes.

## Schema and discovery assumptions

- Rootless Podman, a discoverable service account, a local MongoDB, and an
  unauthenticated Mongo shell in the container are assumed. Discovery can select
  a single unrelated container or an ambiguous fallback service.
- The Network database defaults to `ace` on port `27117`. Searching other
  databases and offering to switch risks editing a database the application
  does not actually use.
- Site `_id` values are assumed to be ObjectIds; they are interpolated into
  JavaScript without strict validation. Tab-separated fields can be corrupted
  by descriptions containing tabs or newlines.
- `attr_hidden_id: "default"` identifies Default; `super` identifies the system
  site. Boolean protection flags and unique internal names are assumed.
- Configuration references are assumed to use `site_id`, either a string or an
  ObjectId. The deletion collection list is based on one observed deployment,
  not a complete versioned schema contract. Other references may survive.
- The singleton global `super_mgmt` record is assumed to be safe to change.
  Client result formats are assumed to expose modern update counters.

## Existing protections and gaps

The script excludes the system site from selection, checks for exactly one
Default before writes, checks update counts, re-reads flags and checks identities
before deletion. These are useful protections but insufficient:

- It does not count devices associated with the existing Default, validate
  imported configuration, require exactly two user sites, detect duplicate
  names, or detect orphan/unsupported reference representations.
- It does not establish versions or a supported schema before editing.
- It does not verify recovery prerequisites, require a restore rehearsal, or
  provide a complete recovery procedure. A suggested flag repair cannot undo
  deleted configuration and should not be mistaken for recovery.
- Write filters use identity alone, allowing concurrent changes between reads
  and writes. The application remains online and may race the migration.
- Some calls parse success text without checking the process exit status.
  Raw database errors are printed and could expose sensitive data.
- There is no durable operation journal, exclusive lock, TERM/HUP handling or
  reliable interrupted-run detection. There is no automated test harness.

## Failure and partial states

The first update can leave no Default; the second can leave flags moved but
the old site intact. Restart failure leaves either that state or the later
renamed/deleted state. Deletion can stop after any collection, leaving a partly
removed site. Rename can fail after irreversible deletion. Multi-Site changes
can fail independently. A shell interruption or an ambiguous network response
can occur after a write committed but before its acknowledgement was received.
Rerunning can select the wrong site, discard evidence, or compound damage.
Final diagnostics warn but do not provide a machine-verifiable success status.

## Hardening decisions

- Preserve rootless Podman discovery and the overall flag/restart/delete/rename
  sequence where justified, but fail closed on ambiguous discovery and schema.
- Add an independently testable read-only preflight, explicit ObjectId selection,
  conservative topology/device/configuration checks and scoped write guards.
- Require an operator-attested, restore-tested external recovery checkpoint and
  a local durable journal before writes; never infer recoverability from a file.
- Treat interrupted or uncertain writes as requiring investigation and recovery;
  do not implement automatic rollback or resume.
- Do not modify global Multi-Site settings automatically. Avoid optional global
  changes and source-controller/device-migration instructions.
- Assess transaction capability. A transaction cannot span application restarts;
  transaction deployment and application concurrency need controlled validation.
  Do not claim end-to-end atomicity or add an untested transaction path.
- Keep direct database editing explicitly experimental until controlled restore
  and migration tests establish compatibility. Capability checks cannot prove
  complete compatibility with an undocumented vendor schema.
