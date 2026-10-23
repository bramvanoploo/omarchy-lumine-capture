// LumineConfig.js is a QML library (`.pragma library`), so node cannot import
// it. Strip that line, evaluate the rest, and check the reader the settings
// panel uses to show the app's own defaults.
//
//   node tests/lumine-config.test.mjs

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"

const here = path.dirname(fileURLToPath(import.meta.url))
const src = readFileSync(path.join(here, "..", "LumineConfig.js"), "utf8").replace(/^\.pragma library/m, "")
const api = new Function(`"use strict"; ${src}; return { value, parse, serialize, applyVal, displayVal }`)()

let failures = 0
function eq(label, got, want) {
  const a = JSON.stringify(got), b = JSON.stringify(want)
  if (a !== b) { failures++; console.log(`FAIL ${label}\n  got  ${a}\n  want ${b}`) }
  else console.log(`ok   ${label}`)
}

const toml = `# a comment
[general]
to = "cs"

[save]
directory = "screenshots"
`

eq("reads a key from a section", api.value(toml, "general", "to"), "cs")
eq("reads the save directory", api.value(toml, "save", "directory"), "screenshots")
eq("missing key in a present section", api.value(toml, "general", "overlay"), "")
eq("missing section", api.value(toml, "theme", "accent"), "")
eq("empty text", api.value("", "general", "to"), "")
eq("comment is not a value", api.value("# to = \"xx\"\n[general]\nto = \"c\"", "general", "to"), "c")
eq("single-quoted literal string", api.value("[save]\ndirectory = 'my#shots'", "save", "directory"), "my#shots")
eq("escaped backslash before quote in comment strip", api.value('[save]\ndirectory = "a\\\\" # comment', "save", "directory"), "a\\")
eq("applyVal bool does not short-circuit num", (() => {
  const b = { kind: "bool", val: false }
  const n = { kind: "num", val: "1" }
  api.applyVal(b, "true")
  api.applyVal(n, "42")
  return [b.val, n.val]
})(), [true, "42"])
eq("unclosed bracket is treated as plain string", api.value("[save]\ndirectory = [unclosed", "save", "directory"), "[unclosed")
eq("inline string array round-trips", (() => {
  const sections = api.parse('[ocr]\nlanguages = ["eng", "nld"]\n')
  return api.displayVal(sections[0].items[0])
})(), "eng, nld")

console.log(failures ? `\n${failures} failed` : "\nall good")
process.exit(failures ? 1 : 0)
