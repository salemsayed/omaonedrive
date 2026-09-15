# OmaOneDrive 1.6.1 verification

Verified on September 15, 2026, on Omarchy 4.0.3 with the OneDrive Linux client
2.5.11. The running control implementation was commit `17e5344`; the release
adds version metadata, this report, and the changelog without further runtime
changes.

## Live desktop and account checks

- The installed plugin loaded and discovered the existing real account.
- The actual panel rendered its service state, storage, and recent activity.
  Escape and clicking outside dismissed it and restored the underlying window.
- A fresh Microsoft storage query succeeded and updated the panel's timestamp.
- A fresh cloud sync-status check reported "Up to date" in the panel.
- The control test selected the real account and immediately requested a timed
  pause. The IPC returned `busy` during the selection refresh, then `ok` when
  the retry was accepted.
- A five-minute pause stopped `onedrive.service` and created the active,
  waiting `omaonedrive-resume.timer`.
- Resume returned `busy` during a pending refresh, then `ok`. The plugin
  cancelled the timer and restarted the same service. Verification accounted
  for the installed service's configured 15-second startup delay.
- Final state: service active/running, Result=success, NRestarts=0, and no active
  resume timer. The successful run needed no fallback service command.
- An invalid pause duration returned `invalid duration` without changing the
  service.

The live test reproduced the previous false `ok` response before the fix.
No existing synced files were edited or deleted during these checks.

## Automated checks

`PATH=/usr/bin:/bin OMAONEDRIVE_REQUIRE_QT=1 tests/run` passed:

- 129 Node tests, including the IPC delegation contract.
- 331 checks executing the real Account and Service QML with controlled process
  fixtures, including selection refresh, rejected controls, retry acceptance,
  and account isolation.
- 11 panel lifecycle checks and QML structural validation.
- Python journal tests and shell status/discovery tests.

The opt-in cloud contract suite was not run against multiple real accounts.
The earlier [1.6.0 QEMU report](VM-TEST-REPORT-1.6.0.md) records the separate
three-account fixture, notification, layout, and upgrade checks performed for
that release.

## Remaining live coverage

Two-account cloud transfer and isolation tests are pending access to a second
Microsoft account. Account recovery did not reveal the original test account's
full username, and Microsoft blocked replacement account creation. No usable
replacement account was created.

This report does not claim live two-account upload/download verification,
cross-account cloud edits, or automatic timed resume at expiry. Those remain
distinct from the completed fixture tests and single-account control checks.
