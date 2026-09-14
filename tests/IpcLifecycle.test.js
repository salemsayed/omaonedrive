const assert = require("node:assert/strict")
const { readFileSync } = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const source = readFileSync(path.join(__dirname, "..", "BarWidget.qml"), "utf8")

test("IPC registration waits for a relocated bar slot to retire", () => {
  assert.match(source, /property bool ipcRegistrationReady: false/)
  assert.match(source, /id: ipcRegistrationTimer\s+interval: 100/)
  assert.match(source, /IpcHandler \{\s+enabled: root\.ipcRegistrationReady\s+target: root\.moduleName/)
})

// --- the account IPC surface -------------------------------------------------
//
// `accounts()` and `selectAccount()` are how automation reaches a non-default
// account: every other IPC control acts on the SELECTED one, so a wrong answer
// here silently redirects a pause, a resync or a reauth to another account.
// Both were previously deletable outright with the whole suite still green.

const Model = require("../Model.js")

function account(instance, overrides) {
  return Object.assign({
    service: instance === "" ? "onedrive.service" : "onedrive@" + instance + ".service",
    instance: instance,
    displayName: instance === "" ? "OneDrive" : instance,
    statusText: "Monitoring"
  }, overrides || {})
}

const THREE = [account(""), account("personal"), account("dragones")]

test("accounts() reports every account, in discovery order, with one selected", () => {
  const rows = Model.accountRows(THREE, "onedrive@personal.service")
  assert.equal(rows.length, 3)
  assert.deepEqual(rows.map(row => row.instance), ["", "personal", "dragones"])
  assert.deepEqual(rows.map(row => row.selected), [false, true, false])
  assert.equal(rows.filter(row => row.selected).length, 1)
  assert.deepEqual(rows[1], {
    service: "onedrive@personal.service",
    instance: "personal",
    name: "personal",
    selected: true,
    status: "Monitoring"
  })
  // Round-trips as JSON, which is what the IPC caller actually receives.
  assert.deepEqual(JSON.parse(JSON.stringify(rows)), rows)
})

test("a selection that matches nothing marks nothing selected", () => {
  // Reachable during discovery: selectedService is cleared before the new list
  // settles. Reporting a stale `selected: true` would point a script at an
  // account the widget is no longer acting on.
  const rows = Model.accountRows(THREE, "onedrive@gone.service")
  assert.deepEqual(rows.map(row => row.selected), [false, false, false])
  assert.deepEqual(Model.accountRows([], "onedrive.service"), [])
  assert.deepEqual(Model.accountRows(null, ""), [])
  // An empty selection must not select the plain account by accident of both
  // being falsy.
  assert.deepEqual(Model.accountRows(THREE, "").map(row => row.selected),
    [false, false, false])
})

test("selectAccount accepts the full unit name and the bare instance", () => {
  assert.equal(Model.resolveAccountTarget(THREE, "onedrive@dragones.service"),
    "onedrive@dragones.service")
  assert.equal(Model.resolveAccountTarget(THREE, "dragones"), "onedrive@dragones.service")
  assert.equal(Model.resolveAccountTarget(THREE, "onedrive.service"), "onedrive.service")
})

test("an unknown or empty target resolves to nothing rather than to an account", () => {
  // "" is what an unset argument arrives as, and the plain account's instance is
  // also "". No account key can equal "" today, so this pins a contract rather
  // than catching a live mutation -- but the day an account carries an empty
  // service or instance, an unset argument must still resolve to nothing.
  assert.equal(Model.resolveAccountTarget(THREE, ""), "")
  assert.equal(Model.resolveAccountTarget(THREE, null), "")
  assert.equal(Model.resolveAccountTarget(THREE, "personal.service"), "")
  assert.equal(Model.resolveAccountTarget(THREE, "Personal"), "")
  assert.equal(Model.resolveAccountTarget([], "personal"), "")
})

test("an exact unit name beats another account's instance, whatever the order", () => {
  // systemd instance names may contain dots, so an instance CAN equal another
  // account's unit name. Testing both keys account-by-account made the winner
  // depend on discovery order, and the control then acted on the wrong account.
  const collide = [
    account("legacy", { instance: "onedrive.service" }),
    account("")
  ]
  assert.equal(Model.resolveAccountTarget(collide, "onedrive.service"), "onedrive.service")
  // ...and reversed, so this cannot pass by the order of the fixture.
  assert.equal(Model.resolveAccountTarget(collide.slice().reverse(), "onedrive.service"),
    "onedrive.service")
  // The instance form still reaches the account that has no unambiguous rival.
  assert.equal(Model.resolveAccountTarget(collide, "legacy"), "")
})

test("the IPC handler still exposes both account functions, and selects without a cloud call", () => {
  // The pure functions above are worthless if nothing calls them. These pin the
  // wiring, which is the half that lives in a file no harness can instantiate.
  const handler = source.slice(source.indexOf("IpcHandler {"))
  assert.match(handler, /function accounts\(\): string/)
  assert.match(handler, /function selectAccount\(target: string\): string/)
  assert.match(handler, /Model\.accountRows\(root\.service\.accounts, root\.service\.selectedService\)/)
  assert.match(handler, /Model\.resolveAccountTarget\(root\.service\.accounts, target\)/)
  // The second argument is the fix from an earlier round: automation selecting
  // an account must not inherit the panel's stale-quota retry, which contacts
  // Microsoft. Dropping the `false` restores that.
  assert.match(handler, /root\.service\.selectAccount\(found, false\)/)
  // An unresolved target must report, not silently act on whatever is selected.
  assert.match(handler, /return "unknown account: " \+ target/)
})
