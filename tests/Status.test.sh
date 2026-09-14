#!/bin/bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
test_home="$test_root/home"
sync_dir="$test_home/My OneDrive"
mkdir -p "$fake_bin" "$test_home/.config/onedrive" "$sync_dir/Docs" "$sync_dir/Photos"
printf 'sync_dir = "%s"\n' "$sync_dir" >"$test_home/.config/onedrive/config"
touch "$test_home/.config/onedrive/refresh_token"
printf 'report' >"$sync_dir/Docs/report.pdf"
printf 'photo' >"$sync_dir/Photos/photo.jpg"
touch -d '2026-08-14 10:00:00 UTC' "$sync_dir/Docs/report.pdf"
touch -d '2026-08-15 10:00:00 UTC' "$sync_dir/Photos/photo.jpg"

cat >"$fake_bin/onedrive" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_ONEDRIVE_LOG:?}"
if [[ -n ${FAKE_ONEDRIVE_ARGV_LOG:-} ]]; then
  printf 'ARGC=%s\n' "$#" >>"$FAKE_ONEDRIVE_ARGV_LOG"
  for argument in "$@"; do printf '[%s]\n' "$argument" >>"$FAKE_ONEDRIVE_ARGV_LOG"; done
fi
confdir=""
previous=""
for argument in "$@"; do
  [[ $previous == --confdir ]] && confdir="$argument"
  previous="$argument"
done
sync_dir="${FAKE_SYNC_DIR:?}"
if [[ -n $confdir && -f "$confdir/config" ]]; then
  from_config=$(sed -n 's/^sync_dir *= *"\(.*\)"$/\1/p' "$confdir/config" | head -1)
  [[ -n $from_config ]] && sync_dir="$from_config"
fi
case " $* " in
  *" --display-config "*)
    printf "Application version                          = onedrive v2.5.11\n"
    printf "Config option 'sync_dir'                      = %s\n" "$sync_dir"
    printf "Config option 'upload_only'                   = %s\n" "${FAKE_UPLOAD_ONLY:-false}"
    printf "Config option 'download_only'                 = %s\n" "${FAKE_DOWNLOAD_ONLY:-true}"
    ;;
  *" --display-quota "*)
    if [[ ${FAKE_QUOTA_FAILURE:-0} == 1 ]]; then
      echo "OneDrive quota query failed" >&2
      exit 8
    fi
    cat <<'OUT'
Remaining: 8.00 GB (8000000000 bytes)
State:     normal
Total:     10.00 GB (10000000000 bytes)
Used:      2.00 GB (2000000000 bytes)
OUT
    ;;
  *" --display-sync-status "*)
    if [[ ${FAKE_STATUS_FAILURE:-0} == 1 ]]; then
      echo "OneDrive status query failed" >&2
      exit 9
    elif [[ ${FAKE_PENDING_CHANGES:-0} == 1 ]]; then
      cat <<'OUT'
The configured local 'sync_dir' directory is out of sync with Microsoft OneDrive
Approximate data to download from Microsoft OneDrive: 1124 KB
OUT
    else
      echo "There are no pending changes from Microsoft OneDrive; your local directory matches the data online."
    fi
    ;;
  *) exit 2 ;;
esac
SH

cat >"$fake_bin/systemctl" <<'SH'
#!/bin/bash
unit=""
timer=""
for argument in "$@"; do
  case "$argument" in
    *.service) unit="$argument" ;;
    *.timer) timer="$argument" ;;
  esac
done
case " $* " in
  *" list-timers "*)
    # Only the unit actually asked for reports a pending resume, so an account
    # cannot inherit another account's timer.
    if [[ -n ${FAKE_RESUME_AT:-} && $timer == "${FAKE_RESUME_TIMER:-omaonedrive-resume.timer}" ]]; then
      printf '[{"next":%s,"unit":"%s"}]\n' "$((FAKE_RESUME_AT * 1000000))" "$timer"
    else
      echo '[]'
    fi
    ;;
  *" list-units "*)
    case " $* " in
      *" --plain "*) ;;
      *) echo "list-units called without --plain" >&2; exit 64 ;;
    esac
    case " $* " in
      *" --no-legend "*) ;;
      *) echo "list-units called without --no-legend" >&2; exit 64 ;;
    esac
    if [[ ${FAKE_NO_SYSTEMD:-0} == 1 ]]; then
      exit 1
    fi
    if [[ -n ${FAKE_UNITS:-} ]]; then
      printf '%s\n' "$FAKE_UNITS"
    fi
    exit 0
    ;;
  *"--property=ExecStart"*)
    if [[ ${FAKE_NO_SYSTEMD:-0} == 1 ]]; then
      exit 1
    fi
    load=loaded
    extra=""
    case "$unit" in
      onedrive.service)
        description='OneDrive Client for Linux'
        args='--monitor'
        ;;
      onedrive@personal.service)
        # confdir deliberately unrelated to the instance name, written with the
        # "--confdir=<path>" spelling.
        description='OneDrive sync (personal account)'
        args='--monitor --confdir=/srv/onedrive/mailboxes/alpha'
        ;;
      onedrive@work.service)
        # Same, with the "--confdir <path>" spelling systemd also preserves.
        description='OneDrive sync (work account)'
        args='--monitor --confdir /srv/onedrive/mailboxes/beta'
        ;;
      onedrive@spaced.service)
        # A confdir containing a space. systemd joins argv with literal spaces
        # and does not quote, so this is indistinguishable from extra arguments.
        description='OneDrive sync (spaced account)'
        args="--monitor --confdir=${FAKE_SPACED_CONFDIR:-/nonexistent/My Config}"
        ;;
      onedrive@decoy.service)
        # path= itself contains the literal text "argv[]=" plus a --confdir. A
        # parser that searches the whole property for "argv[]=" reads the decoy.
        description='OneDrive sync (decoy account)'
        path='/opt/argv[]=/dummy --confdir=/srv/onedrive/DECOY'
        args='--monitor --confdir=/srv/onedrive/mailboxes/real'
        ;;
      onedrive@prepared.service)
        # Two ExecStart lines: a preparatory command with its own --confdir,
        # then the real client. Only the client's confdir is this account's.
        description='OneDrive sync (prepared account)'
        extra='ExecStart={ path=/usr/bin/prepare ; argv[]=/usr/bin/prepare --confdir=/srv/onedrive/STAGING ; ignore_errors=no ; }'
        args='--monitor --confdir=/srv/onedrive/mailboxes/prepared'
        ;;
      onedrive@bogus.service)
        # Present but unusable: a relative confdir. Must be dropped, never
        # rewritten to the default account's directory.
        description='OneDrive sync (bogus account)'
        args='--monitor --confdir=relative/not/absolute'
        ;;
      onedrive@masked.service)
        load=masked
        description='onedrive@masked.service'
        args=''
        ;;
      onedrive@ghost.service)
        load=not-found
        description='onedrive@ghost.service'
        args=''
        ;;
      onedrive@broken.service)
        # A unit systemd could not parse. Like masked and not-found, it has no
        # ExecStart -- and an empty ExecStart used to read as "passes no
        # --confdir", which aliased this instance onto the DEFAULT account.
        load=error
        description='onedrive@broken.service'
        args=''
        ;;
      onedrive@stub.service)
        load=stub
        description='onedrive@stub.service'
        args=''
        ;;
      onedrive@unloadable.service)
        # LoadState=error WITH a perfectly good ExecStart. systemd could not load
        # this unit, so it will never run: offering it as an account gives the
        # user a tab whose pause and resume buttons do nothing. The empty-
        # ExecStart rule does not catch this one -- only the allowlist does.
        load=error
        description='OneDrive sync (unloadable account)'
        args='--monitor --confdir=/srv/onedrive/mailboxes/unloadable'
        ;;
      onedrive@hollow.service)
        # Loaded, but `systemctl show` tells us nothing about what it runs.
        load=loaded
        description='OneDrive sync (hollow account)'
        args=''
        ;;
      *) exit 1 ;;
    esac
    echo "LoadState=$load"
    echo "Description=$description"
    [[ -n $extra ]] && echo "$extra"
    if [[ -n $args ]]; then
      echo "ExecStart={ path=${path:-/usr/bin/onedrive} ; argv[]=/usr/bin/onedrive $args ; ignore_errors=no ; start_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
    else
      echo 'ExecStart='
    fi
    exit 0
    ;;
  *" show "*)
    active=${FAKE_ACTIVE:-active}
    sub_state=dead
    [[ $active == active ]] && sub_state=running
    cat <<OUT
LoadState=loaded
ActiveState=$active
SubState=$sub_state
UnitFileState=${FAKE_ENABLED:-enabled}
Result=${FAKE_RESULT:-success}
ExecMainCode=exited
ExecMainStatus=${FAKE_EXIT_STATUS:-0}
OUT
    ;;
  *) exit 1 ;;
esac
SH

cat >"$fake_bin/journalctl" <<'SH'
#!/bin/bash
cat <<'OUT'
{"MESSAGE":"Starting a sync with Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786787990000000"}
OUT
if [[ ${FAKE_RECOVERED_NETWORK:-0} == 1 ]]; then
  echo '{"MESSAGE":"ERROR: Encountered a std.net.curl.CurlException:","__REALTIME_TIMESTAMP":"1786787995000000"}'
  echo '{"MESSAGE":"  Error Message: Failed sending data to the peer","__REALTIME_TIMESTAMP":"1786787995000000"}'
fi
cat <<'OUT'
{"MESSAGE":"Sync with Microsoft OneDrive is complete","__REALTIME_TIMESTAMP":"1786788000000000"}
OUT
if [[ ${FAKE_INCOMPLETE_SYNC:-0} == 1 ]]; then
  echo '{"MESSAGE":"Starting a sync with Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786788010000000"}'
fi
if [[ ${FAKE_TRANSFER:-0} == 1 ]]; then
  echo '{"MESSAGE":"Downloading changes from Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786788011000000"}'
  echo '{"MESSAGE":"Uploading new file ./Docs/report.pdf ... done","__REALTIME_TIMESTAMP":"1786788015000000"}'
fi
if [[ ${FAKE_RECONCILIATION:-0} == 1 ]]; then
  echo '{"MESSAGE":"Performing a full scan of online data to ensure consistent local state","__REALTIME_TIMESTAMP":"1786788011000000"}'
  echo '{"MESSAGE":"Processing 71903 applicable JSON items received from Microsoft OneDrive","__REALTIME_TIMESTAMP":"1786788015000000"}'
fi
if [[ ${FAKE_REAUTH:-0} == 1 ]]; then
  echo '{"MESSAGE":"ERROR: You will need to issue a --reauth and re-authorise this client to obtain a fresh auth token.","__REALTIME_TIMESTAMP":"1786788020000000"}'
fi
if [[ ${FAKE_LIVE_UPLOAD:-0} == 1 ]]; then
  now_us=$(( $(date +%s) * 1000000 ))
  echo "{\"MESSAGE\":\"New items to upload to Microsoft OneDrive: 1\",\"__REALTIME_TIMESTAMP\":\"$(( now_us - 20000000 ))\"}"
  echo "{\"MESSAGE\":\"Uploading: Documents/all-hands recording.mp4 ... 66%  |  ETA    00:00:10\",\"__REALTIME_TIMESTAMP\":\"$(( now_us - 5000000 ))\"}"
fi
SH

chmod +x "$fake_bin/onedrive" "$fake_bin/systemctl" "$fake_bin/journalctl"
export FAKE_ONEDRIVE_LOG="$test_root/onedrive.log"
export FAKE_SYNC_DIR="$sync_dir"
export HOME="$test_home"
export XDG_CONFIG_HOME="$test_home/.config"
export XDG_STATE_HOME="$test_root/state"
export OMAONEDRIVE_UNIT_ROOTS="$test_home/.config/systemd/user"
export PATH="$fake_bin:$PATH"

local_output="$test_root/local.json"
python3 "$root/onedrive-status.py" --limit 5 >"$local_output"
jq -e --arg sync_dir "$sync_dir" '
  .ok == true
  and .installed == true
  and .serviceAvailable == true
  and .running == true
  and .enabled == true
  and .authenticated == true
  and .syncing == false
  and .statusText == "Monitoring"
  and .syncDir == $sync_dir
  and .syncMode == "Download only"
  and .clientVersion == "onedrive v2.5.11"
  and .serviceFailed == false
  and .resyncRequired == false
  and .reauthRequired == false
  and .lastSyncTs == 1786788000
  and .quotaKnown == false
  and .remoteStatus == "Not checked"
  and (.files | length) == 2
  and .files[0].name == "photo.jpg"
  and (.activity | type) == "array"
  and ((.activity | length) > 0)
  and any(.activity[]; .kind == "sync" and .title == "Sync complete")
  and ([.activity[].ts] == ([.activity[].ts] | sort | reverse))
  and all(.activity[] | select(.kind == "file"); .detail | startswith("changed in"))
  and all(.activity[]; ((.title + " " + .detail) | ascii_downcase | test("uploaded|downloaded") | not))
' "$local_output" >/dev/null
[[ $(grep -c -- '--display-config' "$FAKE_ONEDRIVE_LOG") == 1 ]]
if grep -q -- '--display-quota\|--display-sync-status' "$FAKE_ONEDRIVE_LOG"; then
  echo "local refresh unexpectedly contacted OneDrive" >&2
  exit 1
fi

FAKE_LIVE_UPLOAD=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/live-upload.json"
jq -e '
  .syncing == true
  and .statusText == "Uploading all-hands recording.mp4 · 66%"
' "$test_root/live-upload.json" >/dev/null

FAKE_RECOVERED_NETWORK=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/recovered-network.json"
jq -e '
  .lastError == ""
  and any(.activity[];
    .kind == "error"
    and .recovered == true
    and .title == "Connection interruption — recovered"
    and (.detail | contains("Failed sending data to the peer")))
' "$test_root/recovered-network.json" >/dev/null

remote_output="$test_root/remote.json"
python3 "$root/onedrive-status.py" --remote --limit 5 >"$remote_output"
jq -e '
  .quotaKnown == true
  and .usedBytes == 2000000000
  and .quotaBytes == 10000000000
  and .quotaCheckedTs > 0
  and .quotaError == ""
  and .remoteStatus == "Up to date"
  and .syncStatusCheckedTs > 0
  and .syncStatusError == ""
  and .remoteCheckedTs > 0
  and .remoteError == ""
  and .lastError == ""
' "$remote_output" >/dev/null
[[ $(grep -c -- '--display-quota' "$FAKE_ONEDRIVE_LOG") == 1 ]]
[[ $(grep -c -- '--display-sync-status' "$FAKE_ONEDRIVE_LOG") == 1 ]]

FAKE_PENDING_CHANGES=1 python3 "$root/onedrive-status.py" --sync-status --limit 5 >"$test_root/pending.json"
jq -e '
  .remoteStatus == "Pending changes"
  and .syncStatusError == ""
  and .quotaError == ""
' "$test_root/pending.json" >/dev/null

cached_output="$test_root/cached.json"
python3 "$root/onedrive-status.py" --limit 5 >"$cached_output"
jq -e '.quotaKnown == true and .remoteStatus == "Pending changes"' "$cached_output" >/dev/null
[[ $(grep -c -- '--display-quota' "$FAKE_ONEDRIVE_LOG") == 1 ]]
[[ $(grep -c -- '--display-sync-status' "$FAKE_ONEDRIVE_LOG") == 2 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive") == 700 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive/status-cache.json") == 600 ]]
[[ $(stat -c '%a' "$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive/status.lock") == 600 ]]

FAKE_STATUS_FAILURE=1 python3 "$root/onedrive-status.py" --sync-status --limit 5 >"$test_root/remote-failure.json"
jq -e '
  .remoteStatus == "Pending changes"
  and .syncStatusError == "Cloud sync check failed"
  and .quotaError == ""
  and .remoteError == "Cloud sync check failed"
  and .lastError == ""
  and .quotaKnown == true
' "$test_root/remote-failure.json" >/dev/null

python3 "$root/onedrive-status.py" --limit 5 >"$test_root/cached-failure.json"
jq -e '
  .remoteStatus == "Pending changes"
  and .syncStatusError == "Cloud sync check failed"
  and .quotaError == ""
  and .remoteError == "Cloud sync check failed"
  and .lastError == ""
' "$test_root/cached-failure.json" >/dev/null

python3 "$root/onedrive-status.py" --quota --limit 5 >"$test_root/quota-retry.json"
jq -e '
  .quotaError == ""
  and .syncStatusError == "Cloud sync check failed"
  and .remoteError == "Cloud sync check failed"
' "$test_root/quota-retry.json" >/dev/null

python3 "$root/onedrive-status.py" --sync-status --limit 5 >"$test_root/remote-recovered.json"
jq -e '
  .remoteStatus == "Up to date"
  and .quotaError == ""
  and .syncStatusError == ""
  and .remoteError == ""
  and .lastError == ""
' "$test_root/remote-recovered.json" >/dev/null

FAKE_QUOTA_FAILURE=1 python3 "$root/onedrive-status.py" --quota --limit 5 >"$test_root/quota-failure.json"
jq -e '
  .quotaKnown == true
  and .usedBytes == 2000000000
  and .quotaBytes == 10000000000
  and .quotaError == "Cloud quota check failed"
  and .syncStatusError == ""
  and .lastError == ""
' "$test_root/quota-failure.json" >/dev/null

python3 "$root/onedrive-status.py" --quota --limit 5 >"$test_root/quota-recovered.json"
jq -e '.quotaError == "" and .syncStatusError == "" and .remoteError == ""' \
  "$test_root/quota-recovered.json" >/dev/null

python3 - "$root/onedrive-status.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("omaonedrive_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
exit_code, output = module.command_output(
  ["bash", "-c", "printf 'partial\\n'; sleep 5"],
  timeout=1.0,
)
assert exit_code == 124
assert output == "partial"
PY

rm "$test_home/.config/onedrive/refresh_token"
FAKE_ACTIVE=inactive python3 "$root/onedrive-status.py" --limit 5 >"$test_root/login.json"
jq -e '.authenticated == false and .running == false and .statusText == "Login required"' "$test_root/login.json" >/dev/null

touch "$test_home/.config/onedrive/refresh_token"
FAKE_ACTIVE=inactive FAKE_INCOMPLETE_SYNC=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/paused.json"
jq -e '.authenticated == true and .running == false and .syncing == false and .statusText == "Sync paused"' "$test_root/paused.json" >/dev/null

FAKE_INCOMPLETE_SYNC=1 FAKE_TRANSFER=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/transfer.json"
jq -e '.syncing == true and .statusText == "Uploading report.pdf"' "$test_root/transfer.json" >/dev/null

FAKE_INCOMPLETE_SYNC=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/syncing.json"
jq -e '.syncing == true and .statusText == "Syncing…"' "$test_root/syncing.json" >/dev/null

FAKE_INCOMPLETE_SYNC=1 FAKE_RECONCILIATION=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/reconciliation.json"
jq -e '
  .syncing == true
  and .syncStage == "Processing 71,903 cloud items…"
  and .statusText == "Processing 71,903 cloud items…"
' "$test_root/reconciliation.json" >/dev/null

resume_at=$(($(date +%s) + 3600))
FAKE_ACTIVE=inactive FAKE_RESUME_AT="$resume_at" python3 "$root/onedrive-status.py" --limit 5 >"$test_root/timed-pause.json"
jq -e --argjson resume_at "$resume_at" '
  .running == false
  and .resumeAt == $resume_at
  and (.statusText | startswith("Paused · resumes in "))
' "$test_root/timed-pause.json" >/dev/null

FAKE_ACTIVE=inactive FAKE_ENABLED=disabled python3 "$root/onedrive-status.py" --limit 5 >"$test_root/disabled.json"
jq -e '.enabled == false and .serviceFailed == false and .statusText == "Auto-start disabled"' "$test_root/disabled.json" >/dev/null

FAKE_ACTIVE=activating python3 "$root/onedrive-status.py" --limit 5 >"$test_root/starting.json"
jq -e '.activeState == "activating" and .running == false and .statusText == "Starting…"' "$test_root/starting.json" >/dev/null

FAKE_ACTIVE=failed FAKE_RESULT=exit-code FAKE_EXIT_STATUS=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/failed.json"
jq -e '.serviceFailed == true and .resyncRequired == false and .statusText == "Attention needed"' "$test_root/failed.json" >/dev/null

FAKE_ACTIVE=failed FAKE_RESULT=exit-code FAKE_EXIT_STATUS=126 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/resync.json"
jq -e '
  .serviceFailed == true
  and .resyncRequired == true
  and .serviceExitStatus == 126
  and .statusText == "Resync required"
  and (.lastError | contains("manual --resync"))
' "$test_root/resync.json" >/dev/null

FAKE_REAUTH=1 python3 "$root/onedrive-status.py" --limit 5 >"$test_root/reauth.json"
jq -e '
  .authenticated == true
  and .reauthRequired == true
  and .statusText == "Reauthentication required"
' "$test_root/reauth.json" >/dev/null

FAKE_DOWNLOAD_ONLY=false FAKE_UPLOAD_ONLY=true python3 "$root/onedrive-status.py" --limit 5 >"$test_root/upload-only.json"
jq -e '.syncMode == "Upload only"' "$test_root/upload-only.json" >/dev/null

FAKE_DOWNLOAD_ONLY=false FAKE_UPLOAD_ONLY=false python3 "$root/onedrive-status.py" --limit 5 >"$test_root/two-way.json"
jq -e '.syncMode == "Two-way"' "$test_root/two-way.json" >/dev/null

if python3 "$root/onedrive-status.py" --service '../bad.service' >/dev/null 2>&1; then
  echo "invalid service name unexpectedly passed" >&2
  exit 1
fi

# --- multi-account discovery -------------------------------------------------

# A loaded template ("onedrive@.service") is not an account; a not-found unit is
# a stale enablement symlink; a masked unit is deliberately off and its empty
# ExecStart must not read as "uses the default confdir"; and a unit whose
# ExecStart carries a present-but-unusable confdir must be dropped rather than
# silently aliased onto the default account.
#
# error, stub and a LOADED unit whose `systemctl show` reports no ExecStart at
# all reach the same place by a different road: an empty ExecStart read as "this
# unit passes no --confdir, so the client default applies", which pointed a
# template instance at the DEFAULT account's token, cache and sync directory.
# The rule is an allowlist -- loaded, with something to run -- not a list of the
# bad states we happened to think of.
units=$'onedrive.service loaded active running OneDrive Client for Linux
onedrive@.service loaded active running OneDrive sync template
onedrive@ghost.service not-found inactive dead onedrive@ghost.service
onedrive@masked.service masked inactive dead onedrive@masked.service
onedrive@broken.service error inactive dead onedrive@broken.service
onedrive@stub.service stub inactive dead onedrive@stub.service
onedrive@unloadable.service error inactive dead OneDrive sync (unloadable account)
onedrive@hollow.service loaded inactive dead OneDrive sync (hollow account)
onedrive@bogus.service loaded inactive dead OneDrive sync (bogus account)
onedrive@work.service loaded inactive dead OneDrive sync (work account)
onedrive@personal.service loaded active running OneDrive sync (personal account)'

log_lines_before=$(wc -l <"$FAKE_ONEDRIVE_LOG")
FAKE_UNITS="$units" python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts.json"
jq -e --arg default_confdir "$test_home/.config/onedrive" '
  length == 3
  and ([.[].service] | index("onedrive@broken.service")) == null
  and ([.[].service] | index("onedrive@stub.service")) == null
  and ([.[].service] | index("onedrive@hollow.service")) == null
  and ([.[].service] | index("onedrive@unloadable.service")) == null
  and ([.[] | select(.confdir == $default_confdir)] | length) == 1
  and .[0].service == "onedrive.service"
  and .[0].instance == ""
  and .[0].confdir == $default_confdir
  and .[0].description == "OneDrive Client for Linux"
  and .[1].service == "onedrive@personal.service"
  and .[1].instance == "personal"
  and .[1].confdir == "/srv/onedrive/mailboxes/alpha"
  and .[1].description == "OneDrive sync (personal account)"
  and .[2].service == "onedrive@work.service"
  and .[2].instance == "work"
  and .[2].confdir == "/srv/onedrive/mailboxes/beta"
  and .[2].description == "OneDrive sync (work account)"
' "$test_root/accounts.json" >/dev/null
# Discovery is pure enumeration: it must not shell out to the OneDrive client.
[[ $(wc -l <"$FAKE_ONEDRIVE_LOG") == "$log_lines_before" ]]

FAKE_NO_SYSTEMD=1 python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts-no-systemd.json"
jq -e --arg default_confdir "$test_home/.config/onedrive" '
  length == 1
  and .[0].service == "onedrive.service"
  and .[0].instance == ""
  and .[0].confdir == $default_confdir
  and .[0].description == "OneDrive"
' "$test_root/accounts-no-systemd.json" >/dev/null

python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts-empty.json"
jq -e --arg default_confdir "$test_home/.config/onedrive" '
  length == 1 and .[0].service == "onedrive.service" and .[0].confdir == $default_confdir
' "$test_root/accounts-empty.json" >/dev/null

# An instance that is enabled but not currently loaded never appears in
# "list-units", and "list-unit-files" never expands template instances, so
# discovery also reads the enablement symlinks.
mkdir -p "$test_home/.config/systemd/user/default.target.wants"
ln -sf "$test_home/.config/systemd/user/onedrive@.service" \
  "$test_home/.config/systemd/user/default.target.wants/onedrive@work.service"
python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts-unloaded.json"
jq -e '
  length == 1
  and .[0].service == "onedrive@work.service"
  and .[0].instance == "work"
  and .[0].confdir == "/srv/onedrive/mailboxes/beta"
' "$test_root/accounts-unloaded.json" >/dev/null
# Remove it again: a leftover enablement symlink is a real discovery source and
# would otherwise add a fourth account to every later assertion.
rm "$test_home/.config/systemd/user/default.target.wants/onedrive@work.service"

python3 - "$root/onedrive-status.py" <<'ACCOUNTS_PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("omaonedrive_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

import os
import tempfile

assert module.confdir_from_argv("/usr/bin/onedrive --monitor --confdir=/a/b") == "/a/b"
assert module.confdir_from_argv("/usr/bin/onedrive --monitor --confdir /a/b") == "/a/b"
# None, not "": a unit that passes no --confdir genuinely uses the client default,
# which is a different answer from a --confdir that is present but unusable.
assert module.confdir_from_argv("/usr/bin/onedrive --monitor") is None

# The confdir comes out of argv[], never out of path= — including when path=
# itself contains the literal text "argv[]=" and a decoy --confdir.
assert module.confdir_from_exec_start(
  "{ path=/opt/onedrive--confdir=/decoy ; "
  "argv[]=/usr/bin/onedrive --monitor --confdir=/real/mailbox ; ignore_errors=no ; }"
) == "/real/mailbox"
assert module.confdir_from_exec_start(
  "{ path=/opt/argv[]=/dummy --confdir=/DECOY ; "
  "argv[]=/usr/bin/onedrive --monitor --confdir=/real/mailbox ; ignore_errors=no ; }"
) == "/real/mailbox"
assert module.confdir_from_exec_start(
  "{ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor ; ignore_errors=no ; }"
) is None

# Several ExecStart records: the OneDrive one owns the confdir, not a
# preparatory command that happens to take the same flag.
assert module.confdir_from_exec_start(
  "{ path=/usr/bin/prepare ; argv[]=/usr/bin/prepare --confdir=/staging ; ignore_errors=no ; }\n"
  "{ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor --confdir=/accounts/work ; ignore_errors=no ; }"
) == "/accounts/work"
# ...and the client's record stays authoritative when it carries no --confdir at
# all, or a preparatory command's flag would win by default.
assert module.confdir_from_exec_start(
  "{ path=/usr/bin/prepare ; argv[]=/usr/bin/prepare --confdir=/staging ; ignore_errors=no ; }\n"
  "{ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor ; ignore_errors=no ; }"
) is None

# A brace inside the confdir is not a record boundary. Returning None here would
# put the unit on the default account, which is the aliasing this guards against.
assert module.confdir_from_exec_start(
  "{ path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor --confdir=/srv/{acct}/od ; ignore_errors=no ; }"
) == "/srv/{acct}/od"
# An ExecStart that cannot be parsed at all is "unknown" (drop the unit), never
# "uses the default".
assert module.confdir_from_exec_start("garbage with no record") == ""
assert not module.valid_confdir("")

# systemd joins argv with single spaces, so a tab inside a path is part of the
# path and must survive.
assert module.confdir_from_argv("/usr/bin/onedrive --monitor --confdir=/a\tb") == "/a\tb"

# When a shorter prefix ALSO exists, the longest real directory wins -- returning
# the prefix would point the client at a directory that is not a config dir.
with tempfile.TemporaryDirectory() as temporary:
  os.makedirs(os.path.join(temporary, "OneDrive"))
  os.makedirs(os.path.join(temporary, "OneDrive Work"))
  assert module.confdir_from_argv(
    "/usr/bin/onedrive --monitor --confdir=" + os.path.join(temporary, "OneDrive Work")
  ) == os.path.join(temporary, "OneDrive Work")

# A unit that is not one of ours is not an account, and must not crash the
# helper on the instance-name match.
assert module.account_entry("dbus.service") is None

# systemd joins argv with literal spaces and never quotes, so a confdir
# containing a space arrives split. The longest prefix that is a real directory
# is the answer; a path that resolves nowhere stays at the first token.
with tempfile.TemporaryDirectory() as temporary:
  spaced = os.path.join(temporary, "My Config", "personal")
  os.makedirs(spaced)
  assert module.confdir_from_argv(
    "/usr/bin/onedrive --monitor --confdir=" + spaced
  ) == spaced
  assert module.confdir_from_argv(
    "/usr/bin/onedrive --monitor --confdir " + spaced + " --verbose"
  ) == spaced
  assert module.confdir_from_argv(
    '/usr/bin/onedrive --monitor --confdir="' + spaced + '"'
  ) == spaced
  # Two accounts under one spaced parent must stay distinct, not merge.
  other = os.path.join(temporary, "My Config", "work")
  os.makedirs(other)
  assert module.confdir_from_argv("/usr/bin/onedrive --confdir=" + other) == other
  assert module.account_state_dir("a.service", spaced) != module.account_state_dir("a.service", other)

assert module.valid_confdir("/home/user/.config/onedrive")
assert not module.valid_confdir("relative/onedrive")
assert not module.valid_confdir("/tmp/onedrive\n--resync")
# ".." is not a threat when nothing is shell-interpolated, and a real directory
# reached through one must not be refused.
assert module.valid_confdir("/etc/../etc")
assert module.canonical_confdir("/etc/../etc") == module.Path("/etc")
# One account, one cache: "." and a trailing slash must not key two.
assert module.account_state_dir("a.service", "/x/onedrive/.") == module.account_state_dir("a.service", "/x/onedrive")
assert module.account_state_dir("a.service", "/x/onedrive/") == module.account_state_dir("a.service", "/x/onedrive")
# Two services sharing one confdir are still two accounts.
assert module.account_state_dir("a.service", "/x") != module.account_state_dir("b.service", "/x")
# The default pair keeps the historical directory; nothing else may claim it.
assert module.account_state_dir("onedrive.service", module.default_confdir()) == module.state_dir()
assert module.account_state_dir("onedrive@x.service", module.default_confdir()) != module.state_dir()
# A non-UTF-8 path is surrogate-escaped by the OS and must not raise.
module.account_state_dir("a.service", os.fsdecode(b"/tmp/\xff/onedrive"))

# Discovery and the --service gate must accept exactly the same names, or an
# account can be discoverable and permanently unusable.
for name in ("onedrive.service", "onedrive@work.service", "onedrive@work:west.service",
             "onedrive@team\\x20space.service"):
  assert module.ONEDRIVE_UNIT_PATTERN.fullmatch(name), name
  assert module.SERVICE_NAME_PATTERN.fullmatch(name), name
for name in ("onedrive@.service", "../bad.service", "onedrive@a/b.service"):
  assert not (module.ONEDRIVE_UNIT_PATTERN.fullmatch(name) and module.SERVICE_NAME_PATTERN.fullmatch(name)), name
ACCOUNTS_PY

# --- --confdir selects the account -------------------------------------------

alt_confdir="$test_home/.config/onedrive-accounts/work"
alt_sync_dir="$test_home/Work OneDrive"
mkdir -p "$alt_confdir" "$alt_sync_dir"
printf 'sync_dir = "%s"\n' "$alt_sync_dir" >"$alt_confdir/config"
printf '%s' "$alt_sync_dir" >"$alt_confdir/fake_sync_dir"

python3 "$root/onedrive-status.py" --confdir "$alt_confdir" --service onedrive@work.service --limit 5 \
  >"$test_root/alt-confdir.json"
jq -e --arg sync_dir "$alt_sync_dir" '
  .ok == true
  and .syncDir == $sync_dir
  and .authenticated == false
  and .statusText == "Login required"
' "$test_root/alt-confdir.json" >/dev/null
grep -Fq -- "--confdir $alt_confdir --display-config" "$FAKE_ONEDRIVE_LOG"
# Accounts must not share the status cache, or one account's quota leaks into
# another's panel.
state_root="$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive"
[[ -f "$state_root/status-cache.json" ]]
# The lock must be per-account too, not just the cache: a 30s cloud check on one
# account must not block another account's ordinary poll.
[[ $(find "$state_root/accounts" -mindepth 2 -maxdepth 2 -name 'status-cache.json' | wc -l) == 1 ]]
[[ $(find "$state_root/accounts" -mindepth 2 -maxdepth 2 -name 'status.lock' | wc -l) == 1 ]]
account_dir=$(find "$state_root/accounts" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ $(stat -c '%a' "$account_dir") == 700 ]]
[[ $(stat -c '%a' "$account_dir/status-cache.json") == 600 ]]
[[ $(stat -c '%a' "$account_dir/status.lock") == 600 ]]
[[ $(stat -c '%a' "$state_root/accounts") == 700 ]]

# The default account still reads the default directory.
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/default-confdir.json"
jq -e --arg sync_dir "$sync_dir" '.syncDir == $sync_dir and .authenticated == true' \
  "$test_root/default-confdir.json" >/dev/null

# The predicate itself is covered in-process above; this proves the argparse
# wiring actually rejects. ".." is deliberately NOT in this list — a real
# directory reached through one is valid, and refusing it was a false rejection.
for bad_confdir in 'relative/onedrive' "$test_home/.config/onedrive/config"; do
  if python3 "$root/onedrive-status.py" --confdir "$bad_confdir" >/dev/null 2>&1; then
    echo "invalid confdir unexpectedly passed: $bad_confdir" >&2
    exit 1
  fi
done
# A real directory reached through ".." is accepted.
python3 "$root/onedrive-status.py" --confdir "$test_home/.config/../.config/onedrive" --limit 5 \
  >"$test_root/dotdot.json"
jq -e --arg sync_dir "$sync_dir" '.syncDir == $sync_dir' "$test_root/dotdot.json" >/dev/null
# Every reply names the config directory it actually READ, canonicalised. The
# widget's startup poll runs before discovery has read the unit's ExecStart, so
# it uses the client's default; without this stamp the widget cannot tell that
# reply apart from one describing the account it later learns this unit is, and
# it showed the default account's sync directory, quota and token state under
# the other account's name.
jq -e --arg confdir "$test_home/.config/onedrive" '.confdir == $confdir' \
  "$test_root/dotdot.json" >/dev/null || {
  echo "the reply did not report the canonical confdir it read" >&2
  jq -r '.confdir' "$test_root/dotdot.json" >&2
  exit 1
}
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/stamp.json"

# THE invariant behind the stamp: the directory discovery reports for an account
# and the directory a poll of that account reports must be byte-identical. If
# they ever diverge -- an un-normalised default, a trailing slash -- the widget
# refuses every reply and that account shows nothing, for ever, with no error to
# explain it. Check it for the plain service, whose confdir comes from
# default_confdir() on one path and canonical_confdir() on the other.
FAKE_UNITS='onedrive.service loaded active running OneDrive Client for Linux' \
  python3 "$root/onedrive-status.py" --list-accounts >"$test_root/stamp-accounts.json"
discovered=$(jq -r '.[0].confdir' "$test_root/stamp-accounts.json")
polled=$(python3 "$root/onedrive-status.py" \
  --confdir "$discovered" --limit 5 | jq -r '.confdir')
if [[ "$discovered" != "$polled" ]]; then
  echo "discovery and polling disagree about the same account's confdir" >&2
  echo "  discovery: $discovered" >&2
  echo "  poll:      $polled" >&2
  exit 1
fi
# ...and it holds when XDG_CONFIG_HOME is not already normalised, which is where
# the two paths used to diverge.
# pathlib silently drops "." segments but keeps "..", so ".." is the form that
# actually reaches normpath and diverges.
odd_home="$test_home/.config/../.config"
XDG_CONFIG_HOME="$odd_home" FAKE_UNITS='onedrive.service loaded active running OneDrive Client for Linux' \
  python3 "$root/onedrive-status.py" --list-accounts >"$test_root/odd-accounts.json"
# Polled the way the WIDGET polls it: with the confdir discovery just reported.
# That is the path that normalises, so this is where the two used to diverge.
XDG_CONFIG_HOME="$odd_home" python3 "$root/onedrive-status.py" \
  --confdir "$(jq -r '.[0].confdir' "$test_root/odd-accounts.json")" --limit 5 \
  >"$test_root/odd-stamp.json"
odd_discovered=$(jq -r '.[0].confdir' "$test_root/odd-accounts.json")
odd_polled=$(jq -r '.confdir' "$test_root/odd-stamp.json")
if [[ "$odd_discovered" != "$odd_polled" ]]; then
  echo "an unnormalised XDG_CONFIG_HOME made discovery and polling disagree" >&2
  echo "  discovery: $odd_discovered" >&2
  echo "  poll:      $odd_polled" >&2
  exit 1
fi
if [[ "$odd_discovered" == *"/../"* ]]; then
  echo "the reported confdir was not normalised: $odd_discovered" >&2
  exit 1
fi

# A cache file that is valid JSON but has a string where a number belongs used to
# raise ValueError before the code that would have repaired or replaced it. One
# bad byte -- an editor, a truncated write, a botched migration -- and that
# account's helper failed on EVERY poll from then on, for ever, with no way out
# but finding and deleting the file. The reply below must still be produced.
default_cache="$XDG_STATE_HOME/omarchy/io.github.salemsayed.omaonedrive/status-cache.json"
cat >"$default_cache" <<'JSON'
{"scanLimit":"not-a-number","scanAt":"also-bad","usedBytes":null,"quotaBytes":[],
 "quotaCheckedTs":1e999,"remoteStatus":"Not checked","files":[]}
JSON
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/badcache.json" || {
  echo "a malformed cache value killed the helper" >&2
  exit 1
}
jq -e '.ok == true and .usedBytes == 0 and .quotaBytes == 0 and .quotaCheckedTs == 0' \
  "$test_root/badcache.json" >/dev/null || {
  echo "a malformed cache was not treated as absent" >&2
  exit 1
}
# JSON's 1e999 parses to float infinity, which int() refuses with OverflowError
# rather than ValueError -- a different exception through the same fatal door.
jq -e '.quotaCheckedTs == 0' "$test_root/badcache.json" >/dev/null || {
  echo "an infinite cache value was not treated as absent" >&2
  exit 1
}
# A truncated write -- the ordinary way this file goes wrong, on a full disk or
# a hard poweroff -- must also be survivable.
printf '{"usedBytes": 12' >"$default_cache"
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/truncated.json" || {
  echo "a truncated cache killed the helper" >&2
  exit 1
}
jq -e '.ok == true and .usedBytes == 0' "$test_root/truncated.json" >/dev/null || {
  echo "a truncated cache was not discarded" >&2
  exit 1
}
# ...and a cache that is valid JSON but not an object at all.
printf '["not", "an", "object"]' >"$default_cache"
python3 "$root/onedrive-status.py" --limit 5 >/dev/null || {
  echo "a non-object cache killed the helper" >&2
  exit 1
}

cat >"$default_cache" <<'JSON'
{"scanLimit":"not-a-number","scanAt":"also-bad","files":[]}
JSON
python3 "$root/onedrive-status.py" --limit 5 >/dev/null
# ...and the next write repairs it, rather than leaving the bad value to be
# re-read for ever.
jq -e '(.scanLimit | type) == "number" and (.scanAt | type) == "number"' \
  "$default_cache" >/dev/null || {
  echo "the cache was not repaired on save" >&2
  cat "$default_cache" >&2
  exit 1
}
jq -e --arg confdir "$test_home/.config/onedrive" '.confdir == $confdir' \
  "$test_root/stamp.json" >/dev/null || {
  echo "a default-confdir reply did not report which directory it read" >&2
  exit 1
}

# Today's no-flag invocation keeps exactly the fields the QML layer reads.
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/shape.json"
jq -e '
  ([keys_unsorted[]] | sort) == ([
    "ok","installed","serviceAvailable","running","enabled","activeState","subState",
    "serviceResult","serviceExitStatus","serviceFailed","resyncRequired","authenticated",
    "reauthRequired","syncing","syncStage","statusText","resumeAt","confdir","syncDir","syncMode",
    "clientVersion","lastSyncTs","usedBytes","quotaBytes","quotaKnown","quotaCheckedTs",
    "quotaError","remoteStatus","syncStatusCheckedTs","syncStatusError","remoteCheckedTs",
    "remoteError","files","activity","lastError"
  ] | sort)
' "$test_root/shape.json" >/dev/null

# --- discovery regressions ---------------------------------------------------

# path= containing the literal "argv[]=" and a decoy confdir; two ExecStart lines
# where a preparatory command takes the same flag; and a confdir with a space.
mkdir -p "$test_home/My Config/spaced"
regression_units=$'onedrive@decoy.service loaded active running OneDrive sync (decoy account)
onedrive@prepared.service loaded active running OneDrive sync (prepared account)
onedrive@spaced.service loaded active running OneDrive sync (spaced account)'
FAKE_UNITS="$regression_units" FAKE_SPACED_CONFDIR="$test_home/My Config/spaced" \
  python3 "$root/onedrive-status.py" --list-accounts >"$test_root/accounts-regressions.json"
jq -e --arg spaced "$test_home/My Config/spaced" '
  length == 3
  and any(.[]; .instance == "decoy" and .confdir == "/srv/onedrive/mailboxes/real")
  and any(.[]; .instance == "prepared" and .confdir == "/srv/onedrive/mailboxes/prepared")
  and any(.[]; .instance == "spaced" and .confdir == $spaced)
' "$test_root/accounts-regressions.json" >/dev/null

# An account discovered by --list-accounts must be usable: every service name it
# emits has to survive the --service gate.
python3 - "$root/onedrive-status.py" "$test_root/accounts.json" <<'ROUNDTRIP_PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("omaonedrive_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for account in json.load(open(sys.argv[2])):
  assert module.SERVICE_NAME_PATTERN.fullmatch(account["service"]), account["service"]
ROUNDTRIP_PY

# --- the confdir reaches the client as exactly one argument ------------------

export FAKE_ONEDRIVE_ARGV_LOG="$test_root/argv.log"
hostile="$test_home/pwn; touch $test_root/OWNED --resync --monitor"
mkdir -p "$hostile"
python3 "$root/onedrive-status.py" --confdir "$hostile" --limit 5 >/dev/null
unset FAKE_ONEDRIVE_ARGV_LOG
# Three arguments, not five: the hostile string must not have been split, and no
# extra flag may have been introduced.
[[ $(grep -c '^ARGC=3$' "$test_root/argv.log") -ge 1 ]]
grep -Fqx -- "[$hostile]" "$test_root/argv.log"
[[ ! -e "$test_root/OWNED" ]]
if grep -Fqx -- '[--resync]' "$test_root/argv.log"; then
  echo "confdir was split into additional arguments" >&2
  exit 1
fi

# --- the helper never creates a config directory -----------------------------

absent_confdir="$test_home/.config/onedrive-accounts/never-created"
python3 "$root/onedrive-status.py" --confdir "$absent_confdir" --limit 5 >"$test_root/absent.json"
if [[ -e $absent_confdir ]]; then
  echo "helper created a config directory it was only asked to read" >&2
  exit 1
fi
# An account whose config could not be read must not inherit the DEFAULT
# account's sync directory, or its files show under this account's identity.
jq -e '.syncDir == "" and (.files | length) == 0' "$test_root/absent.json" >/dev/null

# --- --service without --confdir resolves the account, not the default -------

# Reporting the default account's token, files and sync directory under another
# account's name would be a lie; the confdir is read from that unit instead.
FAKE_UNITS="$units" python3 "$root/onedrive-status.py" --service onedrive@personal.service --limit 5 \
  >"$test_root/service-only.json"
jq -e '.authenticated == false and .syncDir == ""' "$test_root/service-only.json" >/dev/null

# An unresolvable account must not be answered with the DEFAULT account's token,
# files and sync directory under its name.
FAKE_UNITS="$units" python3 "$root/onedrive-status.py" --service onedrive@nosuch.service --limit 5 \
  >"$test_root/unresolvable.json"
jq -e '.authenticated == false and .syncDir == "" and (.files | length) == 0' \
  "$test_root/unresolvable.json" >/dev/null
# ...while the default account, in the same run, still reports its own.
python3 "$root/onedrive-status.py" --limit 5 >"$test_root/default-contrast.json"
jq -e --arg sync_dir "$sync_dir" '.syncDir == $sync_dir and .authenticated == true' \
  "$test_root/default-contrast.json" >/dev/null

# A config file that is not valid UTF-8 must not turn a status call into a
# traceback -- --confdir makes arbitrary directories reachable.
binary_confdir="$test_home/.config/onedrive-accounts/binary"
mkdir -p "$binary_confdir"
printf 'sync_dir = "\xff\xfe"\n' >"$binary_confdir/config"
python3 "$root/onedrive-status.py" --confdir "$binary_confdir" --limit 5 >"$test_root/binary.json"
jq -e '.ok == true' "$test_root/binary.json" >/dev/null

# --- the plugin state root stays 0700 even if only another account ever runs --

isolated_state="$test_root/isolated-state"
XDG_STATE_HOME="$isolated_state" FAKE_UNITS="$units" python3 "$root/onedrive-status.py" \
  --service onedrive@work.service --confdir "$alt_confdir" --limit 5 >/dev/null
[[ $(stat -c '%a' "$isolated_state/omarchy/io.github.salemsayed.omaonedrive") == 700 ]]
[[ $(stat -c '%a' "$isolated_state/omarchy/io.github.salemsayed.omaonedrive/accounts") == 700 ]]

# --- --resume-unit reads that account's own timer ----------------------------

resume_at=$(($(date +%s) + 3600))
# An authenticated second account, so the paused status text is actually
# reachable -- an unauthenticated one short-circuits to "Login required".
paused_confdir="$test_home/.config/onedrive-accounts/paused"
paused_sync_dir="$test_home/Paused OneDrive"
mkdir -p "$paused_confdir" "$paused_sync_dir"
printf 'sync_dir = "%s"\n' "$paused_sync_dir" >"$paused_confdir/config"
touch "$paused_confdir/refresh_token"

# The tandera account's timer is pending...
FAKE_ACTIVE=inactive FAKE_RESUME_AT="$resume_at" FAKE_RESUME_TIMER="omaonedrive-resume@tandera.timer" \
  python3 "$root/onedrive-status.py" --service onedrive@tandera.service --confdir "$paused_confdir" \
  --resume-unit omaonedrive-resume@tandera --limit 5 >"$test_root/resume-tandera.json"
jq -e --argjson resume_at "$resume_at" '
  .authenticated == true
  and .resumeAt == $resume_at
  and (.statusText | startswith("Paused · resumes in"))
' "$test_root/resume-tandera.json" >/dev/null

# ...and on the same machine state a different account must NOT inherit it.
FAKE_ACTIVE=inactive FAKE_RESUME_AT="$resume_at" FAKE_RESUME_TIMER="omaonedrive-resume@tandera.timer" \
  python3 "$root/onedrive-status.py" --service onedrive@personal.service --confdir "$paused_confdir" \
  --resume-unit omaonedrive-resume@personal --limit 5 >"$test_root/resume-personal.json"
jq -e '
  .authenticated == true
  and .resumeAt == 0
  and (.statusText | startswith("Paused · resumes in") | not)
' "$test_root/resume-personal.json" >/dev/null

# With no flag, a NON-default account reports no resume time rather than
# borrowing the legacy timer -- and this account is authenticated, so the status
# text clause bites instead of short-circuiting on "Login required".
FAKE_ACTIVE=inactive FAKE_RESUME_AT="$resume_at" python3 "$root/onedrive-status.py" \
  --service onedrive@work.service --confdir "$paused_confdir" --limit 5 \
  >"$test_root/other-resume.json"
jq -e '
  .authenticated == true
  and .resumeAt == 0
  and (.statusText | startswith("Paused · resumes in") | not)
' "$test_root/other-resume.json" >/dev/null

# The plain account keeps the legacy unit name with no flag at all, so an
# in-flight timer survives an upgrade...
FAKE_ACTIVE=inactive FAKE_RESUME_AT="$resume_at" python3 "$root/onedrive-status.py" --limit 5 \
  >"$test_root/resume-legacy.json"
jq -e --argjson resume_at "$resume_at" '.resumeAt == $resume_at' "$test_root/resume-legacy.json" >/dev/null

# ...and that legacy default follows the SERVICE, not the config directory: the
# timer starts onedrive.service, so its pending time is that service's whichever
# directory was named.
FAKE_ACTIVE=inactive FAKE_RESUME_AT="$resume_at" python3 "$root/onedrive-status.py" \
  --confdir "$paused_confdir" --limit 5 >"$test_root/resume-legacy-otherdir.json"
jq -e --argjson resume_at "$resume_at" '.resumeAt == $resume_at' \
  "$test_root/resume-legacy-otherdir.json" >/dev/null

# The value becomes a systemd unit name passed to systemctl as a positional
# argument, so it is validated at least as strictly as a service name.
for bad_unit in 'bad/unit' 'unit with space' '../escape' \
                "$(python3 -c 'print("u" * 260)')"; do
  if python3 "$root/onedrive-status.py" --resume-unit "$bad_unit" >/dev/null 2>&1; then
    echo "invalid resume unit unexpectedly passed: $bad_unit" >&2
    exit 1
  fi
done

# Option-shaped names MUST be spelled with "=" here. In the two-token form
# argparse rejects them itself ("expected one argument") before either validator
# runs, so the assertion would pass even if the first-character restriction were
# removed -- which is exactly the regression it exists to catch.
for option_shaped in '--resume-unit=-Mguest' '--resume-unit=-Hsomewhere.example.com' \
                     '--service=-Mguest.service' '--service=-Hsomewhere.example.com.service'; do
  if python3 "$root/onedrive-status.py" "$option_shaped" >/dev/null 2>&1; then
    echo "option-shaped unit name unexpectedly passed: $option_shaped" >&2
    exit 1
  fi
done
# Prove the guard is the validator and not argparse: the same spelling with a
# leading character that is legal does reach the helper and succeeds.
python3 "$root/onedrive-status.py" --resume-unit=omaonedrive-resume --limit 5 >/dev/null

# A bare name whose instance legitimately ends in ".timer" must NOT be refused --
# systemd-escape produces such names -- and a caller-supplied ".timer" suffix is
# normalised rather than doubled.
python3 - "$root/onedrive-status.py" <<'SUFFIX_PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("omaonedrive_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.valid_resume_unit("omaonedrive-resume@team.service")
assert module.valid_resume_unit("omaonedrive-resume@foo.timer")
assert module.valid_resume_unit("omaonedrive-resume.timer")
assert module.resume_unit_name("omaonedrive-resume.timer") == "omaonedrive-resume"
assert module.resume_unit_name("omaonedrive-resume") == "omaonedrive-resume"
assert not module.valid_resume_unit("-Mguest")
assert not module.valid_resume_unit("bad/unit")
assert not module.valid_resume_unit("u" * 260)
# The service gate carries the same length rule, not just the same characters.
assert not module.SERVICE_NAME_PATTERN.fullmatch("-Mguest.service")
assert not module.valid_unit_name("o" * 300, ".service")
SUFFIX_PY

# A confdir whose own directory name contains " - " must not resolve to a
# shorter path that merely happens to exist -- that would be another account.
dashed_parent="$test_home/accounts"
mkdir -p "$dashed_parent/My" "$dashed_parent/My - Work"
python3 - "$root/onedrive-status.py" "$dashed_parent" <<'DASHED_PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("omaonedrive_status", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

parent = sys.argv[2]
assert module.confdir_from_argv(
  "/usr/bin/onedrive --monitor --confdir=" + parent + "/My - Work"
) == parent + "/My - Work"
# A real trailing flag still never forms an existing path.
assert module.confdir_from_argv(
  "/usr/bin/onedrive --confdir=" + parent + "/My --monitor"
) == parent + "/My"
DASHED_PY

# --list-accounts must not be a validation bypass: the same values it would
# accept there are rejected in status mode.
if python3 "$root/onedrive-status.py" --list-accounts --confdir relative/path >/dev/null 2>&1; then
  echo "--list-accounts accepted an invalid confdir" >&2
  exit 1
fi
if python3 "$root/onedrive-status.py" --list-accounts '--service=-Mguest.service' >/dev/null 2>&1; then
  echo "--list-accounts accepted an option-shaped service name" >&2
  exit 1
fi

# The command vectors themselves are asserted as exact arrays, with injected
# account identity, in tests/Commands.test.js. Greping the QML for hard-coded
# unit names is what those tests replace: a per-account vector has no fixed
# string to grep for, and re-pinning one account's spelling here would only
# assert that the multi-account work had not happened.
grep -Fq 'retryStaleQuotaOnOpen' "$root/Panel.qml"
grep -Fq '(oneDrive.syncing ? "Syncing" : (oneDrive.active ? "Monitoring" : "Paused"))' "$root/Panel.qml"

# Resync may only ever run interactively through omarchy-launch-terminal (the
# CLI prompts for confirmation there); every direct or scripted mutation stays
# forbidden. The QML must now contain NO mutating flag at all, because every
# command vector is built in Commands.js. Commands.js itself is deliberately not
# line-scanned -- it builds arrays across several lines, which a line-based grep
# cannot reason about -- and is instead covered behaviourally by the
# "--resync appears only in the interactive terminal vector" test in
# tests/Commands.test.js, which exercises every builder and inspects its output.
for boundary_file in Service.qml Account.qml Panel.qml BarWidget.qml; do
  if grep -v 'omarchy-launch-terminal' "$root/$boundary_file" \
    | grep -Eq 'bash.*-c|--resync|--logout|--sync([^a-z-]|$)'; then
    echo "service boundary includes an unsafe OneDrive mutation: $boundary_file" >&2
    exit 1
  fi
done

echo "Status tests passed (local state, timed pause, remote opt-in, cache, permissions, login, multi-account discovery, --confdir and control boundaries)"
