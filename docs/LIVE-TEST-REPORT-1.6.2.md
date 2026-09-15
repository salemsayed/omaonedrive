# OmaOneDrive 1.6.2: real two-account verification

Verified September 15, 2026, on the live Omarchy 4.0.3 desktop with OneDrive Linux client 2.5.11.

The account controls, transfers, timers, and desktop checks ran on 1.6.1 commit `8147a00fb0bf8f1cebd980a9e89b6dd117532293`. The resulting combined cloud-check fix was verified live for 1.6.2.

This supplements the initial single-account report included in the release. Access to the original disposable account was recovered, allowing the previously pending real two-account checks to run. The final combined cloud check revealed a client database-lock conflict, fixed in 1.6.2 by running the quota and sync-status commands sequentially for the same account. A regression fixture reproduces the exclusive client lock: it fails before the fix and passes afterward.

## Live cloud and control checks

- Both independently authenticated Microsoft accounts were discovered by the installed plugin. Fresh cloud queries confirmed different drive identities and account-specific quotas.
- Each account uploaded the same test filename containing different data. Independent Microsoft Graph downloads matched each account's expected SHA-256 hash.
- Remote file creation and edits reconciled into the correct local sync folder. The final repeat verified unchanged service PIDs throughout creation, editing, and cleanup.
- Pausing either account left the other running and uploading. The paused account's queued local changes remained absent from the cloud until resume, then uploaded correctly.
- Both accounts had separate active five-minute resume timers.
- Both timers survived a shell restart and both accounts were rediscovered.
- Resuming the primary account cancelled only its timer. The second account stayed paused until its own five-minute timer automatically resumed it.
- Cloud contents were checked again after resume. Only uniquely named verification folders were created, edited, and deleted; their deletion reconciled locally on both accounts.

The corrected combined quota and sync-status check passed on both real accounts, returning known storage, "Up to date", and empty error fields. Both services finished active/running with no active resume timers and no verification folders remaining.

The full suite passed: 129 Node tests, 331 QML checks, 11 panel lifecycle checks, Python journal tests, and shell status/discovery tests. The opt-in live contract passed four widget-built commands: two routine, one quota, and one sync-status.

## Desktop checks

- Full and Compact layouts were visually inspected using the actual desktop.
- Mouse and keyboard selection changed the selected account, storage data, service status, and activity.
- Folder actions opened the corresponding real sync directories in the configured Strata file manager.
- Test notifications generated through the installed Commands.js and click helper selected the intended account in both directions.
- Escape and outside clicks dismissed the panel.
- The original Full layout was restored.

## Test corrections and limits

The first test harness incorrectly used SIGUSR1 as a refresh request. This client terminated on that signal and systemd restarted it. The harness was corrected, and all affected remote-creation, remote-edit, and cleanup checks were repeated successfully with unchanged running process IDs. The earlier restart counters therefore reflect the test harness, not a plugin failure.

The notification test initially inherited BB AppImage's incompatible libnotify through LD_LIBRARY_PATH. Repeating with system libraries passed. The actual Quickshell processes did not have that override.

Authorization-failure, resync-required, hung-process, and other forced-error cases remain covered by the existing QEMU/fixture tests; those failures were not induced against the primary real account. The full automated suite was rerun for the combined-check fix.

Marketplace verification is tracked separately on [issue #6957](https://github.com/omacom/omarchy-plugin-marketplace/issues/6957). Final approval belongs to the marketplace maintainers.
