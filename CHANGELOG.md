# Changelog

## Unreleased

- Fix a panel that could not be closed on Omarchy 4.0. The shell now passes
  third-party plugins the `PluginBarApi` facade rather than the host `Bar`, and
  there `centerHoverRevealSuppressed` is readonly — writable only through
  `setCenterHoverRevealSuppressed()`. The `in` probe still matched the readonly
  property, so `setCenterHoverRevealSuppressed()` assigned it anyway and threw
  `TypeError: Cannot assign to read-only property`. Because `close()` called it
  before `controller.hide()`, the panel stayed mapped and no dismissal route
  could shut it — Escape, an outside click, the bar button and the IPC methods
  all funnel through `close()`. Prefer the setter, as the first-party clock and
  weather panels do, and hide before touching the facade so a future throw
  cannot pin the panel open again.

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
