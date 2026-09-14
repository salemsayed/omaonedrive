# OmaOneDrive 1.6.0 verification

Tested on 2026-09-15. The candidate integrates PR #5 (panel dismissal) and
PR #4 (multiple accounts), preserving the notification and file-reveal fixes
from 1.5.7 and 1.5.8.

## Environment

- Disposable QEMU/KVM guest, Omarchy 4.0.3, Hyprland 0.56.2,
  Quickshell 0.3.0.r20, Qt 6.11.1, 1280 by 800 desktop.
- Clean Omarchy guest upgraded using the signed Omarchy packages. The guest
  used a temporary disk snapshot with no host drives attached.
- Three synthetic accounts: the default `onedrive.service`,
  `onedrive@work.service`, and `onedrive@other.service`. Each had its own
  configuration directory, files, real systemd user service, and resume timer.
- A fake OneDrive executable recorded command arguments and supplied local
  status, quota, sync, reauthentication, and resync fixtures. Authentication
  and repair terminal launches were recorded without executing those flows.
- The full guest suite ran against runtime commit
  `eb6ce7d29f72956fff45d0c0666ca5f0b65c674a`. Subsequent release changes add
  documentation and a screenshot only.

## Automated results

`OMAONEDRIVE_REQUIRE_QT=1 OMAONEDRIVE_LIVE_CONTRACT=1 tests/run` passed in
the guest: 129 Node tests, 311 QML account/coordinator checks, 11 panel lifecycle
checks, the Python journal suite, and the shell status/discovery suite.
The contract check executed five command vectors built by the widget against
the real status helper: three routine reads, one quota query, and one sync
status query, all using the synthetic accounts.

Local required-Qt tests, shellcheck, Python compilation, and whitespace checks
passed. GitHub Actions also passed with Ubuntu 24.04 and Qt 6.4. CI now requires
the Qt harness so those checks cannot silently skip. CI exposed two harness
portability problems, both fixed: defer `Qt.exit` until the qmlscene event loop
starts, and avoid the reserved Qt 6.4 type name `short` as a function parameter.

## Desktop and integration results

| Check | Observed result |
| --- | --- |
| Single account | Existing panel layout appears without account tabs. |
| Account discovery | Three unique accounts appear; each control uses the selected account's own service and configuration directory. |
| Panel dismissal | Escape, outside click, repeated bar click, toggle IPC, and close IPC remove the actual compositor panel layer. |
| Keyboard focus | With Hyprland `follow_mouse=2`, typing after closing the panel reaches the previously focused terminal. |
| Selection | Mouse tabs and arrow-key/Enter navigation select Other from Work. `Shift+L` launches login for Other. |
| Routine polling | Startup discovery and normal polls issue no quota or cloud sync-status queries. Explicit checks for Work query only Work. |
| Timed pause | Pausing Work leaves the other two services running. Work and Other own independent timers; resuming Other preserves Work's pause and timer. Work resumes automatically at the five-minute minimum. |
| Notification action | A real Omarchy reauthentication notification for Other persists an account-specific action. Invoking its default action opens Other while Work was selected. |
| Standard notification action | On a separate D-Bus session, real `notify-send` and `omaonedrive-click` register a standard default action, deliver the account-specific command once, and exit cleanly after the action. |
| Reauthentication and repair | Clicking the reauthentication row records Other's `--confdir` and `--reauth`. Calling `repairAccount other` while Work is selected launches Other's `--sync --resync` command. |
| File reveal | Clicking Work's activity row opens Nautilus at Work's directory with the requested file selected through FileManager1. |
| Layout | Full and Compact panels render without clipping in dark and light themes. The panel opens correctly with top, bottom, left, and right bars. |
| Upgrade | The official `omarchy plugin update` command upgrades an installed 1.5.8 checkout. After shell restart it discovers all three accounts and preserves the default account's active resume timer and stopped service. |
| Installed validation | The official plugin validator accepts the installed candidate. No plugin QML type, reference, or property-assignment errors appear after startup. |

The [multiple-account screenshot](images/panel-multi.png) is captured directly
from the guest desktop. Raw local logs retain early harness failures: the guest
uses Foot rather than Alacritty, startup readiness requires polling, timed
pauses clamp to five minutes, and file-row coordinates depend on panel state.
Those checks were corrected and repeated. One timer assertion also overlapped
an intentionally failed Other service; inspecting the individual units
confirmed that the timer resumed only Work and preserved the other states.

## Coverage limits

This release verification uses synthetic accounts. It does not claim a live
Microsoft OAuth, upload/download, or destructive resync test. The earlier
[VM report](VM-TEST-REPORT.md) documents previous single-account testing;
it is not a substitute for live cloud testing of this release.

Marketplace verification is a separate, exact-commit process. This test report
does not confer marketplace verification. Publication of an update follows the
[official verification workflow](https://github.com/omacom/omarchy-plugin-marketplace/blob/main/VERIFICATION.md).
