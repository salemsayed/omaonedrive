const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")
const test = require("node:test")

// BarWidget.qml and Panel.qml derive from the bar's own types, so neither can be
// instantiated headless and neither is reachable by the QML harness. A reviewer
// showed what regex assertions cost there: with `assert.match` alone, the broken
// "one missing account dims a healthy bar" expression could be restored, the IPC
// handlers given early returns, and Panel.open()'s selection call wrapped in
// `if (false)` -- all with the entire suite green, because a regex only proves
// the text appears SOMEWHERE.
//
// So these compare the whole decision, exactly. Every rule is tested for real in
// Model.js; what is pinned here is that these two files do nothing but delegate
// to it. That makes them brittle by design: if you change the wiring, change the
// expectation below, and the diff will say what the bar's behaviour now is.

function occurrences(text, needle) {
  let count = 0
  let at = text.indexOf(needle)
  while (at !== -1) {
    count += 1
    at = text.indexOf(needle, at + needle.length)
  }
  return count
}

const root = path.join(__dirname, "..")
const barWidget = readFileSync(path.join(root, "BarWidget.qml"), "utf8")
const panel = readFileSync(path.join(root, "Panel.qml"), "utf8")

// Comments are stripped so wording changes do not break the test; everything
// else -- including an added `if (false)` or an early return -- does.
//
// Both markers must be UNIQUE. A reviewer defeated an earlier version of this
// by adding a string property containing the expected text: indexOf found the
// decoy, the comparison passed, and the live wiring below it was wrong.
function code(source, from, to) {
  assert.equal(occurrences(source, from), 1,
    "marker is not unique, so this test can be spoofed: " + from)
  const start = source.indexOf(from)
  const end = source.indexOf(to, start + from.length)
  assert.notEqual(end, -1, "could not find: " + to)
  assert.equal(occurrences(source.slice(start), to), 1,
    "end marker is not unique after the start: " + to)
  return source
    .slice(start, end)
    .split("\n")
    .map(line => line.replace(/(^|\s)\/\/.*$/, ""))
    .join(" ")
    .replace(/\s+/g, " ")
    .trim()
}

test("the bar's state is Model's answer, unmodified", () => {
  // Nothing may be recomputed, overridden or short-circuited on the way to the
  // icon. Every one of these rules is table-tested in Aggregate.test.js.
  assert.equal(
    code(barWidget, "readonly property var barState:", "readonly property color iconColor:"),
    'readonly property var barState: Model.barState(aggregate) ' +
    'readonly property bool active: barState.active ' +
    'readonly property bool syncing: barState.syncing ' +
    'readonly property bool installed: barState.installed')
})

test("the badge follows the worst account's kind, pause included", () => {
  // Worst-first, pause included -- the user's decision: a paused account
  // anywhere is a state the bar must show, and every account has to be working
  // before it looks normal.
  assert.equal(
    code(barWidget, "readonly property string badgeKind:", "readonly property color badgeColor:"),
    'readonly property string badgeKind: Model.badgeKind(aggregate.kind) ' +
    'readonly property string badgeGlyph: Model.badgeGlyph(badgeKind)')
})

test("the aggregate comes from the service, with a checking placeholder", () => {
  assert.equal(
    code(barWidget, "readonly property var aggregate:", "readonly property int accountCount:"),
    'readonly property var aggregate: service ? service.aggregate ' +
    ': ({ kind: "checking", count: 0, anyActive: false, initialized: false })')
})

test("the IPC account handlers delegate and do nothing else", () => {
  assert.equal(
    code(barWidget, "function accounts(): string", "function selectAccount(target: string)"),
    'function accounts(): string { if (!root.service) return "[]" ' +
    'return JSON.stringify(Model.accountRows(root.service.accounts, root.service.selectedService)) }')
  assert.equal(
    code(barWidget, "function selectAccount(target: string)", "function openAccount"),
    'function selectAccount(target: string): string { if (!root.service) return "no accounts" ' +
    'var found = Model.resolveAccountTarget(root.service.accounts, target) ' +
    'if (found === "") return "unknown account: " + target ' +
    // false: automation must not inherit the panel's stale-quota retry, which
    // contacts Microsoft.
    'root.service.selectAccount(found, false) return "ok" }')
  // The notification click handlers: the daemon delivers a click as a fresh
  // `omarchy-shell <target> openAccount|repairAccount <service>` invocation,
  // so these two ARE the click behaviour. Substance lives in Service.qml where
  // the harness drives it; here only the delegation is pinned.
  assert.equal(
    code(barWidget, "function openAccount(target: string)", "function repairAccount"),
    'function openAccount(target: string): string ' +
    // Open first: Panel.open()'s selectBadgedAccount may move the selection,
    // and the popup's account is the user's explicit choice -- it lands last.
    '{ root.open(target) return "ok" }')
  assert.equal(
    code(barWidget, "function repairAccount(target: string)", "\n  }\n\n  BarIconButton"),
    'function repairAccount(target: string): string ' +
    '{ if (root.service) root.service.repairFromNotification(target) return "ok" }')
})

test("opening the panel selects the badged account first, then refreshes", () => {
  // Order matters: the panel's bindings and its refresh both read the selection.
  assert.equal(
    code(panel, "function open(accountTarget) {", "Qt.callLater"),
    'function open(accountTarget) { root.controller.show() ' +
    'var fromNotification = typeof accountTarget === "string" && accountTarget !== "" ' +
    'if (fromNotification) oneDrive.openFromNotification(accountTarget) ' +
    'else oneDrive.selectBadgedAccount() oneDrive.refreshSelected() ' +
    'if (!fromNotification) oneDrive.retryStaleQuotaOnOpen()')
})

test("every IPC control routes to the coordinator, and none of them to another one", () => {
  // A reviewer changed IPC `resync()` to call pause() and the whole suite stayed
  // green: only five hand-picked regions were pinned, and this was not one. The
  // fix is to pin the WHOLE handler -- fourteen one-line delegations, each of
  // which is a command a script can run against the user's real account.
  const handler = code(barWidget, "IpcHandler {", "\n  }\n\n  BarIconButton")
  assert.equal(handler,
    'IpcHandler { enabled: root.ipcRegistrationReady target: root.moduleName ' +
    'function open(): void { root.open() } ' +
    'function close(): void { root.close() } ' +
    'function show(): void { root.open() } ' +
    'function hide(): void { root.close() } ' +
    'function toggle(): void { root.togglePanel() } ' +
    'function refresh(): string { if (root.service) root.service.refresh(false) return "ok" } ' +
    'function check(): string { if (root.service) root.service.checkQuota() return "ok" } ' +
    'function fullStatus(): string { if (root.service) root.service.checkFullStatus() return "ok" } ' +
    'function pause(): string { return root.service ? root.service.pause() : "no accounts" } ' +
    'function pauseFor(minutes: int): string { return root.service ? root.service.pauseFor(minutes) : "no accounts" } ' +
    'function resume(): string { return root.service ? root.service.resume() : "no accounts" } ' +
    'function toggleSync(): string { return root.service ? root.service.toggleRunning() : "no accounts" } ' +
    'function folder(): string { if (root.service) root.service.openFolder() return "ok" } ' +
    'function web(): string { if (root.service) root.service.openWeb() return "ok" } ' +
    'function resync(): string { if (root.service) root.service.repairResync() return "ok" } ' +
    'function status(): string { return root.service ? root.service.statusText : "Checking…" } ' +
    'function accounts(): string { if (!root.service) return "[]" ' +
    'return JSON.stringify(Model.accountRows(root.service.accounts, root.service.selectedService)) } ' +
    'function selectAccount(target: string): string { if (!root.service) return "no accounts" ' +
    'var found = Model.resolveAccountTarget(root.service.accounts, target) ' +
    'if (found === "") return "unknown account: " + target ' +
    'root.service.selectAccount(found, false) return "ok" } ' +
    'function openAccount(target: string): string ' +
    '{ root.open(target) return "ok" } ' +
    'function repairAccount(target: string): string ' +
    '{ if (root.service) root.service.repairFromNotification(target) return "ok" }')
})

test("a composed notification reaches Commands.notify with its own account", () => {
  // Upstream pinned its durable-click call site with a static test that runs in
  // CI (node-only, no Qt); the harness equivalent is skipped wherever qml6 is
  // absent, so without this pin a mutation that drops the behaviour or the
  // account from the exec hint -- or swaps summary and body, or hardcodes the
  // urgency -- keeps CI green. The harness still proves the behaviour end to
  // end; this makes the CI tier see it too.
  const service = readFileSync(path.join(root, "Service.qml"), "utf8")
  const at = service.indexOf("function flushTransitions()")
  assert.notEqual(at, -1)
  const body = service.slice(at, service.indexOf("\n  }", at))
    .split("\n").map(line => line.replace(/(^|\s)\/\/.*$/, "")).join(" ")
    .replace(/\s+/g, " ").trim()
  assert.ok(body.endsWith(
    "Quickshell.execDetached(Commands.notify( " +
    "composed.urgency, composed.summary, composed.body, " +
    "composed.action, composed.service, clickHelperPath))"), body)
})

test("the notification exec target and the IPC registration are the same name", () => {
  // Commands.js bakes the omarchy-shell target into every notification's exec
  // hint; BarWidget.qml registers the IpcHandler under moduleName. If they ever
  // drift, every notification click silently reaches nothing.
  const commands = readFileSync(path.join(root, "Commands.js"), "utf8")
  const constant = commands.match(/var IPC_TARGET = "([^"]+)"/)
  assert.ok(constant, "Commands.js must declare IPC_TARGET")
  assert.match(barWidget,
    new RegExp('moduleName: "' + constant[1].replace(/\./g, "\\.") + '"'))
})

test("no surface renders helper or file data as rich text", () => {
  // From upstream 1.5.6, widened to our extra files: every Text in the
  // presentation layer declares PlainText, so markup-shaped filenames cannot
  // execute as markup anywhere -- not only at the boundaries inheritedPlainText
  // already guards.
  for (const name of ["Panel.qml", "StatusBadge.qml", "BarWidget.qml"]) {
    const source = readFileSync(path.join(root, name), "utf8")
    const textItems = source.match(/\bText\s*\{/g) || []
    const plainTexts = source.match(/\bText\s*\{\s*\n\s*textFormat:\s*Text\.PlainText\b/g) || []
    assert.equal(plainTexts.length, textItems.length,
      name + ": every Text must declare textFormat: Text.PlainText")
    const headers = source.match(/\bPanelSectionHeader\s*\{/g) || []
    const plainHeaders = source.match(/\bPanelSectionHeader\s*\{\s*\n\s*textFormat:\s*Text\.PlainText\b/g) || []
    assert.equal(plainHeaders.length, headers.length,
      name + ": every PanelSectionHeader must declare textFormat: Text.PlainText")
  }
  const panel = readFileSync(path.join(root, "Panel.qml"), "utf8")
  assert.ok((panel.match(/\bText\s*\{/g) || []).length >= 20,
    "the Panel sweep must actually be sweeping something")
  // QML launches the detached helper; only Commands.js constructs notify-send.
  for (const name of ["Service.qml", "BarWidget.qml"]) {
    const source = readFileSync(path.join(root, name), "utf8")
    assert.ok(!source.includes('"notify-send"'), name + " bypasses the click helper")
  }
  const service = readFileSync(path.join(root, "Service.qml"), "utf8")
  assert.match(service, /readonly property string clickHelperPath: Model\.filePath\(/)

})

test("release metadata stays synchronized", () => {
  // Verbatim from upstream 1.5.5: the manifest version must have a dated
  // changelog entry.
  const manifest = JSON.parse(readFileSync(path.join(root, "manifest.json"), "utf8"))
  const changelog = readFileSync(path.join(root, "CHANGELOG.md"), "utf8")
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/)
  assert.match(changelog, new RegExp(
    "^## " + manifest.version.replaceAll(".", "\\.") + " - \\d{4}-\\d{2}-\\d{2}$", "m"))
})

test("every bar gesture points at the badged account before acting", () => {
  // Left-click was fixed; middle-click and right-click were not, so middle-click
  // opened the folder of whichever account happened to be selected -- at cold
  // boot, the first discovered one -- while the badge was about another, and
  // right-click spent the single 30-second cloud slot on the wrong account.
  assert.equal(
    code(barWidget, "onPressed: function(buttonCode) {", "\n    }\n  }\n}"),
    'onPressed: function(buttonCode) { ' +
    'if (root.service) root.service.selectBadgedAccount() ' +
    'if (buttonCode === Qt.RightButton && root.service) root.service.checkQuota() ' +
    'else if (buttonCode === Qt.MiddleButton && root.service) root.service.openFolder() ' +
    'else root.togglePanel()')
})
