# Testing

Disposable-VM results are in [the VM test report](docs/VM-TEST-REPORT.md).

## Automated

CI requires the Qt harness and panel lifecycle checks as well as the Node,
Python, and shell suites. Run `OMAONEDRIVE_REQUIRE_QT=1 tests/run` locally to
require Qt too. `OMAONEDRIVE_QML_RUNNER` can select a Qt 6 `qml` or `qmlscene`.

The live helper contract check is opt-in because it queries quota and sync
status against configured accounts. Use `OMAONEDRIVE_LIVE_CONTRACT=1
tests/contract.sh` only with disposable test accounts or the VM fixtures.

```bash
tests/run
shellcheck tests/run tests/Status.test.sh
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I ~/.cache/omarchy-shell-ref *.qml   # optional
```

`tests/run` covers the presentation helpers and a fake OneDrive CLI, service,
timer, journal, authentication state, local files, quota, sync status, cache
reuse and state permissions — including that a routine refresh never runs a
cloud query and that quota and sync-status failures never clear each other.

It also covers multi-account behaviour against a fake `systemctl`: that
`--list-accounts` finds every account from its own unit's `ExecStart` (ignoring
the bare template, stale `not-found` symlinks and masked units, and never
guessing a confdir from an instance name), that `--confdir` selects an account
and gives it its own cache *and* lock, that the confdir reaches the client as
exactly one argument and cannot introduce a second flag, that the helper never
creates a config directory it was only asked to read, that `--resume-unit` reads
that account's own timer and no other's, that the scheduler interleaves accounts
that have not reported rather than letting one monopolise the ramp, that a cloud
check waiting behind a routine poll still holds the shared slot, that an account
discovered by
`--list-accounts` always survives the `--service` gate, that a present-but-
unusable confdir is dropped rather than aliased onto the default account, and
that the no-flag JSON output keeps exactly its expected field set.

The QML layer's pure logic is covered by node tests: `tests/Commands.test.js`
asserts every command vector as an exact array for both a plain service and a
template instance, `tests/Aggregate.test.js` covers all ten account states and
the worst-of-N rules, `tests/Discovery.test.js` covers reconciling discovery
results without churning delegates, and `tests/Notifications.test.js` covers
grouping a burst of events into one notification.

## Multiple accounts, by hand

With a plain `onedrive.service` only, the panel must be pixel-identical to the
single-account screenshots: no selector row, no extra spacing, hero title
`OneDrive`.

With template instances (`onedrive@a`, `onedrive@b`, …):

- each account appears once in the selector, named from its instance;
- switching accounts changes the hero, storage, activity and every control,
  returns the scroll to the top, and leaves keyboard navigation working;
- pausing one account for 15 minutes leaves the others running, and its timer
  resumes only that account;
- one account failing while another syncs shows the attention badge while the
  cloud icon stays lit;
- removing the selected unit and waiting for rediscovery falls back to the
  first remaining account rather than emptying the panel;
- restarting the shell with an active timed pause still shows the pending
  resume for the right account.

## In the shell

Use an Omarchy Quattro VM with no host block device attached:

```bash
omarchy plugin add file://$HOME/Coding/omarchy-onedrive --enable --yes
omarchy bar move io.github.salemsayed.omaonedrive --section right --index 0
omarchy-shell io.github.salemsayed.omaonedrive status
journalctl --user -u omarchy-shell -n 200 --no-pager
```

Check each state and control:

1. CLI missing → missing-client badge and install message.
2. Token missing → login badge; the action opens a terminal.
3. Service stopped → paused badge and resume control; disabled, failed,
   exit-126 and expired-authorization show attention instead.
4. Service running → monitoring dot or syncing badge, pause control.
5. Timed pauses (15 min, 1 h, 4 h) stop the service, show the remaining
   time and resume on schedule; another preset replaces the timer; **Resume
   syncing now** cancels it; the timer survives a shell restart; a
   scheduling failure restores syncing.
6. Two-way, download-only and upload-only modes in the hero and tooltip.
7. **Refresh storage** queries quota only, with a spinner; **Verify sync** is
   labelled optional and slow. Cutting the network during either keeps its
   last good value and does not mark the service unhealthy.
8. Full layout: storage, activity timeline, folder/cloud chips, clickable
   file rows. Compact: storage and actions only.
9. Arrow keys and Enter reach every control in visual order; long lists
   scroll to the selection.
10. Clean shell restart with no QML errors; a service still starting is
    caught by the startup refresh ramp.
11. Horizontal and vertical bars; a light and a dark theme; every bar badge
    distinct.
12. Notifications fire once per edge (failure, resync, reauthentication,
    recovery, 90% storage) and the `notifications` setting silences them;
    clicking a failure notification opens the panel or starts the repair.
13. Resync repair opens `onedrive --sync --resync` in a terminal, which asks
    for confirmation first.
14. During a sync the hero names the transferring file and phase; uploads
    the client starts on its own show the same; a progress line older than
    ten minutes does not pin the syncing state; interruptions show as
    retrying, not a frozen percentage.
15. Web chip, `W` key and `web` IPC open OneDrive on the web.
16. Benign client fallbacks never reach the feed; multi-line errors fold into
    one row; errors resolved by a later sync show as recovered.
17. A failed storage check older than five minutes is retried once on open;
    Verify sync never is.

Use a disposable Microsoft account for live tests.

## Cleanup

```bash
omarchy plugin disable io.github.salemsayed.omaonedrive
omarchy plugin remove io.github.salemsayed.omaonedrive
rm -r -- "$HOME/.local/state/omarchy/io.github.salemsayed.omaonedrive"   # optional
```
