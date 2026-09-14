#!/bin/bash
# Integration: every command the QML builds must be accepted by the real helper.
# Skips cleanly where qml6 or real accounts are unavailable.
set -uo pipefail
# This check queries account quota and sync status. Ordinary tests must not
# contact Microsoft or touch the user's account caches without an explicit opt-in.
if [[ ${OMAONEDRIVE_LIVE_CONTRACT:-0} != 1 ]]; then
  echo "Contract check SKIPPED (set OMAONEDRIVE_LIVE_CONTRACT=1 on a test account)"
  exit 0
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
qml_runner=${OMAONEDRIVE_QML_RUNNER:-$(command -v qml6 || echo /usr/lib/qt6/bin/qml)}
[ -x "$qml_runner" ] || { echo "Contract check SKIPPED (no qml6)"; exit 0; }

# A helper that CRASHED and a machine with no accounts are not the same thing.
# Swallowing the exit status turned "--list-accounts raises" into a clean skip,
# so breaking discovery outright passed the suite.
if ! accounts=$(python3 "$root/onedrive-status.py" --list-accounts 2>&1); then
  echo "Contract check FAILED: --list-accounts exited non-zero" >&2
  printf '  %s\n' "$accounts" >&2
  exit 1
fi
if ! printf '%s' "$accounts" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "Contract check FAILED: --list-accounts did not produce JSON" >&2
  printf '  %s\n' "$accounts" >&2
  exit 1
fi
case "$accounts" in '[]') echo "Contract check SKIPPED (no accounts on this machine)"; exit 0 ;; esac

# Generated beside Contract.qml so its relative import of the widget resolves.
harness="$root/tests/qml/.Contract.generated.qml"
trap 'rm -f -- "$harness"' EXIT
python3 - "$root/tests/qml/Contract.qml" "$harness" "$accounts" <<'PY'
import json, sys
src = open(sys.argv[1]).read()
src = src.replace('property string discoveryJson: "[]"',
                  'property string discoveryJson: %s' % json.dumps(sys.argv[3]))
open(sys.argv[2], "w").write(src)
PY

qml_out=$(mktemp)
# Unset for the same reason tests/run does: an inherited gtk3 platform theme
# tries to open the X display even under the offscreen platform, and the check
# then fails for a reason that has nothing to do with the widget.
( ulimit -c 0; unset QT_QPA_PLATFORMTHEME; \
  QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  "$qml_runner" -I "$root/tests/qmlstubs" "$harness" >"$qml_out" 2>&1 )
qml_status=$?
commands=$(sed -n 's/^qml: CMD //p' "$qml_out")
rm -f -- "$qml_out"
# The QML's own status matters: without this, a harness that printed one command
# and then exited 1 passed the check.
[ "$qml_status" -eq 0 ] || { echo "Contract check FAILED: the QML harness exited $qml_status" >&2; exit 1; }
[ -n "$commands" ] || { echo "Contract check FAILED: the QML produced no commands" >&2; exit 1; }
count=0
routine=0
quota=0
syncstatus=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # In a process substitution this python3 could fail and the check would sail
  # on: feeding it a line that is not JSON printed a traceback and still ended
  # with "Contract check passed (0 commands)".
  if ! argv_lines=$(python3 -c 'import json,sys
argv = json.loads(sys.argv[1])
assert isinstance(argv, list) and argv, "not a non-empty argv array"
for a in argv: print(a)' "$line" 2>&1); then
    echo "Contract check FAILED: the QML emitted a line that is not an argv array" >&2
    printf '  line:  %s\n  error: %s\n' "$line" "$argv_lines" >&2
    exit 1
  fi
  mapfile -t argv <<<"$argv_lines"
  [ "${#argv[@]}" -gt 0 ] || continue
  case "${argv[*]}" in *--list-accounts*) continue ;; esac
  if ! out=$("${argv[@]}" 2>&1); then
    echo "Contract check FAILED: the helper rejected a command the widget builds" >&2
    printf '  argv:  %s\n  error: %s\n' "$line" "$out" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True' 2>/dev/null; then
    echo "Contract check FAILED: helper output was not a valid status object" >&2
    printf '  argv: %s\n' "$line" >&2
    exit 1
  fi
  count=$((count + 1))
  case "${argv[*]}" in
    *--quota*)       quota=$((quota + 1)) ;;
    *--sync-status*) syncstatus=$((syncstatus + 1)) ;;
    *)               routine=$((routine + 1)) ;;
  esac
done <<<"$commands"

# Counted from what was actually EXECUTED, not grepped out of the QML's output.
# The old gate looked only for --quota and --sync-status, so making every
# routine status vector return [] -- the poll the widget runs every few seconds,
# and the only one that reports sync state -- still passed. And nothing required
# the count to be positive at all.
[ "$count" -gt 0 ] || { echo "Contract check FAILED: no command was executed" >&2; exit 1; }
for mode in "routine:$routine" "quota:$quota" "sync-status:$syncstatus"; do
  case "$mode" in *:0)
    echo "Contract check FAILED: no ${mode%%:*} status command was produced" >&2
    exit 1 ;;
  esac
done

echo "Contract check passed ($count widget-built command(s) accepted by the real helper:" \
     "$routine routine, $quota quota, $syncstatus sync-status)"
