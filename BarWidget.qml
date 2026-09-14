import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.salemsayed.omaonedrive"
  // Moving a bar widget briefly overlaps its old and replacement instances.
  // Wait for the retired slot to release this process-wide IPC target.
  property bool ipcRegistrationReady: false

  readonly property var service: panelLoader.item ? panelLoader.item.service : null

  // Worst of N. With one account this resolves to exactly the state the old
  // flat ternary produced; the mapping and the precedence are table-tested in
  // tests/Aggregate.test.js rather than spelled out here.
  readonly property var aggregate: service
    ? service.aggregate
    : ({ kind: "checking", count: 0, anyActive: false, initialized: false })
  readonly property int accountCount: service ? service.accountCount : 0

  // Lit/dim/spinning is decided in Model.js, not here: nothing in this file can
  // be instantiated by a test, so an expression written inline is one no
  // assertion can reach. tests/Aggregate.test.js pins the rules.
  readonly property var barState: Model.barState(aggregate)
  readonly property bool active: barState.active
  readonly property bool syncing: barState.syncing
  readonly property bool installed: barState.installed
  readonly property color iconColor: active
    ? (bar ? bar.barForeground : Color.foreground)
    : Qt.darker(bar ? bar.barForeground : Color.foreground, 1.55)
  // The worst account's kind, pause included: every account has to be working
  // before the bar looks normal. See the note in Model.aggregateAccounts.
  readonly property string badgeKind: Model.badgeKind(aggregate.kind)
  readonly property string badgeGlyph: Model.badgeGlyph(badgeKind)
  readonly property color badgeColor: badgeKind === "login" || badgeKind === "attention"
    ? (bar ? bar.urgent : Color.urgent)
    : (badgeKind === "syncing" ? Color.accent : iconColor)
  readonly property color badgeBackground: bar ? bar.background : Color.background
  readonly property string tooltipText: service
    ? Model.aggregateTooltip(service.accounts, Date.now())
    : "Checking OneDrive…"
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: Style.space(15)

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open(accountTarget) { if (panelLoader.item) panelLoader.item.open(accountTarget) }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: ipcRegistrationTimer.start()

  Timer {
    id: ipcRegistrationTimer
    interval: 100
    onTriggered: root.ipcRegistrationReady = true
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    enabled: root.ipcRegistrationReady
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): string {
      if (root.service) root.service.refresh(false)
      return "ok"
    }
    function check(): string {
      if (root.service) root.service.checkQuota()
      return "ok"
    }
    function fullStatus(): string {
      if (root.service) root.service.checkFullStatus()
      return "ok"
    }
    function pause(): string {
      if (root.service) root.service.pause()
      return "ok"
    }
    function pauseFor(minutes: int): string {
      if (root.service) root.service.pauseFor(minutes)
      return "ok"
    }
    function resume(): string {
      if (root.service) root.service.resume()
      return "ok"
    }
    function toggleSync(): string {
      if (root.service) root.service.toggleRunning()
      return "ok"
    }
    function folder(): string {
      if (root.service) root.service.openFolder()
      return "ok"
    }
    function web(): string {
      if (root.service) root.service.openWeb()
      return "ok"
    }
    function resync(): string {
      if (root.service) root.service.repairResync()
      return "ok"
    }
    function status(): string { return root.service ? root.service.statusText : "Checking…" }
    // Enumerate and select, so automation can reach a non-default account before
    // invoking any of the controls above -- which all act on the selected one.
    // Both bodies live in Model.js: this file cannot be instantiated headless,
    // so anything inline here is untestable.
    function accounts(): string {
      if (!root.service) return "[]"
      return JSON.stringify(Model.accountRows(root.service.accounts, root.service.selectedService))
    }
    function selectAccount(target: string): string {
      if (!root.service) return "no accounts"
      var found = Model.resolveAccountTarget(root.service.accounts, target)
      if (found === "") return "unknown account: " + target
      // false: automation selecting an account merely to target a control must
      // not trigger the panel's stale-quota retry, which contacts Microsoft.
      root.service.selectAccount(found, false)
      return "ok"
    }
    // Notification clicks land here: the daemon persists the popup's --exec
    // hint and runs `omarchy-shell <target> openAccount <service>` on click,
    // which works even after this process has been reloaded. Behaviour lives
    // in Service.qml so the harness can drive it.
    function openAccount(target: string): string {
      // The panel selects the target before any account refresh or quota retry.
      root.open(target)
      return "ok"
    }
    function repairAccount(target: string): string {
      if (root.service) root.service.repairFromNotification(target)
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltipText
    dimmed: !root.installed
    iconComponent: Component {
      Item {
        OneDriveIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.iconColor
        }

        Rectangle {
          width: Style.space(4)
          height: width
          radius: width / 2
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(3)
          color: root.syncing ? Color.accent : root.iconColor
          visible: root.active && root.badgeKind === ""

          SequentialAnimation on opacity {
            running: root.syncing
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 500 }
            NumberAnimation { to: 1.0; duration: 500 }
          }
        }

        StatusBadge {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(3)
          visible: root.badgeKind !== ""
          badgeSize: Style.space(8)
          glyph: root.badgeGlyph
          glyphColor: root.badgeColor
          ringColor: root.badgeColor
          background: root.badgeBackground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          pulsing: root.badgeKind === "syncing"
        }
      }
    }
    // Every gesture points at the account the badge is about before acting.
    // Only left-click did, so middle-click opened the folder of whichever
    // account happened to be selected -- at cold boot, the first discovered one
    // -- while the badge was about another, and right-click spent the single
    // 30-second cloud slot on the wrong account.
    onPressed: function(buttonCode) {
      if (root.service) root.service.selectBadgedAccount()
      if (buttonCode === Qt.RightButton && root.service) root.service.checkQuota()
      else if (buttonCode === Qt.MiddleButton && root.service) root.service.openFolder()
      else root.togglePanel()
    }
  }
}
