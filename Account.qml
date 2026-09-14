import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Commands.js" as Commands

// One OneDrive account: its own systemd unit, config directory, resume timer,
// status process and control processes. Nothing here reads or writes another
// account's state, and every command vector is built from this object's own
// identity by Commands.js.
Item {
  id: root

  // Identity, supplied by discovery. confdir is read out of this unit's own
  // ExecStart by the helper -- never guessed from the instance name.
  property string service: Commands.DEFAULT_SERVICE
  property string instance: ""
  property string confdir: ""
  property string description: ""

  readonly property string displayName: Model.accountName(instance, description)
  // Waiting to be told what a control actually did. The coordinator gives these
  // the next poll slot: without that the answer could be swallowed indefinitely
  // by a neighbour's polling, and the bar would keep showing pre-control state.
  readonly property bool settling: settleTimer.waiting
  // The config directory the displayed sample actually came from, as the helper
  // reported it -- not the one we believe this unit uses.
  property string sampleConfdir: ""

  // Discovery can tell us this unit's real directory AFTER a poll has already
  // reported under a different one. That sample is another account's; nothing in
  // it may stay on screen.
  onConfdirChanged: {
    if (sampleConfdir !== "" && confdir !== "" && sampleConfdir !== confdir) forgetSample()
  }
  readonly property string resumeUnit: Commands.resumeUnit(instance)
  // True once a status poll has produced a usable sample. Until then this
  // account contributes no state to the aggregate, so default values cannot
  // flash a wrong badge.
  property bool initialized: false
  // True once a poll has been ATTEMPTED, whatever its outcome. An account whose
  // helper always fails is never `initialized`, so this is what "the first round
  // is over" must be measured with -- otherwise one broken account either
  // freezes the aggregate forever or defeats the startup notification hold.
  property bool attempted: false
  // Incremented whenever this account's identity changes. A status reply carries
  // the generation it was started under, so a reply from the previous config
  // directory is discarded instead of overwriting the new one's state.
  property int generation: 0
  property int _pendingGeneration: 0

  property var settings: ({})
  property var coordinator: null

  property bool installed: false
  property bool serviceAvailable: false
  property bool running: false
  property bool enabled: false
  property string activeState: ""
  property bool serviceFailed: false
  property bool resyncRequired: false
  property bool authenticated: false
  property bool reauthRequired: false
  property bool syncing: false
  property string syncStage: ""
  property int _desired: -1
  // Real Quickshell sets `running` false WITHOUT ever emitting `exited` when the
  // executable cannot be started -- a missing python3, a helper deleted under
  // us, a systemd-run that is not on PATH. Every one of these processes cleans
  // up only in onExited, and the coordinator's one-poll-at-a-time gate hangs off
  // `refreshing`, so a single unstartable command froze routine polling for
  // EVERY account for the life of the session. Each process therefore settles on
  // whichever signal arrives first, and settles exactly once.
  // Per-INVOCATION, not a shared boolean. A deferred settle callback outlives
  // the process that scheduled it: start a quota check, queue a sync-status for
  // the same account, let the quota finish normally, and the quota's deferred
  // callback then found `_statusSettled` false again -- because the sync-status
  // had started -- and abandoned a process that was running perfectly well.
  // Each start takes a new token; a callback acts only on its own.
  property int _statusRun: 0
  property int _statusSettledRun: 0
  property int _controlRun: 0
  property int _controlSettledRun: 0
  property int _cancelRun: 0
  property int _cancelSettledRun: 0
  property int _scheduleRun: 0
  property int _scheduleSettledRun: 0
  readonly property bool _statusSettled: _statusSettledRun === _statusRun
  // Polls are numbered as they START, and the number of the poll whose sample was
  // last APPLIED is kept. Counting completions was not enough: a poll started
  // BEFORE the control could complete after it and be accepted as the
  // confirmation, which undid the optimistic pause with pre-control data --
  // exactly the revert the settle loop exists to prevent.
  property int _pollsStarted: 0
  property int _pendingPoll: 0
  property int _confirmedPoll: 0
  readonly property bool active: _desired === -1
    ? (running || activeState === "activating") : _desired === 1
  property bool refreshing: false
  // Distinct from `refreshing`: only a ROUTINE poll occupies the coordinator's
  // one-at-a-time slot. A 30s cloud check must not freeze every account's
  // routine polling.
  readonly property bool routinePolling: refreshing && _activeCloudMode === ""
  // Any status process at all -- routine or cloud. An account in this state
  // cannot accept a poll slot, so the scheduler must skip it rather than
  // spending a tick on a refresh() that returns immediately.
  readonly property bool statusBusy: statusProcess.running
  property string statusText: "Checking…"
  property string syncDir: ""
  property string syncMode: "Two-way"
  property string clientVersion: ""
  property double resumeAt: 0
  property double lastSyncTs: 0
  property double usedBytes: 0
  property double quotaBytes: 0
  property bool quotaKnown: false
  property double quotaCheckedTs: 0
  property string quotaError: ""
  property string remoteStatus: "Not checked"
  property double syncStatusCheckedTs: 0
  property string syncStatusError: ""
  property double remoteCheckedTs: 0
  property string remoteError: ""
  property var files: []
  property var activity: []
  property string actionStatus: ""
  property string lastError: ""

  readonly property bool notificationsEnabled: {
    var value = setting("notifications", true)
    return value === true || String(value).toLowerCase() === "true"
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int recentFileLimit: intSetting("recentFileLimit", 20, 5, 50)
  readonly property string helperPath: Model.filePath(Qt.resolvedUrl("onedrive-status.py"))
  readonly property bool busy: statusProcess.running || controlProcess.running
    || cancelTimerProcess.running || scheduleTimerProcess.running
  readonly property bool cloudChecking: _activeCloudMode !== "" && statusProcess.running
  // A cloud check that is waiting for this account's routine poll to finish is
  // already holding the shared slot, even though no process is running for it
  // yet. Without this the coordinator saw "not busy" and started a second one.
  readonly property bool cloudPending: _cloudRequested !== ""
  // Which cloud mode this account occupies the shared slot with, running or
  // merely deferred, so the coordinator can recognise a duplicate request.
  readonly property string activeCloudMode: _activeCloudMode !== "" ? _activeCloudMode : _cloudRequested
  readonly property bool quotaChecking: _activeCloudMode === "quota" && statusProcess.running
  readonly property bool fullStatusChecking: _activeCloudMode === "sync-status" && statusProcess.running

  // Must match QUOTA_TIMEOUT_SECONDS / SYNC_STATUS_TIMEOUT_SECONDS in onedrive-status.py.
  readonly property int cloudTimeoutSec: 30
  // How long a routine poll may run before it is abandoned, and how long the
  // settle loop waits between asking for the result of a control. Both are
  // settings rather than constants only so the test harness can drive them in
  // milliseconds instead of minutes; nothing sets them in production.
  readonly property int statusTimeoutMs: intSetting("statusTimeoutMs",
    Math.max(60, cloudTimeoutSec * 2) * 1000, 200, 600000)
  readonly property int settleIntervalMs: intSetting("settleIntervalMs", 1200, 20, 60000)
  readonly property int cloudRetryAfterSec: 300

  property string _cloudRequested: ""
  property string _activeCloudMode: ""
  property string _statusOutput: ""
  property string _statusError: ""
  property string _controlOutput: ""
  property string _controlError: ""
  property string _timerOutput: ""
  property string _timerError: ""
  property string _afterTimerCancel: ""
  property int _pauseMinutes: 0
  property int _controlDesired: -1
  property bool _scheduleRecovery: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  // Drop everything derived from a previous config directory, keeping identity
  // and in-flight processes. The next poll repopulates it.
  // Discard whatever is in flight without touching what is on screen.
  //
  // The startup seed polls `onedrive.service` before discovery has told us its
  // config directory, so that poll uses the CLIENT's default. If the unit's
  // ExecStart names a different --confdir, the reply describes a different
  // account: its sync directory, quota and token state would be applied under
  // this one's name, and "Open folder" would open the wrong tree. Nothing is
  // displayed yet at that point, so there is no sample worth forgetting -- only
  // a reply worth refusing.
  function discardInFlight() {
    generation += 1
  }

  function forgetSample() {
    // Any reply already in flight was started under the previous config
    // directory; this makes onExited drop it.
    generation += 1
    sampleConfdir = ""
    initialized = false
    // A new identity has not been polled yet, whatever the old one had done.
    attempted = false
    actionStatus = ""
    // The displayed fields too: leaving these meant the panel showed the old
    // account's status and "Open folder" opened the PREVIOUS account's sync
    // directory -- the exact leak this function exists to prevent.
    syncDir = ""
    statusText = "Checking…"
    syncStage = ""
    syncMode = "Two-way"
    clientVersion = ""
    activeState = ""
    installed = false
    running = false
    enabled = false
    syncing = false
    serviceAvailable = false
    resumeAt = 0
    files = []
    activity = []
    quotaKnown = false
    usedBytes = 0
    quotaBytes = 0
    quotaCheckedTs = 0
    quotaError = ""
    remoteStatus = "Not checked"
    syncStatusCheckedTs = 0
    syncStatusError = ""
    remoteCheckedTs = 0
    remoteError = ""
    lastError = ""
    lastSyncTs = 0
    // Edge latches too: a condition that was true for the old directory must be
    // able to notify again for the new one.
    authenticated = false
    serviceFailed = false
    resyncRequired = false
    reauthRequired = false
    accountStateChanged()
  }

  function refresh(remote) {
    if (remote === true) {
      checkQuota()
      return
    }
    if (statusProcess.running || helperPath === "") return
    startStatusProcess("")
  }

  // Internal follow-up refreshes -- after a control command settles, or a
  // delayed re-read -- go through the coordinator's shared slot like everything
  // else. Calling refresh() directly from those timers started a second helper
  // while another account was mid-poll.
  function requestRefresh() {
    if (coordinator && coordinator.routinePollRunning()) return
    refresh(false)
  }

  function checkQuota() {
    requestCloud("quota")
  }

  // Opening the panel is explicit user intent, so a failed storage result
  // older than cloudRetryAfterSec is retried once on open. The decision is
  // deferred until the next status poll returns, because at open() time the
  // in-memory state may predate the poll the panel just started.
  // quotaCheckedTs updates even on failure, which blocks another retry until
  // the window passes. Verify sync is never retried automatically — it is
  // the expensive full-drive check and stays strictly manual.
  property bool _quotaRetryQueued: false

  function retryStaleQuotaOnOpen() {
    _quotaRetryQueued = true
  }

  function maybeRetryStaleQuota() {
    if (quotaError === "" || quotaChecking) return
    if (Date.now() / 1000 - quotaCheckedTs < cloudRetryAfterSec) return
    checkQuota()
  }

  function checkFullStatus() {
    requestCloud("sync-status")
  }

  // Cloud checks are slow and shared: the coordinator serialises them across
  // every account so two 30s checks cannot run at once. Without a coordinator
  // this account serves itself, which keeps Account usable on its own.
  function requestCloud(mode) {
    if (helperPath === "") return
    if (coordinator) {
      coordinator.requestCloud(root, mode)
      return
    }
    startCloudCheck(mode)
  }

  function startCloudCheck(mode) {
    if (helperPath === "") return
    if (statusProcess.running) {
      _cloudRequested = mode
      return
    }
    startStatusProcess(mode)
  }

  function startStatusProcess(cloudMode) {
    var command = Commands.status(helperPath, root, recentFileLimit, cloudMode)
    if (command.length === 0) {
      // This account cannot be described (a non-default service with no known
      // config directory). Starting a Process on an empty command would never
      // exit, so `refreshing` would stay true forever and the coordinator's
      // one-poll-at-a-time gate would freeze EVERY account permanently.
      attempted = true
      lastError = "This account's configuration directory is unknown"
      accountStateChanged()
      pollFinished(root.service)
      return
    }
    _activeCloudMode = cloudMode
    _statusOutput = ""
    _statusError = ""
    _pendingGeneration = generation
    _pollsStarted += 1
    _pendingPoll = _pollsStarted
    _statusRun += 1
    statusWatchdog.restart()
    refreshing = true
    if (cloudMode !== "") {
      actionStatusTimer.stop()
      actionStatus = (cloudMode === "quota" ? "Refreshing storage" : "Verifying sync")
        + "… may take up to " + String(cloudTimeoutSec) + "s"
    }
    statusProcess.command = command
    statusProcess.running = true
  }

  signal pollFinished(string service)
  signal transition(var event)
  // NOT named stateChanged: QQuickItem already has that as the NOTIFY signal for
  // `state`, so declaring it is an invalid override -- Qt warns once per account
  // per start and Item.state loses its change notification. qmllint does not
  // catch it. The design doc named it stateChanged; this is a deliberate
  // deviation.
  signal accountStateChanged()

  // Transitions are reported, not delivered. The coordinator batches whatever
  // arrives in one polling burst into at most one desktop notification, so three
  // accounts going wrong together do not produce three popups.
  function report(kind, summary, shortText, body, action) {
    transition({
      service: root.service,
      name: displayName,
      kind: kind,
      summary: summary,
      short: shortText,
      body: body,
      action: action || ""
    })
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError || "Failed to read OneDrive status"
      return
    }
    // The helper reports which config directory it actually read. A reply from a
    // different one describes a different account, and applying it would put
    // that account's sync directory, quota, token state and file list under this
    // account's name -- which is what the startup seed poll did whenever a unit
    // overrode the client's default directory.
    var reported = String(parsed.confdir || "")
    if (reported !== "" && confdir !== "" && reported !== confdir) {
      // Say so. A silent return leaves the account permanently on "Checking…"
      // with nothing to explain it, and if the two directories ever disagree for
      // a reason other than the startup race -- a normalisation difference, say
      // -- that is a bug that must be visible rather than a mystery.
      lastError = "OneDrive status came from " + reported + ", not " + confdir
      return
    }
    var wasFailed = serviceFailed
    var wasResync = resyncRequired
    var wasReauth = reauthRequired
    var hadAttention = serviceFailed || resyncRequired || reauthRequired
    var wasStorageSevere = Model.usageSevere(usedBytes, quotaBytes, quotaKnown)
    installed = parsed.installed === true
    serviceAvailable = parsed.serviceAvailable === true
    running = parsed.running === true
    enabled = parsed.enabled === true
    activeState = String(parsed.activeState || "")
    serviceFailed = parsed.serviceFailed === true
    resyncRequired = parsed.resyncRequired === true
    authenticated = parsed.authenticated === true
    reauthRequired = parsed.reauthRequired === true
    syncing = parsed.syncing === true
    syncStage = String(parsed.syncStage || "")
    _confirmedPoll = _pendingPoll
    sampleConfdir = reported
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    statusText = String(parsed.statusText || (installed ? "Sync paused" : "Not installed"))
    syncDir = String(parsed.syncDir || "")
    syncMode = String(parsed.syncMode || "Two-way")
    clientVersion = String(parsed.clientVersion || "")
    resumeAt = Number(parsed.resumeAt || 0)
    lastSyncTs = Number(parsed.lastSyncTs || 0)
    usedBytes = Number(parsed.usedBytes || 0)
    quotaBytes = Number(parsed.quotaBytes || 0)
    quotaKnown = parsed.quotaKnown === true
    quotaCheckedTs = Number(parsed.quotaCheckedTs || 0)
    quotaError = String(parsed.quotaError || "")
    remoteStatus = String(parsed.remoteStatus || "Not checked")
    syncStatusCheckedTs = Number(parsed.syncStatusCheckedTs || 0)
    syncStatusError = String(parsed.syncStatusError || "")
    remoteCheckedTs = Number(parsed.remoteCheckedTs || 0)
    remoteError = String(parsed.remoteError || "")
    files = parsed.files || []
    activity = parsed.activity || []
    lastError = String(parsed.lastError || "")
    // Last, and only once the whole snapshot is applied: this is the gate that
    // lets an account contribute to the aggregate, and opening it early would
    // publish default values as if they were a reading.
    initialized = true
    accountStateChanged()

    if (resyncRequired && !wasResync)
      report("resync", "OneDrive needs a resync", "Resync required",
        "Syncing stopped until the resync repair runs.", "repair")
    else if (serviceFailed && !wasFailed)
      report("failed", "OneDrive sync failed", "Sync failed",
        lastError !== "" ? lastError : "The OneDrive service entered a failed state.", "open")
    if (reauthRequired && !wasReauth)
      report("reauth", "OneDrive needs reauthentication", "Reauthentication required",
        "Sign in again to keep syncing.", "open")
    // Recovery is only meaningful for an account that was seen unhealthy first.
    if (hadAttention && !serviceFailed && !resyncRequired && !reauthRequired)
      report("recovered", "OneDrive recovered", "Recovered", "Syncing is healthy again.")
    if (!wasStorageSevere && Model.usageSevere(usedBytes, quotaBytes, quotaKnown))
      report("storage", "OneDrive storage almost full", "Almost full",
        Model.freeText(usedBytes, quotaBytes, quotaKnown) + " of "
          + Model.formatBytes(quotaBytes) + " remains.")
  }

  // Reached when the status process stopped without an exit -- it could not be
  // started, or the watchdog gave up on it. Everything onExited would have
  // released has to be released here too, or the account keeps the coordinator's
  // poll slot and no other account is ever polled again.
  function abandonStatus(run, reason) {
    // Not this invocation any more: the process was restarted before this
    // deferred callback ran, and settling now would abandon a live poll.
    if (run !== _statusRun || _statusSettledRun === run) return
    _statusSettledRun = run
    statusWatchdog.stop()
    refreshing = false
    if (_pendingGeneration === generation) {
      attempted = true
      lastError = reason
    }
    _activeCloudMode = ""
    _cloudRequested = ""
    _quotaRetryQueued = false
    accountStateChanged()
    pollFinished(root.service)
  }

  // In Model.js so it is testable; kept as a method because four handlers and
  // two bindings call it.
  function elideStatus(text) { return Model.elideStatus(text) }

  function login() {
    if (!installed) return
    Quickshell.execDetached(Commands.login(confdir))
    actionStatus = "Opened OneDrive login"
    actionStatusTimer.restart()
  }

  function reauthenticate() {
    if (!installed || running) return
    Quickshell.execDetached(Commands.login(confdir, "reauth"))
    actionStatus = "Opened OneDrive reauthentication"
    actionStatusTimer.restart()
  }

  function repairResync() {
    if (!installed || running || busy) return
    Quickshell.execDetached(Commands.login(confdir, "resync"))
    actionStatus = "Opened OneDrive resync repair"
    actionStatusTimer.restart()
  }

  function openWeb() {
    Quickshell.execDetached(["uwsm-app", "--", "xdg-open", "https://onedrive.live.com/"])
  }

  function pause() {
    if (busy) return
    _pauseMinutes = 0
    cancelResumeTimer("pause")
  }

  function pauseFor(minutes) {
    var requested = parseInt(String(minutes), 10)
    if (!isFinite(requested) || requested <= 0) return
    var duration = Math.max(5, Math.min(1440, requested))
    if (!installed || !serviceAvailable || !authenticated || busy
        || serviceFailed || resyncRequired || reauthRequired) return
    // No derivable resume unit means no timer can be scheduled for this account.
    // An untimed pause is honest; a timer that collides with another account is
    // not. Say so, or the user gets an indefinite pause from a button labelled
    // "4 hours".
    if (resumeUnit === "") {
      actionStatus = "Paused — no resume timer is available for this account"
      actionStatusTimer.restart()
      pause()
      return
    }
    _pauseMinutes = duration
    cancelResumeTimer("pause")
  }

  function resume() {
    if (!authenticated) {
      login()
      return
    }
    if (busy) return
    _pauseMinutes = 0
    cancelResumeTimer("resume")
  }

  function toggleRunning() {
    if (active) pause()
    else resume()
  }

  function runControl(command, desired) {
    if (!installed || !serviceAvailable || controlProcess.running) return
    _desired = desired
    _controlDesired = desired
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = command
    _controlRun += 1
    controlWatchdog.restart()
    controlProcess.running = true
  }

  function cancelResumeTimer(afterAction) {
    if (resumeUnit === "") {
      // Nothing to cancel, and "systemctl stop .timer .service" is not a command
      // worth sending. Continue straight to the action the cancel precedes.
      _afterTimerCancel = afterAction
      Qt.callLater(function() { root.afterResumeTimerCancelled() })
      return
    }
    _afterTimerCancel = afterAction
    _timerOutput = ""
    _timerError = ""
    cancelTimerProcess.command = Commands.cancelResume(resumeUnit)
    _cancelRun += 1
    cancelWatchdog.restart()
    cancelTimerProcess.running = true
  }

  function settleResumeTimerCancel(run) {
    if (run !== _cancelRun || _cancelSettledRun === run) return
    _cancelSettledRun = run
    cancelWatchdog.stop()
    afterResumeTimerCancelled()
  }

  // Shared by the cancel process and by the no-timer path, which has nothing to
  // cancel but must still perform the action the cancel precedes.
  function afterResumeTimerCancelled() {
    var action = _afterTimerCancel
    _afterTimerCancel = ""
    resumeAt = 0
    if (action === "resume") {
      runControl(Commands.control("start", root.service), 1)
    } else if (action === "pause") {
      if (running || active || activeState === "activating") {
        runControl(Commands.control("stop", root.service), 0)
      } else if (_pauseMinutes > 0) {
        var minutes = _pauseMinutes
        _pauseMinutes = 0
        scheduleResume(minutes)
      } else {
        requestRefresh()
      }
    }
  }

  function scheduleResume(minutes) {
    _timerOutput = ""
    _timerError = ""
    scheduleTimerProcess.command = Commands.scheduleResume(resumeUnit, service, minutes)
    _scheduleRun += 1
    scheduleWatchdog.restart()
    scheduleTimerProcess.running = true
  }

  function openFolder() {
    if (syncDir !== "") Quickshell.execDetached(["uwsm-app", "--", "xdg-open", syncDir])
  }

  function openFile(file) {
    if (!file || !file.path) return
    Quickshell.execDetached([
      "busctl", "--user", "call", "org.freedesktop.FileManager1",
      "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1",
      "ShowItems", "ass", "1", fileUri(String(file.path)), ""
    ])
  }

  function fileUri(path) {
    var parts = String(path || "").split("/")
    for (var index = 0; index < parts.length; index++) parts[index] = encodeURIComponent(parts[index])
    return "file://" + parts.join("/")
  }

  // No repeating poll timer here: the coordinator owns cadence, so N accounts
  // share one budget instead of each polling every refreshIntervalSec. The
  // timers that remain are per-account control flow -- settling after a control
  // command, and clearing transient action text.

  Timer {
    id: delayedRefresh
    interval: 750
    repeat: false
    onTriggered: root.requestRefresh()
  }

  // After a control succeeds, keep asking until a poll taken AFTER it lands.
  //
  // This used to give up after five ticks and clear the optimistic state
  // unconditionally. `requestRefresh` is drop-not-queue, so with two or three
  // accounts a neighbour holding the shared poll slot swallowed every one of
  // those five asks -- and six seconds after the user paused Work, the bar
  // reverted to "Monitoring" from a sample that predated the pause, while the
  // unit was really stopped. Reverting to known-stale data is strictly worse
  // than holding the user's intent, so the intent is now held until fresh truth
  // arrives (`applyStatus` clears it the moment reality agrees) or the account
  // gives up asking entirely.
  Timer {
    id: settleTimer
    property int ticks: 0
    property int baseline: 0
    // Whether this account is waiting to be told what a control actually did.
    // The coordinator gives it the next poll slot, so the answer arrives in one
    // round rather than never.
    readonly property bool waiting: running && root._confirmedPoll <= baseline
    interval: root.settleIntervalMs
    repeat: true
    onTriggered: {
      ticks += 1
      root.requestRefresh()
      if (root._confirmedPoll > baseline) {
        // A poll taken after the control has landed and applyStatus has had its
        // say. Anything still optimistic now is a genuine divergence.
        ticks = 0
        stop()
        root._desired = -1
      } else if (ticks >= 30) {
        // ~36s of a completely blocked slot. Stop asking, but leave the intent
        // alone: the next successful poll clears it through applyStatus.
        ticks = 0
        stop()
      }
    }
  }

  // A helper that never exits -- a wedged python3, an os.walk over a stalled
  // network mount -- held the single poll slot forever, and with it every other
  // account's polling. Nothing else in the stack bounds this: the helper's own
  // 30s limit covers only its outbound CLI calls, not its local directory scan.
  // The control processes need the same bound the poll has. `pause()` refuses
  // while `busy`, and `busy` is true for as long as one of these runs -- so a
  // `systemctl --user stop` that never exits (the user bus not yet back after a
  // suspend is the realistic way) left that account's Pause and Resume dead for
  // the rest of the session, recoverable only by restarting the bar.
  Timer {
    id: controlWatchdog
    interval: root.statusTimeoutMs
    repeat: false
    onTriggered: {
      if (root._controlSettledRun === root._controlRun) return
      var run = root._controlRun
      controlProcess.running = false
      root.settleControl(run, 124)
    }
  }

  Timer {
    id: cancelWatchdog
    interval: root.statusTimeoutMs
    repeat: false
    onTriggered: {
      if (root._cancelSettledRun === root._cancelRun) return
      var run = root._cancelRun
      cancelTimerProcess.running = false
      // The action the cancel precedes still goes ahead: an untimed pause is a
      // worse outcome than a stranded timer, but silently doing nothing at all
      // is worse than both.
      root.settleResumeTimerCancel(run)
    }
  }

  Timer {
    id: scheduleWatchdog
    interval: root.statusTimeoutMs
    repeat: false
    onTriggered: {
      if (root._scheduleSettledRun === root._scheduleRun) return
      var run = root._scheduleRun
      scheduleTimerProcess.running = false
      root.settleResumeSchedule(run, 124)
    }
  }

  Timer {
    id: statusWatchdog
    interval: root.statusTimeoutMs
    repeat: false
    onTriggered: {
      if (root._statusSettled) return
      // Assigning false terminates it in real Quickshell; the exit that follows
      // finds the process already settled and is ignored.
      var run = root._statusRun
      statusProcess.running = false
      root.abandonStatus(run, "OneDrive status check timed out")
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: root._statusOutput = text
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
      onStreamFinished: root._statusError = text
    }
    onRunningChanged: {
      // Ordering between `exited` and `running` is not ours to rely on, so defer:
      // by the time this runs, a real exit has already settled the process and
      // this is a no-op. Only a failure to start reaches abandonStatus.
      if (!running) {
        var run = root._statusRun
        Qt.callLater(function() {
          root.abandonStatus(run, "Could not run the OneDrive status helper")
        })
      }
    }
    onExited: function(exitCode) {
      if (root._statusSettledRun === root._statusRun) return
      root._statusSettledRun = root._statusRun
      statusWatchdog.stop()
      var cloudMode = root._activeCloudMode
      root.refreshing = false
      // Only a reply for the CURRENT identity counts as an attempt; a discarded
      // one would tell the ramp this account had been sampled when it has not.
      if (root._pendingGeneration === root.generation) root.attempted = true
      if (root._pendingGeneration !== root.generation) {
        // Started under a previous config directory. Applying it would restore
        // that directory's syncDir, quota and edge latches over the new
        // account's. Everything the normal path clears must still be cleared, or
        // a pending cloud request keeps holding the global semaphore until the
        // next routine poll.
        root._activeCloudMode = ""
        root._cloudRequested = ""
        root._quotaRetryQueued = false
        root.pollFinished(root.service)
        return
      }
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elideStatus(stderr || stdout || "Could not read OneDrive status")
      if (cloudMode !== "") {
        if (exitCode !== 0) root.actionStatus = root.lastError
        else if (cloudMode === "quota")
          root.actionStatus = root.quotaError === "" ? "Storage refreshed" : root.quotaError
        else root.actionStatus = root.syncStatusError === ""
          ? "Sync verified" : root.syncStatusError
        actionStatusTimer.restart()
      }
      root._activeCloudMode = ""
      if (root._cloudRequested !== "") {
        var requested = root._cloudRequested
        root._cloudRequested = ""
        // Back through the coordinator, not straight into startCloudCheck:
        // going direct released the shared slot and then took it again without
        // asking, which let a second account start its own check in between.
        Qt.callLater(function() { root.requestCloud(requested) })
      }
      if (root._quotaRetryQueued) {
        root._quotaRetryQueued = false
        Qt.callLater(function() { root.maybeRetryStaleQuota() })
      }
      root.pollFinished(root.service)
    }
  }

  Process {
    id: cancelTimerProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    // A cancel that cannot even start must still let the action it precedes
    // through, or pause and resume simply do nothing from then on.
    onRunningChanged: {
      if (!running) {
        var run = root._cancelRun
        Qt.callLater(function() { root.settleResumeTimerCancel(run) })
      }
    }
    onExited: function(exitCode) { root.settleResumeTimerCancel(root._cancelRun) }
  }

  function settleResumeSchedule(run, exitCode) {
    if (run !== _scheduleRun || _scheduleSettledRun === run) return
    _scheduleSettledRun = run
    scheduleWatchdog.stop()
    var stdout = String(timerStdout.text || _timerOutput || "")
    var stderr = String(timerStderr.text || _timerError || "")
    if (exitCode !== 0) {
      lastError = elideStatus(stderr || stdout || "Could not schedule OneDrive resume")
      actionStatus = "Timed pause failed; resuming syncing…"
      _scheduleRecovery = true
      // Recovery starts the SAME service the pause stopped.
      runControl(Commands.control("start", root.service), 1)
    } else {
      lastError = ""
      actionStatus = "Timed pause scheduled"
      actionStatusTimer.restart()
      requestRefresh()
    }
  }

  Process {
    id: scheduleTimerProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: timerStdout
      waitForEnd: true
      onStreamFinished: root._timerOutput = text
    }
    stderr: StdioCollector {
      id: timerStderr
      waitForEnd: true
      onStreamFinished: root._timerError = text
    }
    // systemd-run failing to START is the same outcome for the user as it
    // failing: the account is already stopped and nothing will resume it. Take
    // the recovery path rather than leaving it paused indefinitely.
    onRunningChanged: {
      if (!running) {
        var run = root._scheduleRun
        Qt.callLater(function() { root.settleResumeSchedule(run, 127) })
      }
    }
    onExited: function(exitCode) { root.settleResumeSchedule(root._scheduleRun, exitCode) }
  }

  function settleControl(run, exitCode) {
    if (run !== _controlRun || _controlSettledRun === run) return
    _controlSettledRun = run
    controlWatchdog.stop()
    var desired = root._controlDesired
    root._controlDesired = -1
    var stdout = String(controlStdout.text || root._controlOutput || "")
    var stderr = String(controlStderr.text || root._controlError || "")
    if (exitCode !== 0) {
      root._desired = -1
      root._pauseMinutes = 0
      root._scheduleRecovery = false
      root.lastError = root.elideStatus(stderr || stdout || "OneDrive service command failed")
    } else {
      root.lastError = ""
      settleTimer.ticks = 0
      // Every poll started from here on outranks this number; one started
      // before the control does not, however late it comes back.
      settleTimer.baseline = root._pollsStarted
      settleTimer.start()
      if (desired === 0 && root._pauseMinutes > 0) {
        var minutes = root._pauseMinutes
        root._pauseMinutes = 0
        root.scheduleResume(minutes)
      } else if (root._scheduleRecovery) {
        root._scheduleRecovery = false
        root.actionStatus = "Timed pause failed; syncing resumed"
        actionStatusTimer.restart()
      }
    }
    delayedRefresh.restart()
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: controlStdout
      waitForEnd: true
      onStreamFinished: root._controlOutput = text
    }
    stderr: StdioCollector {
      id: controlStderr
      waitForEnd: true
      onStreamFinished: root._controlError = text
    }
    // A control that could not start leaves the unit exactly as it was, so the
    // optimistic state has to be dropped -- otherwise the bar claims a pause
    // that never happened.
    onRunningChanged: {
      if (!running) {
        var run = root._controlRun
        Qt.callLater(function() { root.settleControl(run, 127) })
      }
    }
    onExited: function(exitCode) { root.settleControl(root._controlRun, exitCode) }
  }
}
