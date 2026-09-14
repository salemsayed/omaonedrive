import QtQuick
import Quickshell
import "../../"

// Feeds the REAL `--list-accounts` output into the real Service.qml and prints
// every command the QML would run. tests/contract.sh then executes those against
// the real helper, so the argv the widget builds is checked against the argv the
// helper accepts -- a contract nothing else in the suite covers.
Item {
  property string discoveryJson: "[]"

  Service { id: svc; settings: ({ refreshIntervalSec: 10, recentFileLimit: 5 }) }

  property int step: 0
  Timer {
    interval: 60; repeat: true; running: true
    onTriggered: {
      step += 1
      if (step === 1) {
        var disc = Quickshell.runningWith("--list-accounts")
        if (disc.length) disc[0].finish(0, discoveryJson)
      } else if (step === 2) {
        for (var i = 0; i < svc.accounts.length; i++) svc.accounts[i].refresh(false)
      } else if (step === 3) {
        var live = Quickshell.running()
        for (var j = 0; j < live.length; j++) console.log("CMD " + JSON.stringify(live[j].command))
        for (var k = 0; k < live.length; k++) live[k].finish(0, "{}")
        // Both cloud modes on the first account, which take a different argv.
        if (svc.accounts.length) {
          svc.accounts[0].startCloudCheck("quota")
        }
      } else if (step === 4) {
        var q = Quickshell.running()
        for (var m = 0; m < q.length; m++) console.log("CMD " + JSON.stringify(q[m].command))
        for (var n = 0; n < q.length; n++) q[n].finish(0, "{}")
        if (svc.accounts.length) svc.accounts[0].startCloudCheck("sync-status")
      } else if (step === 5) {
        var s2 = Quickshell.running()
        for (var p = 0; p < s2.length; p++) console.log("CMD " + JSON.stringify(s2[p].command))
        Qt.exit(0)
      }
    }
  }
}
