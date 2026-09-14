const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")

test("status parser accepts valid data and fails closed", () => {
  const parsed = Model.parseStatus(JSON.stringify({
    ok: true,
    installed: true,
    running: true,
    files: [{ name: "report.pdf" }]
  }))
  assert.equal(parsed.installed, true)
  assert.equal(parsed.files.length, 1)
  assert.equal(Model.parseStatus("broken").ok, false)
  assert.deepEqual(Model.parseStatus("").files, [])
})

test("file kinds and glyphs cover common content", () => {
  assert.equal(Model.fileKind("photo.JPG"), "image")
  assert.equal(Model.fileKind("clip.webm"), "video")
  assert.equal(Model.fileKind("report.pdf"), "document")
  assert.equal(Model.fileKind("archive.zip"), "misc")
  assert.notEqual(Model.fileGlyph("report.pdf"), Model.fileGlyph("archive.zip"))
})

test("byte and quota formatting is deterministic", () => {
  assert.equal(Model.formatBytes(1530), "1.53 KB")
  assert.equal(Model.formatBytes(2_000_000_000), "2 GB")
  assert.equal(Model.usageText(1000, 2000, true), "1 KB of 2 KB")
  assert.equal(Model.usageText(0, 0, false), "Refresh storage to load")
})

test("storage presentation handles known and unknown quotas", () => {
  assert.equal(Model.freeText(42_000_000_000, 100_000_000_000, true), "58 GB free")
  assert.equal(Model.freeText(0, 0, false), "")
  assert.equal(Model.usageFraction(25, 100, true), 0.25)
  assert.equal(Model.usageFraction(125, 100, true), 1)
  assert.equal(Model.usageFraction(-25, 100, true), 0)
  assert.equal(Model.usageFraction(25, 100, false), 0)
  assert.equal(Model.usageShort(42_000_000_000, 100_000_000_000, true), "42 GB / 100 GB")
  assert.equal(Model.usageShort(0, 0, false), "Not checked")
  assert.equal(Model.usageSevere(90, 100, true), true)
  assert.equal(Model.usageSevere(89, 100, true), false)
  assert.equal(Model.usageSevere(95, 100, false), false)
})

test("relative timestamps and file metadata are readable", () => {
  assert.equal(Model.relativeTime(1000, 1000 * 1000 + 45 * 1000), "Just now")
  assert.equal(Model.relativeTime(1000, 1000 * 1000 + 3600 * 1000), "1h ago")
  assert.equal(Model.fileMeta({ modifiedTs: 1000, folder: "Docs" }, 1000 * 1000 + 3600 * 1000), "1h ago · Docs")
  assert.equal(Model.relativeTime(0), "Never")
  assert.equal(Model.checkedText(1000, 1000 * 1000 + 2 * 3600 * 1000), "checked 2h ago")
  assert.equal(Model.checkedText(0), "never checked")
})

test("activity rows use payload activity and fall back to files", () => {
  const syncRow = { kind: "sync", ts: 2000, title: "Sync complete", detail: "", path: "" }
  const fileRow = { kind: "file", ts: 1500, title: "a.md", detail: "changed in Docs", path: "/OneDrive/Docs/a.md" }
  const errorRow = { kind: "error", ts: 1200, title: "Sync aborted", detail: "", path: "" }
  assert.deepEqual(
    Model.activityRows({ activity: [syncRow, fileRow, errorRow], files: [] }),
    [fileRow, errorRow]
  )
  assert.deepEqual(Model.activityRows({ activity: [syncRow], files: [] }), [])
  assert.deepEqual(Model.activityRows({
    activity: [],
    files: [{ modifiedTs: 1000, name: "report.pdf", folder: "Docs", path: "/OneDrive/Docs/report.pdf" }]
  }), [{
    kind: "file",
    ts: 1000,
    title: "report.pdf",
    detail: "changed in Docs",
    path: "/OneDrive/Docs/report.pdf"
  }])
  assert.deepEqual(Model.activityRows(null), [])
})

test("activity metadata and glyphs describe recent rows", () => {
  assert.equal(Model.activityMeta([], 1000 * 1000), "")
  assert.equal(Model.activityMeta([{ ts: 1000 }], 1000 * 1000 + 2 * 3600 * 1000), "last 24 h")
  assert.equal(Model.activityMeta([{ ts: 1000 }], 1000 * 1000 + 25 * 3600 * 1000), "1d ago")
  assert.equal(Model.activityGlyph({ kind: "file", title: "report.pdf" }), Model.fileGlyph("report.pdf"))
  assert.equal(Model.activityGlyph({ kind: "sync" }), "󰄬")
  assert.equal(Model.activityGlyph({ kind: "error" }), "󰀪")
  assert.equal(Model.activityGlyph({ kind: "error", recovered: true }), "󰄬")
  assert.equal(Model.syncMeta(1000, 1000 * 1000 + 3 * 60 * 1000), "synced 3m ago")
  assert.equal(Model.syncMeta(1000, 1000 * 1000 + 45 * 1000), "synced Just now")
  assert.equal(Model.syncMeta(0), "")
})

test("folder, tooltip, and plugin paths handle spaces", () => {
  assert.equal(Model.folderName("/home/salem/My OneDrive/"), "My OneDrive")
  assert.equal(Model.folderName(""), "Not configured")
  assert.equal(Model.tooltip({ installed: false }), "OneDrive CLI is not installed")
  assert.equal(
    Model.tooltip({ installed: true, statusText: "Monitoring", syncMode: "", lastSyncTs: 1000 }, 1000 * 1000 + 60 * 1000),
    "Monitoring · last sync 1m ago"
  )
  assert.equal(
    Model.tooltip({
      installed: true,
      authenticated: true,
      statusText: "Monitoring",
      syncMode: "Download only",
      lastSyncTs: 0
    }),
    "Monitoring · Download only"
  )
  assert.equal(Model.heroMeta({
    authenticated: true,
    statusText: "Monitoring",
    syncMode: "Upload only"
  }), "Monitoring · Upload only")
  assert.equal(Model.filePath("file:///tmp/Oma%20OneDrive/status.py"), "/tmp/Oma OneDrive/status.py")
})

test("an error line is squashed to one line and capped", () => {
  // systemd and the onedrive client both emit multi-line errors hundreds of
  // characters long. Pasted straight into the panel they pushed every other row
  // off the screen.
  assert.equal(Model.elideStatus("  one\n  two \t three  "), "one two three")
  assert.equal(Model.elideStatus(""), "")
  assert.equal(Model.elideStatus(null), "")
  assert.equal(Model.elideStatus(undefined), "")

  const long = "x".repeat(400)
  const cut = Model.elideStatus(long)
  assert.equal(cut.length, 178, cut.length + " characters")
  assert.ok(cut.endsWith("…"))
  // The boundary: 180 is kept whole, 181 is cut.
  assert.equal(Model.elideStatus("y".repeat(180)).length, 180)
  assert.ok(!Model.elideStatus("y".repeat(180)).endsWith("…"))
  assert.ok(Model.elideStatus("y".repeat(181)).endsWith("…"))
  // A tall error is squashed FIRST and capped second, so what survives is 177
  // characters of message rather than 177 characters of indentation.
  const tall = Model.elideStatus("    a\n".repeat(100))
  assert.ok(!tall.includes("\n"), tall)
  assert.ok(!tall.includes("  "), tall)
  assert.equal(tall.length, 178)
  assert.ok(tall.startsWith("a a a a"), tall)
  // Whitespace alone is nothing to report.
  assert.equal(Model.elideStatus("   \n\t  "), "")
})

test("relative times step through every unit, including the ones nobody reaches", () => {
  // Inverting the month/year boundary left the suite green. A stale account is
  // exactly where these matter: "13mo ago" and "1y ago" are the difference
  // between a sync that is old and one that never happened.
  const now = Date.UTC(2026, 0, 1)
  const ago = seconds => Model.relativeTime(now / 1000 - seconds, now)
  assert.equal(ago(30), "Just now")
  assert.equal(Model.relativeTime(0, now), "Never")
  assert.equal(ago(60 * 5), "5m ago")
  assert.equal(ago(60 * 60 * 3), "3h ago")
  assert.equal(ago(60 * 60 * 24 * 5), "5d ago")
  assert.equal(ago(60 * 60 * 24 * 60), "2mo ago")
  // The boundary the inversion crossed: 11 months is months, 12 is years.
  assert.equal(ago(60 * 60 * 24 * 30 * 11), "11mo ago")
  assert.equal(ago(60 * 60 * 24 * 400), "1y ago")
  assert.equal(ago(60 * 60 * 24 * 800), "2y ago")
})

test("a file's glyph follows its kind, and each kind has its own", () => {
  // Literal glyphs, not "whatever this kind currently returns": deriving the
  // expectation from the code under test made the whole check self-consistent,
  // and inverting the document branch stayed green.
  const byKind = { image: "\u{f02e9}", video: "\u{f022b}", document: "\u{f0219}", other: "\u{f0214}" }
  assert.equal(Model.fileGlyph("a.png"), byKind.image)
  assert.equal(Model.fileGlyph("a.mp4"), byKind.video)
  assert.equal(Model.fileGlyph("a.docx"), byKind.document)
  assert.equal(Model.fileGlyph("a.bin"), byKind.other)
  const drawn = Object.values(byKind)
  assert.equal(new Set(drawn).size, drawn.length, "two file kinds share a glyph")
  assert.equal(Model.fileGlyph("report.pdf"), byKind.document)
  assert.equal(Model.fileGlyph("notes.txt"), byKind.document)
  assert.equal(Model.fileGlyph("photo.JPG"), byKind.image, "extensions are case-insensitive")
  assert.equal(Model.fileGlyph(""), byKind.other)
})

test("the hero line names the sync mode only when it means something", () => {
  // Before sign-in the client reports a mode it is not using. Showing
  // "Sign in required · Two-way" reads as though syncing were configured.
  assert.equal(Model.heroMeta({ statusText: "Monitoring", authenticated: true, syncMode: "Two-way" }),
    "Monitoring · Two-way")
  assert.equal(Model.heroMeta({ statusText: "Sign in required", authenticated: false, syncMode: "Two-way" }),
    "Sign in required")
  assert.equal(Model.heroMeta({ statusText: "Monitoring", authenticated: true, syncMode: "" }),
    "Monitoring")
  assert.equal(Model.heroMeta(null), "Checking…")
})

test("markup in helper data cannot become rich text at inherited boundaries", () => {
  // From upstream 1.5.6: Omarchy 4.0.1's shared bar tooltip and PanelHero use
  // Text.AutoText, so a filename shaped like markup would render as markup.
  // The delimiters are swapped for lookalikes, so the name stays readable.
  const markupStatus = {
    installed: true,
    authenticated: true,
    statusText: "Uploading <b>quarterly report</b>.pdf",
    syncMode: "Two-way",
    lastSyncTs: 0
  }
  assert.equal(Model.tooltip(markupStatus),
    "Uploading ‹b›quarterly report‹/b›.pdf · Two-way")
  assert.equal(Model.heroMeta(markupStatus),
    "Uploading ‹b›quarterly report‹/b›.pdf · Two-way")
  assert.doesNotMatch(Model.tooltip(markupStatus), /[<>]/)

  // The multi-account tooltip is the SAME shared bar boundary, and its lines
  // carry helper-derived names and errors too.
  const fleet = Model.aggregateTooltip([
    { initialized: true, installed: true, authenticated: true, serviceAvailable: true,
      running: true, activeState: "active", instance: "a<script>",
      description: "OneDrive sync (a<script> account)",
      statusText: "Uploading <img> file", syncMode: "Two-way", lastSyncTs: 0 },
    { initialized: true, installed: true, authenticated: true, serviceAvailable: true,
      running: true, activeState: "active", instance: "b", description: "",
      statusText: "Monitoring", syncMode: "Two-way", lastSyncTs: 0 }
  ], Date.now())
  assert.doesNotMatch(fleet, /[<>]/, fleet)
  assert.ok(fleet.includes("‹img›"), fleet)
  // ...and the broken-account error path.
  const broken = Model.aggregateTooltip(
    [{ initialized: false, attempted: true, instance: "x",
       lastError: "systemd said <no>" }], Date.now())
  assert.doesNotMatch(broken, /[<>]/, broken)
})
