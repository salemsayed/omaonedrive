const assert = require("node:assert")
const test = require("node:test")

const Model = require("../Model.js")

// These exist because a reviewer pointed out that deleting the ramp or bypassing
// the cloud semaphore passed the entire suite: the logic lived in QML, which has
// no harness here. Pulling the DECISIONS out makes them assertable.

// A healthy account that has already reported. `initialized` has to DEFAULT to
// true: without it every fixture looked equally unreported, so reverting the
// product's priority from `attempted` back to `initialized` -- the monopoly bug
// -- left the test named after it green.
function acct(overrides) {
  return Object.assign(
    { routinePolling: false, busy: false, attempted: true, initialized: true },
    overrides || {})
}

test("an account already polling is never handed another slot", () => {
  const accounts = [acct({ routinePolling: true }), acct()]
  assert.equal(Model.nextPollIndex(accounts, 0), 1)
  // ...and if every account is busy, nobody is picked.
  assert.equal(Model.nextPollIndex([acct({ routinePolling: true })], 0), -1)
})

test("accounts that have not reported take priority over ones that have", () => {
  const accounts = [acct(), acct({ attempted: false }), acct()]
  assert.equal(Model.nextPollIndex(accounts, 0), 1)
})

test("several unreported accounts interleave instead of one taking every slot", () => {
  // This is the defect this function was extracted to prevent: the old code
  // returned the FIRST unreported account every slot, so with three of them the
  // second and third were never polled until the first exhausted a 15-slot
  // counter -- 150 seconds at default settings, with no badge on the bar.
  const accounts = [acct({ attempted: false }), acct({ attempted: false }), acct({ attempted: false })]
  const picked = []
  let cursor = 0
  for (let slot = 0; slot < 6; slot++) {
    const index = Model.nextPollIndex(accounts, cursor)
    picked.push(index)
    cursor = (index + 1) % accounts.length
  }
  assert.deepEqual(picked, [0, 1, 2, 0, 1, 2])
  // Every account is reached within one round, not after the first gives up.
  assert.equal(new Set(picked.slice(0, 3)).size, 3)
})

test("a paused account does not consume startup priority", () => {
  // Priority is "has not reported", not "not running". A deliberately paused
  // account is a known state; treating it as ramping made it monopolise slots
  // every time the user paused it.
  const accounts = [acct({ attempted: true }), acct({ attempted: false })]
  assert.equal(Model.nextPollIndex(accounts, 0), 1)
})

test("the round-robin advances and wraps", () => {
  const accounts = [acct(), acct(), acct()]
  assert.equal(Model.nextPollIndex(accounts, 0), 0)
  assert.equal(Model.nextPollIndex(accounts, 1), 1)
  assert.equal(Model.nextPollIndex(accounts, 2), 2)
  assert.equal(Model.nextPollIndex(accounts, 3), 0)
  // A cursor left over from a longer list cannot index out of range.
  assert.equal(Model.nextPollIndex(accounts, 99), 0)
  assert.equal(Model.nextPollIndex([], 0), -1)
})

test("a busy slot queues a cloud check rather than starting a second one", () => {
  // Two concurrent 30-second cloud checks is the invariant this protects.
  assert.equal(Model.cloudDecision(false, [], "a.service", "quota"), "start")
  assert.equal(Model.cloudDecision(true, [], "a.service", "quota"), "queue")
})

test("a repeated request is dropped, not queued twice", () => {
  const queue = [{ service: "a.service", mode: "quota" }]
  assert.equal(Model.cloudDecision(true, queue, "a.service", "quota"), "drop")
  // A different mode for the same account is a different request.
  assert.equal(Model.cloudDecision(true, queue, "a.service", "sync-status"), "queue")
  // ...as is the same mode for a different account.
  assert.equal(Model.cloudDecision(true, queue, "b.service", "quota"), "queue")
})

test("a malformed cloud request is dropped", () => {
  assert.equal(Model.cloudDecision(false, [], "", "quota"), "drop")
  assert.equal(Model.cloudDecision(false, [], "a.service", ""), "drop")
})

test("the queue cannot grow past one entry per account per mode", () => {
  // Bounded by construction: 2 modes x N accounts. A user leaning on the refresh
  // key cannot build a backlog.
  const queue = []
  for (const service of ["a", "b", "c"]) {
    for (const mode of ["quota", "sync-status"]) {
      for (let repeat = 0; repeat < 5; repeat++) {
        if (Model.cloudDecision(true, queue, service, mode) === "queue") {
          queue.push({ service: service, mode: mode })
        }
      }
    }
  }
  assert.equal(queue.length, 6)
})

test("an account busy with a cloud check is skipped, not handed a wasted slot", () => {
  // routinePolling is false during a cloud check -- it is not a routine poll --
  // but the account will still refuse the slot, so handing it one wastes the
  // tick entirely. Deleting the busy guard used to keep this file green.
  const accounts = [acct({ busy: true }), acct()]
  assert.equal(Model.nextPollIndex(accounts, 0), 1)

  // ...including when it is the unreported account that would otherwise take
  // pass-0 priority.
  const priority = [acct({ busy: true, attempted: false }), acct()]
  assert.equal(Model.nextPollIndex(priority, 0), 1)

  // If every account is busy for any reason, nobody is picked.
  assert.equal(Model.nextPollIndex([acct({ busy: true }), acct({ routinePolling: true })], 0), -1)
})

test("an account that can never report does not monopolise the scheduler", () => {
  // A helper that always fails leaves `initialized` false forever. Priority is
  // "has not been ATTEMPTED", so such an account rejoins the round-robin after
  // its first try instead of taking every slot for the life of the session.
  //
  // An earlier version of this test asserted [0, 1, 0, 1] -- encoding the
  // monopoly as the expected behaviour, with the healthy third account never
  // polled at all.
  const accounts = [
    acct({ attempted: true, initialized: false }),   // broken, already tried
    acct({ attempted: true }),
    acct({ attempted: true })
  ]
  const picks = []
  let cursor = 0
  for (let i = 0; i < 9; i++) {
    const index = Model.nextPollIndex(accounts, cursor)
    picks.push(index)
    cursor = (index + 1) % accounts.length
  }
  assert.deepEqual(picks, [0, 1, 2, 0, 1, 2, 0, 1, 2])
  assert.equal(new Set(picks).size, 3, "every account must be reached")
})

test("priority is 'not yet attempted', not 'not yet reported'", () => {
  // Before the first attempt, an account jumps the queue -- that is the ramp.
  assert.equal(Model.nextPollIndex(
    [acct({ attempted: true }), acct({ attempted: false })], 0), 1)
  // After it, even if it never produced a usable sample, it waits its turn.
  assert.equal(Model.nextPollIndex(
    [acct({ attempted: true }), acct({ attempted: true, initialized: false })], 0), 0)
})

test("a request identical to the one already RUNNING is dropped", () => {
  // Seeing only a busy boolean, the coordinator could not tell that the check in
  // flight was already this exact (service, mode) -- so a repeat click queued a
  // duplicate that ran the same 30-second query again the moment it finished.
  const active = { service: "a.service", mode: "quota" }
  assert.equal(Model.cloudDecision(true, [], "a.service", "quota", active), "drop")
  // A different mode for the same account is still a real request.
  assert.equal(Model.cloudDecision(true, [], "a.service", "sync-status", active), "queue")
  // ...as is the same mode for another account.
  assert.equal(Model.cloudDecision(true, [], "b.service", "quota", active), "queue")
  // Without the active pair the old behaviour is unchanged.
  assert.equal(Model.cloudDecision(true, [], "a.service", "quota"), "queue")
})

test("an account waiting on a control it just ran gets the next slot", () => {
  // `requestRefresh` is drop-not-queue, so the settle loop's asks are swallowed
  // whenever a neighbour holds the shared slot. With two or three accounts that
  // meant the poll confirming a pause could be delayed indefinitely -- and the
  // bar reverted to a sample taken before the pause. Settling therefore outranks
  // even the startup ramp, which costs at most a few seconds of "Checking".
  const accounts = [
    acct({ attempted: true }),
    acct({ attempted: false }),
    acct({ attempted: true, settling: true })
  ]
  assert.equal(Model.nextPollIndex(accounts, 0), 2)
  // ...from any cursor position, since the user's click decides urgency, not
  // where the round-robin happened to be.
  assert.equal(Model.nextPollIndex(accounts, 1), 2)
  assert.equal(Model.nextPollIndex(accounts, 2), 2)
})

test("a settling account that is busy still does not get a slot it would refuse", () => {
  assert.equal(Model.nextPollIndex(
    [acct({ settling: true, routinePolling: true }), acct()], 0), 1)
  assert.equal(Model.nextPollIndex(
    [acct({ settling: true, busy: true }), acct()], 0), 1)
})

test("two settling accounts interleave rather than one taking every slot", () => {
  const accounts = [acct({ settling: true }), acct({ settling: true }), acct()]
  const picks = []
  let cursor = 0
  for (let i = 0; i < 4; i++) {
    const index = Model.nextPollIndex(accounts, cursor)
    picks.push(index)
    cursor = (index + 1) % accounts.length
  }
  assert.deepEqual(picks, [0, 1, 0, 1])
})

test("settling priority does not disturb the ordinary round-robin", () => {
  // Nothing settling: the previous behaviour, unchanged.
  const accounts = [acct(), acct(), acct()]
  assert.deepEqual([0, 1, 2, 0].map((_, i) => Model.nextPollIndex(accounts, i)),
    [0, 1, 2, 0])
  // Ramp still beats steady state when nothing is settling.
  assert.equal(Model.nextPollIndex([acct(), acct({ attempted: false })], 0), 1)
})
