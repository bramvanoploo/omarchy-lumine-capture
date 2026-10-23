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
const api = new Function(`"use strict"; ${src}; return { value }`)()

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

console.log(failures ? `\n${failures} failed` : "\nall good")
process.exit(failures ? 1 : 0)
