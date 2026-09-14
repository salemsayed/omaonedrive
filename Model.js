var IMAGE_EXTENSIONS = {
  jpg: true, jpeg: true, png: true, gif: true, webp: true, avif: true, heic: true,
  svg: true, bmp: true, tif: true, tiff: true
}

var VIDEO_EXTENSIONS = {
  mp4: true, mov: true, mkv: true, webm: true, avi: true, m4v: true, mpg: true,
  mpeg: true, wmv: true
}

var DOCUMENT_EXTENSIONS = {
  pdf: true, txt: true, md: true, doc: true, docx: true, xls: true, xlsx: true,
  ppt: true, pptx: true, odt: true, ods: true, odp: true, rtf: true, csv: true,
  pages: true, numbers: true, key: true
}

function defaultStatus() {
  return {
    ok: true,
    installed: false,
    serviceAvailable: false,
    running: false,
    enabled: false,
    activeState: "",
    serviceFailed: false,
    resyncRequired: false,
    authenticated: false,
    reauthRequired: false,
    syncing: false,
    syncStage: "",
    statusText: "Unavailable",
    syncDir: "",
    syncMode: "Two-way",
    clientVersion: "",
    resumeAt: 0,
    lastSyncTs: 0,
    usedBytes: 0,
    quotaBytes: 0,
    quotaKnown: false,
    quotaCheckedTs: 0,
    quotaError: "",
    remoteStatus: "Not checked",
    syncStatusCheckedTs: 0,
    syncStatusError: "",
    remoteCheckedTs: 0,
    remoteError: "",
    files: [],
    lastError: ""
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    parsed.files = Array.isArray(parsed.files) ? parsed.files : []
    return parsed
  } catch (error) {
    var failed = defaultStatus()
    failed.ok = false
    failed.lastError = "Failed to parse OneDrive status"
    return failed
  }
}

function fileExtension(name) {
  var value = String(name || "").toLowerCase()
  var index = value.lastIndexOf(".")
  return index >= 0 ? value.substring(index + 1) : ""
}

function fileKind(name) {
  var extension = fileExtension(name)
  if (IMAGE_EXTENSIONS[extension]) return "image"
  if (VIDEO_EXTENSIONS[extension]) return "video"
  if (DOCUMENT_EXTENSIONS[extension]) return "document"
  return "misc"
}

function fileGlyph(name) {
  var kind = fileKind(name)
  if (kind === "image") return "󰋩"
  if (kind === "video") return "󰈫"
  if (kind === "document") return "󰈙"
  return "󰈔"
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function usageText(usedBytes, quotaBytes, quotaKnown) {
  if (quotaKnown && Number(quotaBytes || 0) > 0)
    return formatBytes(usedBytes) + " of " + formatBytes(quotaBytes)
  return "Refresh storage to load"
}

function freeText(usedBytes, quotaBytes, quotaKnown) {
  var quota = Number(quotaBytes || 0)
  if (!quotaKnown || !isFinite(quota) || quota <= 0) return ""
  var used = Number(usedBytes || 0)
  if (!isFinite(used)) used = 0
  return formatBytes(Math.max(0, quota - used)) + " free"
}

function usageFraction(usedBytes, quotaBytes, quotaKnown) {
  var quota = Number(quotaBytes || 0)
  if (!quotaKnown || !isFinite(quota) || quota <= 0) return 0
  var used = Number(usedBytes || 0)
  if (!isFinite(used)) used = 0
  return Math.max(0, Math.min(1, used / quota))
}

var QUOTA_WARNING_FRACTION = 0.9

function usageSevere(usedBytes, quotaBytes, quotaKnown) {
  return usageFraction(usedBytes, quotaBytes, quotaKnown) >= QUOTA_WARNING_FRACTION
}

function usageShort(usedBytes, quotaBytes, quotaKnown) {
  var quota = Number(quotaBytes || 0)
  if (!quotaKnown || !isFinite(quota) || quota <= 0) return "Not checked"
  return formatBytes(usedBytes) + " / " + formatBytes(quota)
}

function relativeTime(timestampSec, nowMs) {
  var timestamp = Number(timestampSec || 0)
  if (!isFinite(timestamp) || timestamp <= 0) return "Never"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var difference = Math.max(0, Math.floor((now - timestamp * 1000) / 1000))
  if (difference < 60) return "Just now"
  var minutes = Math.floor(difference / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function checkedText(remoteCheckedTs, nowMs) {
  var timestamp = Number(remoteCheckedTs || 0)
  if (!isFinite(timestamp) || timestamp <= 0) return "never checked"
  return "checked " + relativeTime(timestamp, nowMs)
}

function activityRows(status) {
  if (!status || typeof status !== "object") return []
  if (Array.isArray(status.activity) && status.activity.length > 0)
    return status.activity.filter(function(row) { return !row || row.kind !== "sync" })
  if (!Array.isArray(status.files)) return []

  var rows = []
  for (var index = 0; index < status.files.length; index++) {
    var file = status.files[index]
    if (!file || typeof file !== "object") file = {}
    var timestamp = Number(file.modifiedTs || 0)
    if (!isFinite(timestamp)) timestamp = 0
    var folder = String(file.folder || "/")
    rows.push({
      kind: "file",
      ts: timestamp,
      title: String(file.name || ""),
      detail: folder === "/" ? "changed in OneDrive" : "changed in " + folder,
      path: String(file.path || "")
    })
  }
  return rows.sort(function(left, right) { return right.ts - left.ts }).slice(0, 8)
}

function activityMeta(rows, nowMs) {
  if (!Array.isArray(rows) || rows.length === 0) return ""
  var newest = 0
  for (var index = 0; index < rows.length; index++) {
    var row = rows[index]
    var timestamp = Number(row && row.ts || 0)
    if (isFinite(timestamp) && timestamp > newest) newest = timestamp
  }
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  if (!isFinite(now)) now = Date.now()
  if (newest > 0 && now - newest * 1000 <= 24 * 60 * 60 * 1000) return "last 24 h"
  return relativeTime(newest, now)
}

function syncMeta(lastSyncTs, nowMs) {
  var timestamp = Number(lastSyncTs || 0)
  if (!isFinite(timestamp) || timestamp <= 0) return ""
  return "synced " + relativeTime(timestamp, nowMs)
}

function activityGlyph(row) {
  if (!row || typeof row !== "object") return ""
  if (row.kind === "file") return fileGlyph(row.title)
  if (row.kind === "sync") return "󰄬"
  if (row.kind === "error" && row.recovered === true) return "󰄬"
  if (row.kind === "error") return "󰀪"
  return ""
}

function fileMeta(file, nowMs) {
  if (!file) return ""
  var parts = [relativeTime(file.modifiedTs, nowMs)]
  var folder = String(file.folder || "")
  if (folder !== "") parts.push(folder)
  return parts.join(" · ")
}

function folderName(path) {
  var value = String(path || "").replace(/\/+$/, "")
  if (value === "") return "Not configured"
  var parts = value.split("/")
  return parts[parts.length - 1] || value
}

// Omarchy 4.0.1's shared bar tooltip and PanelHero labels use Text.AutoText.
// Replace markup delimiters only at those inherited rendering boundaries so a
// local filename from the OneDrive journal remains visible but cannot become
// rich text.
function inheritedPlainText(value) {
  return String(value || "").replace(/</g, "\u2039").replace(/>/g, "\u203a")
}

function tooltip(status, nowMs) {
  if (!status || status.installed !== true) return "OneDrive CLI is not installed"
  var parts = [String(status.statusText || "OneDrive")]
  if (status.authenticated === true && String(status.syncMode || "") !== "")
    parts.push(String(status.syncMode))
  if (Number(status.lastSyncTs || 0) > 0)
    parts.push("last sync " + relativeTime(status.lastSyncTs, nowMs))
  return inheritedPlainText(parts.join(" · "))
}

function heroMeta(status) {
  if (!status || typeof status !== "object") return "Checking…"
  var parts = [String(status.statusText || "OneDrive")]
  if (status.authenticated === true && String(status.syncMode || "") !== "")
    parts.push(String(status.syncMode))
  return inheritedPlainText(parts.join(" · "))
}

// --- multi-account aggregation ------------------------------------------------

// "personal" -> "Personal", "work-mail" -> "Work Mail". The plain service has no
// instance and is simply "OneDrive", which is also the hero title, so a
// single-account install reads exactly as it does today. The description is
// accepted for callers that want it but is not used: systemd descriptions are
// sentences ("OneDrive sync (personal account)"), not labels for a tab.
function accountName(instance, description) {
  var value = String(instance || "").trim()
  if (value === "") return "OneDrive"
  var words = value.replace(/[_-]+/g, " ").split(" ")
  var named = []
  for (var index = 0; index < words.length; index++) {
    var word = words[index]
    if (word === "") continue
    named.push(word.charAt(0).toUpperCase() + word.slice(1))
  }
  return named.length ? named.join(" ") : value
}

// One total order, worst first. Ranked rather than named-compared so the bar can
// pick a winner without knowing what any particular state means.
//
// resync is deliberately checked before failed: a required resync exits 126,
// which sets serviceFailed too, and "Resync required" is the actionable half.
var ACCOUNT_STATES = [
  { kind: "resync", rank: 1 },
  { kind: "reauth", rank: 2 },
  { kind: "failed", rank: 3 },
  { kind: "missing", rank: 4 },
  { kind: "login", rank: 5 },
  { kind: "unavailable", rank: 6 },
  { kind: "paused", rank: 7 },
  { kind: "starting", rank: 8 },
  { kind: "syncing", rank: 9 },
  { kind: "healthy", rank: 10 }
]

function accountStateKind(account) {
  if (!account || typeof account !== "object") return "missing"
  if (account.resyncRequired === true) return "resync"
  if (account.reauthRequired === true) return "reauth"
  if (account.serviceFailed === true) return "failed"
  if (account.installed !== true) return "missing"
  if (account.authenticated !== true) return "login"
  if (account.serviceAvailable !== true) return "unavailable"
  if (String(account.activeState || "") === "activating") return "starting"
  // `active` folds in the optimistic desired state, which is what made the old
  // bar respond to Pause and Resume immediately instead of a poll later. Fall
  // back to `running` for plain objects that have no `active`.
  var isActive = account.active !== undefined ? account.active === true : account.running === true
  if (!isActive) return "paused"
  // ...and a syncing flag left over from before a pause must not outrank it.
  if (account.syncing === true) return "syncing"
  return "healthy"
}

function accountState(account) {
  var kind = accountStateKind(account)
  for (var index = 0; index < ACCOUNT_STATES.length; index++) {
    if (ACCOUNT_STATES[index].kind === kind) return ACCOUNT_STATES[index]
  }
  return ACCOUNT_STATES[ACCOUNT_STATES.length - 1]
}

// Worst of N. Until every discovered account has produced a first sample the
// aggregate is "checking" with no badge, so default property values cannot flash
// a missing-client badge before the first poll lands.
function aggregateAccounts(accounts) {
  var list = Array.isArray(accounts) ? accounts : []
  if (list.length === 0) {
    return { kind: "checking", rank: 0, count: 0, worst: null, anyActive: false, initialized: false }
  }
  // Accounts that have not reported yet are EXCLUDED rather than gating the
  // whole aggregate. Excluding them already prevents default property values
  // from flashing a missing-client badge, which is the reason the design gives
  // for the checking state -- while gating on all of them meant a single
  // permanently-failing account (its confdir unreadable, say) froze the bar at
  // "checking" forever, hiding a resync-required account behind it.
  var anyInitialized = false
  var worst = null
  var worstRank = Number.MAX_VALUE
  var anyActive = false
  for (var index = 0; index < list.length; index++) {
    var account = list[index]
    if (!account || account.initialized !== true) continue
    anyInitialized = true
    var state = accountState(account)
    // Strictly less-than, so equal ranks keep discovery order.
    if (state.rank < worstRank) {
      worstRank = state.rank
      worst = account
    }
    // account.active already folds in the optimistic _desired state, so a just-
    // pressed Pause dims the icon immediately instead of waiting for a poll.
    // Fall back to the raw fields for plain objects that have no `active`.
    var stated = account.active
    var isActive = stated !== undefined
      ? stated === true
      : (account.running === true || String(account.activeState || "") === "activating")
    // A transfer keeps the icon lit even between "running" samples -- but NOT
    // for an account the user has just paused. The helper only ever sets
    // `syncing` alongside `running`, so the leftover flag from the sample before
    // the pause was the one thing this clause could still light, and the icon
    // stayed bright until a confirming poll landed. Pausing during an upload
    // looked like it had not taken.
    if (isActive || (account.syncing === true && stated !== false)) anyActive = true
  }
  if (!anyInitialized || worst === null) {
    return {
      kind: "checking", rank: 0, count: list.length,
      worst: null, anyActive: anyActive, initialized: false
    }
  }
  var kind = accountStateKind(worst)
  return {
    // Worst-first, INCLUDING a pause. A reviewer argued that progress should
    // outrank a deliberate pause on the badge, and for one round it did; the
    // user overruled it: a paused account anywhere is a state you must be shown,
    // and every account has to be working before the bar looks normal. The
    // badge, the tooltip and the aggregate therefore all answer with the same
    // worst account.
    kind: kind,
    rank: worstRank,
    count: list.length,
    worst: worst,
    anyActive: anyActive,
    initialized: true
  }
}

// N=1 keeps exactly today's one-line tooltip. N>1 is attributed and ordered
// worst first, then discovery order, capped so a large installation cannot grow
// an unbounded tooltip.
function aggregateTooltip(accounts, nowMs, maxLines) {
  var list = Array.isArray(accounts) ? accounts : []
  if (list.length === 0) return "Checking OneDrive…"
  if (list.length === 1) {
    var only = list[0]
    // An account that has not reported still carries its default values, and the
    // default `installed: false` renders as "OneDrive CLI is not installed" --
    // which sends the user looking for a missing package when what actually
    // happened is that the status helper could not be run, or timed out. Say
    // that instead, and only guess at the client when a poll has told us.
    if (!only || only.initialized !== true) {
      var why = only && only.attempted === true ? String(only.lastError || "") : ""
      if (why === "") return "Checking OneDrive…"
      return inheritedPlainText("OneDrive status unavailable\n" + why)
    }
    return tooltip(only, nowMs)
  }
  // An account that has been polled and still cannot report is not "checking":
  // its helper failed, or timed out, and it will keep failing. Saying so is the
  // only way the user learns which account is broken and why -- and when the
  // helper is missing outright, EVERY account is in this state at once, so this
  // is the whole tooltip, not a footnote.
  var broken = list.filter(function (account) {
    return account && account.initialized !== true && account.attempted === true
      && String(account.lastError || "") !== ""
  })
  var summary = aggregateAccounts(list)
  if (!summary.initialized) {
    if (broken.length === 0) return "Checking " + list.length + " OneDrive accounts…"
    var stalled = ["OneDrive status unavailable"]
    for (var b = 0; b < broken.length; b++) {
      stalled.push(accountName(broken[b].instance, broken[b].description)
        + ": " + String(broken[b].lastError))
    }
    if (broken.length < list.length) {
      stalled.push("Checking " + (list.length - broken.length) + " more…")
    }
    return inheritedPlainText(stalled.join("\n"))
  }

  // Only accounts that have reported. An un-polled account still carries default
  // values, which classify as "missing" and would sort to the TOP of a
  // worst-first list -- so the tooltip would announce a missing client while the
  // badge, which already excludes them, showed nothing.
  var reported = list.filter(function (account) {
    return account && account.initialized === true
  })
  var ordered = reported.map(function (account, index) {
    return { account: account, index: index, rank: accountState(account).rank }
  })
  ordered.sort(function (left, right) {
    return left.rank === right.rank ? left.index - right.index : left.rank - right.rank
  })

  var cap = maxLines === undefined ? 5 : maxLines
  var lines = ["OneDrive · " + list.length + " accounts"]
  // A broken account listed among the healthy ones, so a permanently failing
  // helper is visible next to the accounts that ARE working rather than being
  // folded into a "checking" count that never goes down.
  for (var f = 0; f < broken.length; f++) {
    lines.push(accountName(broken[f].instance, broken[f].description)
      + ": " + String(broken[f].lastError))
  }
  var stillChecking = list.length - reported.length - broken.length
  if (stillChecking > 0) lines.push("Checking " + stillChecking + " more…")
  for (var index = 0; index < ordered.length && index < cap; index++) {
    var account = ordered[index].account
    lines.push(accountName(account.instance, account.description) + ": " + tooltip(account, nowMs))
  }
  if (ordered.length > cap) lines.push("+" + (ordered.length - cap) + " more")
  // The per-account lines are already plain (tooltip() wraps itself), but the
  // account NAMES and the broken-account error lines are helper-derived too.
  return inheritedPlainText(lines.join("\n"))
}

// Map an aggregate state onto the bar's existing badge vocabulary. The visual
// language does not grow with the state list: several states share a badge and
// the tooltip distinguishes them, because at eight pixels a badge can only
// carry "something is wrong", "signed out", "paused" or "working".
// What the bar icon does with an aggregate: lit or dim, spinning or not.
//
// This lived as three expressions in BarWidget.qml, which derives from the bar's
// own BarWidget type and so cannot be instantiated by any harness. A reviewer
// demonstrated the cost: the old broken `installed` expression -- the one that
// dimmed a bar with a healthy account syncing because some OTHER account was
// missing -- could be restored there with the entire suite still green.
function barState(aggregate) {
  var summary = aggregate && typeof aggregate === "object" ? aggregate : {}
  var kind = String(summary.kind || "")
  // Lit while ANY account is working, so one paused account does not dim a bar
  // that is still syncing two others.
  var anyActive = summary.anyActive === true
  return {
    active: anyActive,
    syncing: kind === "syncing" || kind === "starting",
    // Dimming asks whether ANYTHING is usable, which is not the question the
    // badge answers. Deriving it from the badge kind left the icon undimmed
    // before the first poll, and undimmed while showing the missing-client badge
    // for an account whose unit is merely unavailable.
    installed: summary.initialized === true
      && (anyActive || (kind !== "missing" && kind !== "unavailable"))
  }
}

// One line of error text, fit for a tooltip or a status row.
//
// A systemd or onedrive error can be several hundred characters of multi-line
// output; pasting that straight into the panel pushed every other row off the
// screen. This lived in Account.qml, where no test could reach it.
function elideStatus(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > 180 ? value.substring(0, 177) + "…" : value
}

function badgeKind(kind) {
  if (kind === "resync" || kind === "reauth" || kind === "failed") return "attention"
  if (kind === "missing" || kind === "unavailable") return "missing"
  if (kind === "login") return "login"
  if (kind === "paused") return "paused"
  if (kind === "starting" || kind === "syncing") return "syncing"
  return ""   // healthy, and checking before the first poll
}

// Which account the panel should show when it is opened from the bar.
//
// The badge is worst-of-N, but every control in the panel -- the buttons, the
// keyboard shortcuts, right-click Storage, middle-click Folder, and the IPC
// controls -- acts on the SELECTED account, which stays wherever the user last
// left it (the first discovered account, until they pick a tab). So the bar
// could show "reauthentication required" for Work while the panel opened on a
// perfectly healthy Personal, and pressing P paused Personal.
//
// Returns the service to select, or "" to leave the selection alone. The user's
// own choice is only overridden when it is not itself asking for attention:
// having deliberately opened Work to deal with it, they must not be bounced to
// Personal the moment Personal goes wrong too.
function openSelection(summary, selectedKind) {
  var aggregate = summary && typeof summary === "object" ? summary : {}
  var kind = String(aggregate.kind || "")
  if (needsAttention(kind)) {
    // A selection the user made for a reason is not stolen: having opened Work
    // to deal with its reauth, they must not be bounced to Personal the moment
    // Personal fails too.
    if (needsAttention(selectedKind)) return ""
    return aggregate.worst ? String(aggregate.worst.service || "") : ""
  }
  // A spinning bar is about the transfer. Under worst-first the transferring
  // account IS the worst one, so clicking the spin reaches it rather than
  // whatever was selected last -- but never away from an account the user is
  // already watching sync.
  if ((kind === "syncing" || kind === "starting") && selectedKind !== "syncing"
      && selectedKind !== "starting") {
    return aggregate.worst ? String(aggregate.worst.service || "") : ""
  }
  return ""
}

// The states that put a badge on the bar and have something for the user to do.
// "paused" is deliberate and "syncing" is progress, so neither steals a
// selection.
function needsAttention(kind) {
  return kind === "resync" || kind === "reauth" || kind === "failed"
    || kind === "missing" || kind === "login" || kind === "unavailable"
}

// Compose one desktop notification from the events of a single polling burst.
//
// Three accounts going wrong at once must not produce three popups, and the old
// unattributed summaries ("OneDrive sync failed") are useless when several
// accounts exist. Returns null when there is nothing to send.
//
// An event is { service, name, kind, body, action } where kind is one of
// "resync" | "failed" | "reauth" | "storage" | "recovered".
// Must agree with ACCOUNT_STATES, or a grouped notification opens a different
// account than the bar badge blames.
var ATTENTION_KINDS = { resync: 1, reauth: 2, failed: 3 }

function composeNotification(events, multiAccount) {
  var list = Array.isArray(events) ? events.filter(function (event) {
    return event && typeof event === "object"
  }) : []
  if (list.length === 0) return null

  var attention = list.filter(function (event) { return ATTENTION_KINDS[event.kind] })
  var recovered = list.filter(function (event) { return event.kind === "recovered" })
  var storage = list.filter(function (event) { return event.kind === "storage" })

  // Attention outranks everything: it is the only kind that is actionable.
  if (attention.length === 1 && recovered.length === 0 && storage.length === 0) {
    var only = attention[0]
    return {
      urgency: "critical",
      summary: multiAccount ? only.summary + " — " + only.name : only.summary,
      body: only.body,
      action: only.action || "",
      service: only.service
    }
  }
  if (attention.length > 0) {
    var worst = attention.slice().sort(function (left, right) {
      return ATTENTION_KINDS[left.kind] - ATTENTION_KINDS[right.kind]
    })[0]
    var others = attention.concat(recovered, storage)
    // With one account every event is about that account, so "needs attention in
    // 2 accounts" would be nonsense. Lead with the worst condition and keep its
    // own action -- which is how a single account behaved before this work.
    if (!multiAccount) {
      return {
        urgency: "critical",
        summary: worst.summary,
        body: others.length > 1
          ? others.map(function (event) { return event.short }).join("\n")
          : worst.body,
        action: worst.action || "open",
        service: worst.service
      }
    }
    if (attention.length === 1) {
      return {
        urgency: "critical",
        summary: worst.summary + " — " + worst.name,
        body: others.map(function (event) { return event.name + ": " + event.short }).join("\n"),
        // A grouped popup deliberately does not carry a direct repair action: it
        // cannot know which account the reader meant.
        action: "open",
        service: worst.service
      }
    }
    // Count ACCOUNTS, not events: one account with two conditions is not two
    // accounts. And carry the other kinds in the body -- a storage threshold is
    // edge-latched, so dropping it here loses it until it clears and re-arms.
    var names = {}
    for (var scan = 0; scan < attention.length; scan++) names[attention[scan].service] = true
    var accountCount = Object.keys(names).length
    return {
      urgency: "critical",
      summary: accountCount > 1
        ? "OneDrive needs attention in " + accountCount + " accounts"
        : worst.summary + " — " + worst.name,
      body: others.map(function (event) { return event.name + ": " + event.short }).join("\n"),
      action: "open",
      service: worst.service
    }
  }
  if (storage.length > 0) {
    // A recovery in the same burst is reported in the body rather than dropped;
    // the previous code returned the storage popup alone.
    if (storage.length === 1 && recovered.length === 0) {
      return {
        urgency: "normal",
        summary: multiAccount ? storage[0].summary + " — " + storage[0].name : storage[0].summary,
        body: storage[0].body,
        action: "",
        service: storage[0].service
      }
    }
    if (storage.length === 1) {
      return {
        urgency: "normal",
        summary: multiAccount ? storage[0].summary + " — " + storage[0].name : storage[0].summary,
        body: storage.concat(recovered).map(function (event) {
          return multiAccount ? event.name + ": " + event.short : event.short
        }).join("\n"),
        action: "",
        service: storage[0].service
      }
    }
    return {
      urgency: "normal",
      summary: storage.length + " OneDrive accounts are almost full",
      // Recoveries are carried here too. The single-storage branch above already
      // does this; omitting it here dropped an edge-latched recovery, which then
      // never re-reports.
      body: storage.concat(recovered).map(function (event) {
        return event.name + ": " + event.short
      }).join("\n"),
      action: "",
      service: storage[0].service
    }
  }
  if (recovered.length === 1) {
    return {
      urgency: "normal",
      summary: multiAccount ? "OneDrive recovered — " + recovered[0].name : "OneDrive recovered",
      body: recovered[0].body,
      action: "",
      service: recovered[0].service
    }
  }
  if (recovered.length > 1) {
    return {
      urgency: "normal",
      summary: recovered.length + " OneDrive accounts recovered",
      body: recovered.map(function (event) { return event.name + ": " + event.short }).join("\n"),
      action: "",
      service: recovered[0].service
    }
  }
  // No branch matched: an event kind this function does not know about. Say
  // nothing rather than throwing -- flushTransitions has already cleared the
  // pending list, so an exception here would lose the whole burst silently.
  return null
}

// The glyph for a badge kind. Shared so the bar badge and the account selector
// cannot drift apart -- they are the same vocabulary at two sizes.
function badgeGlyph(kind) {
  if (kind === "missing") return "\u{f0156}"
  if (kind === "login") return "\u{f030b}"
  if (kind === "paused") return "\u{f03e4}"
  if (kind === "syncing") return "\u{f0453}"
  if (kind === "attention") return "\u{f002a}"
  return ""
}

// --- scheduling decisions -----------------------------------------------------
//
// These are pure so they can be tested. The QML that calls them cannot be, and a
// reviewer's observation is the reason they exist here: "the suite is green;
// that is not evidence these paths work". Deleting the ramp or bypassing the
// semaphore used to pass every test.

// Which account should take the next poll slot? Returns an index, or -1.
// `accounts` is [{ routinePolling, initialized }]. Accounts that have not
// reported yet take priority, but the cursor still advances, so several
// unreported accounts interleave rather than the first one taking every slot.
function nextPollIndex(accounts, cursor) {
  var list = Array.isArray(accounts) ? accounts : []
  if (list.length === 0) return -1
  var start = ((cursor % list.length) + list.length) % list.length
  // Three passes: an account waiting on the result of a control it just ran,
  // then one that has never been attempted, then everyone else.
  for (var pass = 0; pass < 3; pass++) {
    for (var step = 0; step < list.length; step++) {
      var index = (start + step) % list.length
      var account = list[index]
      // `busy` covers a cloud check too: such an account will refuse the slot,
      // so handing it one wastes the tick entirely.
      if (!account || account.routinePolling === true || account.busy === true) continue
      // Priority is "has not been ATTEMPTED yet", not "has not reported". An
      // account whose helper always fails never reports, and gating on that gave
      // it every slot forever while the healthy accounts went unpolled.
      // An account that has just paused or resumed is holding an optimistic
      // state that only a fresh poll can confirm or drop. Until it gets one the
      // bar shows the pre-control sample, so it goes first -- ahead even of the
      // startup ramp, which is at worst a few seconds of "checking".
      if (pass === 0 && account.settling !== true) continue
      if (pass === 1 && account.attempted === true) continue
      return index
    }
  }
  return -1
}

// May this cloud request start now, and if not, should it be queued?
// Returns "start" | "queue" | "drop".
function cloudDecision(busy, queue, service, mode, active) {
  if (!service || !mode) return "drop"
  if (busy) {
    // The request already RUNNING counts as a duplicate too. Seeing only a
    // boolean, this used to queue a second copy of the check in flight, which
    // then ran the same 30-second query again the moment the first finished.
    if (active && active.service === service && active.mode === mode) return "drop"
    var pending = Array.isArray(queue) ? queue : []
    for (var index = 0; index < pending.length; index++) {
      if (pending[index].service === service && pending[index].mode === mode) return "drop"
    }
    return "queue"
  }
  return "start"
}

// Decide how to bring the current descriptor list in line with what discovery
// returned, as a plan of operations rather than a rebuilt list. Delegates must
// be preserved for services that still exist: recreating them would drop
// in-flight processes and the notification edge history that decides whether a
// condition is newly true.
//
// `current` is the ordered list of service names already present.
// Returns { updates: [{index,row}], appends: [row], removes: [index desc] }.
// --- the IPC account surface -------------------------------------------------
//
// These two live here rather than inline in BarWidget.qml because that file
// cannot be instantiated headless -- it derives from the bar's own BarWidget
// type -- so logic left inside it is unreachable by any test. Both functions
// were previously deletable outright without a single assertion failing.

// One row per account, in discovery order, for `omarchy-cmd ... accounts`.
function accountRows(accounts, selectedService) {
  var list = accounts || []
  var rows = []
  for (var index = 0; index < list.length; index++) {
    var account = list[index]
    rows.push({
      service: String(account.service || ""),
      instance: String(account.instance || ""),
      name: String(account.displayName || ""),
      selected: String(account.service || "") === String(selectedService || ""),
      status: String(account.statusText || "")
    })
  }
  return rows
}

// Accept either the full unit name or the bare instance, because a script author
// reaches for "personal" before "onedrive@personal.service".
//
// The full unit name is the unambiguous form, so it is matched across EVERY
// account before any instance is considered. Scanning account-by-account and
// testing both keys per account made the answer depend on discovery order: an
// instance match on the first account would beat an exact unit-name match on the
// second, and the control would then act on the wrong account.
//
// Returns the matched account's service name, or "" when nothing matches.
function resolveAccountTarget(accounts, target) {
  var list = accounts || []
  var wanted = String(target || "")
  // The plain account's instance IS "", so an unset argument would otherwise
  // match it and silently retarget every later control at the default account.
  // (No account key can equal "" today, so this guard cannot currently be
  // observed failing -- it is here so that stops being an accident.)
  if (wanted === "") return ""
  var index
  for (index = 0; index < list.length; index++) {
    if (String(list[index].service || "") === wanted) return wanted
  }
  for (index = 0; index < list.length; index++) {
    if (String(list[index].instance || "") === wanted) return String(list[index].service || "")
  }
  return ""
}

function reconcilePlan(current, discovered) {
  var present = Array.isArray(current) ? current : []
  var rows = Array.isArray(discovered) ? discovered : []
  var plan = { updates: [], appends: [], removes: [] }
  var seen = {}

  for (var index = 0; index < rows.length; index++) {
    var row = rows[index]
    if (!row || typeof row !== "object") continue
    var service = String(row.service || "")
    if (service === "") continue
    if (seen[service]) continue   // discovery should not repeat, but never trust it
    seen[service] = true
    var existing = present.indexOf(service)
    if (existing === -1) plan.appends.push(row)
    else plan.updates.push({ index: existing, row: row })
  }

  // Descending, so applying them cannot invalidate the indices that follow.
  for (var scan = present.length - 1; scan >= 0; scan--) {
    if (!seen[present[scan]]) plan.removes.push(scan)
  }
  return plan
}

function filePath(url) {
  return decodeURIComponent(String(url || "").replace(/^file:\/\//, ""))
}

if (typeof module !== "undefined") {
  module.exports = {
    defaultStatus: defaultStatus,
    parseStatus: parseStatus,
    fileExtension: fileExtension,
    fileKind: fileKind,
    fileGlyph: fileGlyph,
    formatBytes: formatBytes,
    usageText: usageText,
    freeText: freeText,
    usageFraction: usageFraction,
    usageSevere: usageSevere,
    usageShort: usageShort,
    relativeTime: relativeTime,
    checkedText: checkedText,
    activityRows: activityRows,
    activityMeta: activityMeta,
    syncMeta: syncMeta,
    activityGlyph: activityGlyph,
    fileMeta: fileMeta,
    folderName: folderName,
    tooltip: tooltip,
    heroMeta: heroMeta,
    accountName: accountName,
    accountStateKind: accountStateKind,
    accountState: accountState,
    aggregateAccounts: aggregateAccounts,
    aggregateTooltip: aggregateTooltip,
    composeNotification: composeNotification,
    elideStatus: elideStatus,
    inheritedPlainText: inheritedPlainText,
    barState: barState,
    badgeKind: badgeKind,
    openSelection: openSelection,
    needsAttention: needsAttention,
    badgeGlyph: badgeGlyph,
    nextPollIndex: nextPollIndex,
    cloudDecision: cloudDecision,
    accountRows: accountRows,
    resolveAccountTarget: resolveAccountTarget,
    reconcilePlan: reconcilePlan,
    filePath: filePath
  }
}
