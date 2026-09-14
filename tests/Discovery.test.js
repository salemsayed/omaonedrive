const assert = require("node:assert")
const test = require("node:test")

const Model = require("../Model.js")

function row(service, instance, confdir) {
  return {
    service: service,
    instance: instance === undefined ? service.replace(/^onedrive@|\.service$/g, "") : instance,
    confdir: confdir || ("/c/" + service),
    description: "OneDrive sync"
  }
}

const PLAIN = row("onedrive.service", "", "/c/default")
const DRAGONES = row("onedrive@dragones.service", "dragones")
const PERSONAL = row("onedrive@personal.service", "personal")
const TANDERA = row("onedrive@tandera.service", "tandera")

test("first discovery appends everything", () => {
  const plan = Model.reconcilePlan([], [DRAGONES, PERSONAL, TANDERA])
  assert.equal(plan.appends.length, 3)
  assert.equal(plan.updates.length, 0)
  assert.equal(plan.removes.length, 0)
})

test("an unchanged set is all updates and no churn", () => {
  // This is the property that matters: a repeat discovery must not recreate a
  // single delegate, or in-flight processes and notification latches are lost.
  const current = [DRAGONES.service, PERSONAL.service, TANDERA.service]
  const plan = Model.reconcilePlan(current, [DRAGONES, PERSONAL, TANDERA])
  assert.equal(plan.appends.length, 0)
  assert.equal(plan.removes.length, 0)
  // deepEqual on the ROW, not just the index. Pinning only the index let every
  // update carry the same row, which would give every account the first
  // account's confdir -- they would all poll and display one drive.
  assert.deepEqual(plan.updates, [
    { index: 0, row: DRAGONES },
    { index: 1, row: PERSONAL },
    { index: 2, row: TANDERA }
  ])
})

test("each update carries its OWN row, not a neighbour's", () => {
  // Reordered discovery: the rows must still pair with the right descriptors.
  const current = [DRAGONES.service, PERSONAL.service, TANDERA.service]
  const plan = Model.reconcilePlan(current, [TANDERA, DRAGONES, PERSONAL])
  const byIndex = {}
  for (const update of plan.updates) byIndex[update.index] = update.row.service
  assert.deepEqual(byIndex, {
    0: DRAGONES.service,
    1: PERSONAL.service,
    2: TANDERA.service
  })
})

test("a changed confdir updates in place rather than replacing the account", () => {
  const moved = Object.assign({}, DRAGONES, { confdir: "/srv/moved" })
  const plan = Model.reconcilePlan([DRAGONES.service], [moved])
  assert.equal(plan.appends.length, 0)
  assert.equal(plan.removes.length, 0)
  assert.deepEqual(plan.updates, [{ index: 0, row: moved }])
})

test("a new account appends without disturbing existing indices", () => {
  const plan = Model.reconcilePlan([DRAGONES.service], [DRAGONES, PERSONAL])
  assert.deepEqual(plan.updates.map(u => u.index), [0])
  assert.deepEqual(plan.appends, [PERSONAL])
  assert.equal(plan.removes.length, 0)
})

test("a removed account is dropped, and removals are descending", () => {
  const current = [DRAGONES.service, PERSONAL.service, TANDERA.service]
  const plan = Model.reconcilePlan(current, [PERSONAL])
  assert.deepEqual(plan.updates.map(u => u.index), [1])
  // Descending, so applying one cannot shift the next.
  assert.deepEqual(plan.removes, [2, 0])
  for (let index = 1; index < plan.removes.length; index++) {
    assert.ok(plan.removes[index] < plan.removes[index - 1])
  }
})

test("everything disappearing removes everything", () => {
  const plan = Model.reconcilePlan([DRAGONES.service, PERSONAL.service], [])
  assert.deepEqual(plan.removes, [1, 0])
  assert.equal(plan.appends.length, 0)
})

test("reordered discovery does not churn delegates", () => {
  // Discovery sorts by instance; a rename elsewhere could reorder it. Existing
  // services must still map to their existing rows, not be torn down.
  const current = [DRAGONES.service, PERSONAL.service]
  const plan = Model.reconcilePlan(current, [PERSONAL, DRAGONES])
  assert.equal(plan.appends.length, 0)
  assert.equal(plan.removes.length, 0)
  assert.deepEqual(plan.updates.map(u => u.index).sort(), [0, 1])
})

test("malformed discovery rows are ignored, not turned into accounts", () => {
  const plan = Model.reconcilePlan([], [null, {}, { service: "" }, DRAGONES, "nonsense"])
  assert.deepEqual(plan.appends, [DRAGONES])
})

test("a repeated service in one payload is taken once", () => {
  const plan = Model.reconcilePlan([], [DRAGONES, DRAGONES])
  assert.equal(plan.appends.length, 1)
})

test("the plain account is reconciled like any other", () => {
  // The single-account fallback is a first-class descriptor, not a special path.
  const plan = Model.reconcilePlan([PLAIN.service], [PLAIN])
  assert.deepEqual(plan.updates, [{ index: 0, row: PLAIN }])
  assert.equal(plan.appends.length, 0)
  assert.equal(plan.removes.length, 0)
})

test("the seeded fallback is replaced in place when discovery names it", () => {
  // Startup seeds { onedrive.service, confdir: "" }; discovery returns the same
  // service with a real confdir. That must update the existing delegate rather
  // than remove-and-append, which would restart its processes.
  const seeded = ["onedrive.service"]
  const discovered = [Object.assign({}, PLAIN, { confdir: "/home/u/.config/onedrive" })]
  const plan = Model.reconcilePlan(seeded, discovered)
  assert.equal(plan.updates.length, 1)
  assert.equal(plan.appends.length, 0)
  assert.equal(plan.removes.length, 0)
})

test("switching from the plain account to templates removes the plain one", () => {
  // A machine that stops using onedrive.service and starts three instances.
  const plan = Model.reconcilePlan(["onedrive.service"], [DRAGONES, PERSONAL, TANDERA])
  assert.deepEqual(plan.removes, [0])
  assert.equal(plan.appends.length, 3)
  assert.equal(plan.updates.length, 0)
})
