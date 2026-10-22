.pragma library

// The launch options OmaLumineCapture keeps in settings.json, turned into
// lumine-capture command line arguments - and back again.
//
// Every option in the panel maps to one documented flag of lumine-capture 0.3:
//
//   -m, --monitor            only the monitor under the pointer
//   -d, --delay <SECONDS>    take the shot this long after launch (3, 0.5, ...)
//   -t, --to <LETTERS>       c copy, p pin, s save, o stdout, r primary selection
//   -o, --output <DIR>       save into this directory (implies s)
//   -n, --nonotify           no notifications for this launch
//   --ocr-daemon <ACTION>    serve | status | stop | calibrate
//
// Modes are not in that list, but they decide whether the `r` letter of --to
// means anything ("only for -r ocr"), so they are modelled here too.
//
// Pure JS with no QML in it: it is also runnable under node, see
// tests/launch-args.test.mjs.

var MODES = [
  { value: "", label: "Editor (no mode)", argv: [], hint: "Opens the editor: drag a selection, annotate, choose what to do." },
  { value: "full", label: "Full screen", argv: ["-f"], hint: "Grabs the whole screen at once, no editor." },
  { value: "window", label: "Active window", argv: ["-w"], hint: "Grabs the active window, no editor." },
  { value: "region", label: "Region", argv: ["-r"], hint: "Drag a region; releasing the mouse takes the shot, then does what Send to says." },
  { value: "region-ocr", label: "Region OCR", argv: ["-r", "ocr"], hint: "Drag a region and read the text in it. Notification when the scan is done." }
]

// The letters of -t, in the order they are written back out. Labels and
// descriptions are plain words: the letters stay in settings.json only.
var TO_OPTIONS = [
  { value: "c", label: "Copy", description: "put the image on the clipboard" },
  { value: "p", label: "Pin", description: "keep the shot on screen" },
  { value: "s", label: "Save", description: "write it to the output folder" },
  { value: "o", label: "Stdout", description: "hand the PNG to a command on stdout" },
  { value: "r", label: "Primary selection", description: "the middle-click target, only Region OCR acts on it" }
]

var TO_ORDER = ["c", "p", "s", "o", "r"]

var DAEMON_ACTIONS = [
  { value: "", label: "Not on launch", hint: "No daemon action when the shortcut runs. The engine reads its OCR settings when the daemon starts, so run stop after changing them." },
  { value: "serve", label: "serve", hint: "Keep a ready OCR engine in the background for later launches." },
  { value: "status", label: "status", hint: "Report whether the OCR daemon is running." },
  { value: "stop", label: "stop", hint: "Stop the background OCR daemon." },
  { value: "calibrate", label: "calibrate", hint: "Measure this machine once and pick CPU or GPU for the daemon." }
]

// Characters a shell command line carries without quoting. Anything else makes
// the path quoted.
var SAFE_PATH = /^[A-Za-z0-9._+=/@%~-]+$/

var MAX_DELAY = 3600

function modeArgv(mode) {
  for (var i = 0; i < MODES.length; i++) {
    if (MODES[i].value === mode) return MODES[i].argv
  }
  return []
}

function isDaemonAction(v) {
  for (var i = 0; i < DAEMON_ACTIONS.length; i++) {
    if (DAEMON_ACTIONS[i].value === v) return true
  }
  return false
}

function defaultOptions() {
  return {
    mode: "",
    monitor: false,
    delay: "",
    to: "",
    toNothing: false,
    output: "",
    nonotify: false,
    ocrDaemon: "",
    extraArgs: ""
  }
}

// Seconds as typed: accepts "3", "0.5", ".5", "3,5". Returns "" for no delay.
function normalizeDelay(raw) {
  var t = String(raw === undefined || raw === null ? "" : raw).trim().replace(",", ".")
  if (t === "") return ""
  if (!/^(\d+(\.\d*)?|\.\d+)$/.test(t)) return null
  var n = Number(t)
  if (!isFinite(n) || n <= 0) return ""
  if (n > MAX_DELAY) return null
  // Trim a trailing ".0" so "-d 3" stays "-d 3" and round-trips.
  return String(n)
}

// Letters in canonical order, deduplicated, unknown letters dropped.
function toLetters(list) {
  var picked = {}
  var arr = []
  if (list) {
    for (var i = 0; i < list.length; i++) {
      var raw = String(list[i])
      for (var j = 0; j < raw.length; j++) {
        var ch = raw.charAt(j).toLowerCase()
        if (TO_ORDER.indexOf(ch) >= 0 && !picked[ch]) { picked[ch] = true; arr.push(ch) }
      }
    }
  }
  arr.sort(function (a, b) { return TO_ORDER.indexOf(a) - TO_ORDER.indexOf(b) })
  return arr.join("")
}

function quotePath(p) {
  // Single quotes, the way Omarchy's own Hyprland bindings quote commands.
  // A literal single quote in the path is out of reach: the plugin's launchers
  // strip them, so drop it here rather than build a command line that breaks.
  var clean = String(p).replace(/'/g, "")
  return SAFE_PATH.test(clean) ? clean : "'" + clean + "'"
}

// Path as stored in settings.json: strip surrounding quotes a user may paste.
function cleanPath(p) {
  var t = String(p === undefined || p === null ? "" : p).trim()
  if (t.length >= 2 && (t.charAt(0) === "'" && t.charAt(t.length - 1) === "'" ||
      t.charAt(0) === '"' && t.charAt(t.length - 1) === '"')) {
    t = t.slice(1, -1)
  }
  return t
}

// opts -> { args, argv, warnings }
function buildArgs(opts) {
  var o = opts || {}
  var argv = []
  var warnings = []
  var mode = o.mode || ""
  var daemon = o.ocrDaemon || ""
  var output = cleanPath(o.output)
  var delay = normalizeDelay(o.delay)
  var letters = toLetters(o.to || "")

  if (delay === null) {
    warnings.push("Delay \u201c" + String(o.delay).trim() + "\u201d is not a usable number of seconds, ignored (use 3, 0.5, ...).")
    delay = ""
  }

  if (daemon && !isDaemonAction(daemon)) {
    warnings.push("Unknown --ocr-daemon action \u201c" + daemon + "\u201d, ignored.")
    daemon = ""
  }

  if (daemon) {
    argv.push("--ocr-daemon", daemon)
    var carried = []
    if (mode) carried.push("mode")
    if (o.monitor) carried.push("monitor")
    if (delay) carried.push("delay")
    if (letters) carried.push("send to")
    if (o.toNothing) carried.push("nothing happens when you finish")
    if (output) carried.push("output folder")
    if (o.nonotify) carried.push("no notifications")
    if (carried.length) {
      warnings.push("The daemon action is a command of its own: " + carried.join(", ") +
                    (carried.length > 1 ? " are" : " is") + " not part of it.")
    }
  } else {
    argv = argv.concat(modeArgv(mode))

    if (o.monitor) {
      argv.push("-m")
      if (mode === "window") {
        warnings.push("\u201cOnly the monitor under the pointer\u201d does nothing in active window mode: the app ignores it.")
      }
    }

    if (delay) {
      argv.push("-d", delay)
      if (Number(delay) > 60) {
        warnings.push("A delay of " + delay + " s is a long wait for a shortcut.")
      }
    }

    if (o.toNothing) {
      argv.push("-t")
      if (letters) {
        warnings.push("\u201cNothing happens when you finish\u201d leaves no room for \u201c" + letters + "\u201d: those choices are not used.")
      }
    } else if (letters) {
      argv.push("-t", letters)
      if (letters.indexOf("r") >= 0 && mode !== "region-ocr") {
        warnings.push("Primary selection only does something in Region OCR mode; a screenshot ignores it.")
      }
      if (letters.indexOf("o") >= 0 && mode === "region-ocr") {
        warnings.push("The OCR run uses copy, primary selection and stdout; pin and save are ignored.")
      }
    }

    if (output) {
      argv.push("-o", quotePath(output))
      if (letters && letters.indexOf("s") < 0) {
        warnings.push("An output folder saves the shot, so it is saved even without \u201cSave\u201d ticked.")
      }
      if (output.indexOf(",") >= 0) {
        warnings.push("The output path contains a comma, which the global keybinding cannot carry: only the bar icon will pass it on.")
      }
    }

    if (o.nonotify) argv.push("-n")
  }

  var extra = String(o.extraArgs || "").trim()
  if (extra) {
    argv.push(extra)
    if (!/^[\x20-\x7e]*$/.test(extra) || !/^[A-Za-z0-9 ._+=/@%:,~'-]*$/.test(extra)) {
      warnings.push("Extra arguments use characters the global keybinding cannot carry: only the bar icon will pass them on.")
    }
  }

  return { argv: argv, args: argv.join(" "), warnings: warnings }
}

// Split a command line into tokens, honouring 'single' and "double" quotes.
// Shell escapes ('\'' inside a single-quoted run) are folded back.
function tokenize(str) {
  var out = []
  var cur = ""
  var quote = null
  var text = String(str || "")
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (quote) {
      if (c === quote) { quote = null; continue }
      if (quote === "'" && c === "\\" && text.charAt(i + 1) === "'" ) { i++; cur += "'"; continue }
      cur += c
      continue
    }
    if (c === "'" || c === '"') { quote = c; continue }
    if (/\s/.test(c)) {
      if (cur !== "") { out.push(cur); cur = "" }
      continue
    }
    cur += c
  }
  if (cur !== "") out.push(cur)
  return out
}

var DAEMON_FLAGS = { "serve": 1, "status": 1, "stop": 1, "calibrate": 1 }

// Flags the plugin does not model, kept verbatim in extraArgs.
var PASSTHROUGH_BOOL = {
  "-s": 1, "--speed": 1, "-h": 1, "--help": 1, "-V": 1, "--version": 1,
  "--print-default-config": 1, "--clipboard-daemon": 1, "--pin": 1
}

var PASSTHROUGH_VALUE = { "--config": 1 }

function needsQuoting(token) {
  return !/^[A-Za-z0-9._+=/@%:,~'-]*$/.test(token)
}

// A launch argument string -> the options it stands for. Used to migrate the
// free-text "launch args" of older settings, and to read back what the panel
// produced. Leftover flags go to extraArgs, so nothing is lost.
function parseArgs(str) {
  var o = defaultOptions()
  var tokens = tokenize(str)
  var extra = []
  var i = -1
  var t = "", longName = "", longValue = "", shortName = "", shortValue = "", hasEq = false

  // -d, -d0.5, --delay 0.5 and --delay=0.5 all name the same option.
  function isFlag(shortFlag, longFlag) {
    if (shortFlag && t === shortFlag) return true
    if (longFlag && (t === longFlag || (hasEq && longName === longFlag))) return true
    return !!(shortFlag && shortName === shortFlag && shortValue !== "")
  }

  function valueOf(shortFlag, longFlag) {
    if (hasEq && longName === longFlag) return longValue
    if (shortName === shortFlag && shortValue !== "") return shortValue
    var v = i + 1 < tokens.length ? tokens[i + 1] : ""
    // A dash means the value was left out: "-t -m" is a bare -t, not "-t -m".
    if (v === "" || v.charAt(0) === "-") return ""
    i++
    return v
  }

  for (i = 0; i < tokens.length; i++) {
    t = tokens[i]
    var eq = t.indexOf("=")
    hasEq = t.indexOf("--") === 0 && eq > 0
    longName = t.indexOf("--") === 0 ? (eq > 0 ? t.slice(0, eq) : t) : ""
    longValue = eq > 0 ? t.slice(eq + 1) : ""
    shortName = t.length > 2 && t.charAt(0) === "-" && t.charAt(1) !== "-" ? t.slice(0, 2) : ""
    shortValue = shortName ? t.slice(2) : ""

    if (t === "-f" || t === "--full") { o.mode = "full"; continue }
    if (t === "-w" || t === "--window") { o.mode = "window"; continue }
    if (t === "-m" || t === "--monitor") { o.monitor = true; continue }
    if (t === "-n" || t === "--nonotify") { o.nonotify = true; continue }
    if (t === "-r" || t === "--region") {
      if (tokens[i + 1] === "ocr") { o.mode = "region-ocr"; i++ } else { o.mode = "region" }
      continue
    }
    if (isFlag("-t", "--to")) {
      var lettersArg = valueOf("-t", "--to")
      if (lettersArg === "") { o.toNothing = true; continue }
      var letters = toLetters(lettersArg)
      if (letters) o.to = letters
      continue
    }
    if (isFlag("-d", "--delay")) {
      var secs = normalizeDelay(valueOf("-d", "--delay"))
      o.delay = secs === null ? "" : secs
      continue
    }
    if (isFlag("-o", "--output")) {
      o.output = cleanPath(valueOf("-o", "--output"))
      continue
    }
    if (t === "--ocr-daemon" || (hasEq && longName === "--ocr-daemon")) {
      var action = hasEq ? longValue : valueOf("", "--ocr-daemon")
      if (DAEMON_FLAGS[action]) o.ocrDaemon = action
      continue
    }
    if (PASSTHROUGH_BOOL[t]) { extra.push(t); continue }
    if (PASSTHROUGH_VALUE[t] || PASSTHROUGH_VALUE[longName]) {
      extra.push(t)
      if (!hasEq) {
        var val = valueOf("", longName)
        if (val !== "") extra.push(needsQuoting(val) ? "'" + val + "'" : val)
      }
      continue
    }
    // "ocr" on its own, or anything unrecognised: keep it for the user.
    extra.push(needsQuoting(t) ? "'" + t + "'" : t)
  }

  o.extraArgs = extra.join(" ")
  return o
}

// Per-mode shortcut command: the global options with the mode replaced by the
// mode of the shortcut. The OCR daemon action is a command of its own, so it
// is dropped here; buildArgs would emit it alone and drop the mode flag.
function buildArgsForMode(opts, mode) {
  var merged = {}
  for (var k in opts) merged[k] = opts[k]
  merged.mode = mode
  merged.ocrDaemon = ""
  return buildArgs(merged)
}
