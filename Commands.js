// Command vectors for one OneDrive account.
//
// Every function returns an argv array. Nothing here is ever passed through a
// shell, and no value is interpolated into a string that becomes a command --
// that is the invariant `docs/ARCHITECTURE.md` states and that
// `tests/Commands.test.js` pins with exact-array assertions.
//
// Each account is identified by its systemd service, its config directory, and
// the instance parsed out of the service name. Nothing is derived from a naming
// convention: the confdir comes from the helper's discovery, which reads it out
// of each unit's own ExecStart.

var DEFAULT_SERVICE = "onedrive.service"
var DEFAULT_RESUME_UNIT = "omaonedrive-resume"
// Must match BarWidget.qml's moduleName: notification clicks are delivered by
// Omarchy's notification daemon running `omarchy-shell <target> <function>`,
// long after this process may have restarted. tests/PanelWiring.test.js pins
// the two files against each other.
var IPC_TARGET = "io.github.salemsayed.omaonedrive"

// The plain service deliberately keeps the legacy unit name, so a timer that is
// already in flight survives an upgrade and stays visible and cancellable.
//
// Returns "" when no usable resume unit can be derived. The caller degrades to
// an untimed pause rather than scheduling a timer that would collide with
// another account's or that systemd would refuse.
function resumeUnit(instance) {
  var value = String(instance || "")
  if (value === "") return DEFAULT_RESUME_UNIT
  // systemd-run reads a --unit value ending in a unit suffix as THAT unit, so
  // instance "foo.timer" would derive the same timer as instance "foo" -- and
  // cancelling it would target "…foo.timer.timer", which does not exist,
  // stranding the other account's pause.
  if (value.endsWith(".timer") || value.endsWith(".service")) return ""
  var unit = DEFAULT_RESUME_UNIT + "@" + value
  // systemd-run creates a .timer AND a .service, so the longer suffix is what
  // has to fit. Checking only .timer let a 230-character instance stop the
  // account and then fail to schedule its resume.
  if (unit.length + ".service".length > 255) return ""
  return unit
}

// The status call is account-complete: every invocation names the service, the
// config directory and the resume unit, so no part of the answer can be about a
// different account. `mode` is "" for the routine local poll, or "quota" /
// "sync-status" for an explicit cloud check.
function status(helperPath, account, recentFileLimit, mode) {
  var command = ["python3", String(helperPath)]
  // An empty value means "unspecified", not "empty string": the helper's own
  // defaults are the single-account behaviour, so before discovery has supplied
  // an identity this produces exactly the command the widget sends today.
  var service = String(account.service || "")
  var confdir = String(account.confdir || "")
  var instance = String(account.instance || "")
  if (service !== "" && service !== DEFAULT_SERVICE) {
    command.push("--service", service)
  }
  if (confdir !== "") command.push("--confdir", confdir)
  // A non-default account with no confdir must not be polled at all. The helper
  // independently re-derives the confdir in that case, so this is belt-and-
  // braces -- but relying on that means the widget silently reports the DEFAULT
  // account's token, quota and files under this account's name if the helper
  // guard is ever relaxed. Refuse instead, and let the caller show nothing.
  else if (service !== "" && service !== DEFAULT_SERVICE) return []
  var unit = instance === "" ? "" : resumeUnit(instance)
  if (unit !== "") command.push("--resume-unit", unit)
  command.push("--limit", String(recentFileLimit))
  if (mode === "quota") command.push("--quota")
  else if (mode === "sync-status") command.push("--sync-status")
  return command
}

function listAccounts(helperPath) {
  return ["python3", String(helperPath), "--list-accounts"]
}

function control(action, service) {
  return ["systemctl", "--user", String(action), String(service)]
}

// The interactive CLI flows are the only place --resync may appear, and only
// through omarchy-launch-terminal, where the client prompts for confirmation.
function login(confdir, mode) {
  var command = ["omarchy-launch-terminal", "onedrive"]
  // Same rule as status(): an unspecified confdir means the client's own
  // default, not an empty string. Passing "--confdir ''" would hand the CLI a
  // value it must reject, and this path is reachable before discovery has
  // supplied an identity.
  if (String(confdir || "") !== "") command.push("--confdir", String(confdir))
  if (mode === "reauth") command.push("--reauth")
  else if (mode === "resync") {
    command.push("--sync")
    command.push("--resync")
  }
  return command
}

// Cancel only this account's timer and service; another account's pause is
// untouched.
function cancelResume(unit) {
  return ["systemctl", "--user", "stop", unit + ".timer", unit + ".service"]
}

// On expiry the timer starts the SAME service the pause stopped.
function scheduleResume(unit, service, minutes) {
  return [
    "systemd-run", "--user",
    "--unit=" + unit,
    "--description=Resume OneDrive after timed pause",
    "--on-active=" + String(minutes) + "m",
    "--timer-property=AccuracySec=1s",
    "--collect",
    "/usr/bin/systemctl", "--user", "start", String(service)
  ]
}

// The click command a notification carries, as a closed argv set. Omarchy's
// notification daemon persists this and runs it on click, so it works after a
// shell or plugin reload -- unlike the old notify-send stdout tracking, which
// died with the process that spawned it. The account rides along as its own
// argv element; nothing user-controlled is ever joined into a command string.
function notificationExec(behavior, service) {
  var target = String(service || "")
  if (behavior === "open") {
    if (target === "") return ["omarchy-shell", IPC_TARGET, "open"]
    return ["omarchy-shell", IPC_TARGET, "openAccount", target]
  }
  if (behavior === "repair") {
    if (target === "") return ["omarchy-shell", IPC_TARGET, "resync"]
    return ["omarchy-shell", IPC_TARGET, "repairAccount", target]
  }
  return []
}

// Preserve both Omarchy's persisted hint and the standard notification action.
// The detached helper keeps the action alive and carries the account as argv.
function notify(urgency, summary, body, behavior, service, clickHelper) {
  var actionArgv = notificationExec(behavior, service)
  if (actionArgv.length === 0 || !clickHelper) {
    return [
      "omarchy-notification-send", "--app-name", "OmaOneDrive", "--urgency", urgency,
      summary, body
    ]
  }
  // The action and its file descriptor belong to the helper, which owns this
  // notification's lifetime; they are not set here.
  var notifyArgv = [
    "notify-send", "-a", "OmaOneDrive", "-u", urgency,
    "--hint", "string:omarchy-exec-argv:" + JSON.stringify(actionArgv),
    summary, body
  ]
  return [clickHelper, JSON.stringify(actionArgv), JSON.stringify(notifyArgv)]
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_SERVICE: DEFAULT_SERVICE,
    DEFAULT_RESUME_UNIT: DEFAULT_RESUME_UNIT,
    IPC_TARGET: IPC_TARGET,
    notificationExec: notificationExec,
    resumeUnit: resumeUnit,
    status: status,
    listAccounts: listAccounts,
    control: control,
    login: login,
    cancelResume: cancelResume,
    scheduleResume: scheduleResume,
    notify: notify
  }
}
