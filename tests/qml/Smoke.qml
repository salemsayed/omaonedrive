import QtQuick
import Quickshell
import "../../"

Item {
  Service { id: svc; settings: ({}) }
  property int step: 0
  Timer {
    interval: 50; repeat: true; running: true
    onTriggered: {
      step += 1
      if (step === 1) {
        console.log("accounts:", svc.accountCount, "| spawned:", Quickshell.spawnCount)
        var live = Quickshell.running()
        for (var i = 0; i < live.length; i++) console.log("  running:", JSON.stringify(live[i].command))
      }
      if (step === 2) {
        // Answer the discovery call with three accounts.
        var disc = Quickshell.runningWith("--list-accounts")
        console.log("discovery processes:", disc.length)
        if (disc.length) {
          disc[0].finish(0, JSON.stringify([
            {service:"onedrive@a.service",instance:"a",confdir:"/c/a",description:"A"},
            {service:"onedrive@b.service",instance:"b",confdir:"/c/b",description:"B"},
            {service:"onedrive@c.service",instance:"c",confdir:"/c/c",description:"C"}
          ]))
        }
      }
      if (step === 3) {
        console.log("after discovery, accounts:", svc.accountCount)
        for (var j = 0; j < svc.accounts.length; j++) {
          console.log("  ", svc.accounts[j].service, "confdir=" + svc.accounts[j].confdir,
                      "resumeUnit=" + svc.accounts[j].resumeUnit,
                      "name=" + svc.accounts[j].displayName)
        }
        console.log("aggregate:", JSON.stringify(svc.aggregate.kind), "initialized:", svc.aggregate.initialized)
      }
      if (step >= 4) Qt.exit(0)
    }
  }
}
