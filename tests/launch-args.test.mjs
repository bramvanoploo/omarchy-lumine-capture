// LaunchArgs.js is a QML library, so it starts with `.pragma library`, which
// node cannot parse. Strip that line, evaluate the rest, and check the
// round trip: options -> arguments -> options.
//
//   node tests/launch-args.test.mjs

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"

const here = path.dirname(fileURLToPath(import.meta.url))
const src = readFileSync(path.join(here, "..", "LaunchArgs.js"), "utf8").replace(/^\.pragma library/m, "")
// Top-level `function`/`var` declarations of the library live in the scope of
// the wrapper, so hand the ones under test back out as an object.
const names = ["MODES", "TO_OPTIONS", "TO_ORDER", "DAEMON_ACTIONS", "defaultOptions",
  "normalizeDelay", "toLetters", "toLabels", "quotePath", "cleanPath", "buildArgs", "buildArgsForMode", "tokenize", "parseArgs", "modeArgv"]
const api = new Function(`"use strict"; ${src}; return {${names.join(", ")}}`)()

let failures = 0
function eq(label, got, want) {
  const a = JSON.stringify(got), b = JSON.stringify(want)
  if (a !== b) { failures++; console.log(`FAIL ${label}\n  got  ${a}\n  want ${b}`) }
  else console.log(`ok   ${label}`)
}

// --- mode flags
eq("editor mode adds nothing", api.buildArgs({}).args, "")
eq("full", api.buildArgs({ mode: "full" }).args, "-f")
eq("window", api.buildArgs({ mode: "window" }).args, "-w")
eq("region", api.buildArgs({ mode: "region" }).args, "-r")
eq("region ocr", api.buildArgs({ mode: "region-ocr" }).args, "-r ocr")

// --- the six parameters of the settings panel
eq("monitor", api.buildArgs({ mode: "region", monitor: true }).args, "-r -m")
eq("delay seconds", api.buildArgs({ mode: "region", delay: "3" }).args, "-r -d 3")
eq("delay fraction", api.buildArgs({ mode: "region", delay: "0.5" }).args, "-r -d 0.5")
eq("delay comma decimal", api.buildArgs({ delay: "2,5" }).args, "-d 2.5")
eq("delay zero omitted", api.buildArgs({ delay: "0" }).args, "")
eq("to letters", api.buildArgs({ to: "sc" }).args, "-t cs")
eq("bare -t", api.buildArgs({ toNothing: true }).args, "-t")
eq("output quotes spaces", api.buildArgs({ output: "/tmp/my shots" }).args, "-o '/tmp/my shots'")
eq("output plain path", api.buildArgs({ output: "~/Pictures" }).args, "-o ~/Pictures")
eq("output tilde stays for the shell", api.quotePath("/home/x/a b"), "'/home/x/a b'")
eq("nonotify", api.buildArgs({ nonotify: true }).args, "-n")
eq("all together", api.buildArgs({
  mode: "region", monitor: true, delay: "3", to: "cs", output: "/tmp/shots", nonotify: true
}).args, "-r -m -d 3 -t cs -o /tmp/shots -n")
eq("ocr daemon on launch", api.buildArgs({ ocrDaemon: "status" }).args, "--ocr-daemon status")
eq("daemon drops capture options", api.buildArgs({ ocrDaemon: "stop", mode: "region", monitor: true }).args, "--ocr-daemon stop")
eq("daemon warns about dropped options",
  api.buildArgs({ ocrDaemon: "stop", mode: "region" }).warnings.length, 1)

// --- warnings that point at the app's own quirks
eq("r letter without ocr mode", api.buildArgs({ to: "cr" }).warnings.length, 1)
eq("r letter with ocr mode is quiet", api.buildArgs({ mode: "region-ocr", to: "cr" }).warnings.length, 0)
eq("-o implies save", api.buildArgs({ to: "c", output: "/tmp/x" }).warnings.length, 1)
eq("-o with save ticked is quiet", api.buildArgs({ to: "cs", output: "/tmp/x" }).warnings.length, 0)
eq("-m with -w", api.buildArgs({ mode: "window", monitor: true }).warnings.length, 1)
eq("bad delay", api.buildArgs({ delay: "3sec" }).warnings.length, 1)
eq("comma in path", api.buildArgs({ output: "/tmp/a,b" }).warnings.length, 1)

// --- extra args pass through untouched
eq("extra args", api.buildArgs({ mode: "region", extraArgs: "-s" }).args, "-r -s")

// --- reading a command line back (migration from the free-text field)
eq("parse mixed", api.parseArgs("-r -t sc -m"), {
  mode: "region", monitor: true, delay: "", to: "cs", toNothing: false,
  output: "", nonotify: false, ocrDaemon: "", extraArgs: ""
})
eq("parse attached short values", api.parseArgs("-r -tcs -d0.5 -o /tmp/x -n").to, "cs")
eq("parse attached delay", api.parseArgs("-d0.5").delay, "0.5")
eq("parse output with quotes", api.parseArgs("-o '/tmp/my shots'").output, "/tmp/my shots")
eq("parse long form", api.parseArgs("--region --to=pc --delay 2 --output /tmp/z --monitor --nonotify"), {
  mode: "region", monitor: true, delay: "2", to: "cp", toNothing: false,
  output: "/tmp/z", nonotify: true, ocrDaemon: "", extraArgs: ""
})
eq("parse bare -t", api.parseArgs("-r -t").toNothing, true)
eq("parse bare -t before another flag", api.parseArgs("-r -t -m").monitor, true)
eq("parse bare -t keeps letters off", api.parseArgs("-r -t -m").to, "")
eq("parse ocr daemon", api.parseArgs("--ocr-daemon calibrate").ocrDaemon, "calibrate")
eq("parse region ocr", api.parseArgs("-r ocr -t cr"), {
  mode: "region-ocr", monitor: false, delay: "", to: "cr", toNothing: false,
  output: "", nonotify: false, ocrDaemon: "", extraArgs: ""
})
eq("unknown flags stay in extraArgs", api.parseArgs("-f -s --config /tmp/c.toml").extraArgs, "-s --config /tmp/c.toml")

// --- round trip: build, read back, build again
const cases = [
  { mode: "region", monitor: true, delay: "0.5", to: "ps", output: "/tmp/my dir", nonotify: true },
  { mode: "region-ocr", to: "cr" },
  { toNothing: true },
  { ocrDaemon: "serve" },
  { mode: "full", extraArgs: "-s" },
]
for (const c of cases) {
  const once = api.buildArgs(c).args
  const twice = api.buildArgs(api.parseArgs(once)).args
  eq(`round trip: ${once}`, twice, once)
}

// --- the panel's option lists cover every letter and action
eq("letters", api.TO_ORDER, ["c", "p", "s", "o", "r"])
eq("letters are the option values", api.TO_OPTIONS.map(o => o.value), api.TO_ORDER)
eq("daemon actions", api.DAEMON_ACTIONS.map(o => o.value), ["", "serve", "status", "stop", "calibrate"])

// --- the app's own general.to, spelled out in the panel
eq("to labels", api.toLabels("cs"), "Copy, Save")
eq("to labels in canonical order", api.toLabels("sc"), "Copy, Save")
eq("to labels drop unknown letters", api.toLabels("cx"), "Copy")
eq("to labels of nothing", api.toLabels(""), "")
eq("modes cover every mode flag", api.MODES.map(m => m.argv.join(" ")).sort(),
  ["", "-f", "-r", "-r ocr", "-w"].sort())

// --- per-mode shortcut commands
{
  const base = { mode: "region", monitor: false, delay: "2", to: "cs", toNothing: false, output: "", nonotify: true, ocrDaemon: "serve", extraArgs: "" }
  eq("mode command swaps the mode", api.buildArgsForMode(base, "full").args, "-f -d 2 -t cs -n")
  eq("mode command drops the daemon", api.buildArgsForMode(base, "region-ocr").argv.join(" "), "-r ocr -d 2 -t cs -n")
  eq("editor command has no mode flag", api.buildArgsForMode(base, "").args, "-d 2 -t cs -n")
}

console.log(failures ? `\n${failures} failed` : "\nall good")
process.exit(failures ? 1 : 0)
