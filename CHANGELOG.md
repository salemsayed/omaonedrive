# Changelog

## 1.6.1 - 2026-09-15

- Return `busy` when an IPC pause, timed pause, resume, or toggle cannot start
  during an account refresh or another control. Previously these requests
  returned `ok` even when they did nothing, including immediately after
  `selectAccount`. Scripts can now retry and distinguish acceptance from rejection.
- Report unavailable services, invalid pause durations, and account requirements
  through the same IPC control replies.

## 1.6.0 - 2026-09-15

- Fix panel dismissal on Omarchy 4.0.3 by using the bar API setter and hiding
  before any bar API call, so an API error cannot trap keyboard focus.
- Preserve clickable notifications across notification daemons and reveal files
  through the desktop file manager when using multiple accounts.
- Discover every configured OneDrive account -- the plain service and any
  `onedrive@<instance>` template units -- and show them all: one badge
  aggregated worst-first across the fleet, per-account tabs in the panel, and
  every action (pause, timed pause, resume, reauthentication, resync repair,
  folder, storage) running against the selected account's own service, config
  directory, and resume timer. A machine with one account keeps the
  existing controls and layout.
- Poll accounts round-robin on one shared budget with a startup ramp, run at
  most one cloud check at a time across the fleet, and coalesce each polling
  burst into a single desktop notification that names its account and opens
  the one it is about.
- Add `accounts` and `selectAccount` IPC functions so scripts can target a
  specific account; notification clicks use the new `openAccount` and
  `repairAccount` functions with the account carried in the persisted exec
  hint.
- Survive a helper, `systemctl`, or `systemd-run` that fails to start, hangs,
  or exits without reporting: every spawned process settles exactly once, with
  watchdogs, so one wedged command can no longer freeze polling or disable
  Pause for the session.
- Stamp every helper reply with the config directory it actually read and
  refuse mismatches, so the startup poll can never attach one account's data
  to another account's name.

## 1.5.8 - 2026-09-09

- Reveal files through the desktop FileManager1 ShowItems interface instead of launching a hard-coded Nautilus process.

## 1.5.7 - 2026-09-06

- Make actionable notifications clickable under notification daemons other
  than Omarchy's own. The click command travelled only in Omarchy's
  `omarchy-exec-argv` hint, which no other daemon reads, so under a
  replacement service such as omapager clicking "OneDrive failed" did nothing
  at all. A clickable toast now also registers a real libnotify `default`
  action, served by the new `omaonedrive-click` helper, which stays on the bus
  for as long as the toast is on screen because an action exists only while
  its sender does. Omarchy's own service still reads the hint, which it checks
  first, so a toast never runs its command twice.

## 1.5.6 - 2026-08-31

- Make actionable notifications compatible with Omarchy 4.0.1 by placing
  `--exec` after the title and body and preserving the click command as
  separate argv elements.
- Render filenames, folders, and helper output as literal plain text so
  markup-shaped data cannot be interpreted by the shell, including the shared
  Omarchy 4.0.1 bar tooltip and panel hero.
- Make the partial-output timeout regression reliable on the single-vCPU
  Omarchy compatibility VM instead of depending on a 50 ms cold Python start.

## 1.5.5 - 2026-08-31

- Make repair and open-panel notification clicks survive shell and plugin
  reloads by using Omarchy's persisted, fixed-command `--exec` hint.
- Validate the plugin against current Omarchy Quattro and run its isolated test
  suite in CI.

## 1.5.4 - 2026-08-26

- Keep the panel's IPC target available while moving its bar slot.
