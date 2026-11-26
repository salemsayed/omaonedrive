import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ServiceLink.js" as ServiceLink

BarWidget {
  id: root
  moduleName: "io.github.salemsayed.omaonedrive"

  // The one Service the shell creates for every monitor's widget. The built-in
  // bar's facade returns it from serviceFor(); under a replacement bar that is
  // null and ServiceLink.js answers, telling this widget when a Service loads,
  // reloads or goes away. Null until one exists: the icon shows the checking
  // state and no panel is loaded.
  property var linkedService: ServiceLink.current()
  readonly property var service: (bar && bar.shell ? bar.shell.serviceFor(moduleName) : null)
    || linkedService
  function followServiceLink() { root.linkedService = ServiceLink.current() }

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
    if ("service" in target) target.service = root.service
  }

  // A service gets no bar settings, so each widget pushes its entry's. Every
  // monitor draws the same entry, so the last push wins.
  function pushSettings() {
    if (root.service) root.service.settings = root.settings
  }

  // The panel is created with the service already set, so none of its bindings
  // reads a null one, and is unloaded when the service goes away.
  function loadPanel() {
    if (!root.service) panelLoader.source = ""
    else if (panelLoader.item) root.injectPanel()
    else panelLoader.setSource(Qt.resolvedUrl("Panel.qml"), { service: root.service })
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    pushSettings()
    injectPanel()
  }
  onServiceChanged: {
    pushSettings()
    loadPanel()
  }
  Component.onCompleted: {
    ServiceLink.subscribe(followServiceLink)
    pushSettings()
    loadPanel()
  }
  Component.onDestruction: ServiceLink.unsubscribe(followServiceLink)

  Loader {
    id: panelLoader
    active: true
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
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
