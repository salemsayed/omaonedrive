import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.salemsayed.omaonedrive"
  ipcTarget: "io.github.salemsayed.omaonedrive.panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool cursorActive: false
  property var cursorItem: null
  readonly property var barIdentity: hostWidget || root
  property alias service: oneDrive

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Util.alpha(foreground, 0.62)
  readonly property color faint: Util.alpha(foreground, 0.42)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: oneDrive.authenticated && oneDrive.active ? foreground : dim
  readonly property string toggleHint: oneDrive.active ? "Pause syncing" : "Resume syncing"
  readonly property string panelStyle: String(root.settings && root.settings.panelStyle
    ? root.settings.panelStyle : "full").toLowerCase() === "compact" ? "compact" : "full"
  readonly property var activityRows: Model.activityRows(oneDrive)
  readonly property bool storageSevere: Model.usageSevere(
    oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
  readonly property bool headerHasCursor: cursorActive && cursorItem === headerItem

  function navigationItems() {
    var items = []
    collectNavigationItems(content, items)
    return items
  }

  // Walks the content tree in declaration (= visual) order, so new rows join
  // keyboard navigation by defining keyboardEnabled + keyboardActivate.
  function collectNavigationItems(item, items) {
    if (!item || item.visible !== true) return
    if (item.keyboardEnabled !== undefined && typeof item.keyboardActivate === "function") {
      if (item.keyboardEnabled === true) items.push(item)
      return
    }
    var children = item.children
    if (!children) return
    for (var index = 0; index < children.length; index++)
      collectNavigationItems(children[index], items)
  }

  function setCursor(item) {
    if (!item || item.keyboardEnabled !== true) return
    cursorActive = true
    cursorItem = item
    scrollItemIntoView(item)
  }

  function ensureCursor() {
    if (!cursorActive) return
    var items = navigationItems()
    if (items.length === 0) {
      cursorItem = null
      return
    }
    if (items.indexOf(cursorItem) < 0) cursorItem = items[0]
    scrollItemIntoView(cursorItem)
  }

  function moveCursor(dx, dy) {
    var items = navigationItems()
    if (items.length === 0) return
    var step = dy !== 0 ? dy : dx
    if (step === 0) return
    if (!cursorActive || items.indexOf(cursorItem) < 0) {
      setCursor(step < 0 ? items[items.length - 1] : items[0])
      return
    }
    var next = Math.max(0, Math.min(items.length - 1, items.indexOf(cursorItem) + (step < 0 ? -1 : 1)))
    setCursor(items[next])
  }

  function activateCursor() {
    if (!cursorActive || !cursorItem || cursorItem.keyboardEnabled !== true) return
    cursorItem.keyboardActivate()
  }

  function scrollItemIntoView(item) {
    if (!panelScroll || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelScroll.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelScroll.contentY
      var viewBottom = viewTop + panelScroll.height
      var maxY = Math.max(0, panelScroll.contentHeight - panelScroll.height)
      if (top < viewTop + margin) panelScroll.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin)
        panelScroll.contentY = Math.min(maxY, bottom + margin - panelScroll.height)
    })
  }

  function open() {
    root.controller.show()
    oneDrive.refresh(false)
    oneDrive.retryStaleQuotaOnOpen()
    Qt.callLater(function() {
      if (root.opened) {
        root.setCenterHoverRevealSuppressed(true)
        keyCatcher.forceActiveFocus()
      }
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) close()
    else open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function closeForPopoutSwitch() {
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    cursorActive = false
    cursorItem = null
    if (opened && panelScroll) panelScroll.contentY = 0
  }
  onPanelStyleChanged: ensureCursor()

  Service {
    id: oneDrive
    settings: root.settings
  }

  Connections {
    target: oneDrive
    function onAuthenticatedChanged() { root.ensureCursor() }
    function onActivityChanged() { root.ensureCursor() }
    function onQuotaKnownChanged() { root.ensureCursor() }
    function onBusyChanged() { root.ensureCursor() }
    function onResumeAtChanged() { root.ensureCursor() }
    function onActiveChanged() { root.ensureCursor() }
  }

  BarIconButton {
    id: button
    visible: false
    bar: root.bar
    text: ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.activateCursor()
      onTextKey: function(value) {
        if (value === "r" || value === "R") oneDrive.checkQuota()
        else if (value === "f" || value === "F") oneDrive.checkFullStatus()
        else if (value === "p" || value === "P") oneDrive.toggleRunning()
        else if (value === "o" || value === "O") oneDrive.openFolder()
        else if (value === "l" || value === "L") oneDrive.login()
        else if (value === "w" || value === "W") oneDrive.openWeb()
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelScroll.width
          spacing: Style.space(10)

          Item {
            id: headerItem
            visible: oneDrive.authenticated
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool keyboardEnabled: oneDrive.installed
              && oneDrive.serviceAvailable && oneDrive.authenticated && !oneDrive.busy
            readonly property bool ringVisible: root.headerHasCursor
            readonly property string switchHint: root.toggleHint
            function keyboardActivate() { oneDrive.toggleRunning() }
            function focusHero() { root.setCursor(headerItem) }

            PanelHero {
              id: hero
              width: parent.width
              title: "OneDrive"
              meta: Model.heroMeta(oneDrive)
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: oneDrive.active ? 1.0 : 0.55
              iconComponent: Component {
                OneDriveIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                }
              }
              trailingControl: Component {
                Row {
                  spacing: Style.space(6)
                  visible: oneDrive.installed && oneDrive.serviceAvailable && oneDrive.authenticated

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: oneDrive.activeState === "activating" ? "Starting"
                      : (oneDrive.syncing ? "Syncing" : (oneDrive.active ? "Monitoring" : "Paused"))
                    color: root.dim
                    font.family: hero.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  ToggleSwitch {
                    id: powerSwitch
                    anchors.verticalCenter: parent.verticalCenter
                    checked: oneDrive.active
                    busy: oneDrive.busy
                    hasCursor: headerItem.ringVisible
                    foreground: hero.foreground
                    onHovered: function(on) { if (on) headerItem.focusHero() }
                    onToggled: oneDrive.toggleRunning()

                    PanelToolTip {
                      visible: powerSwitch.containsMouse
                      text: headerItem.switchHint
                      fontFamily: hero.fontFamily
                    }
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: oneDrive.actionStatus !== "" || oneDrive.lastError !== ""
            width: parent.width
            text: oneDrive.actionStatus !== "" ? oneDrive.actionStatus : oneDrive.lastError
            color: oneDrive.lastError !== "" && oneDrive.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ActionRow {
            visible: !oneDrive.installed
            width: parent.width
            title: "OneDrive CLI is not installed"
            subtitle: "Install the abraunegg OneDrive client first"
            icon: "󰅟"
            actionIcon: ""
            actionEnabled: false
          }

          ActionRow {
            id: loginAction
            visible: oneDrive.installed && !oneDrive.authenticated
            width: parent.width
            title: "Login to OneDrive"
            subtitle: "Open the CLI authentication flow"
            icon: "󰌋"
            actionIcon: "󰐕"
            onActivated: oneDrive.login()
          }

          ActionRow {
            id: reauthAction
            visible: oneDrive.authenticated && oneDrive.reauthRequired
            width: parent.width
            title: oneDrive.running ? "Pause sync to reauthenticate" : "Reauthenticate OneDrive"
            subtitle: "Open the CLI's Microsoft authorization flow"
            icon: "󰌋"
            actionIcon: oneDrive.running ? "" : "󰐕"
            actionEnabled: !oneDrive.running
            onActivated: oneDrive.reauthenticate()
          }

          ActionRow {
            id: resyncAction
            visible: oneDrive.authenticated && oneDrive.resyncRequired
            width: parent.width
            title: oneDrive.running ? "Pause sync to run resync" : "Run resync repair"
            subtitle: "Opens a terminal · asks to confirm first"
            icon: "󰑐"
            actionIcon: oneDrive.running ? "" : "󰐊"
            actionEnabled: !oneDrive.running && !oneDrive.busy
            onActivated: oneDrive.repairResync()
          }

          Text {
            textFormat: Text.PlainText
            visible: oneDrive.authenticated && oneDrive.serviceAvailable && !oneDrive.enabled
            width: parent.width
            text: oneDrive.running
              ? "Automatic startup is disabled; syncing will not resume after reboot."
              : "Automatic startup is disabled; Resume starts syncing for this session only."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ActionRow {
            id: timedResumeAction
            visible: oneDrive.authenticated && !oneDrive.active
              && oneDrive.resumeAt > Date.now() / 1000
            width: parent.width
            title: "Resume syncing now"
            subtitle: oneDrive.statusText
            icon: "󰏤"
            actionIcon: "󰐊"
            actionEnabled: !oneDrive.busy
            onActivated: oneDrive.resume()
          }

          CursorSurface {
            id: storageBlock
            readonly property bool keyboardEnabled: storageMouse.enabled
            function keyboardActivate() { oneDrive.checkQuota() }
            visible: oneDrive.authenticated
            width: parent.width
            foreground: root.foreground
            hasCursor: (storageMouse.containsMouse || root.cursorItem === storageBlock)
              && storageMouse.enabled
            implicitHeight: storageContent.implicitHeight + Style.space(8)
            height: implicitHeight

            Column {
              id: storageContent
              width: parent.width - Style.space(8)
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(storageHeader.implicitHeight, storageValue.implicitHeight)

                PanelSectionHeader {
                  textFormat: Text.PlainText
                  id: storageHeader
                  text: "STORAGE"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  id: storageValue
                  text: Model.usageShort(oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Rectangle {
                id: storageTrack
                width: parent.width
                height: Style.space(6)
                radius: Style.cornerRadius
                color: Style.selectedFillFor(root.foreground, Color.accent)
                opacity: oneDrive.quotaKnown ? 1.0 : 0.5

                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  visible: oneDrive.quotaKnown
                  width: storageTrack.width * Model.usageFraction(
                    oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
                  height: storageTrack.height
                  radius: Style.cornerRadius
                  color: root.storageSevere ? root.urgent : root.foreground
                }
              }

              Item {
                width: parent.width
                implicitHeight: Math.max(storageFree.implicitHeight, storageChecked.implicitHeight)

                Text {
                  textFormat: Text.PlainText
                  id: storageFree
                  text: oneDrive.quotaKnown
                    ? Model.freeText(oneDrive.usedBytes, oneDrive.quotaBytes, oneDrive.quotaKnown)
                      + (root.storageSevere ? " · almost full" : "")
                    : "Refresh for exact usage"
                  color: root.storageSevere ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  id: storageChecked
                  text: Model.checkedText(oneDrive.quotaCheckedTs)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                textFormat: Text.PlainText
                id: quotaWarning
                visible: oneDrive.quotaChecking || oneDrive.quotaError !== ""
                width: parent.width
                text: oneDrive.quotaChecking
                  ? "Refreshing storage… may take up to " + String(oneDrive.cloudTimeoutSec) + "s"
                  : oneDrive.quotaError + " · " + Model.checkedText(oneDrive.quotaCheckedTs) + " · Retry"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.underline: quotaWarningMouse.containsMouse && !oneDrive.quotaChecking
                wrapMode: Text.Wrap

                MouseArea {
                  id: quotaWarningMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: !oneDrive.busy && !oneDrive.quotaChecking
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: oneDrive.checkQuota()
                }
              }
            }

            MouseArea {
              id: storageMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: !oneDrive.quotaKnown
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onEntered: root.setCursor(storageBlock)
              onClicked: oneDrive.checkQuota()
            }
          }

          Column {
            id: activityBlock
            visible: oneDrive.authenticated && root.panelStyle === "full"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(activityHeader.implicitHeight, activityMeta.implicitHeight)

              PanelSectionHeader {
                textFormat: Text.PlainText
                id: activityHeader
                text: "ACTIVITY"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                id: activityMeta
                text: Model.syncMeta(oneDrive.lastSyncTs) || Model.activityMeta(root.activityRows)
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.activityRows.length === 0
              width: parent.width
              text: "No recent OneDrive activity."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: activityColumn
              visible: root.activityRows.length > 0
              width: parent.width
              spacing: Style.space(3)

              Repeater {
                id: activityRepeater
                model: root.activityRows

                ActivityRow {
                  required property var modelData
                  width: activityColumn.width
                  rowData: modelData
                }
              }
            }
          }

          Column {
            id: pausePresets
            visible: oneDrive.authenticated && oneDrive.serviceAvailable
              && !oneDrive.serviceFailed && !oneDrive.resyncRequired && !oneDrive.reauthRequired
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              textFormat: Text.PlainText
              text: oneDrive.active ? "PAUSE FOR" : "RESUME IN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              ActionChip {
                id: pause15Chip
                width: (parent.width - parent.spacing * 2) / 3
                text: "15 min"
                icon: "󰔛"
                enabled: !oneDrive.busy
                onActivated: oneDrive.pauseFor(15)
              }

              ActionChip {
                id: pause60Chip
                width: (parent.width - parent.spacing * 2) / 3
                text: "1 hour"
                icon: "󰔛"
                enabled: !oneDrive.busy
                onActivated: oneDrive.pauseFor(60)
              }

              ActionChip {
                id: pause240Chip
                width: (parent.width - parent.spacing * 2) / 3
                text: "4 hours"
                icon: "󰔛"
                enabled: !oneDrive.busy
                onActivated: oneDrive.pauseFor(240)
              }
            }
          }

          ActionRow {
            id: fullStatusAction
            visible: root.panelStyle === "full" && oneDrive.installed && oneDrive.authenticated
            width: parent.width
            title: oneDrive.fullStatusChecking ? "Verifying sync…" : "Verify sync"
            subtitle: oneDrive.fullStatusChecking
              ? "Scanning your drive · may take up to " + String(oneDrive.cloudTimeoutSec) + "s"
              : (oneDrive.syncStatusError !== ""
                ? oneDrive.syncStatusError + " · " + Model.checkedText(oneDrive.syncStatusCheckedTs) + " · Retry"
                : (oneDrive.remoteStatus === "Not checked"
                  ? "Compares every file with the cloud · may take a while"
                  : oneDrive.remoteStatus + " · " + Model.checkedText(oneDrive.syncStatusCheckedTs)))
            icon: "󰍉"
            actionIcon: oneDrive.fullStatusChecking ? "" : "󰑐"
            spinning: oneDrive.fullStatusChecking
            actionEnabled: !oneDrive.busy
            onActivated: oneDrive.checkFullStatus()
          }

          Row {
            id: chipRow
            visible: root.panelStyle === "full" && oneDrive.installed && oneDrive.authenticated
            width: parent.width
            spacing: Style.space(6)
            readonly property int chipCount: folderChip.visible ? 3 : 2
            readonly property real chipWidth: (width - spacing * (chipCount - 1)) / chipCount

            ActionChip {
              id: checkChip
              width: chipRow.chipWidth
              text: oneDrive.quotaChecking ? "Refreshing…" : "Storage"
              icon: "󰑓"
              spinning: oneDrive.quotaChecking
              enabled: !oneDrive.busy
              onActivated: oneDrive.checkQuota()
            }

            ActionChip {
              id: folderChip
              visible: oneDrive.syncDir !== ""
              width: chipRow.chipWidth
              text: "Folder"
              icon: "󰉋"
              onActivated: oneDrive.openFolder()
            }

            ActionChip {
              id: webChip
              width: chipRow.chipWidth
              text: "Web"
              icon: "󰖟"
              onActivated: oneDrive.openWeb()
            }
          }

          Column {
            id: compactActions
            visible: oneDrive.authenticated && root.panelStyle === "compact"
            width: parent.width
            spacing: Style.space(5)

            CompactActionRow {
              id: compactCheck
              width: parent.width
              title: oneDrive.quotaChecking ? "Refreshing storage…" : "Refresh storage"
              icon: "󰑓"
              meta: oneDrive.quotaChecking ? "up to " + String(oneDrive.cloudTimeoutSec) + "s"
                : Model.relativeTime(oneDrive.quotaCheckedTs)
              spinning: oneDrive.quotaChecking
              actionEnabled: !oneDrive.busy
              onActivated: oneDrive.checkQuota()
            }

            CompactActionRow {
              id: compactFullStatus
              width: parent.width
              title: oneDrive.fullStatusChecking ? "Verifying sync…" : "Verify sync"
              icon: "󰍉"
              meta: oneDrive.fullStatusChecking ? "up to " + String(oneDrive.cloudTimeoutSec) + "s"
                : (oneDrive.syncStatusError !== "" ? "retry"
                  : (oneDrive.remoteStatus === "Not checked" ? "may be slow"
                    : Model.relativeTime(oneDrive.syncStatusCheckedTs)))
              spinning: oneDrive.fullStatusChecking
              actionEnabled: !oneDrive.busy
              onActivated: oneDrive.checkFullStatus()
            }

            CompactActionRow {
              id: compactFolder
              width: parent.width
              title: "Open OneDrive folder"
              icon: "󰉋"
              actionEnabled: oneDrive.syncDir !== ""
              onActivated: oneDrive.openFolder()
            }

            CompactActionRow {
              id: compactWeb
              width: parent.width
              title: "Open OneDrive on the web"
              icon: "󰖟"
              onActivated: oneDrive.openWeb()
            }
          }
        }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow

    property string title: ""
    property string subtitle: ""
    property string icon: ""
    property string actionIcon: "󰐕"
    property bool actionEnabled: true
    property bool spinning: false
    readonly property bool keyboardEnabled: actionEnabled
    signal activated()
    function keyboardActivate() { if (actionEnabled) activated() }
    onSpinningChanged: { if (!spinning) actionRowGlyph.rotation = 0 }

    foreground: root.foreground
    hasCursor: (actionMouse.containsMouse || root.cursorItem === actionRow) && actionEnabled
    implicitHeight: Math.max(Style.space(54), row.implicitHeight + Style.spacing.rowPaddingX)
    height: implicitHeight

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionRow.actionEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: actionRow.actionEnabled
      onEntered: root.setCursor(actionRow)
      onClicked: actionRow.activated()
    }

    RowLayout {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(9)

      Text {
        textFormat: Text.PlainText
        id: actionRowGlyph
        text: actionRow.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter

        RotationAnimation on rotation {
          running: actionRow.spinning
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      PanelActionButton {
        visible: actionRow.actionIcon !== ""
        iconText: actionRow.actionIcon
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: actionRow.actionEnabled
        Layout.alignment: Qt.AlignVCenter
        onClicked: actionRow.activated()
      }
    }
  }

  component ActivityRow: CursorSurface {
    id: activityRow
    property var rowData: null
    readonly property string kind: String(rowData && rowData.kind || "")
    readonly property bool fileRow: kind === "file"
    readonly property bool recovered: rowData && rowData.recovered === true
    readonly property bool keyboardEnabled: fileRow
    readonly property string title: String(rowData && rowData.title || "")
    readonly property string detail: String(rowData && rowData.detail || "")

    foreground: root.foreground
    hasCursor: (activityMouse.containsMouse || root.cursorItem === activityRow) && fileRow
    implicitHeight: Math.max(Style.space(32), activityContent.implicitHeight + Style.space(6))
    height: implicitHeight

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.space(5)
      anchors.bottomMargin: Style.space(5)
      width: Style.space(2)
      radius: width / 2
      color: activityRow.fileRow ? root.dim : Color.accent
    }

    MouseArea {
      id: activityMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: activityRow.fileRow
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor(activityRow)
      onClicked: oneDrive.openFile({
        path: activityRow.rowData && activityRow.rowData.path || "",
        name: activityRow.title
      })
    }

    function keyboardActivate() {
      if (!fileRow) return
      oneDrive.openFile({
        path: rowData && rowData.path || "",
        name: title
      })
    }

    RowLayout {
      id: activityContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(7)

      Text {
        textFormat: Text.PlainText
        text: Model.activityGlyph(activityRow.rowData)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: activityRow.title
          color: activityRow.kind === "error" && !activityRow.recovered
            ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: activityRow.detail !== ""
          Layout.fillWidth: true
          text: activityRow.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        textFormat: Text.PlainText
        text: Model.relativeTime(activityRow.rowData && activityRow.rowData.ts || 0)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        Layout.alignment: Qt.AlignTop | Qt.AlignRight
      }
    }
  }

  component ActionChip: CursorSurface {
    id: actionChip
    property string text: ""
    property string icon: ""
    property bool spinning: false
    readonly property bool keyboardEnabled: enabled
    signal activated()
    function keyboardActivate() { if (enabled) activated() }
    onSpinningChanged: { if (!spinning) actionChipGlyph.rotation = 0 }

    foreground: root.foreground
    bordered: true
    hasCursor: (chipMouse.containsMouse || root.cursorItem === actionChip) && actionChip.enabled
    implicitHeight: Style.space(34)
    height: implicitHeight
    opacity: enabled ? 1.0 : 0.5

    Row {
      id: actionChipContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        id: actionChipGlyph
        anchors.verticalCenter: parent.verticalCenter
        text: actionChip.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        RotationAnimation on rotation {
          running: actionChip.spinning
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
        }
      }

      Text {
        textFormat: Text.PlainText
        // Keep the label inside the chip border: give it only the width the
        // chip can spare, shrinking the font slightly before eliding.
        readonly property real availableWidth: actionChip.width - Style.space(16)
          - (actionChip.icon !== "" ? actionChipGlyph.width + actionChipContent.spacing : 0)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, Math.max(0, availableWidth))
        text: actionChip.text
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: Style.font.bodySmall - 3
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: actionChip.enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor(actionChip)
      onClicked: actionChip.activated()
    }
  }

  component CompactActionRow: CursorSurface {
    id: compactRow
    property string title: ""
    property string icon: ""
    property string meta: ""
    property bool selected: false
    property bool actionEnabled: true
    property bool spinning: false
    readonly property bool keyboardEnabled: actionEnabled
    signal activated()
    function keyboardActivate() { if (actionEnabled) activated() }
    onSpinningChanged: { if (!spinning) compactActionGlyph.rotation = 0 }

    foreground: root.foreground
    current: selected
    currentFill: Style.selectedFillFor(root.foreground, Color.accent)
    hasCursor: (compactMouse.containsMouse || root.cursorItem === compactRow) && actionEnabled
    implicitHeight: Style.space(34)
    height: implicitHeight
    opacity: actionEnabled ? 1.0 : 0.5

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        id: compactActionGlyph
        text: compactRow.icon
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter

        RotationAnimation on rotation {
          running: compactRow.spinning
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: compactRow.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: compactRow.meta !== ""
        text: compactRow.meta
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
      }
    }

    MouseArea {
      id: compactMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: compactRow.actionEnabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor(compactRow)
      onClicked: compactRow.activated()
    }
  }
}
