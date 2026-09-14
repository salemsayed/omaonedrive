import QtQuick
import Quickshell

// A Process that never actually launches.
//
// Two behaviours here are copied from real Quickshell (0.3.1) rather than
// invented, because the widget depended on the difference:
//
//  * an executable that cannot be started takes `running` true -> false and
//    NEVER emits `exited`. failToStart() reproduces that.
//  * an empty command does not start anything, so `running` stays false. The
//    old stub latched it true, which would have hidden the freeze that an empty
//    status vector caused.
QtObject {
  id: proc
  property var command: []
  property bool running: false
  property var stdout: null
  property var stderr: null
  signal exited(int exitCode, int exitStatus)

  onRunningChanged: {
    if (running) {
      if ((command || []).length === 0) {
        // Real Quickshell does not start an empty command.
        running = false
        return
      }
      Quickshell.spawnCount += 1
      lastCommand = (command || []).slice()
    }
  }
  property var lastCommand: []

  Component.onCompleted: Quickshell.register(proc)
  Component.onDestruction: Quickshell.unregister(proc)

  // Harness: the executable could not be started. `exited` never fires, which
  // is what froze every account when the only cleanup lived in onExited.
  function failToStart() {
    if (!running) return false
    running = false
    return true
  }

  // Harness: complete this process with the given exit code and stdout.
  function finish(exitCode, out) {
    if (!running) return false
    if (stdout && out !== undefined) stdout.feed(out)
    if (stderr) stderr.feed("")
    running = false
    exited(exitCode === undefined ? 0 : exitCode, 0)
    return true
  }
}
