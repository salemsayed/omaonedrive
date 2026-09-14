const assert = require("node:assert")
const test = require("node:test")
const fs = require("node:fs")
const path = require("node:path")

const Commands = require("../Commands.js")
const Model = require("../Model.js")

const root = path.join(__dirname, "..")

const PLAIN = {
  service: "onedrive.service",
  instance: "",
  confdir: "/home/u/.config/onedrive",
  description: "OneDrive Client for Linux"
}
const DRAGONES = {
  service: "onedrive@dragones.service",
  instance: "dragones",
  confdir: "/home/u/.config/onedrive/accounts/dragones",
  description: "OneDrive sync (dragones account)"
}

test("resume units are collision-free and keep the legacy name for the plain service", () => {
  assert.equal(Commands.resumeUnit(""), "omaonedrive-resume")
  assert.equal(Commands.resumeUnit("dragones"), "omaonedrive-resume@dragones")
  assert.equal(Commands.resumeUnit("personal"), "omaonedrive-resume@personal")
  // Distinct instances can never collide on one unit name -- and the set has to
  // include the shapes that can actually collide, not just well-behaved ones.
  const units = ["", "dragones", "personal", "tandera"].map(Commands.resumeUnit)
  assert.equal(new Set(units).size, units.length)
})

test("an instance that cannot yield a safe timer yields none at all", () => {
  // systemd-run reads a --unit value ending in a unit suffix as THAT unit, so
  // instance "foo.timer" would derive the same timer as instance "foo" and one
  // account could cancel the other's pause. Refusing to derive is the safe
  // answer; the caller falls back to an untimed pause.
  assert.equal(Commands.resumeUnit("foo.timer"), "")
  assert.equal(Commands.resumeUnit("foo.service"), "")
  // ...and the collision it prevents:
  assert.notEqual(Commands.resumeUnit("foo"), Commands.resumeUnit("foo.timer"))

  // The derived name must fit systemd's 255-byte limit -- and systemd-run creates
  // BOTH a .timer and a .service, so the LONGER suffix is the binding one.
  // These two lengths are the band where the two rules disagree: checking only
  // ".timer" accepted them, and the account was then stopped by a pause whose
  // timer could not be scheduled.
  assert.equal(Commands.resumeUnit("x".repeat(229)), "", "229 must be refused (.service overflows)")
  assert.equal(Commands.resumeUnit("x".repeat(231)), "")
  const longest = Commands.resumeUnit("x".repeat(228))
  assert.notEqual(longest, "", "228 must still be accepted")
  assert.ok(longest.length + ".service".length <= 255)

  // Every derived timer name, across shapes, is unique or empty.
  const derived = ["", "foo", "foo.timer", "foo.service", "bar", "x".repeat(231)]
    .map(Commands.resumeUnit).filter(unit => unit !== "")
  assert.equal(new Set(derived).size, derived.length)
})

test("a status command omits a resume unit it could not derive", () => {
  // Passing nothing is right: the helper then reports no resume time, rather
  // than one belonging to a different account.
  const command = Commands.status("/p/h.py",
    { service: "onedrive@foo.timer.service", instance: "foo.timer", confdir: "/c" }, 20)
  assert.ok(!command.includes("--resume-unit"), command.join(" "))
  assert.ok(!command.includes(""), command.join(" "))
})

test("control vectors name the account's own service", () => {
  assert.deepEqual(
    Commands.control("stop", "onedrive@dragones.service"),
    ["systemctl", "--user", "stop", "onedrive@dragones.service"])
  assert.deepEqual(
    Commands.control("start", "onedrive.service"),
    ["systemctl", "--user", "start", "onedrive.service"])
})

test("interactive flows carry the account's own confdir", () => {
  assert.deepEqual(Commands.login(DRAGONES.confdir),
    ["omarchy-launch-terminal", "onedrive", "--confdir", DRAGONES.confdir])
  assert.deepEqual(Commands.login(DRAGONES.confdir, "reauth"),
    ["omarchy-launch-terminal", "onedrive", "--confdir", DRAGONES.confdir, "--reauth"])
  assert.deepEqual(Commands.login(DRAGONES.confdir, "resync"),
    ["omarchy-launch-terminal", "onedrive", "--confdir", DRAGONES.confdir, "--sync", "--resync"])
})

test("an unspecified confdir is omitted from the interactive flows too", () => {
  // Reachable before discovery supplies an identity: the seeded fallback
  // descriptor has no confdir. "--confdir ''" is not the same as no --confdir --
  // the client would reject it -- and the old code ran a plain `onedrive` here.
  assert.deepEqual(Commands.login(""), ["omarchy-launch-terminal", "onedrive"])
  assert.deepEqual(Commands.login("", "reauth"),
    ["omarchy-launch-terminal", "onedrive", "--reauth"])
  assert.deepEqual(Commands.login("", "resync"),
    ["omarchy-launch-terminal", "onedrive", "--sync", "--resync"])
  assert.deepEqual(Commands.login(null), ["omarchy-launch-terminal", "onedrive"])
  // No builder may ever emit an empty argument.
  for (const vector of [Commands.login(""), Commands.login("", "reauth"),
                        Commands.status("/p/h.py", {}, 20)]) {
    for (const argument of vector) assert.notEqual(argument, "", vector.join(" "))
  }
})

test("the plain account sends exactly today's command", () => {
  // Before discovery supplies an identity, and for the plain service afterwards,
  // the helper's own defaults ARE the single-account behaviour. Sending the
  // default service or an empty confdir explicitly would be noise at best and,
  // for an empty confdir, rejected by the helper's absolute-path rule.
  assert.deepEqual(
    Commands.status("/p/h.py", { service: "onedrive.service", instance: "", confdir: "" }, 20),
    ["python3", "/p/h.py", "--limit", "20"])
  assert.deepEqual(
    Commands.status("/p/h.py", {}, 20),
    ["python3", "/p/h.py", "--limit", "20"])
  // ...but a discovered plain account still passes its real confdir.
  assert.deepEqual(
    Commands.status("/p/h.py", PLAIN, 20),
    ["python3", "/p/h.py", "--confdir", PLAIN.confdir, "--limit", "20"])
})

test("a non-default account with no confdir is not polled at all", () => {
  // The helper independently re-derives the confdir in this case, so this is
  // belt-and-braces -- but depending on that means the widget would silently
  // report the DEFAULT account's token, quota and files under this account's
  // name if that guard were ever relaxed. An empty command means "show nothing".
  assert.deepEqual(
    Commands.status("/p/h.py", { service: "onedrive@x.service", instance: "x", confdir: "" }, 20),
    [])
  // The plain service is unaffected: its default IS the correct behaviour.
  assert.deepEqual(
    Commands.status("/p/h.py", { service: "onedrive.service", instance: "", confdir: "" }, 20),
    ["python3", "/p/h.py", "--limit", "20"])
})

test("an empty status command is a refusal the caller must handle", () => {
  // This shape bricked the widget once: startStatusProcess assigned the empty
  // vector to a Process and set running = true. An empty command never launches,
  // so onExited never fired, `refreshing` stayed true forever, and the
  // coordinator's one-poll-at-a-time gate then froze EVERY account permanently.
  // Account.startStatusProcess must bail before touching any state.
  const refused = Commands.status("/p/h.py",
    { service: "onedrive@x.service", instance: "x", confdir: "" }, 20)
  assert.deepEqual(refused, [])
  assert.equal(refused.length, 0)

  const source = fs.readFileSync(path.join(root, "Account.qml"), "utf8")
  const fn = source.slice(source.indexOf("function startStatusProcess"))
  const body = fn.slice(0, fn.indexOf("\n  }"))
  // The guard must come before `refreshing = true`, or the state is already
  // corrupted by the time we return.
  const guard = body.indexOf("command.length === 0")
  const setsRefreshing = body.indexOf("refreshing = true")
  assert.ok(guard !== -1, "startStatusProcess has no empty-command guard")
  assert.ok(guard < setsRefreshing,
    "the empty-command guard must precede `refreshing = true`")
})

test("the status command is account-complete", () => {
  const command = Commands.status("/p/onedrive-status.py", DRAGONES, 20)
  assert.deepEqual(command, [
    "python3", "/p/onedrive-status.py",
    "--service", "onedrive@dragones.service",
    "--confdir", DRAGONES.confdir,
    "--resume-unit", "omaonedrive-resume@dragones",
    "--limit", "20"
  ])
  // The three identity flags must agree with each other on every invocation.
  assert.equal(command[command.indexOf("--service") + 1], DRAGONES.service)
  assert.equal(command[command.indexOf("--confdir") + 1], DRAGONES.confdir)
  assert.equal(command[command.indexOf("--resume-unit") + 1],
    Commands.resumeUnit(DRAGONES.instance))
})

test("cloud modes add exactly one flag, in the right place", () => {
  // Exact vectors, not membership: a stray extra flag would make a quota
  // refresh also run the slow full-drive check, and membership cannot see that.
  const base = ["python3", "/p/h.py", "--confdir", PLAIN.confdir, "--limit", "5"]
  assert.deepEqual(Commands.status("/p/h.py", PLAIN, 5), base)
  assert.deepEqual(Commands.status("/p/h.py", PLAIN, 5, "quota"), base.concat(["--quota"]))
  assert.deepEqual(Commands.status("/p/h.py", PLAIN, 5, "sync-status"), base.concat(["--sync-status"]))
  // An unknown mode adds nothing rather than guessing.
  assert.deepEqual(Commands.status("/p/h.py", PLAIN, 5, "nonsense"), base)
})

test("a timed pause cancels and schedules only its own account", () => {
  const unit = Commands.resumeUnit(DRAGONES.instance)
  assert.deepEqual(Commands.cancelResume(unit),
    ["systemctl", "--user", "stop",
      "omaonedrive-resume@dragones.timer", "omaonedrive-resume@dragones.service"])

  const schedule = Commands.scheduleResume(unit, DRAGONES.service, 15)
  assert.deepEqual(schedule, [
    "systemd-run", "--user",
    "--unit=omaonedrive-resume@dragones",
    "--description=Resume OneDrive after timed pause",
    "--on-active=15m",
    "--timer-property=AccuracySec=1s",
    "--collect",
    "/usr/bin/systemctl", "--user", "start", "onedrive@dragones.service"
  ])
  // The timer must start the same service the pause stopped.
  assert.equal(schedule[schedule.length - 1], DRAGONES.service)
  // ...and must not mention any other account.
  assert.ok(!schedule.join(" ").includes("personal"))
})

test("the plain service keeps today's exact vectors", () => {
  const unit = Commands.resumeUnit(PLAIN.instance)
  assert.deepEqual(Commands.cancelResume(unit),
    ["systemctl", "--user", "stop", "omaonedrive-resume.timer", "omaonedrive-resume.service"])
  assert.deepEqual(Commands.scheduleResume(unit, PLAIN.service, 60), [
    "systemd-run", "--user",
    "--unit=omaonedrive-resume",
    "--description=Resume OneDrive after timed pause",
    "--on-active=60m",
    "--timer-property=AccuracySec=1s",
    "--collect",
    "/usr/bin/systemctl", "--user", "start", "onedrive.service"
  ])
})

test("--resync appears only in the interactive terminal vector", () => {
  // Every non-interactive builder, exercised, must be free of the mutating flags.
  const vectors = [
    Commands.status("/p/h.py", DRAGONES, 20),
    Commands.status("/p/h.py", DRAGONES, 20, "quota"),
    Commands.status("/p/h.py", DRAGONES, 20, "sync-status"),
    Commands.listAccounts("/p/h.py"),
    Commands.control("start", DRAGONES.service),
    Commands.control("stop", DRAGONES.service),
    Commands.cancelResume(Commands.resumeUnit(DRAGONES.instance)),
    Commands.scheduleResume(Commands.resumeUnit(DRAGONES.instance), DRAGONES.service, 15),
    Commands.notify("normal", "s", "b")
  ]
  for (const vector of vectors) {
    const joined = vector.join(" ")
    assert.ok(!joined.includes("--resync"), joined)
    assert.ok(!joined.includes("--logout"), joined)
  }
  // ...and it must actually BE there. Without this, deleting the push in
  // Commands.login leaves the test green while Repair silently stops repairing.
  const repair = Commands.login(DRAGONES.confdir, "resync")
  assert.equal(repair[0], "omarchy-launch-terminal")
  assert.ok(repair.includes("--resync"), repair.join(" "))
  assert.ok(repair.includes("--sync"), repair.join(" "))
})

test("only the interactive vector may carry a mutating token", () => {
  // Token-level, not substring: the old shell grep banned a bare --sync as well
  // as --resync and --logout, and "--sync-status" must not false-positive. A new
  // builder that leaked one of these would otherwise pass every other check.
  const FORBIDDEN = ["--sync", "--resync", "--logout", "--reauth"]
  const nonInteractive = {
    status: Commands.status("/p/h.py", DRAGONES, 20),
    statusQuota: Commands.status("/p/h.py", DRAGONES, 20, "quota"),
    statusSync: Commands.status("/p/h.py", DRAGONES, 20, "sync-status"),
    listAccounts: Commands.listAccounts("/p/h.py"),
    controlStart: Commands.control("start", DRAGONES.service),
    controlStop: Commands.control("stop", DRAGONES.service),
    cancelResume: Commands.cancelResume("omaonedrive-resume@dragones"),
    scheduleResume: Commands.scheduleResume("omaonedrive-resume@dragones", DRAGONES.service, 15),
    notify: Commands.notify("normal", "s", "b")
  }
  for (const [name, vector] of Object.entries(nonInteractive)) {
    for (const token of vector) {
      assert.ok(!FORBIDDEN.includes(token), name + " leaked " + token)
    }
  }
  // --sync-status is a distinct token and must survive the check above.
  assert.ok(nonInteractive.statusSync.includes("--sync-status"))
})

test("no builder ever produces a shell invocation", () => {
  const vectors = [
    Commands.status("/p/h.py", DRAGONES, 20),
    Commands.listAccounts("/p/h.py"),
    Commands.control("start", DRAGONES.service),
    Commands.login(DRAGONES.confdir, "reauth"),
    Commands.cancelResume("omaonedrive-resume"),
    Commands.scheduleResume("omaonedrive-resume", PLAIN.service, 5),
    Commands.notify("critical", "s", "b", { id: "resync", label: "Run resync repair" })
  ]
  for (const vector of vectors) {
    assert.ok(Array.isArray(vector))
    for (const argument of vector) assert.equal(typeof argument, "string")
    assert.ok(!["sh", "bash", "/bin/sh", "/bin/bash", "env"].includes(vector[0]), vector[0])
    assert.ok(!vector.includes("-c"), vector.join(" "))
  }
})

test("the source itself contains no shell construction", () => {
  const source = fs.readFileSync(path.join(root, "Commands.js"), "utf8")
  assert.ok(!/\bbash\b|\bsh -c\b|execDetached\(\s*"/.test(source))
})

test("account names are labels, not systemd sentences", () => {
  assert.equal(Model.accountName("dragones"), "Dragones")
  assert.equal(Model.accountName("personal"), "Personal")
  assert.equal(Model.accountName("work-mail"), "Work Mail")
  assert.equal(Model.accountName("work_mail"), "Work Mail")
  // The plain service has no instance and keeps today's identity.
  assert.equal(Model.accountName("", "OneDrive Client for Linux"), "OneDrive")
  assert.equal(Model.accountName(null), "OneDrive")
})

test("notification actions preserve both daemon support and their account", () => {
  for (const [behavior, method, account] of [
    ["repair", "repairAccount", "onedrive@work.service"],
    ["open", "openAccount", "onedrive@personal.service"]
  ]) {
    const command = Commands.notify("critical", "Needs attention", "Body <text>.",
      behavior, account, "/x/omaonedrive-click")
    assert.equal(command[0], "/x/omaonedrive-click")
    const action = ["omarchy-shell", "io.github.salemsayed.omaonedrive", method, account]
    assert.deepEqual(JSON.parse(command[1]), action)
    const notify = JSON.parse(command[2])
    assert.deepEqual(notify, ["notify-send", "-a", "OmaOneDrive", "-u", "critical",
      "--hint", "string:omarchy-exec-argv:" + JSON.stringify(action),
      "Needs attention", "Body <text>."])
    assert.ok(!notify.includes("--action"))
    assert.ok(!notify.includes("--selected-action-fd"))
  }
  // No behaviour, no exec: the recovered/storage popups are informational.
  assert.deepEqual(
    Commands.notify("normal", "OneDrive recovered", "Sync is healthy.", "", ""),
    ["omarchy-notification-send", "--app-name", "OmaOneDrive", "--urgency", "normal",
     "OneDrive recovered", "Sync is healthy."])
  // A behaviour with no account degrades to the accountless IPC calls, which
  // act on the selected account -- today's single-account behaviour.
  assert.deepEqual(Commands.notificationExec("open", ""),
    ["omarchy-shell", "io.github.salemsayed.omaonedrive", "open"])
  assert.deepEqual(Commands.notificationExec("repair", ""),
    ["omarchy-shell", "io.github.salemsayed.omaonedrive", "resync"])
  // An unrecognised behaviour is a closed door, not a command.
  assert.deepEqual(Commands.notificationExec("arbitrary user input", "x"), [])
  assert.deepEqual(Commands.notificationExec("", "onedrive@a.service"), [])
})
