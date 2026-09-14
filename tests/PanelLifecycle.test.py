#!/usr/bin/env python3
"""Exercise production panel functions in Qt, including readonly QML properties."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
panel = (root / 'Panel.qml').read_text()
bar = (root / 'BarWidget.qml').read_text()
functions = []
for name in ('open', 'close', 'setCenterHoverRevealSuppressed'):
    match = re.search(r'^  function ' + name + r'\([^\n]*\) \{.*?^  \}', panel, re.M | re.S)
    assert match, f'Panel function {name} missing'
    functions.append(match.group())
match = re.search(r'^    function openAccount\([^\n]*\).*?^    \}', bar, re.M | re.S)
assert match, 'Notification IPC missing'
functions.append(match.group())
source = '''import QtQuick
Item {
  id: root
  property var bar: modern
  property bool hidden: true
  readonly property bool opened: !hidden
  property int failures: 0
  property int checks: 0
  property QtObject controller: QtObject {
    function show() { root.hidden = false }
    function hide() { root.hidden = true }
  }
  QtObject {
    id: oneDrive
    property string selected: "previous"
    property string refreshed: ""
    property int retries: 0
    function selectBadgedAccount() { selected = "badged" }
    function openFromNotification(target) { selected = target }
    function refreshSelected() { refreshed = selected }
    function retryStaleQuotaOnOpen() { retries++ }
  }
  Item { id: keyCatcher }
  QtObject {
    id: modern
    property bool suppressed: false
    readonly property bool centerHoverRevealSuppressed: suppressed
    function setCenterHoverRevealSuppressed(value) { suppressed = value }
  }
  QtObject { id: legacy; property bool centerHoverRevealSuppressed: false }
  QtObject {
    id: broken
    readonly property bool centerHoverRevealSuppressed: false
    function setCenterHoverRevealSuppressed(value) { throw new Error("API failure") }
  }
  FUNCTIONS
  function check(ok, description) {
    checks++
    if (!ok) failures++
    console.log((ok ? "PASS " : "FAIL ") + description)
  }
  Component.onCompleted: {
    root.open()
    check(oneDrive.refreshed === "badged", "bar click selects before refresh")
    check(oneDrive.retries === 1, "bar click permits the stale quota retry")
    root.setCenterHoverRevealSuppressed(true)
    check(modern.suppressed, "readonly API uses its setter")
    root.close()
    check(root.hidden && !modern.suppressed, "modern panel closes and clears suppression")
    oneDrive.retries = 0
    root.openAccount("onedrive@work.service")
    check(oneDrive.selected === "onedrive@work.service", "notification selects its account")
    check(oneDrive.refreshed === "onedrive@work.service", "notification refreshes its account")
    check(oneDrive.retries === 0, "notification never queues the bar click's cloud retry")
    root.close()
    root.bar = legacy
    root.hidden = false
    root.setCenterHoverRevealSuppressed(true)
    check(legacy.centerHoverRevealSuppressed, "legacy writable property still works")
    root.close()
    check(root.hidden && !legacy.centerHoverRevealSuppressed, "legacy panel closes")
    root.bar = null
    root.hidden = false
    root.close()
    check(root.hidden, "panel closes without a bar")
    root.bar = broken
    root.hidden = false
    var threw = false
    try { root.close() } catch (error) { threw = true }
    check(threw && root.hidden, "a throwing API cannot prevent hiding")
    console.log("Panel lifecycle: " + checks + " checks, " + failures + " failures")
    Qt.exit(failures ? 1 : 0)
  }
}
'''.replace('FUNCTIONS', '\n'.join(functions))
env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_FORCE_STDERR_LOGGING='1')
env.pop('QT_QPA_PLATFORMTHEME', None)
with tempfile.TemporaryDirectory(prefix='omaonedrive-panel-') as directory:
    path = Path(directory) / 'PanelProbe.qml'
    path.write_text(source)
    result = subprocess.run([sys.argv[1], str(path)], env=env, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    print(output, end='')
    if result.returncode or 'Panel lifecycle: 11 checks, 0 failures' not in output:
        raise SystemExit(1)
