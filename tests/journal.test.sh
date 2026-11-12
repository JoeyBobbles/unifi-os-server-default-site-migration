#!/usr/bin/env bash
set -euo pipefail
source ./unifi-os-server-default-site-migration.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
STATE_DIR=$work/state
mkdir -m 700 "$STATE_DIR"
TARGET_ID=222222222222222222222222 OLD_ID=111111111111111111111111 MONGO_DB=ace
# Child shell exits release lock; existing journal still blocks a rerun.
(open_journal; step flags; ok 'operation acknowledged')
[[ $(stat -c %a "$STATE_DIR/journal") == 600 ]]
[[ $(grep -c 'phase=flags level=OK operation acknowledged' "$STATE_DIR/journal") == 1 ]]
if (open_journal); then exit 1; fi
rm "$STATE_DIR/journal"
(
  exec {TEST_LOCK}>"$STATE_DIR/lock"
  flock -n "$TEST_LOCK"
  if (open_journal); then exit 1; fi
)
chmod 755 "$STATE_DIR"
if (open_journal); then exit 1; fi
chmod 700 "$STATE_DIR"
ln -s "$STATE_DIR" "$work/link"
if (STATE_DIR=$work/link; open_journal); then exit 1; fi
printf '5 journal tests passed\n'
