.pragma library

// Minimal TOML reader/writer for the LumineCapture config subset:
// [section] and [a.b] headers, key = value, values of type bool, number,
// basic string, and inline arrays of those. Comments are stripped on save;
// LumineCapture rolls missing keys back to its defaults, so this is safe.

function stripComment(line) {
  var out = ""
  var inStr = false
  var quoteChar = ""
  var escaped = false
  for (var i = 0; i < line.length; i++) {
    var c = line.charAt(i)
    if (escaped) {
      out += c
      escaped = false
      continue
    }
    if (inStr && quoteChar === '"' && c === "\\") {
      out += c
      escaped = true
      continue
    }
    if (!inStr && (c === '"' || c === "'")) {
      inStr = true
      quoteChar = c
      out += c
      continue
    }
    if (inStr && c === quoteChar) {
      inStr = false
      quoteChar = ""
      out += c
      continue
    }
    if (c === "#" && !inStr) break
    out += c
  }
  return out
}

function parseValue(raw) {
  var t = raw.trim()
  if (t === "true") return { kind: "bool", val: true }
  if (t === "false") return { kind: "bool", val: false }
  if (t.charAt(0) === '"') {
    try { return { kind: "str", val: JSON.parse(t) } } catch (e) { return { kind: "str", val: t.slice(1, -1) } }
  }
  if (t.charAt(0) === "'" && t.length >= 2 && t.charAt(t.length - 1) === "'") {
    return { kind: "str", val: t.slice(1, -1) }
  }
  if (t.charAt(0) === "[" && t.charAt(t.length - 1) === "]") {
    var inner = t.slice(1, -1)
    var items = []
    var cur = "", inStr = false, quoteChar = "", escaped = false
    for (var i = 0; i < inner.length; i++) {
      var c = inner.charAt(i)
      if (escaped) { cur += c; escaped = false; continue }
      if (inStr && quoteChar === '"' && c === "\\") { cur += c; escaped = true; continue }
      if (!inStr && (c === '"' || c === "'")) { inStr = true; quoteChar = c }
      else if (inStr && c === quoteChar) { inStr = false; quoteChar = "" }
      if (c === "," && !inStr) { items.push(cur); cur = "" } else cur += c
    }
    if (cur.trim()) items.push(cur)
    var parsed = items.map(function (s) { return parseValue(s) })
    var allStr = parsed.every(function (p) { return p.kind === "str" })
    var allNum = parsed.every(function (p) { return p.kind === "num" })
    if (allStr) return { kind: "arr-str", val: parsed.map(function (p) { return p.val }) }
    if (allNum) return { kind: "arr-num", val: parsed.map(function (p) { return p.val }) }
    return { kind: "str", val: items.join(", ") }
  }
  var n = Number(t)
  if (!isNaN(n) && t !== "") return { kind: "num", val: t }
  // Unquoted fallback string
  return { kind: "str", val: t }
}

function parse(text) {
  var sections = []
  var current = null
  var lines = String(text === undefined || text === null ? "" : text).split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var line = stripComment(lines[i]).trim()
    if (!line) continue
    if (line.charAt(0) === "[") {
      var closeIdx = line.indexOf("]")
      var name = (closeIdx > 0 ? line.slice(1, closeIdx) : line.slice(1)).trim()
      current = { name: name, items: [] }
      sections.push(current)
      continue
    }
    var eq = -1
    var inStr = false, quoteChar = "", escaped = false
    for (var j = 0; j < line.length; j++) {
      var c = line.charAt(j)
      if (escaped) { escaped = false; continue }
      if (inStr && quoteChar === '"' && c === "\\") { escaped = true; continue }
      if (!inStr && (c === '"' || c === "'")) { inStr = true; quoteChar = c }
      else if (inStr && c === quoteChar) { inStr = false; quoteChar = "" }
      if (c === "=" && !inStr) { eq = j; break }
    }
    if (eq < 0 || !current) continue
    var key = line.slice(0, eq).trim()
    var v = parseValue(line.slice(eq + 1))
    current.items.push({ key: key, kind: v.kind, val: v.val })
  }
  return sections
}

// A single value as text, "" when the section or key is absent. The settings
// panel reads the app's own defaults with this; it never writes them back.
function value(text, section, key) {
  var sections = parse(text)
  for (var i = 0; i < sections.length; i++) {
    if (sections[i].name !== section) continue
    var items = sections[i].items
    for (var j = 0; j < items.length; j++) {
      if (items[j].key === key) return String(items[j].val)
    }
    return ""
  }
  return ""
}

function encodeVal(item) {
  if (item.kind === "bool") return item.val ? "true" : "false"
  if (item.kind === "num") return String(item.val)
  if (item.kind === "str") return JSON.stringify(String(item.val))
  if (item.kind === "arr-str") return "[" + item.val.map(function (s) { return JSON.stringify(String(s)) }).join(", ") + "]"
  if (item.kind === "arr-num") return "[" + item.val.map(function (n) { return String(n) }).join(", ") + "]"
  return String(item.val)
}

function serialize(sections) {
  var out = ["# LumineCapture config — written by OmaLumineCapture", ""]
  for (var i = 0; i < sections.length; i++) {
    var s = sections[i]
    out.push("[" + s.name + "]")
    for (var j = 0; j < s.items.length; j++) {
      out.push(s.items[j].key + " = " + encodeVal(s.items[j]))
    }
    out.push("")
  }
  return out.join("\n")
}

function displayVal(item) {
  if (item.kind === "arr-str" || item.kind === "arr-num") return item.val.join(", ")
  if (item.kind === "bool") return item.val ? "true" : "false"
  return String(item.val)
}

function applyVal(item, text) {
  if (item.kind === "bool") { item.val = (text === "true"); return }
  if (item.kind === "num") {
    var t = text.trim()
    var n = Number(t)
    item.val = (t !== "" && !isNaN(n)) ? t : item.val
    return
  }
  if (item.kind === "arr-str" || item.kind === "arr-num") {
    var parts = text.split(",").map(function (p) { return p.trim() }).filter(function (p) { return p !== "" })
    if (item.kind === "arr-num") {
      var nums = []
      for (var i = 0; i < parts.length; i++) { var x = Number(parts[i]); nums.push(isNaN(x) ? parts[i] : x) }
      item.val = nums
    } else {
      item.val = parts
    }
    return
  }
  item.val = text
}
