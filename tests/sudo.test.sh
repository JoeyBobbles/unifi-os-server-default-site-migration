#!/usr/bin/env bash
set -euo pipefail
source ./unifi-os-server-default-site-migration.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TRACE=$work/args
HAS_NO_UPDATE=0
AUTH_FAIL=0
# No real sudo, Podman or service command is invoked by these tests.
sudo() {
  if [[ $1 == --help ]]; then
    if [[ $HAS_NO_UPDATE == 1 ]]; then echo '-N, --no-update'; else echo '-n, --non-interactive'; fi
    return 0
  fi
  printf '%s\n' "$*" >> "$TRACE"
  if [[ $HAS_NO_UPDATE == 0 && " $* " == *' -N '* ]]; then return 99; fi
  [[ $AUTH_FAIL == 0 ]]
}
configure_sudo
[[ ${SUDO_AUTH_ARGS[*]} == -n && $(tail -n1 "$TRACE") == '-n true' ]]
SVC_USER=synthetic-service SVC_UID=12345
as_svc ps
[[ $(tail -n1 "$TRACE") == '-n -H -u synthetic-service XDG_RUNTIME_DIR=/run/user/12345 podman --remote=false ps' ]]
HAS_NO_UPDATE=1
configure_sudo
[[ ${SUDO_AUTH_ARGS[*]} == '-n -N' && $(tail -n1 "$TRACE") == '-n -N true' ]]
as_svc ps
[[ $(tail -n1 "$TRACE") == '-n -N -H -u synthetic-service XDG_RUNTIME_DIR=/run/user/12345 podman --remote=false ps' ]]
if (AUTH_FAIL=1; configure_sudo); then echo 'Expected authentication rejection'; exit 1; fi
printf '5 sudo compatibility tests passed\n'
