const assert = require("node:assert")
const test = require("node:test")

const Model = require("../Model.js")

function event(kind, name, overrides) {
  const summaries = {
    resync: "OneDrive needs a resync",
    failed: "OneDrive sync failed",
    reauth: "OneDrive needs reauthentication",
    storage: "OneDrive storage almost full",
    recovered: "OneDrive recovered"
  }
  const shorts = {
    resync: "Resync required",
    failed: "Sync failed",
    reauth: "Reauthentication required",
    storage: "Almost full",
    recovered: "Recovered"
  }
  return Object.assign({
    service: "onedrive@" + name.toLowerCase() + ".service",
    name: name,
    kind: kind,
    summary: summaries[kind],
    short: shorts[kind],
    body: "detail for " + name,
    action: kind === "resync" ? "repair" : (kind === "recovered" || kind === "storage" ? "" : "open")
  }, overrides || {})
}

test("nothing to say produces no notification", () => {
  assert.equal(Model.composeNotification([], true), null)
  assert.equal(Model.composeNotification(null, true), null)
  assert.equal(Model.composeNotification([null, undefined], true), null)
})

test("a single account keeps today's unattributed summary", () => {
  const one = Model.composeNotification([event("reauth", "OneDrive")], false)
  assert.equal(one.summary, "OneDrive needs reauthentication")
  assert.ok(!one.summary.includes("—"))
})

test("with several accounts a lone event names its account", () => {
  const one = Model.composeNotification([event("reauth", "Dragones")], true)
  assert.equal(one.summary, "OneDrive needs reauthentication — Dragones")
  assert.equal(one.urgency, "critical")
})

test("a lone resync keeps its actionable repair click", () => {
  // The one case where the click can act directly rather than just opening.
  // The label is gone with the mechanism: omarchy-notification-send renders no
  // button, the whole popup is the click and the behaviour+account travel in
  // its persisted exec hint.
  const one = Model.composeNotification([event("resync", "Dragones")], true)
  assert.equal(one.action, "repair")
  assert.equal(one.service, "onedrive@dragones.service")
})

test("three accounts failing at once produce ONE grouped popup", () => {
  const grouped = Model.composeNotification([
    event("reauth", "Dragones"), event("failed", "Personal"), event("resync", "Tandera")
  ], true)
  assert.equal(grouped.summary, "OneDrive needs attention in 3 accounts")
  assert.equal(grouped.body.split("\n").length, 3)
  assert.ok(grouped.body.includes("Dragones:"))
  assert.ok(grouped.body.includes("Personal:"))
  assert.ok(grouped.body.includes("Tandera:"))
})

test("a grouped popup opens the WORST account, wherever it sits", () => {
  // The previous fixture had the worst account LAST, so "open the last one"
  // passed it. The worst must be found by rank, from any position.
  const worstLast = Model.composeNotification([
    event("reauth", "Dragones"), event("resync", "Tandera")
  ], true)
  assert.equal(worstLast.service, "onedrive@tandera.service")

  const worstFirst = Model.composeNotification([
    event("resync", "Tandera"), event("reauth", "Dragones")
  ], true)
  assert.equal(worstFirst.service, "onedrive@tandera.service")

  const worstMiddle = Model.composeNotification([
    event("failed", "A"), event("resync", "Middle"), event("reauth", "C")
  ], true)
  assert.equal(worstMiddle.service, "onedrive@middle.service")

  // The notification's ranking must agree with the bar's: reauth outranks
  // failed, so a reauth account wins over a failed one.
  const order = Model.composeNotification([
    event("failed", "Failed"), event("reauth", "Reauth")
  ], true)
  assert.equal(order.service, "onedrive@reauth.service")

  assert.equal(worstLast.action, "open")
})

test("several recoveries collapse into one", () => {
  const recovered = Model.composeNotification([
    event("recovered", "Dragones"), event("recovered", "Personal")
  ], true)
  assert.equal(recovered.summary, "2 OneDrive accounts recovered")
  assert.equal(recovered.urgency, "normal")
  assert.equal(recovered.action, "")
})

test("attention outranks recovery in the same burst, and names its account", () => {
  const mixed = Model.composeNotification([
    event("recovered", "Personal"), event("reauth", "Dragones")
  ], true)
  assert.equal(mixed.urgency, "critical")
  assert.ok(mixed.summary.includes("reauthentication"))
  // Attribution is asserted in THIS branch too. It was previously pinned only in
  // the lone-attention branch, so dropping the name here stayed green -- and a
  // three-account user would be told "OneDrive needs reauthentication" with no
  // idea which account.
  assert.ok(mixed.summary.includes("Dragones"), mixed.summary)
  assert.ok(mixed.body.includes("Personal"))
})

test("storage alone stays a normal-urgency notification", () => {
  const one = Model.composeNotification([event("storage", "Dragones")], true)
  assert.equal(one.urgency, "normal")
  assert.equal(one.summary, "OneDrive storage almost full — Dragones")
  const many = Model.composeNotification([
    event("storage", "Dragones"), event("storage", "Personal")
  ], true)
  assert.equal(many.summary, "2 OneDrive accounts are almost full")
})

test("a burst reports every account it received, in one notification", () => {
  // The old version of this test asserted only that a summary was a string.
  // composeNotification returns one object by construction, so NO mutation could
  // fail it. What actually matters is that nothing is DROPPED: a storage
  // threshold is edge-latched, so an event omitted here is lost until it clears
  // and re-arms.
  const burst = [event("resync", "A"), event("failed", "B"),
                 event("storage", "C"), event("recovered", "D")]
  const composed = Model.composeNotification(burst, true)
  assert.equal(typeof composed.summary, "string")
  for (const name of ["A", "B", "C", "D"]) {
    assert.ok(composed.body.includes(name + ":"), name + " missing from: " + composed.body)
  }
})

test("the grouped count is accounts, not events", () => {
  // One account with two conditions is one account. Counting events produced
  // "OneDrive needs attention in 2 accounts" for a single-account machine.
  const sameAccount = [
    Object.assign(event("resync", "Solo"), { service: "onedrive.service" }),
    Object.assign(event("reauth", "Solo"), { service: "onedrive.service" })
  ]
  // Rejecting only the literal "2 accounts" let a mutation reporting "3 accounts"
  // stay green. Assert the shape instead: a single account is never counted.
  const solo = Model.composeNotification(sameAccount, true)
  assert.ok(!/\d+ accounts/.test(solo.summary), solo.summary)
  assert.ok(solo.summary.includes("Solo"), solo.summary)
  const twoAccounts = [event("resync", "A"), event("reauth", "B")]
  assert.ok(Model.composeNotification(twoAccounts, true).summary.includes("2 accounts"))
})

test("a startup round of pre-existing problems is one baseline popup", () => {
  // Three accounts that were already unhealthy when the widget started must not
  // fire three notifications.
  const baseline = Model.composeNotification([
    event("reauth", "Dragones"), event("reauth", "Personal"), event("failed", "Tandera")
  ], true)
  assert.equal(baseline.summary, "OneDrive needs attention in 3 accounts")
})
