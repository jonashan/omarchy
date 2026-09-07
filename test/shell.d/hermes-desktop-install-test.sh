#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

for command in git jq python3; do require_command "$command"; done

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT
export OMARCHY_TEST_ROOT="$test_tmp"
mkdir -p "$test_tmp/bin" "$test_tmp/package/resources" "$test_tmp/share" "$test_tmp/seed"

# Real Git exercises patch checks and preservation; all package, desktop and
# service commands are mocks. No command reaches the live user installation.
git -C "$test_tmp/seed" init -q -b main
printf 'venv/\n.hermes-bootstrap-complete\napps/desktop/release/\n__pycache__/\n' >"$test_tmp/seed/.gitignore"
printf 'before\n' >"$test_tmp/seed/runtime.txt"
mkdir -p "$test_tmp/seed/apps/desktop/src"
printf 'desktop source\n' >"$test_tmp/seed/apps/desktop/src/main.js"
mkdir -p "$test_tmp/seed/hermes_cli"
cat >"$test_tmp/seed/hermes_cli/main.py" <<'PY'
import os
from pathlib import Path

def _write_desktop_build_stamp(project_root, *, source_mode):
    home = Path(os.environ['HERMES_HOME'])
    assert project_root == home / 'hermes-agent'
    assert source_mode is False
    assert (project_root / 'apps/desktop/release/linux-unpacked/resources/app.asar').is_file()
    (home / 'desktop-build-stamp.json').write_text('upstream build stamp')
    with (Path(os.environ['OMARCHY_TEST_ROOT']) / 'events').open('a') as log:
        log.write('build-stamp\n')
PY
git -C "$test_tmp/seed" add .
git -C "$test_tmp/seed" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
release_commit=$(git -C "$test_tmp/seed" rev-parse HEAD)
printf 'after\n' >"$test_tmp/seed/runtime.txt"
git -C "$test_tmp/seed" diff >"$test_tmp/share/runtime.patch"
printf 'before\n' >"$test_tmp/seed/runtime.txt"
printf '{"branch":"main","commit":"%s"}\n' "$release_commit" >"$test_tmp/package/resources/install-stamp.json"
printf 'packaged app\n' >"$test_tmp/package/resources/app.asar"
printf '#!/bin/bash\nexit 0\n' >"$test_tmp/package/Hermes"
touch "$test_tmp/package/chrome-sandbox"
chmod 755 "$test_tmp/package/Hermes"
chmod 4755 "$test_tmp/package/chrome-sandbox"

cat >"$test_tmp/share/install.sh" <<'MOCK'
#!/bin/bash
set -e
printf 'bootstrap\n' >>"$OMARCHY_TEST_ROOT/events"
printf '%s\n' "$@" >"$OMARCHY_TEST_ROOT/install-args"
[[ ${OMARCHY_TEST_INSTALL_FAIL:-0} != 1 ]] || exit 7
while (( $# )); do
  case "$1" in
    --dir) runtime=$2; shift ;;
    --hermes-home) [[ $2 == "$HERMES_HOME" ]] ;;
  esac
  shift
done
mkdir -p -- "${runtime%/*}"
if [[ ! -d $runtime ]]; then git clone -q "$OMARCHY_TEST_ROOT/seed" "$runtime"; fi
mkdir -p "$runtime/venv/bin"
printf '#!/bin/bash\nexit 0\n' >"$runtime/venv/bin/hermes"
chmod +x "$runtime/venv/bin/hermes"
printf '#!/bin/bash\nexec /usr/bin/python3 "$@"\n' >"$runtime/venv/bin/python"
chmod +x "$runtime/venv/bin/python"
[[ ${OMARCHY_TEST_NO_MARKER:-0} == 1 ]] || touch "$runtime/.hermes-bootstrap-complete"
MOCK

cat >"$test_tmp/bin/omarchy-pkg-add" <<'MOCK'
#!/bin/bash
printf 'package %s\n' "$*" >>"$OMARCHY_TEST_ROOT/events"
[[ ${OMARCHY_TEST_PACKAGE_FAIL:-0} != 1 ]]
MOCK
cat >"$test_tmp/bin/omarchy-install-hermes-cli" <<'MOCK'
#!/bin/bash
printf 'handoff\n' >>"$OMARCHY_TEST_ROOT/events"
exit 1
MOCK
cat >"$test_tmp/bin/setsid" <<'MOCK'
#!/bin/bash
exec "$@"
MOCK
cat >"$test_tmp/bin/cp" <<'MOCK'
#!/bin/bash
if [[ ${OMARCHY_TEST_COPY_FAIL:-0} == 1 ]]; then
  touch "${@: -1}/partial-copy"
  exit 9
fi
exec /usr/bin/cp "$@"
MOCK
cat >"$test_tmp/bin/mv" <<'MOCK'
#!/bin/bash
if [[ ${OMARCHY_TEST_COPY_RACE:-0} == 1 && $1 == -T ]]; then
  mkdir -p "${@: -1}"
  printf 'concurrent app\n' >"${@: -1}/keep"
fi
exec /usr/bin/mv "$@"
MOCK
cat >"$test_tmp/bin/uwsm-app" <<'MOCK'
#!/bin/bash
[[ $1 == -- ]] || exit 1
shift
exec "$@"
MOCK
cat >"$test_tmp/bin/hermes-desktop" <<'MOCK'
#!/bin/bash
native="$HERMES_HOME/hermes-agent/apps/desktop/release/linux-unpacked"
if [[ -x $native/Hermes && -f $native/resources/app.asar ]]; then
  printf 'launch\n' >>"$OMARCHY_TEST_ROOT/events"
else
  printf 'launch-before-copy\n' >>"$OMARCHY_TEST_ROOT/events"
fi
MOCK
cat >"$test_tmp/bin/systemctl" <<'MOCK'
#!/bin/bash
printf 'theme-stop\n' >>"$OMARCHY_TEST_ROOT/events"
MOCK
cat >"$test_tmp/bin/systemd-run" <<'MOCK'
#!/bin/bash
printf 'theme-start\n' >>"$OMARCHY_TEST_ROOT/events"
# Join the mock asynchronous launch so every test owns its full lifetime.
for (( attempt=0; attempt<100; attempt++ )); do
  if grep -q '^launch' "$OMARCHY_TEST_ROOT/events"; then exit 0; fi
  sleep 0.01
done
exit 1
MOCK
chmod +x "$test_tmp/bin/"*

# Substitute only system package paths in a scratch copy of the actual script.
python3 - "$ROOT/bin/omarchy-install-ai-hermes" "$test_tmp" <<'PY'
from pathlib import Path
import sys
source, scratch = Path(sys.argv[1]), Path(sys.argv[2])
script = source.read_text()
for original, replacement in {
    '/opt/hermes-desktop': str(scratch / 'package'),
    '/usr/share/hermes-desktop': str(scratch / 'share'),
    '/usr/bin/hermes-desktop': str(scratch / 'bin/hermes-desktop'),
}.items():
    script = script.replace(original, replacement)
(scratch / 'installer').write_text(script)
PY

new_home() {
  test_home="$test_tmp/$1"
  hermes_home="$test_home/.hermes"
  runtime="$hermes_home/hermes-agent"
  native="$runtime/apps/desktop/release/linux-unpacked"
  mkdir -p "$test_home"
  : >"$test_tmp/events"
}
run_installer() {
  HOME="$test_home" HERMES_HOME="${OMARCHY_TEST_HOME:-$hermes_home}" PATH="$test_tmp/bin:$PATH" \
    bash "$test_tmp/installer" >"$test_tmp/output" 2>&1
}
assert_stopped() {
  if grep -Eq '^(launch|theme-|build-stamp)' "$test_tmp/events"; then fail "$1"; fi
}

new_home fresh
run_installer || fail "fresh setup succeeds" "$(cat "$test_tmp/output")"
expected=$(printf '%s\n' --skip-setup --branch main --commit "$release_commit" --dir "$runtime" --hermes-home "$hermes_home")
[[ $(cat "$test_tmp/install-args") == "$expected" ]] || fail "upstream installer receives the pinned main arguments"
[[ $(head -3 "$test_tmp/events") == $'package hermes-desktop\nhandoff\nbootstrap' ]] || fail "package and CLI handoff precede runtime bootstrap"
grep -qx launch "$test_tmp/events" || fail "native app is copied before launch"
[[ $(sed -n '4p' "$test_tmp/events") == build-stamp ]] || fail "upstream build stamp follows the app copy and precedes launch"
[[ $(cat "$hermes_home/desktop-build-stamp.json") == 'upstream build stamp' ]] || fail "the upstream helper records the completed packaged build"
[[ $(cat "$runtime/runtime.txt") == after ]] || fail "the release runtime receives its patch"
[[ $(stat -c %a "$native/chrome-sandbox") == 755 ]] || fail "the user sandbox is not setuid"
[[ $(stat -c %a "$test_tmp/package/chrome-sandbox") == 4755 ]] || fail "package sandbox permissions remain unchanged"
pass "fresh setup pins main, patches the matching runtime and copies the complete app before launch"

printf 'user app\n' >"$native/resources/app.asar"
printf 'user build stamp\n' >"$hermes_home/desktop-build-stamp.json"
: >"$test_tmp/events"
run_installer || fail "repeat setup succeeds" "$(cat "$test_tmp/output")"
! grep -qx bootstrap "$test_tmp/events" || fail "repeat setup does not bootstrap again"
! grep -qx build-stamp "$test_tmp/events" || fail "existing app never reruns the build stamp writer"
[[ $(cat "$hermes_home/desktop-build-stamp.json") == 'user build stamp' ]] || fail "existing native build stamp remains unchanged"
[[ $(cat "$native/resources/app.asar") == 'user app' ]] || fail "existing native app remains unchanged"
pass "repeat setup accepts the applied patch and preserves the existing native app"

# Advancing the runtime must never reinstall the release or reapply its patch.
printf 'new main\n' >"$runtime/runtime.txt"
git -C "$runtime" add runtime.txt
git -C "$runtime" -c user.name=Test -c user.email=test@example.invalid commit -qm update
run_installer || fail "a complete updated runtime and native app are reused"
[[ $(cat "$runtime/runtime.txt") == 'new main' ]] || fail "updated runtime is not release-patched"
mv "$native" "$test_tmp/saved-native"
: >"$test_tmp/events"
run_installer && fail "a newer runtime cannot receive an older native app"
[[ ! -e $native ]] || fail "no mismatched native app was copied"
grep -q 'hermes desktop --build-only' "$test_tmp/output" || fail "missing newer native app has actionable guidance"
assert_stopped "a missing updated app prevents launch and theme setup"
pass "updated runtimes are preserved and never seeded with the old packaged app"

new_home dirty-desktop
HERMES_HOME="$hermes_home" bash "$test_tmp/share/install.sh" --dir "$runtime" --hermes-home "$hermes_home"
printf 'local desktop edit\n' >"$runtime/apps/desktop/src/main.js"
: >"$test_tmp/events"
run_installer && fail "modified desktop sources cannot be certified as the packaged build"
[[ ! -e $native && ! -e $hermes_home/desktop-build-stamp.json ]] || fail "modified desktop sources receive neither packaged app nor build stamp"
[[ $(cat "$runtime/apps/desktop/src/main.js") == 'local desktop edit' ]] || fail "desktop source edits are preserved"
grep -q 'hermes desktop --build-only' "$test_tmp/output" || fail "modified desktop sources have build guidance"
assert_stopped "modified desktop sources prevent stamping, launch and theme setup"
pass "a matching commit with modified desktop sources is preserved without seeding or stamping"

for failure in package install marker; do
  new_home "$failure-failure"
  case "$failure" in
    package) OMARCHY_TEST_PACKAGE_FAIL=1 run_installer && fail "package failure stops setup" ;;
    install) OMARCHY_TEST_INSTALL_FAIL=1 run_installer && fail "installer failure stops setup" ;;
    marker) OMARCHY_TEST_NO_MARKER=1 run_installer && fail "missing marker stops setup" ;;
  esac
  [[ ! -e $native ]] || fail "failed setup does not seed the app"
  assert_stopped "failed setup prevents launch and theme setup"
done
pass "package, upstream installer and readiness failures stop before launch"

for failure in copy race; do
  new_home "$failure-failure"
  if [[ $failure == "copy" ]]; then
    OMARCHY_TEST_COPY_FAIL=1 run_installer && fail "copy failure stops setup"
    [[ ! -e $native ]] || fail "partial copy is never published"
  else
    OMARCHY_TEST_COPY_RACE=1 run_installer && fail "concurrent native app stops publication"
    [[ $(cat "$native/keep") == 'concurrent app' ]] || fail "concurrent native app is preserved"
  fi
  [[ -z $(find "${native%/*}" -maxdepth 1 -name '.linux-unpacked.*' -print) ]] || fail "owned staging directory is cleaned up"
  assert_stopped "publication failure prevents launch"
done
pass "failed copies and concurrent app creation preserve existing work and clean only staging"

new_home incomplete-native
run_installer || fail "incomplete native fixture sets up"
rm "$native/resources/app.asar"
: >"$test_tmp/events"
run_installer && fail "incomplete existing app requires repair"
[[ ! -e $native/resources/app.asar ]] || fail "incomplete existing app is not overwritten"
assert_stopped "incomplete native app prevents launch"
pass "an incomplete existing native app is preserved"

new_home patch-conflict
run_installer || fail "patch conflict fixture sets up"
printf 'local edit\n' >"$runtime/runtime.txt"
: >"$test_tmp/events"
run_installer && fail "unexpected patch conflict stops setup"
[[ $(cat "$runtime/runtime.txt") == 'local edit' ]] || fail "conflicting runtime changes are preserved"
assert_stopped "patch conflict prevents launch"
rm "$runtime/.hermes-bootstrap-complete"
: >"$test_tmp/events"
run_installer && fail "incomplete modified runtime cannot be reset by upstream installer"
! grep -qx bootstrap "$test_tmp/events" || fail "modified runtime never reaches upstream installer"
pass "patch conflicts and incomplete modified runtimes retain local changes and stop safely"

new_home custom-profile
hermes_home="$test_home/custom home"
runtime="$hermes_home/hermes-agent"
OMARCHY_TEST_HOME="$hermes_home/PrOfIlEs/coder/../coder/" run_installer || fail "profile setup succeeds"
[[ -x $runtime/apps/desktop/release/linux-unpacked/Hermes ]] || fail "profile uses the canonical root runtime"
grep -qxF "$hermes_home" "$test_tmp/install-args" || fail "canonical custom home reaches upstream installer"
pass "custom profile paths normalize to the shared Hermes home"
