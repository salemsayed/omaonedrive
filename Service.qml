import QtQuick
import QtQml.Models
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Commands.js" as Commands

// Coordinator over every discovered OneDrive account.
//
// It owns discovery, selection, aggregation and scheduling; each Account owns
// its own state and processes. The panel and bar widget bind to the selected
// account through the forwarding block near the bottom, so a single-account
// install behaves exactly as it did before discovery existed.
Item {
  id: root

  property var settings: ({})

  property var _accountObjects: []
  property int _aggregateRevision: 0

  readonly property var accounts: _accountObjects
  readonly property int accountCount: accounts.length
  property string selectedService: ""

  readonly property var selectedAccount: {
    var found = accountForService(selectedService)
    if (found) return found
    return accounts.length > 0 ? accounts[0] : null
  }

  readonly property var aggregate: {
    void(_aggregateRevision)
    return Model.aggregateAccounts(accounts)
  }

  // Every account has been polled at least once, whatever the outcome. Distinct
  // from aggregate.initialized, which asks whether any account produced a usable
  // sample: an account whose helper always fails is attempted but never
  // initialized, and the startup hold has to end for it.
  readonly property bool allAttempted: {
    void(_aggregateRevision)
    for (var index = 0; index < accounts.length; index++) {
      if (!accounts[index].attempted) return false
    }
    return accounts.length > 0
  }

  readonly property bool notificationsEnabled: {
    var value = setting("notifications", true)
    return value === true || String(value).toLowerCase() === "true"
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property string helperPath: Model.filePath(Qt.resolvedUrl("onedrive-status.py"))
  readonly property string clickHelperPath: Model.filePath(Qt.resolvedUrl("omaonedrive-click"))

  property string discoveryError: ""
  property bool _discoverySettled: true


  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function accountForService(service) {
    for (var index = 0; index < _accountObjects.length; index++) {
      if (_accountObjects[index].service === service) return _accountObjects[index]
    }
    return null
  }

  // `withQuotaRetry` is the panel's behaviour, not selection's: opening the
  // panel onto a stale failed quota check retries it once. Automation selecting
  // an account merely to target a control must not silently contact Microsoft,
  // so IPC passes false.
  function selectAccount(service, withQuotaRetry) {
    var found = accountForService(service)
    if (!found) return
    selectedService = found.service
    if (!routinePollRunning()) found.refresh(false)
    if (withQuotaRetry !== false) found.retryStaleQuotaOnOpen()
  }

  // --- discovery ------------------------------------------------------------

  // Reconcile by the stable service key rather than clearing and rebuilding:
  // recreating delegates would drop in-flight processes and the notification
  // edge history that decides whether a condition is new.
  function applyDiscovery(rows) {
    var current = []
    for (var scan = 0; scan < descriptors.count; scan++) current.push(descriptors.get(scan).service)

    var plan = Model.reconcilePlan(current, rows)
    for (var update = 0; update < plan.updates.length; update++) {
      var descriptor = normalizeDescriptor(plan.updates[update].row)
      var existing = descriptors.get(plan.updates[update].index)
      // A unit repointed at a different config directory is a different account
      // behind the same name. Keeping the delegate preserves its processes, but
      // its quota, file list, auth flag and notification edge history now belong
      // to the previous directory and must not be shown as this one's.
      // Only a real repoint: "" means "not yet known", and the seeded descriptor
      // always starts that way, so treating it as a change wiped the first
      // sample and the edge latches on every startup.
      if (existing.confdir !== descriptor.confdir) {
        var account = accountForService(descriptor.service)
        if (existing.confdir !== "" && descriptor.confdir !== "") {
          if (account) account.forgetSample()
        } else if (account) {
          // "" -> a real directory is the startup seed learning its identity,
          // not a repoint: there is no sample to wipe, and wiping one reset the
          // edge latches on every startup. But a poll already in flight was
          // started against the CLIENT's default directory, which is only the
          // same directory if this unit does not override it. Refuse that reply
          // rather than attach another account's sync directory and quota to
          // this one.
          account.discardInFlight()
        }
      }
      descriptors.set(plan.updates[update].index, descriptor)
    }
    for (var append = 0; append < plan.appends.length; append++) {
      descriptors.append(normalizeDescriptor(plan.appends[append]))
    }
    for (var remove = 0; remove < plan.removes.length; remove++) {
      descriptors.remove(plan.removes[remove])
    }

    if (descriptors.count === 0) descriptors.append(defaultDescriptor())
    // Reconciliation may have removed the account holding the cloud slot, or the
    // one a queued entry belongs to. Re-check once the model has settled.
    Qt.callLater(function() { root.cloudFinished() })
    // A removed selected account falls back to the first discovered one.
    if (accountForService(selectedService) === null) {
      selectedService = descriptors.count > 0 ? descriptors.get(0).service : ""
    }
  }

  function normalizeDescriptor(row) {
    return {
      service: String(row.service || ""),
      instance: String(row.instance || ""),
      confdir: String(row.confdir || ""),
      description: String(row.description || "")
    }
  }

  // The compatibility guarantee: with no template instances this is what
  // discovery returns, and it is also what we fall back to if discovery fails.
  function defaultDescriptor() {
    return {
      service: Commands.DEFAULT_SERVICE,
      instance: "",
      confdir: "",
      description: ""
    }
  }

  function reloadAccounts() {
    if (discoveryProcess.running || helperPath === "") return
    discoveryProcess.command = Commands.listAccounts(helperPath)
    _discoverySettled = false
    discoveryProcess.running = true
  }

  function trackAccount(object) {
    var next = _accountObjects.slice()
    next.push(object)
    _accountObjects = next
    _aggregateRevision++
  }

  function untrackAccount(object) {
    var next = []
    for (var index = 0; index < _accountObjects.length; index++) {
      if (_accountObjects[index] !== object) next.push(_accountObjects[index])
    }
    _accountObjects = next
    _aggregateRevision++
  }

  // --- scheduling -----------------------------------------------------------

  property int _pollCursor: 0

  // One routine status process at a time across every account, so N accounts
  // cost one subprocess per slot rather than N at once.
  function routinePollRunning() {
    for (var index = 0; index < _accountObjects.length; index++) {
      if (_accountObjects[index].routinePolling) return true
    }
    return false
  }

  // Shape Model.nextPollIndex expects: it must skip an account whose status
  // process is busy for ANY reason, not only a routine poll.
  function pollCandidates() {
    var rows = []
    for (var index = 0; index < _accountObjects.length; index++) {
      rows.push({
        routinePolling: _accountObjects[index].routinePolling,
        busy: _accountObjects[index].statusBusy,
        attempted: _accountObjects[index].attempted,
        settling: _accountObjects[index].settling
      })
    }
    return rows
  }

  // An account that has not reported yet takes priority, but the cursor still
  // advances, so several unreported accounts interleave instead of the first one
  // taking every slot until it gives up. Priority is "has not reported"
  // (!initialized), not "not running": a deliberately paused account is a known
  // state and must not consume startup slots at all.
  function nextAccountToPoll() {
    var index = Model.nextPollIndex(pollCandidates(), _pollCursor)
    if (index < 0) return null
    _pollCursor = (index + 1) % _accountObjects.length
    return _accountObjects[index]
  }

  function pollNextAccount() {
    if (routinePollRunning()) return
    var account = nextAccountToPoll()
    if (account) account.refresh(false)
  }

  // --- cloud check semaphore ------------------------------------------------

  // Explicit cloud checks are slow (up to 30s) and are never automatic. One at a
  // time across all accounts, de-duplicated by (service, mode) so repeated
  // clicks cannot queue a backlog.
  property var _cloudQueue: []

  function requestCloud(account, mode) {
    if (!account) return
    var busyAccount = cloudBusyAccount()
    var active = busyAccount
      ? { service: busyAccount.service, mode: busyAccount.activeCloudMode }
      : null
    var decision = Model.cloudDecision(
      busyAccount !== null, _cloudQueue, account.service, mode, active)
    if (decision === "drop") return
    if (decision === "queue") {
      var next = _cloudQueue.slice()
      next.push({ service: account.service, mode: mode })
      _cloudQueue = next
      return
    }
    account.startCloudCheck(mode)
  }

  function hasDescriptor(service) {
    for (var row = 0; row < descriptors.count; row++) {
      if (descriptors.get(row).service === service) return true
    }
    return false
  }

  function cloudBusyAccount() {
    for (var index = 0; index < _accountObjects.length; index++) {
      var account = _accountObjects[index]
      // A delegate discovery has already dropped will never report again, so it
      // must not hold the shared slot: nothing releases a slot held by an
      // account that no longer exists, and every queued account then sat there
      // showing "Not checked".
      //
      // The retry at the end of applyDiscovery is what the harness actually
      // pins -- there the delegate is already destroyed by the time it runs.
      // This guard covers the case where destruction is deferred past that
      // point, which the harness cannot produce and which real Quickshell can.
      if (!hasDescriptor(account.service)) continue
      // Pending counts as busy: a check deferred behind that account's routine
      // poll has already claimed the slot.
      if (account.cloudChecking || account.cloudPending) return account
    }
    return null
  }

  function cloudFinished() {
    // pollFinished fires for routine polls too; only advance when the shared
    // slot is actually free.
    if (cloudBusyAccount() !== null) return
    if (_cloudQueue.length === 0) return
    var next = _cloudQueue.slice()
    // Keep taking entries until one belongs to an account that still exists.
    // Stopping after a single shift meant an account removed by discovery while
    // queued took the whole rest of the queue with it: the entries behind it
    // stayed put and no cloud check started, so the accounts waiting on a
    // storage figure showed "Not checked" until some later poll happened to
    // call back in -- and never, if polling was itself blocked.
    while (next.length > 0) {
      var entry = next.shift()
      var account = accountForService(entry.service)
      if (account) {
        _cloudQueue = next
        account.startCloudCheck(entry.mode)
        return
      }
    }
    _cloudQueue = next
  }

  // --- notification broker --------------------------------------------------

  // One popup per polling burst, not one per account. Accounts report
  // transitions; this decides how many notifications that becomes.
  property var _pendingEvents: []
  property bool _baselineSent: false

  function enqueueTransition(event) {
    if (!notificationsEnabled || !event) return
    var next = _pendingEvents.slice()
    next.push(event)
    _pendingEvents = next
    // start(), not restart(): restarting on every event made the window mean
    // "900ms of quiet", which a staggered scheduler never produces, so each
    // account's events flushed separately. The window now runs from the FIRST
    // event of a batch and is long enough to span one poll round.
    if (!burstTimer.running) burstTimer.start()
  }

  function flushTransitions() {
    var events = _pendingEvents
    _pendingEvents = []
    if (events.length === 0) return
    // Checked at SEND time, not only at enqueue: the burst window is up to a
    // full refresh interval and the startup hold longer still, so a user who
    // turns notifications off inside that window would otherwise still get one.
    if (!notificationsEnabled) return
    var composed = Model.composeNotification(events, accountCount > 1)
    if (!composed) return
    _baselineSent = true
    // The click command rides inside the notification as a persisted --exec
    // hint, so it survives shell and plugin reloads -- the old tracked
    // notify-send read the click back from stdout and died with this process.
    // That also removes the one-tracked-popup-at-a-time constraint and its
    // action-dropping fallback: every popup is fire-and-forget now, and every
    // one keeps its click.
    Quickshell.execDetached(Commands.notify(
      composed.urgency, composed.summary, composed.body,
      composed.action, composed.service, clickHelperPath))
  }

  // What a notification click does, reached over IPC (BarWidget's openAccount
  // and repairAccount) because the daemon delivers the click as a fresh
  // `omarchy-shell` invocation. Both live here so the harness can drive them.
  function openFromNotification(target) {
    var found = Model.resolveAccountTarget(accounts, target)
    // An account that vanished since the popup fired: still open the panel --
    // the user asked for it -- just on whatever is selected.
    if (found !== "" && found !== selectedService) selectAccount(found, false)
  }

  function repairFromNotification(target) {
    var found = Model.resolveAccountTarget(accounts, target)
    // Unlike open, a repair on the WRONG account deletes and re-downloads the
    // wrong drive. A stale target repairs nothing rather than whatever
    // happens to be selected.
    if (found === "") return
    // Repair BEFORE selecting: selection refreshes the account, and
    // repairResync refuses one that is mid-poll -- the click would silently do
    // nothing. The select is only so the panel shows the account being
    // repaired if the user opens it next.
    var account = accountForService(found)
    if (account) account.repairResync()
    if (found !== selectedService) selectAccount(found, false)
  }

  // --- selected-account facade ----------------------------------------------
  //
  // Panel.qml and BarWidget.qml still say `oneDrive.running`. Every forward is
  // null-safe: between startup and the first descriptor there is no account.

  readonly property bool installed: selectedAccount ? selectedAccount.installed : false
  readonly property bool serviceAvailable: selectedAccount ? selectedAccount.serviceAvailable : false
  readonly property bool running: selectedAccount ? selectedAccount.running : false
  readonly property bool enabled: selectedAccount ? selectedAccount.enabled : false
  readonly property string activeState: selectedAccount ? selectedAccount.activeState : ""
  readonly property bool serviceFailed: selectedAccount ? selectedAccount.serviceFailed : false
  readonly property bool resyncRequired: selectedAccount ? selectedAccount.resyncRequired : false
  readonly property bool authenticated: selectedAccount ? selectedAccount.authenticated : false
  readonly property bool reauthRequired: selectedAccount ? selectedAccount.reauthRequired : false
  readonly property bool syncing: selectedAccount ? selectedAccount.syncing : false
  readonly property string syncStage: selectedAccount ? selectedAccount.syncStage : ""
  readonly property bool active: selectedAccount ? selectedAccount.active : false
  readonly property bool refreshing: selectedAccount ? selectedAccount.refreshing : false
  readonly property string statusText: selectedAccount ? selectedAccount.statusText : "Checking…"
  readonly property string syncDir: selectedAccount ? selectedAccount.syncDir : ""
  readonly property string syncMode: selectedAccount ? selectedAccount.syncMode : "Two-way"
  readonly property string clientVersion: selectedAccount ? selectedAccount.clientVersion : ""
  readonly property double resumeAt: selectedAccount ? selectedAccount.resumeAt : 0
  readonly property double lastSyncTs: selectedAccount ? selectedAccount.lastSyncTs : 0
  readonly property double usedBytes: selectedAccount ? selectedAccount.usedBytes : 0
  readonly property double quotaBytes: selectedAccount ? selectedAccount.quotaBytes : 0
  readonly property bool quotaKnown: selectedAccount ? selectedAccount.quotaKnown : false
  readonly property double quotaCheckedTs: selectedAccount ? selectedAccount.quotaCheckedTs : 0
  readonly property string quotaError: selectedAccount ? selectedAccount.quotaError : ""
  readonly property string remoteStatus: selectedAccount ? selectedAccount.remoteStatus : "Not checked"
  readonly property double syncStatusCheckedTs: selectedAccount ? selectedAccount.syncStatusCheckedTs : 0
  readonly property string syncStatusError: selectedAccount ? selectedAccount.syncStatusError : ""
  readonly property double remoteCheckedTs: selectedAccount ? selectedAccount.remoteCheckedTs : 0
  readonly property string remoteError: selectedAccount ? selectedAccount.remoteError : ""
  readonly property var files: selectedAccount ? selectedAccount.files : []
  readonly property var activity: selectedAccount ? selectedAccount.activity : []
  readonly property string actionStatus: selectedAccount ? selectedAccount.actionStatus : ""
  // A discovery failure is non-destructive, but the user should still learn the
  // account list may be stale; the account's own error takes precedence.
  readonly property string lastError: {
    if (selectedAccount && selectedAccount.lastError !== "") return selectedAccount.lastError
    return discoveryError
  }
  readonly property bool busy: selectedAccount ? selectedAccount.busy : false
  readonly property bool cloudChecking: selectedAccount ? selectedAccount.cloudChecking : false
  readonly property bool quotaChecking: selectedAccount ? selectedAccount.quotaChecking : false
  readonly property bool fullStatusChecking: selectedAccount ? selectedAccount.fullStatusChecking : false
  // Forwarded from the selected account, which carries the comment tying it to
  // the helper's own timeout constants. A second literal here would drift.
  readonly property int cloudTimeoutSec: selectedAccount ? selectedAccount.cloudTimeoutSec : 30

  // A cloud check is explicit user intent and is serialised by its own
  // semaphore; a routine refresh goes through the shared slot, so IPC, the panel
  // and the scheduler cannot each start a helper at the same time.
  function refresh(remote) {
    if (!selectedAccount) return
    if (remote === true) { selectedAccount.refresh(true); return }
    refreshSelected()
  }
  // Called when the panel is opened from the bar: point it at the account the
  // badge is blaming, so the controls act on what the user just clicked about.
  function selectBadgedAccount() {
    var current = selectedAccount
    var target = Model.openSelection(aggregate,
      current ? Model.accountStateKind(current) : "")
    if (target !== "" && target !== selectedService) selectAccount(target, false)
  }

  function refreshSelected() {
    if (selectedAccount && !routinePollRunning()) selectedAccount.refresh(false)
  }
  function checkQuota() { if (selectedAccount) selectedAccount.checkQuota() }
  function checkFullStatus() { if (selectedAccount) selectedAccount.checkFullStatus() }
  function retryStaleQuotaOnOpen() { if (selectedAccount) selectedAccount.retryStaleQuotaOnOpen() }
  function login() { if (selectedAccount) selectedAccount.login() }
  function reauthenticate() { if (selectedAccount) selectedAccount.reauthenticate() }
  function repairResync() { if (selectedAccount) selectedAccount.repairResync() }
  function openWeb() { if (selectedAccount) selectedAccount.openWeb() }
  function openFolder() { if (selectedAccount) selectedAccount.openFolder() }
  function openFile(file) { if (selectedAccount) selectedAccount.openFile(file) }
  function pause() { if (selectedAccount) selectedAccount.pause() }
  function pauseFor(minutes) { if (selectedAccount) selectedAccount.pauseFor(minutes) }
  function resume() { if (selectedAccount) selectedAccount.resume() }
  function toggleRunning() { if (selectedAccount) selectedAccount.toggleRunning() }

  // --- wiring ---------------------------------------------------------------

  ListModel { id: descriptors }

  Instantiator {
    id: accountInstances
    model: descriptors
    delegate: Account {
      // Bind the model roles onto Account's OWN properties. Redeclaring them as
      // `required property string service` here SHADOWS the base's, producing a
      // split brain: reads from outside the object see the model role, but every
      // read inside Account.qml -- id-qualified, unqualified, or in a binding --
      // sees the base default. Status reads went through JS and looked correct
      // while every control, timer and login vector silently targeted
      // onedrive.service. Verified with a minimal qml6 reproduction.
      required property var model
      service: model.service
      instance: model.instance
      confdir: model.confdir
      description: model.description
      settings: root.settings
      coordinator: root
      onAccountStateChanged: root._aggregateRevision++
      onPollFinished: root.cloudFinished()
      onTransition: function(event) { root.enqueueTransition(event) }
    }
    onObjectAdded: function(index, object) { root.trackAccount(object) }
    onObjectRemoved: function(index, object) { root.untrackAccount(object) }
  }

  // A polling burst is roughly one scheduler slot. Until every account has
  // reported once, the window is held open so a startup round of pre-existing
  // problems becomes ONE baseline notification rather than N.
  Timer {
    id: burstTimer
    property int heldRounds: 0
    // One poll round, because that is how long it takes every account to be
    // sampled once and therefore how long a related set of transitions takes to
    // arrive. A single account has nothing to wait for and keeps the short
    // window, so its notifications are as prompt as they were before.
    // A full poll round, uncapped: capping at 30s meant a 60-second refresh
    // interval spread one round's events across two windows and produced two
    // popups for the same round.
    interval: root.accountCount > 1 ? Math.max(900, root.refreshIntervalSec * 1000) : 900
    repeat: false
    onTriggered: {
      // Hold the window open until the first round is over, so a startup round of
      // pre-existing problems becomes ONE baseline notification rather than N.
      // Gated on allAttempted, not aggregate.initialized: the latter flips as
      // soon as the FIRST account reports, which released the hold immediately
      // and produced one popup per account -- exactly what this prevents.
      if (!root.allAttempted && !root._baselineSent && heldRounds < 12) {
        heldRounds += 1
        burstTimer.restart()
        return
      }
      heldRounds = 0
      root.flushTransitions()
    }
  }

  Process {
    id: discoveryProcess
    running: false
    command: []
    stdout: StdioCollector { id: discoveryStdout; waitForEnd: true }
    stderr: StdioCollector { id: discoveryStderr; waitForEnd: true }
    // Discovery is a Process like any other, so it too can stop without ever
    // reporting an exit. Without this, a missing python3 left `discoveryError`
    // empty for ever: the user saw one account and nothing at all to say the
    // list might be wrong.
    onRunningChanged: {
      if (!running) Qt.callLater(function() {
        if (root._discoverySettled) return
        root._discoverySettled = true
        root.discoveryError = "Could not run the OneDrive status helper"
      })
    }
    onExited: function(exitCode) {
      root._discoverySettled = true
      if (exitCode !== 0) {
        // Non-destructive: keep whatever accounts we already have. The startup
        // seed and applyDiscovery's own floor both guarantee there is at least
        // one, so there is nothing to re-seed here -- an earlier version tried,
        // in a branch that could never be reached.
        root.discoveryError = String(discoveryStderr.text || "").trim()
          || "Could not list OneDrive accounts"
        return
      }
      var rows = null
      try {
        var parsed = JSON.parse(String(discoveryStdout.text || ""))
        if (Array.isArray(parsed)) rows = parsed
      } catch (error) {
        rows = null
      }
      if (rows === null) {
        // Unparseable output is "could not look", not "found nothing". Treating
        // it as an empty result would remove every account -- more destructive
        // than a non-zero exit, which is handled above -- and it would repeat on
        // every discovery tick.
        root.discoveryError = "Could not read the account list"
        return
      }
      root.discoveryError = ""
      if (rows.length === 0) rows = [root.defaultDescriptor()]
      root.applyDiscovery(rows)
    }
  }

  // Slots are spread across the interval, so three accounts at the default
  // setting start about ten seconds apart and each is still polled about every
  // thirty seconds.
  Timer {
    id: pollScheduler
    interval: Math.max(1000, Math.round(root.refreshIntervalSec * 1000 / Math.max(1, root.accountCount)))
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.pollNextAccount()
  }

  // The old widget ran a dedicated two-second ramp alongside the poll timer, so
  // a service coming up at login was noticed within ~2s. Reordering slots does
  // not reproduce that -- with one account the slot IS the refresh interval --
  // so the fast ramp is a timer of its own again, running only until every
  // account has reported.
  Timer {
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    // Until every account has been polled once -- not until one succeeds, which
    // would leave the rest without ramp coverage, and not forever, which is what
    // an always-failing helper would otherwise get. The old widget capped its
    // ramp at 15 ticks; so does this.
    running: root.accountCount > 0 && !root.allAttempted && ticks < 15 * Math.max(1, root.accountCount)
    onTriggered: {
      ticks += 1
      root.pollNextAccount()
    }
  }

  // Units can be enabled or removed while the widget runs.
  Timer {
    interval: 300000
    repeat: true
    running: true
    onTriggered: root.reloadAccounts()
  }

  Component.onCompleted: {
    // Seed the compatibility descriptor immediately so the panel has an account
    // to bind to before the first discovery returns; discovery then reconciles
    // it in place rather than replacing it.
    descriptors.append(defaultDescriptor())
    selectedService = Commands.DEFAULT_SERVICE
    reloadAccounts()
  }
}
