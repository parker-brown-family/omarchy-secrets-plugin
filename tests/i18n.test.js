// Checks for the catalogs in i18n/. Run: node tests/i18n.test.js
//
// These prove the catalogs are whole and safe to load: every language has every
// string, the %1 and %2 holes survive, plural entries keep their shape, and the
// literal things a person must type or press are untouched. They say nothing
// about whether a translation reads well; that is a person's judgement.
const fs = require("fs"), path = require("path")
const dir = path.join(__dirname, "..", "i18n")
const load = name => JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"))
const en = load("en.json"), sensitive = load("_sensitive.json")
const langs = fs.readdirSync(dir).filter(f => /^[a-z]{2,3}(-[A-Za-z]{2})?\.json$/.test(f) && f !== "en.json").map(f => f.replace(/\.json$/, ""))
// Languages whose plural rules have one form only (CLDR "other").
const oneForm = ["ja", "zh-CN", "zh-TW", "ko", "vi", "th", "id", "ms"]
// Written the same in every language: file names, commands and key legends.
const literal = [".env", ".gitignore", "git rm --cached", "Super+Ctrl+V", "node_modules", "Tab "]
// The holes a string has, each once: a language may need to say %1 twice.
const holes = text => [...new Set(String(text).match(/%[1-9]/g) || [])].sort().join(" ")
let pass = 0, fail = 0
function check(what, problems) {
  const ok = problems.length === 0
  ok ? pass++ : fail++
  console.log((ok ? "  ok    " : "  FAIL  ") + what + (ok ? "" : "\n          " + problems.slice(0, 12).join("\n          ")))
}

console.log("the English catalog")
check("every sensitive string names a string that exists", Object.keys(sensitive).filter(k => k !== "_about" && !(k in en)))
check("a sensitive string's plain idea keeps the same holes", Object.keys(sensitive).filter(k => k !== "_about" && k in en && typeof en[k] === "string" && holes(sensitive[k]) !== holes(en[k])))
check("a plural entry has both English forms", Object.keys(en).filter(k => typeof en[k] === "object" && !(en[k].one && en[k].other)))

for (const lang of langs) {
  const cat = load(lang + ".json")
  console.log(lang)
  check("has every string", Object.keys(en).filter(k => !(k in cat)))
  check("has no string English lacks", Object.keys(cat).filter(k => !(k in en)))
  check("no string is empty", Object.keys(cat).filter(k => typeof cat[k] === "object" ? Object.values(cat[k]).some(v => !String(v).trim()) : !String(cat[k]).trim()))
  check("plural entries keep their shape", Object.keys(en).filter(k => k in cat).filter(k => {
    if ((typeof en[k] === "object") !== (typeof cat[k] === "object")) return true
    if (typeof cat[k] !== "object") return false
    const forms = Object.keys(cat[k]).sort().join(",")
    return forms !== (oneForm.includes(lang) ? "other" : "one,other")
  }))
  check("the %1 and %2 holes are the ones English has", Object.keys(en).filter(k => k in cat).flatMap(k => {
    if (typeof en[k] !== "object") return holes(cat[k]) === holes(en[k]) ? [] : [k]
    return Object.keys(cat[k]).filter(f => holes(cat[k][f]) !== holes(en[k][f] || en[k].other)).map(f => k + "#" + f)
  }))
  check("file names, commands and key legends are untouched", Object.keys(en).filter(k => k in cat).flatMap(k => {
    const source = typeof en[k] === "object" ? en[k].other : en[k]
    const texts = typeof cat[k] === "object" ? Object.values(cat[k]) : [cat[k]]
    return literal.filter(word => source.includes(word) && texts.some(t => !t.includes(word.trim()))).map(word => k + " lost " + JSON.stringify(word.trim()))
  }))
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
