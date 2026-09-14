#!/usr/bin/python3

import argparse
import fcntl
import hashlib
import heapq
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


PLUGIN_ID = "io.github.salemsayed.omaonedrive"
DEFAULT_SERVICE = "onedrive.service"
DEFAULT_RESUME_UNIT = "omaonedrive-resume"
SCAN_CACHE_SECONDS = 120
MAX_SERVICE_EVENTS = 2
MAX_FILE_EVENTS = 5
ACTIVITY_LIMIT = 5
QUOTA_TIMEOUT_SECONDS = 30
SYNC_STATUS_TIMEOUT_SECONDS = 30


def command_output(command, timeout=4):
  try:
    completed = subprocess.run(
      command,
      check=False,
      capture_output=True,
      text=True,
      timeout=timeout,
    )
  except subprocess.TimeoutExpired as error:
    stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
    stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
    return 124, (stdout + stderr).strip()
  except OSError:
    return 1, ""
  return completed.returncode, (completed.stdout + completed.stderr).strip()


def canonical_confdir(value):
  # Collapses "." and ".." segments and any trailing slash so one account cannot
  # key two different caches. Deliberately not realpath(): resolving symlinks
  # would silently move an account whose config directory is a link.
  return Path(os.path.normpath(str(value)))


def default_confdir():
  # Canonical, like every other confdir we report. The widget compares the
  # directory a reply says it read against the one discovery gave it, and refuses
  # a mismatch -- so if discovery reported "/home/u/./config/onedrive" and a poll
  # reported the normalised form, that account would be refused on every poll for
  # ever, showing nothing and saying nothing.
  config_home = os.environ.get("XDG_CONFIG_HOME")
  if config_home:
    return canonical_confdir(Path(config_home) / "onedrive")
  return canonical_confdir(Path.home() / ".config" / "onedrive")


def valid_confdir(value):
  text = str(value)
  if not text.startswith("/"):
    return False
  # Nothing is ever shell-interpolated, so ".." is not a threat here and a real
  # directory reached through one must not be rejected; only characters that
  # cannot appear in a path at all are refused.
  if any(ord(character) < 0x20 or ord(character) == 0x7F for character in text):
    return False
  path = canonical_confdir(text)
  return not path.exists() or path.is_dir()


def account_state_dir(service, confdir):
  # The default account keeps the historical directory, so its cache and lock
  # paths are unchanged. Every other account gets its own directory, which
  # isolates the lock as well as the cache: a 30s cloud check on one account
  # must not block another account's ordinary poll. Keyed on the service AND
  # the config directory, because two services may share one confdir.
  base = state_dir()
  if confdir is not None and str(service) == DEFAULT_SERVICE \
      and canonical_confdir(confdir) == canonical_confdir(default_confdir()):
    return base
  # os.fsencode, not str.encode: Linux paths are bytes, and a non-UTF-8 path
  # arrives surrogate-escaped and would raise on a strict encode.
  # An unknown confdir still gets a stable per-service key of its own.
  confdir_key = os.fsencode(str(canonical_confdir(confdir))) if confdir is not None else b""
  digest = hashlib.sha256(
    os.fsencode(str(service)) + b"\0" + confdir_key
  ).hexdigest()[:16]
  return base / "accounts" / digest


def state_dir():
  state_home = os.environ.get("XDG_STATE_HOME")
  base = Path(state_home) if state_home else Path.home() / ".local" / "state"
  return base / "omarchy" / PLUGIN_ID


# Every cache field that is used as a number. The cache is JSON we wrote, but it
# is also a file on disk that anything can edit, and a *valid* JSON document with
# a string where a number belongs used to raise ValueError before the code that
# would have repaired or replaced it -- so one bad byte made that account's
# helper fail on every poll, for ever, with no way out but deleting the file.
CACHE_INTS = (
  "scanLimit", "scanAt", "usedBytes", "quotaBytes",
  "quotaCheckedTs", "syncStatusCheckedTs", "remoteCheckedTs",
)


def load_cache(path):
  try:
    with path.open("r", encoding="utf-8") as handle:
      value = json.load(handle)
  except (OSError, json.JSONDecodeError):
    return {}
  if not isinstance(value, dict):
    return {}
  # Coerce here, once, rather than at every use site: a field that cannot be a
  # number is treated as absent, and the next save writes it back correctly.
  for key in CACHE_INTS:
    if key not in value:
      continue
    try:
      value[key] = int(value[key] or 0)
    except (TypeError, ValueError, OverflowError):
      # OverflowError is the one that is easy to miss: JSON's 1e999 parses to
      # float infinity, which int() refuses. Like the others, it killed the
      # helper for that account on every poll, for ever, before anything could
      # repair the file.
      value.pop(key, None)
  return value


def save_cache(path, value):
  path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
  os.chmod(path.parent, 0o700)
  descriptor, temporary = tempfile.mkstemp(prefix="cache-", suffix=".json", dir=path.parent)
  try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
      json.dump(value, handle, separators=(",", ":"))
      handle.write("\n")
      handle.flush()
      os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
  finally:
    try:
      os.unlink(temporary)
    except FileNotFoundError:
      pass


def parse_bool(value):
  return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def config_option(output, name):
  match = re.search(rf"^Config option '{re.escape(name)}'\s*=\s*(.*)$", output, re.MULTILINE)
  return match.group(1).strip().strip('"') if match else ""


def read_config_values(confdir):
  values = {}
  try:
    for line in (confdir / "config").read_text(encoding="utf-8").splitlines():
      match = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$", line)
      if not match:
        continue
      values[match.group(1)] = match.group(2).split("#", 1)[0].strip().strip('"')
  except (OSError, UnicodeDecodeError):
    pass
  return values


def client_config(confdir, onedrive_path):
  values = read_config_values(confdir)
  client_version = ""
  # The client CREATES the tree when handed a --confdir that does not exist, which
  # would be a config write the widget has no business making — and, before the
  # argv re-join landed, could have created a truncated path like "/home/u/My".
  if onedrive_path and not Path(confdir).is_dir():
    # --version takes no confdir, so the client version survives even when the
    # account's directory does not exist yet.
    exit_code, output = command_output([onedrive_path, "--version"], timeout=6)
    if exit_code == 0:
      client_version = output.strip().splitlines()[0].strip() if output.strip() else ""
  if onedrive_path and Path(confdir).is_dir():
    exit_code, output = command_output(
      [onedrive_path, "--confdir", str(confdir), "--display-config"],
      timeout=6,
    )
    if exit_code == 0:
      for name in ("sync_dir", "download_only", "upload_only"):
        value = config_option(output, name)
        if value != "":
          values[name] = value
      version_match = re.search(r"^Application version\s*=\s*(.+)$", output, re.MULTILINE)
      if version_match:
        client_version = version_match.group(1).strip()

  sync_dir_value = values.get("sync_dir", "")
  if sync_dir_value:
    sync_dir = Path(os.path.expandvars(os.path.expanduser(sync_dir_value)))
  elif canonical_confdir(confdir) == canonical_confdir(default_confdir()):
    sync_dir = Path.home() / "OneDrive"
  else:
    # An account whose config could not be read has no known sync directory.
    # Falling back to ~/OneDrive would list the DEFAULT account's files under
    # this account's identity, and cache them there.
    sync_dir = None
  download_only = parse_bool(values.get("download_only"))
  upload_only = parse_bool(values.get("upload_only"))
  if download_only and upload_only:
    sync_mode = "Invalid sync mode"
  elif download_only:
    sync_mode = "Download only"
  elif upload_only:
    sync_mode = "Upload only"
  else:
    sync_mode = "Two-way"
  return {
    "syncDir": sync_dir,
    "syncMode": sync_mode,
    "clientVersion": client_version,
  }


def systemctl_value(arguments):
  return command_output(["systemctl", "--user", *arguments], timeout=4)


def unit_properties(unit, names):
  """Parsed `systemctl show` properties for one unit, or None when the call failed.

  Multi-valued properties (ExecStart) keep every line; single-valued ones keep
  the first, which is all systemd emits.
  """
  exit_code, output = systemctl_value([
    "show",
    unit,
    "--property=" + ",".join(names),
    "--no-pager",
  ])
  if exit_code != 0:
    return None
  properties = {}
  for line in output.splitlines():
    key, separator, value = line.partition("=")
    if separator:
      properties.setdefault(key, []).append(value.strip())
  return properties


def service_state(service):
  properties = unit_properties(
    service,
    ["LoadState", "ActiveState", "SubState", "UnitFileState", "Result", "ExecMainCode", "ExecMainStatus"],
  ) or {}
  properties = {key: values[0] for key, values in properties.items()}
  load_state = properties.get("LoadState", "")
  active_state = properties.get("ActiveState", "")
  unit_file_state = properties.get("UnitFileState", "")
  result = properties.get("Result", "")
  try:
    exit_status = int(properties.get("ExecMainStatus", "0") or 0)
  except ValueError:
    exit_status = 0
  failed = active_state == "failed"
  return {
    "serviceAvailable": load_state == "loaded",
    "running": active_state == "active",
    "enabled": unit_file_state in ("enabled", "enabled-runtime"),
    "activeState": active_state,
    "subState": properties.get("SubState", ""),
    "serviceResult": result,
    "serviceExitStatus": exit_status,
    "serviceFailed": failed,
    "resyncRequired": failed and exit_status == 126,
  }


def resume_timer_state(unit):
  exit_code, output = systemctl_value([
    "list-timers",
    unit + ".timer",
    "--all",
    "--output=json",
    "--no-pager",
  ])
  if exit_code != 0:
    return 0
  try:
    rows = json.loads(output)
  except json.JSONDecodeError:
    return 0
  if not isinstance(rows, list) or not rows:
    return 0
  try:
    next_usec = int(rows[0].get("next", 0) or 0)
  except (AttributeError, TypeError, ValueError):
    return 0
  return next_usec // 1_000_000 if next_usec > 0 else 0


# Unit names the helper is willing to hand back to itself through --service or
# --resume-unit. Discovery and the --service gate MUST accept the same set, or an
# account can be discoverable and permanently unusable, so both patterns are
# derived from one class. Backslash and colon are here because systemd-escape
# produces them (e.g. "onedrive@team\x20space.service"); "/" is not, so
# "../bad.service" is still refused. The first character may not be "-": these
# names are passed to systemctl as positional arguments, and "-Mguest.timer" or
# "-Hsomewhere.timer" would be read as its --machine/--host OPTIONS instead.
UNIT_NAME = r"[A-Za-z0-9_.@:\\][A-Za-z0-9_.@:\\-]*"
UNIT_NAME_PATTERN = re.compile(UNIT_NAME)
SERVICE_NAME_PATTERN = re.compile(UNIT_NAME + r"\.service")

# systemd's own ceiling for a unit name, which the ".timer" suffix counts against.
MAX_UNIT_NAME_LENGTH = 255


def valid_unit_name(value, suffix):
  # One rule for every unit name the helper hands to systemctl, so the --service
  # and --resume-unit gates cannot drift apart.
  if len(value) + len(suffix) > MAX_UNIT_NAME_LENGTH:
    return False
  return UNIT_NAME_PATTERN.fullmatch(value) is not None


def resume_unit_name(value):
  # The caller passes a BARE name and resume_timer_state appends ".timer", so a
  # value that already carries one would query "<name>.timer.timer". Strip one
  # rather than refusing: the same spelling is legitimate when an instance ends
  # in ".timer", and refusing would abort the status call entirely.
  return value[: -len(".timer")] if value.endswith(".timer") else value


def valid_resume_unit(value):
  return valid_unit_name(resume_unit_name(value), ".timer")

# "onedrive.service" or "onedrive@<instance>.service"; the bare template
# "onedrive@.service" deliberately does not match — it is not an account.
ONEDRIVE_UNIT_PATTERN = re.compile(r"onedrive(?:@(?P<instance>[A-Za-z0-9_.:\\-]+))?\.service")

# systemd renders each ExecStart entry as a brace-delimited record of
# " ; "-separated key=value fields:
#   { path=/usr/bin/onedrive ; argv[]=/usr/bin/onedrive --monitor --confdir=/x ; ... }
# Splitting the record into fields (rather than searching the whole string for
# "argv[]=") is what keeps a path= value containing the literal text "argv[]="
# from being read as the argv.
# The delimiters are "{ " and " }" (with the spaces), so a brace inside an argv
# value cannot be mistaken for a record boundary.
EXEC_RECORD_PATTERN = re.compile(r"\{ (?P<body>.*?) \}")


def exec_start_fields(body):
  fields = {}
  for part in body.split(" ; "):
    key, separator, value = part.partition("=")
    if separator:
      fields.setdefault(key.strip(), value.strip())
  return fields


def join_confdir_tokens(head, rest):
  # systemd joins argv with literal spaces and does not quote, so a confdir
  # containing a space arrives split across tokens and is indistinguishable from
  # separate arguments. Re-join greedily and let the filesystem arbitrate: the
  # longest prefix that is an existing directory wins. A path that does not
  # exist stays as the first token, which is the honest reading.
  if head[:1] in ("'", '"'):
    quote = head[0]
    candidate = head[1:]
    if candidate.endswith(quote):
      return candidate[:-1]
    for token in rest:
      candidate += " " + token
      if token.endswith(quote):
        return candidate[:-1]
    return candidate
  # Every space-joined prefix is tried, including through tokens that look like
  # flags: a directory may legitimately be named "My - Work", and only the
  # filesystem can settle it. The longest one that exists wins; a following real
  # flag simply never forms an existing path.
  best = head if Path(head).is_dir() else ""
  candidate = head
  for token in rest:
    candidate += " " + token
    if Path(candidate).is_dir():
      best = candidate
  return best or head


def confdir_from_argv(argv):
  """The --confdir in one argv, or None when the argv carries none at all.

  None and "" are different answers: None means this unit simply does not pass
  --confdir (so the client default applies), while a returned string may still
  be invalid. Collapsing the two is what let an unusable confdir silently
  masquerade as the default account.
  """
  tokens = str(argv).split(" ")
  for index, token in enumerate(tokens):
    if token.startswith("--confdir="):
      return join_confdir_tokens(token[len("--confdir="):], tokens[index + 1:])
    if token == "--confdir" and index + 1 < len(tokens):
      return join_confdir_tokens(tokens[index + 1], tokens[index + 2:])
  return None


def confdir_from_exec_start(value):
  """The account's confdir; None when no --confdir applies; "" when unreadable.

  Three answers, because the caller must treat them differently: None means the
  client default genuinely applies, while "" means the ExecStart could not be
  parsed and the unit must be dropped rather than aliased onto the default
  account.
  """
  if not value.strip():
    return None
  # A unit may carry several ExecStart lines, only one of which is the OneDrive
  # client; a preparatory command's --confdir must not be mistaken for it. The
  # client's own record is authoritative once found, INCLUDING when it carries no
  # --confdir at all -- otherwise a preparatory command's flag wins by default.
  fallback = None
  parsed = False
  for match in EXEC_RECORD_PATTERN.finditer(value):
    argv = exec_start_fields(match.group("body")).get("argv[]", "")
    tokens = [token for token in argv.split(" ") if token]
    if not tokens:
      continue
    parsed = True
    confdir = confdir_from_argv(argv)
    if "onedrive" in os.path.basename(tokens[0]):
      return confdir
    if fallback is None and confdir is not None:
      fallback = confdir
  return fallback if parsed else ""


def unit_search_dirs():
  # Overridable so the test suite can enumerate a sandboxed tree instead of the
  # host's real unit directories; also useful in a container.
  override = os.environ.get("OMAONEDRIVE_UNIT_ROOTS")
  if override:
    return [Path(part) for part in override.split(":") if part]
  config_home = os.environ.get("XDG_CONFIG_HOME")
  base = Path(config_home) if config_home else Path.home() / ".config"
  runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
  directories = [base / "systemd" / "user"]
  # Runtime enablement ("systemctl --user enable --runtime") writes here, and is
  # invisible to both list-units and the persistent search path.
  if runtime_dir:
    directories.append(Path(runtime_dir) / "systemd" / "user")
  directories.extend([
    Path("/run/systemd/user"),
    Path("/etc/systemd/user"),
    # /lib/systemd/user is a usrmerge symlink to this one; globbing both is a
    # pure duplicate that the name dedupe would only have to undo.
    Path("/usr/lib/systemd/user"),
  ])
  return directories


def wants_unit_names():
  # "list-units" only reports units systemd currently has loaded, so an instance
  # that is enabled but has never been started (or was garbage-collected while
  # inactive) is invisible there. Its enablement symlink is not, and
  # "list-unit-files" never expands template instances, so the symlinks are the
  # only way to see it.
  names = []
  for directory in unit_search_dirs():
    for pattern in ("*.wants/onedrive*.service", "*.requires/onedrive*.service"):
      try:
        for link in directory.glob(pattern):
          names.append(link.name)
      except OSError:
        continue
  return names


def onedrive_unit_names():
  names = []
  exit_code, output = systemctl_value([
    "list-units",
    "onedrive*",
    "--all",
    "--no-legend",
    "--plain",
    "--no-pager",
  ])
  if exit_code == 0:
    for line in output.splitlines():
      fields = line.split()
      if fields:
        names.append(fields[0])
  # Names swept off the filesystem are raw symlink names, never validated by
  # systemd, so the pattern filter below is what keeps an unusable name out of
  # the payload — it is a gate, not a tidy-up.
  names.extend(wants_unit_names())
  return list(dict.fromkeys(
    name for name in names if ONEDRIVE_UNIT_PATTERN.fullmatch(name)
  ))


def default_account():
  return {
    "service": DEFAULT_SERVICE,
    "instance": "",
    "confdir": str(default_confdir()),
    "description": "OneDrive",
  }


def account_entry(unit):
  match = ONEDRIVE_UNIT_PATTERN.fullmatch(unit)
  if match is None:
    # Reachable from build_status: --service accepts any unit name, not only
    # ours. Not an account, so there is nothing to describe.
    return None
  properties = unit_properties(unit, ["ExecStart", "Description", "LoadState"])
  if properties is None:
    return None
  load_state = (properties.get("LoadState") or [""])[0]
  # An allowlist, not a denylist. not-found is a stale enablement symlink and
  # masked is a unit deliberately turned off, but "error", "stub" and
  # "bad-setting" leave ExecStart empty in exactly the same way -- and an empty
  # ExecStart then read as "this unit passes no --confdir, so the client default
  # applies", aliasing a template instance onto the DEFAULT account's token,
  # cache and sync directory. That is the identity leak the masked case was
  # already there to prevent.
  if load_state != "loaded":
    return None
  # All ExecStart lines are considered together: systemd emits one line per
  # record, and the "prefer the record whose argv[0] is onedrive" rule only
  # means anything when it can see every record at once.
  exec_start = [line for line in properties.get("ExecStart", []) if line.strip()]
  if not exec_start:
    # Loaded, but with nothing to run: `systemctl show` answered with no
    # properties, or the unit has no ExecStart. Either way we have learned
    # nothing about where this account lives, and answering with the default
    # would be a claim about identity we cannot support.
    return None
  confdir = confdir_from_exec_start("\n".join(exec_start))
  if confdir is None:
    # The unit really does pass no --confdir, so the client default applies.
    confdir = str(default_confdir())
  elif valid_confdir(confdir):
    confdir = str(canonical_confdir(confdir))
  else:
    # Present but unusable. Reporting the default here would alias this unit onto
    # the default account's token, cache and sync directory.
    return None
  return {
    "service": unit,
    "instance": match.group("instance") or "",
    "confdir": confdir,
    "description": (properties.get("Description") or [""])[0] or "OneDrive",
  }


def discover_accounts():
  accounts = [
    entry for entry in (account_entry(unit) for unit in onedrive_unit_names()) if entry
  ]
  if not accounts:
    # No systemd, no systemctl, or nothing enabled: degrade to the single
    # default account so callers still get a usable list.
    return [default_account()]
  accounts.sort(key=lambda row: row["instance"])
  return accounts


TRANSFER_SKIP_PREFIXES = ("changes", "differences", "new items", "items", "advertised")

# Multi-line CLI error blocks: "ERROR: ..." then indented detail lines.
ERROR_DETAIL_RE = re.compile(r"^\s*Error (Message|Reason|Code):\s*(.+)$", re.IGNORECASE)

# The client handles these itself and keeps syncing (WebSocket near-real-time
# monitoring is unavailable for some account types; the client falls back to
# interval polling), so they are not worth an attention state or activity row.
BENIGN_ERROR_MARKERS = ("websocket", "notsupported", "unable to send notification")

# The client uploads inotify-detected local changes outside a full sync pass,
# without the "Starting a sync"/"complete" bracket. A progress line older than
# this is treated as an abandoned upload rather than one still running.
LIVE_TRANSFER_STALE_SEC = 600
TRANSFER_DONE_RE = re.compile(
  r"^\s*(?:Uploading|Downloading)\b.*?(?:\|\s*DONE\b|\.\.\.\s*done\b)", re.IGNORECASE
)


def parse_transfer(message):
  match = re.match(r"^\s*(Uploading|Downloading)\b\s*:?\s*(.+)$", message, re.IGNORECASE)
  if not match:
    return None
  direction = "Uploading" if match.group(1).lower() == "uploading" else "Downloading"
  rest = re.sub(r"^(?:new\s+|modified\s+|changed\s+)?file\b\s*:?\s*", "", match.group(2).strip(), flags=re.IGNORECASE)
  percent = -1
  percent_match = re.search(r"(\d{1,3})\s*%[^%]*$", rest)
  if percent_match:
    percent = min(100, int(percent_match.group(1)))
  rest = re.sub(r"\s*\.\.\..*$", "", rest).strip()
  lowered = rest.lower()
  if not rest or any(lowered.startswith(prefix) for prefix in TRANSFER_SKIP_PREFIXES):
    return None
  name = rest.rstrip("/").split("/")[-1].strip()
  if name in ("", ".", "..", "~"):
    return None
  return direction, name, percent


def parse_sync_stage(message):
  """Turn the client's reconciliation log messages into concise UI status."""
  text = re.sub(r"\s+", " ", str(message or "")).strip()
  lowered = text.lower()
  if "internet connectivity to microsoft onedrive service has been interrupted" in lowered \
      or "retrying the respective microsoft graph api call" in lowered:
    return "Connection interrupted · retrying…"
  if "performing a full scan of online data to ensure consistent local state" in lowered:
    return "Preparing full reconciliation…"
  if "fetching items from the onedrive api" in lowered \
      or "fetching /delta response from the onedrive api" in lowered \
      or "generating a /delta response from the onedrive api" in lowered:
    return "Fetching cloud items…"
  processing = re.search(
    r"processing\s+([\d,]+)\s+applicable\s+(?:json\s+items|changes\s+and\s+items)\s+received\s+from\s+microsoft\s+onedrive",
    text,
    re.IGNORECASE,
  )
  if processing:
    try:
      item_count = f"{int(processing.group(1).replace(',', '')):,}"
    except ValueError:
      item_count = processing.group(1)
    return f"Processing {item_count} cloud items…"
  if "performing a database consistency and integrity check on locally stored data" in lowered:
    return "Checking local sync database…"
  if "scanning the local file system" in lowered and "for new data to upload" in lowered:
    return "Scanning local files for uploads…"
  if "performing a last examination of the most recent online data" in lowered \
      or "performing a final true-up scan of online data" in lowered:
    return "Finalizing reconciliation…"
  if "syncing changes from microsoft onedrive" in lowered:
    return "Checking cloud changes…"
  return ""


def journal_state(service, now=None):
  now = int(time.time()) if now is None else now
  exit_code, output = command_output(
    ["journalctl", "--user", "--unit", service, "--lines", "120", "--no-pager", "--output", "json"],
    timeout=5,
  )
  result = {
    "syncing": False,
    "lastSyncTs": 0,
    "lastError": "",
    "reauthRequired": False,
    "events": [],
    "transferFile": "",
    "transferDirection": "",
    "transferPercent": -1,
    "syncStage": "",
  }
  if exit_code != 0:
    return result

  last_start = 0
  last_complete = 0
  last_error = 0
  last_reauth = 0
  last_transfer_ts = 0
  last_transfer = None
  last_stage_ts = 0
  last_stage = ""
  live_start = 0
  live_done = 0
  live_progress = 0
  error_events = []
  for line in output.splitlines():
    try:
      row = json.loads(line)
    except json.JSONDecodeError:
      continue
    message = str(row.get("MESSAGE", ""))
    try:
      timestamp = int(row.get("__REALTIME_TIMESTAMP", 0)) // 1_000_000
    except (TypeError, ValueError):
      timestamp = 0
    lowered = message.lower()
    detail = ERROR_DETAIL_RE.match(message)
    if detail and error_events and timestamp - error_events[-1]["ts"] <= 5:
      merged = error_events[-1]["text"].rstrip() + " " + re.sub(r"\s+", " ", detail.group(2)).strip()
      error_events[-1]["text"] = merged[:180]
      continue
    transfer = parse_transfer(message)
    if transfer and timestamp >= last_transfer_ts:
      last_transfer_ts = timestamp
      last_transfer = transfer
    if TRANSFER_DONE_RE.match(message):
      live_done = max(live_done, timestamp)
    elif transfer:
      live_progress = max(live_progress, timestamp)
    if "new items to upload to microsoft onedrive" in lowered:
      live_start = max(live_start, timestamp)
    stage = parse_sync_stage(message)
    if stage and timestamp >= last_stage_ts:
      last_stage_ts = timestamp
      last_stage = stage
    if "starting a sync with microsoft onedrive" in lowered or "syncing changes from microsoft onedrive" in lowered:
      last_start = max(last_start, timestamp)
    if "sync with microsoft onedrive is complete" in lowered:
      last_complete = max(last_complete, timestamp)
      if timestamp > 0:
        result["events"].append({"kind": "sync", "ts": timestamp, "text": "Sync complete"})
    if any(marker in lowered for marker in ("error:", "fatal:", "sync aborted", "requires a --resync", "integrity failure")):
      cleaned_message = re.sub(r"\s+", " ", message).strip()[:180]
      if timestamp > 0:
        error_events.append({"kind": "error", "ts": timestamp, "text": cleaned_message})
    if any(marker in lowered for marker in (
      "issue a --reauth",
      "fresh auth token is needed",
      "reauthenticate this client",
    )):
      last_reauth = max(last_reauth, timestamp)

  kept_errors = [
    event for event in error_events
    if not any(marker in event["text"].lower() for marker in BENIGN_ERROR_MARKERS)
  ]
  for event in kept_errors:
    event["recovered"] = last_complete >= event["ts"]
  result["events"].extend(kept_errors)
  if kept_errors:
    newest = max(kept_errors, key=lambda event: event["ts"])
    last_error = newest["ts"]
    result["lastError"] = newest["text"]

  result["events"] = sorted(result["events"], key=lambda event: event["ts"], reverse=True)[:MAX_SERVICE_EVENTS]
  pass_syncing = last_start > last_complete
  live_evidence = max(live_start, live_progress)
  live_syncing = (
    not pass_syncing
    and live_evidence > max(live_done, last_complete)
    and now - live_evidence <= LIVE_TRANSFER_STALE_SEC
  )
  result["lastSyncTs"] = last_complete if pass_syncing else max(last_complete, live_done)
  result["syncing"] = pass_syncing or live_syncing
  result["reauthRequired"] = last_reauth > last_complete
  if last_transfer and (
    (pass_syncing and last_transfer_ts >= last_start)
    or (live_syncing and last_transfer_ts >= live_evidence)
  ):
    result["transferDirection"], result["transferFile"], result["transferPercent"] = last_transfer
  if (pass_syncing and last_stage_ts >= last_start) or (live_syncing and last_stage_ts >= live_evidence):
    result["syncStage"] = last_stage
  if last_complete >= last_error:
    result["lastError"] = ""
  return result


def scan_recent(path, limit):
  counter = 0
  recent = []
  if not path.is_dir():
    return []
  try:
    for root, directories, files in os.walk(path):
      directories[:] = [name for name in directories if not os.path.islink(os.path.join(root, name))]
      for name in files:
        file_path = os.path.join(root, name)
        if os.path.islink(file_path):
          continue
        try:
          stat = os.stat(file_path)
        except OSError:
          continue
        relative = os.path.relpath(file_path, path)
        folder = os.path.dirname(relative)
        row = {
          "name": name,
          "path": file_path,
          "folder": "/" if folder in ("", ".") else folder,
          "modifiedTs": int(stat.st_mtime),
          "sizeBytes": stat.st_size,
        }
        counter += 1
        entry = (row["modifiedTs"], counter, row)
        if len(recent) < limit:
          heapq.heappush(recent, entry)
        else:
          heapq.heappushpop(recent, entry)
  except OSError:
    return []
  return [entry[2] for entry in sorted(recent, reverse=True)]


def parse_quota(output):
  used_match = re.search(r"^Used:\s+.*?\((\d+) bytes\)\s*$", output, re.MULTILINE)
  total_match = re.search(r"^Total:\s+.*?\((\d+) bytes\)\s*$", output, re.MULTILINE)
  if not used_match or not total_match:
    return None
  return int(used_match.group(1)), int(total_match.group(1))


def parse_remote_status(output):
  lowered = output.lower()
  if "there are no pending changes" in lowered and "matches the data online" in lowered:
    return "Up to date"
  if "pending changes" in lowered or "is out of sync with microsoft onedrive" in lowered:
    return "Pending changes"
  lines = [re.sub(r"\s+", " ", line).strip() for line in output.splitlines() if line.strip()]
  return lines[-1][:120] if lines else "Could not determine"


def migrate_cloud_cache(cache):
  legacy_error = str(cache.get("remoteError", ""))
  if "quotaError" not in cache:
    cache["quotaError"] = "; ".join(
      part.strip() for part in legacy_error.split(";") if "quota" in part.lower()
    )
  if "syncStatusError" not in cache:
    cache["syncStatusError"] = "; ".join(
      part.strip() for part in legacy_error.split(";") if "quota" not in part.lower()
    )

  checked_at = int(cache.get("remoteCheckedTs", 0) or 0)
  if "quotaCheckedTs" not in cache and cache.get("quotaKnown") is True:
    cache["quotaCheckedTs"] = checked_at
  if "syncStatusCheckedTs" not in cache and (
    cache.get("remoteStatus", "Not checked") != "Not checked" or cache.get("syncStatusError")
  ):
    cache["syncStatusCheckedTs"] = checked_at


def update_cloud_compatibility(cache):
  cache["remoteCheckedTs"] = max(
    int(cache.get("quotaCheckedTs", 0) or 0),
    int(cache.get("syncStatusCheckedTs", 0) or 0),
  )
  cache["remoteError"] = "; ".join(
    error for error in (
      str(cache.get("quotaError", "")),
      str(cache.get("syncStatusError", "")),
    ) if error
  )


def apply_quota_result(cache, exit_code, output, checked_at):
  quota = parse_quota(output) if exit_code == 0 else None
  if quota:
    cache["usedBytes"], cache["quotaBytes"] = quota
    cache["quotaKnown"] = True
    cache["quotaError"] = ""
  else:
    cache["quotaError"] = "Cloud quota check timed out" \
      if exit_code == 124 else "Cloud quota check failed"
  cache["quotaCheckedTs"] = checked_at


def apply_sync_status_result(cache, exit_code, output, checked_at):
  if exit_code == 0:
    cache["remoteStatus"] = parse_remote_status(output)
    cache["syncStatusError"] = ""
  else:
    cache["syncStatusError"] = "Microsoft Graph check timed out" \
      if exit_code == 124 else "Cloud sync check failed"
  cache["syncStatusCheckedTs"] = checked_at


def cloud_check(onedrive_path, confdir, cache, check_quota, check_sync_status):
  quota_command = [onedrive_path, "--confdir", str(confdir), "--display-quota"]
  status_command = [onedrive_path, "--confdir", str(confdir), "--display-sync-status"]
  checked_at = int(time.time())
  if check_quota and check_sync_status:
    with ThreadPoolExecutor(max_workers=2) as executor:
      quota_future = executor.submit(command_output, quota_command, QUOTA_TIMEOUT_SECONDS)
      status_future = executor.submit(command_output, status_command, SYNC_STATUS_TIMEOUT_SECONDS)
      quota_result = quota_future.result()
      status_result = status_future.result()
    apply_quota_result(cache, *quota_result, checked_at)
    apply_sync_status_result(cache, *status_result, checked_at)
  elif check_quota:
    apply_quota_result(cache, *command_output(quota_command, timeout=QUOTA_TIMEOUT_SECONDS), checked_at)
  elif check_sync_status:
    apply_sync_status_result(
      cache,
      *command_output(status_command, timeout=SYNC_STATUS_TIMEOUT_SECONDS),
      checked_at,
    )
  update_cloud_compatibility(cache)


def resume_time_text(resume_at, now=None):
  current = int(time.time()) if now is None else int(now)
  seconds = max(0, int(resume_at or 0) - current)
  if seconds < 60:
    return "<1m"
  minutes = (seconds + 59) // 60
  if minutes < 60:
    return f"{minutes}m"
  hours, remaining = divmod(minutes, 60)
  return f"{hours}h" if remaining == 0 else f"{hours}h {remaining}m"


def status_text(installed, authenticated, service, journal, resume_at=0):
  if not installed:
    return "Not installed"
  if not authenticated:
    return "Login required"
  if journal["reauthRequired"]:
    return "Reauthentication required"
  if not service["serviceAvailable"]:
    return "Service unavailable"
  if service["resyncRequired"]:
    return "Resync required"
  if service["serviceFailed"] or journal["lastError"]:
    return "Attention needed"
  if service["activeState"] == "activating":
    return "Starting…"
  if not service["running"] and resume_at > int(time.time()):
    return "Paused · resumes in " + resume_time_text(resume_at)
  if not service["running"] and not service["enabled"]:
    return "Auto-start disabled"
  if not service["running"]:
    return "Sync paused"
  if journal["syncing"]:
    if journal.get("syncStage") == "Connection interrupted · retrying…":
      return journal["syncStage"]
    transfer_file = journal.get("transferFile", "")
    if transfer_file:
      text = journal.get("transferDirection", "Syncing") + " " + transfer_file
      percent = int(journal.get("transferPercent", -1) or -1)
      if 0 <= percent <= 100:
        text += " · " + str(percent) + "%"
      return text
    if journal.get("syncStage"):
      return journal["syncStage"]
    return "Syncing…"
  return "Monitoring"


def build_status(args):
  onedrive_path = shutil.which("onedrive")
  if args.confdir:
    confdir = canonical_confdir(args.confdir)
  elif args.service != DEFAULT_SERVICE:
    # Asked about another account but told nothing about where it lives: read the
    # confdir out of that unit, exactly as discovery does. Reporting the default
    # account's token and files under this account's name would be a lie.
    entry = account_entry(args.service)
    # None, not the default: an unresolvable unit is an unknown account, and
    # answering with the default account's data would be a lie about identity.
    confdir = canonical_confdir(entry["confdir"]) if entry else None
  else:
    confdir = canonical_confdir(default_confdir())
  config = client_config(confdir, onedrive_path) if confdir else {
    "syncDir": None,
    "syncMode": "Two-way",
    "clientVersion": "",
  }
  sync_dir = config["syncDir"]
  authenticated = confdir is not None and (confdir / "refresh_token").is_file()
  service = service_state(args.service)
  # Each account schedules its own transient resume unit, so the caller names it.
  # Without the flag only the plain service has a well-known one --
  # DEFAULT_RESUME_UNIT starts onedrive.service, so its pending time belongs to
  # that SERVICE whichever config directory was named -- and every other account
  # reports no resume time rather than borrowing that one.
  resume_unit = args.resume_unit or (
    DEFAULT_RESUME_UNIT if args.service == DEFAULT_SERVICE else ""
  )
  resume_at = resume_timer_state(resume_unit_name(resume_unit)) if resume_unit else 0
  journal = journal_state(args.service) if service["serviceAvailable"] else {
    "syncing": False,
    "lastSyncTs": 0,
    "lastError": "",
    "reauthRequired": False,
    "events": [],
    "transferFile": "",
    "transferDirection": "",
    "transferPercent": -1,
    "syncStage": "",
  }

  directory = account_state_dir(args.service, confdir)
  directory.mkdir(parents=True, exist_ok=True, mode=0o700)
  # Every level, not just the leaf: mkdir applies its mode to the leaf alone, so
  # a run for a non-default account would otherwise leave the plugin state root
  # world-traversable on a machine where the default account never polls.
  os.chmod(state_dir(), 0o700)
  os.chmod(directory, 0o700)
  if directory != state_dir():
    os.chmod(directory.parent, 0o700)
  # Both the lock and the cache live in this directory, so a 30s cloud check on
  # one account cannot block another account's ordinary poll.
  lock_path = directory / "status.lock"
  cache_path = directory / "status-cache.json"
  with lock_path.open("a+", encoding="utf-8") as lock:
    os.chmod(lock_path, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX)
    cache = load_cache(cache_path)
    if cache.get("remoteStatus") == "Check failed":
      cache["remoteStatus"] = "Not checked"
    migrate_cloud_cache(cache)
    now = int(time.time())
    cached_sync_dir = str(cache.get("scanSyncDir", ""))
    cached_limit = int(cache.get("scanLimit", 0) or 0)
    scan_at = int(cache.get("scanAt", 0) or 0)
    sync_dir_text = str(sync_dir) if sync_dir else ""
    if cached_sync_dir != sync_dir_text or cached_limit != args.limit or now - scan_at >= SCAN_CACHE_SECONDS:
      cache["files"] = scan_recent(sync_dir, args.limit) if sync_dir else []
      cache["scanAt"] = now
      cache["scanSyncDir"] = sync_dir_text
      cache["scanLimit"] = args.limit

    check_quota = args.remote or args.quota
    check_sync_status = args.remote or args.sync_status
    if (check_quota or check_sync_status) and onedrive_path and authenticated:
      cloud_check(onedrive_path, confdir, cache, check_quota, check_sync_status)

    save_cache(cache_path, cache)

  local_error = journal["lastError"]
  if service["resyncRequired"] and not local_error:
    local_error = "OneDrive stopped because a manual --resync is required"
  elif service["serviceFailed"] and not local_error:
    local_error = "OneDrive service failed"
  files = cache.get("files", [])
  activity = []
  for event in journal["events"]:
    if event["ts"] <= 0:
      continue
    recovered = event["kind"] == "error" and event.get("recovered") is True
    title = event["text"]
    detail = ""
    if recovered:
      lowered = title.lower()
      if "curl" in lowered or "failed sending data to the peer" in lowered:
        title = "Connection interruption — recovered"
      elif "integrity failure" in lowered:
        title = "Upload integrity failure — recovered"
      else:
        title = "Sync error — recovered"
      detail = re.sub(r"^(?:ERROR|WARNING):\s*", "", event["text"], flags=re.IGNORECASE)
    activity.append({
      "kind": event["kind"],
      "recovered": recovered,
      "ts": event["ts"],
      "title": title,
      "detail": detail,
      "path": "",
    })
  recent_files = []
  for row in files:
    modified_ts = row.get("modifiedTs", 0)
    if type(modified_ts) is not int or modified_ts <= 0:
      continue
    recent_files.append((modified_ts, row))
  recent_files = sorted(recent_files, key=lambda entry: entry[0], reverse=True)[:MAX_FILE_EVENTS]
  for modified_ts, row in recent_files:
    folder = str(row.get("folder", "/") or "/")
    activity.append({
      "kind": "file",
      "ts": modified_ts,
      "title": str(row.get("name", "") or ""),
      "detail": "changed in OneDrive" if folder == "/" else "changed in " + folder,
      "path": str(row.get("path", "") or ""),
    })
  activity = sorted(activity, key=lambda row: row["ts"], reverse=True)[:ACTIVITY_LIMIT]
  result = {
    "ok": True,
    "installed": onedrive_path is not None,
    **service,
    "authenticated": authenticated,
    "reauthRequired": journal["reauthRequired"],
    "syncing": service["running"] and journal["syncing"],
    "syncStage": journal["syncStage"] if service["running"] else "",
    "statusText": status_text(onedrive_path is not None, authenticated, service, journal, resume_at),
    "resumeAt": resume_at,
    # The identity stamp. The widget cannot otherwise tell whether a reply
    # describes the account it now believes this unit to be: the startup poll
    # runs before discovery has read the unit's ExecStart, so it uses the
    # client's default directory, and if the unit overrides it that reply belongs
    # to a different account entirely.
    "confdir": str(confdir) if confdir else "",
    "syncDir": str(sync_dir) if sync_dir else "",
    "syncMode": config["syncMode"],
    "clientVersion": config["clientVersion"],
    "lastSyncTs": journal["lastSyncTs"],
    "usedBytes": int(cache.get("usedBytes", 0) or 0),
    "quotaBytes": int(cache.get("quotaBytes", 0) or 0),
    "quotaKnown": cache.get("quotaKnown") is True,
    "quotaCheckedTs": int(cache.get("quotaCheckedTs", 0) or 0),
    "quotaError": str(cache.get("quotaError", "")),
    "remoteStatus": str(cache.get("remoteStatus", "Not checked")),
    "syncStatusCheckedTs": int(cache.get("syncStatusCheckedTs", 0) or 0),
    "syncStatusError": str(cache.get("syncStatusError", "")),
    "remoteCheckedTs": int(cache.get("remoteCheckedTs", 0) or 0),
    "remoteError": str(cache.get("remoteError", "")),
    "files": files,
    "activity": activity,
    "lastError": local_error,
  }
  return result


def main():
  parser = argparse.ArgumentParser(description="Read OneDrive CLI state for OmaOneDrive")
  parser.add_argument("--quota", action="store_true", help="query Microsoft for cloud quota only")
  parser.add_argument("--sync-status", action="store_true", help="query Microsoft for full-drive sync status only")
  parser.add_argument("--remote", action="store_true", help="query both quota and full-drive sync status")
  parser.add_argument("--limit", type=int, default=20, help="number of recent local files")
  parser.add_argument("--service", default=DEFAULT_SERVICE, help="systemd user service name")
  parser.add_argument("--confdir", default=None, help="OneDrive config directory for this account")
  parser.add_argument(
    "--resume-unit",
    default=None,
    help="bare name of this account's transient resume unit, without a suffix; "
         "when omitted only " + DEFAULT_SERVICE + " reads its legacy "
         + DEFAULT_RESUME_UNIT + " timer and every other account reports none",
  )
  parser.add_argument(
    "--list-accounts",
    action="store_true",
    help="print the accounts configured on this machine as JSON and exit",
  )
  args = parser.parse_args()
  args.limit = max(5, min(50, args.limit))
  if not SERVICE_NAME_PATTERN.fullmatch(args.service) \
      or not valid_unit_name(args.service[: -len(".service")], ".service"):
    parser.error("invalid service name")
  if args.confdir is not None and not valid_confdir(args.confdir):
    parser.error("invalid confdir")
  if args.resume_unit is not None and not valid_resume_unit(args.resume_unit):
    parser.error("invalid resume unit")
  if args.list_accounts:
    print(json.dumps(discover_accounts(), separators=(",", ":")))
    return
  print(json.dumps(build_status(args), separators=(",", ":")))


if __name__ == "__main__":
  main()
