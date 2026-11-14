"""Exercise Bash orchestration with every infrastructure command replaced."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = r'''
source ./unifi-os-server-default-site-migration.sh
RUN_PID=$BASHPID
check_basics() { :; }
find_service_unit() { UNIT=uosserver.service; }
find_service_user() { :; }
find_container() { :; }
find_mongo() { MONGO_DB=ace; }
find_versions() { VERSIONS_KNOWN=1; OS_VERSION=9.9.9; NETWORK_VERSION=9.9.9; if [[ ${FAULT:-} == version ]]; then VERSIONS_KNOWN=0; fi; }
recovery_prerequisites() { [[ ${FAULT:-} != recovery ]] || fail 'Recovery rejected'; }
service_running() { return 0; }
sudo() {
  [[ $* == '-n systemctl restart uosserver.service' ]] || exit 99
  echo restart >> "$TRACE"
  [[ ${FAULT:-} != restart ]] || return 1
  if [[ ${FAULT:-} == restart-second && $(grep -c restart "$TRACE") == 2 ]]; then return 1; fi
  return 0
}
ask() {
  case "$1" in
    'Type the selected'*) ANSWER=$TARGET_ID ;;
    'Type DELETE'*) ANSWER='DELETE EMPTY DEFAULT' ;;
    'Type RESTORE'*) ANSWER='RESTORE VERIFIED' ;;
    'Type I ACCEPT'*) ANSWER='I ACCEPT A COMPLETE REBUILD'; [[ ${FAULT:-} != waiver ]] || ANSWER=wrong ;;
    'Type DESTINATION'*) ANSWER='DESTINATION IS ISOLATED'; [[ ${FAULT:-} != isolation ]] || ANSWER=wrong ;;
    *) exit 98 ;;
  esac
  [[ ${FAULT:-} != confirmation ]] || ANSWER=wrong
}
mongo_js() {
  if [[ $1 == *'UOS PING'* ]]; then echo 'UOS PING'; return 0; fi
  local action
  action=$(printf '%s' "$1" | sed -n "s/.*var action = '\([a-z]*\)';.*/\1/p" | head -n1)
  echo "$action" >> "$TRACE"
  if [[ $action == flags && ${FAULT:-} == hardkill ]]; then kill -KILL "$RUN_PID"; return 1; fi
  if [[ $action == flags && ${FAULT:-} == signal ]]; then kill -TERM "$RUN_PID"; return 1; fi
  if [[ $action == "${FAULT:-}" ]]; then echo 'UOS FAIL injected'; return 0; fi
  if [[ $action == check ]]; then echo 'UOS PLAN target=222222222222222222222222 old=111111111111111111111111 configuration_records=1'; fi
  echo 'UOS READY'
  if [[ $action == flags && ${FAULT:-} == process ]]; then return 1; fi
  return 0
}
main "$@"
'''


class Execution(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.trace = self.root / 'trace'

    def run_script(self, fault='', mode='--execute', disposable=False, without_recovery=False, extra_args=()):
        args = [mode, '--site', '222222222222222222222222',
                '--state-dir', str(self.state)]
        if disposable:
            args.append('--disposable-test')
        elif not without_recovery:
            args.extend(['--recovery', str(self.root / 'evidence')])
        args.extend(extra_args)
        return subprocess.run(['bash', '-c', SCRIPT, 'test', *args],
                              env=dict(os.environ, TRACE=str(self.trace), FAULT=fault),
                              capture_output=True, text=True, timeout=15)

    def actions(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def test_success_and_completed_rerun(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.actions(), ['check', 'check', 'flags', 'restart', 'cleanup', 'restart', 'verify'])
        before = (self.state / 'journal').read_bytes()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script(mode='--check').returncode, 0)
        self.assertEqual((self.state / 'journal').read_bytes(), before)
        self.assertEqual(self.actions()[-1], 'verify')

    def test_read_only_preflight(self):
        result = self.run_script(mode='--check')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.actions(), ['check'])
        self.assertEqual(list(self.state.iterdir()), [])

    def test_recovery_rejection(self):
        self.assertNotEqual(self.run_script('recovery').returncode, 0)
        self.assertEqual(self.actions(), ['check'])
        self.assertFalse((self.state / 'journal').exists())

    def test_confirmation_rejection(self):
        self.assertNotEqual(self.run_script('confirmation').returncode, 0)
        self.assertEqual(self.actions(), ['check'])
        self.assertFalse((self.state / 'journal').exists())

    def test_flag_failure_and_partial_rerun(self):
        self.assertNotEqual(self.run_script('flags').returncode, 0)
        self.assertEqual(self.actions(), ['check', 'check', 'flags'])
        before = self.actions()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertNotEqual(self.run_script(mode='--check').returncode, 0)
        self.assertEqual(self.actions(), before)

    def test_nonzero_process_with_success_marker(self):
        self.assertNotEqual(self.run_script('process').returncode, 0)
        self.assertEqual(self.actions(), ['check', 'check', 'flags'])

    def test_restart_failure(self):
        self.assertNotEqual(self.run_script('restart').returncode, 0)
        self.assertEqual(self.actions(), ['check', 'check', 'flags', 'restart'])
        self.assertIn('Service restart failed', (self.state / 'journal').read_text())

    def test_cleanup_failure(self):
        self.assertNotEqual(self.run_script('cleanup').returncode, 0)
        self.assertEqual(self.actions(), ['check', 'check', 'flags', 'restart', 'cleanup'])

    def test_second_restart_failure(self):
        self.assertNotEqual(self.run_script('restart-second').returncode, 0)
        self.assertEqual(self.actions(), ['check', 'check', 'flags', 'restart', 'cleanup', 'restart'])
        self.assertNotIn('phase=complete', (self.state / 'journal').read_text())

    def test_final_verification_failure(self):
        self.assertNotEqual(self.run_script('verify').returncode, 0)
        self.assertNotIn('phase=complete', (self.state / 'journal').read_text())

    def test_hard_kill_retains_journal(self):
        self.assertEqual(self.run_script('hardkill').returncode, -9)
        self.assertIn('phase=flags', (self.state / 'journal').read_text())
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertNotIn('cleanup', self.actions())

    def test_disposable_success_records_real_waiver(self):
        result = self.run_script('recovery', disposable=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        journal = (self.state / 'journal').read_text()
        self.assertIn('disposable_test=yes restore_rehearsal=waived rebuild_accepted=yes isolation_attested=yes', journal)
        self.assertNotIn('RESTORE VERIFIED', result.stdout)
        self.assertIn('phase=complete', journal)
        self.assertEqual(self.actions(), ['check', 'check', 'flags', 'restart', 'cleanup', 'restart', 'verify'])
        before = (self.state / 'journal').read_bytes()
        self.assertEqual(self.run_script(mode='--check', disposable=True).returncode, 0)
        self.assertEqual((self.state / 'journal').read_bytes(), before)

    def test_default_mode_still_requires_recovery(self):
        self.assertNotEqual(self.run_script(without_recovery=True).returncode, 0)
        self.assertEqual(self.actions(), [])

    def test_environment_cannot_enable_disposable_exception(self):
        with patch.dict(os.environ, {'DISPOSABLE_TEST': '1'}):
            self.assertNotEqual(self.run_script(without_recovery=True).returncode, 0)
        self.assertEqual(self.actions(), [])

    def test_duplicate_disposable_option_is_rejected(self):
        self.assertNotEqual(self.run_script(disposable=True, extra_args=['--disposable-test']).returncode, 0)
        self.assertEqual(self.actions(), [])

    def test_disposable_cannot_mix_with_recovery(self):
        result = self.run_script(disposable=True, extra_args=['--recovery', 'synthetic-evidence'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.actions(), [])

    def test_disposable_requires_loss_acceptance(self):
        self.assertNotEqual(self.run_script('waiver', disposable=True).returncode, 0)
        self.assertEqual(self.actions(), ['check'])
        self.assertFalse((self.state / 'journal').exists())

    def test_disposable_requires_isolation_confirmation(self):
        self.assertNotEqual(self.run_script('isolation', disposable=True).returncode, 0)
        self.assertEqual(self.actions(), ['check'])
        self.assertFalse((self.state / 'journal').exists())

    def test_disposable_keeps_database_validation(self):
        self.assertNotEqual(self.run_script('check', disposable=True).returncode, 0)
        self.assertEqual(self.actions(), ['check'])
        self.assertFalse((self.state / 'journal').exists())

    def test_disposable_keeps_version_validation(self):
        self.assertNotEqual(self.run_script('version', disposable=True).returncode, 0)
        self.assertEqual(self.actions(), ['check'])
        self.assertFalse((self.state / 'journal').exists())

    def test_disposable_partial_rerun_is_blocked(self):
        self.assertNotEqual(self.run_script('flags', disposable=True).returncode, 0)
        before = self.actions()
        self.assertNotEqual(self.run_script(disposable=True).returncode, 0)
        self.assertEqual(self.actions(), before)

    def test_disposable_check_remains_read_only(self):
        result = self.run_script(mode='--check', disposable=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('restore rehearsal waived', result.stdout)
        self.assertEqual(self.actions(), ['check'])
        self.assertEqual(list(self.state.iterdir()), [])

    def test_signal_interruption(self):
        self.assertEqual(self.run_script('signal').returncode, 143)
        self.assertIn('outcome=uncertain', (self.state / 'journal').read_text())
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertNotIn('cleanup', self.actions())


if __name__ == '__main__':
    unittest.main()
