// Checks for Model.js, the overlay's pure logic. Run: node tests/model.test.js
const M = require("../Model.js")
let pass = 0, fail = 0
function check(what, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  ok ? pass++ : fail++
  console.log((ok ? "  ok    " : "  FAIL  ") + what + (ok ? "" : "\n          got  " + JSON.stringify(got) + "\n          want " + JSON.stringify(want)))
}
const file = (dir, base, names, extra) => Object.assign({ file: dir + "/" + base, base, example: false, backup: false, names: names.map(([name, set]) => ({ name, set })) }, extra || {})
const shop = { dir: "/w/shop", root: "/w", label: "shop", files: [
  file("/w/shop", ".env", [["DATABASE_URL", true], ["OPENROUTER_API_KEY", false]]),
  file("/w/shop", ".env.example", [["OPENROUTER_API_KEY", false], ["SENTRY_DSN", false]], { example: true }) ] }
const api = { dir: "/w/api", root: "/w", label: "api", files: [file("/w/api", ".env", [["ANTHROPIC_API_KEY", true], ["DATABASE_URL", true]], { git: "ignored" })] }
const next = { dir: "/w/next", root: "/w", label: "next", files: [
  file("/w/next", ".env.local", [["SITE_URL", true]]), file("/w/next", ".env.local.bak", [["OLD", true]], { backup: true }) ] }
const bare = { dir: "/w/apps/bare", root: "/w", label: "apps/bare", files: [] }
const all = [shop, api, next, bare]

console.log("which file a key goes to")
check("a project with a .env uses it", M.makeTarget(shop).path, "/w/shop/.env")
check("a project with only .env.local uses that, and still offers a new .env", M.saveFiles(next).map(f => f.base), [".env.local", ".env"])
check("a backup copy is never offered", M.saveFiles(next).some(f => f.base.endsWith(".bak")), false)
check("a project with no file gets a new .env", [M.makeTarget(bare).path, M.makeTarget(bare).file], ["/w/apps/bare/.env", null])
check("a chosen file overrides the usual one", M.makeTarget(next, "/w/next/.env").base, ".env")

console.log("names offered for a key")
const names = M.nameSuggestions("", "OPENROUTER_API_KEY", [M.makeTarget(shop)], all)
check("the key's own prefix comes first, then example names, then names with values, then other projects",
  names.map(n => n.name + ":" + n.kind), ["OPENROUTER_API_KEY:guess", "SENTRY_DSN:wanted", "DATABASE_URL:replace", "ANTHROPIC_API_KEY:elsewhere", "OLD:elsewhere", "SITE_URL:elsewhere"])
check("with no guess, an empty name in the file leads", M.nameSuggestions("", null, [M.makeTarget(shop)], all)[0], { name: "OPENROUTER_API_KEY", kind: "empty", why: "waiting empty" })
check("typing narrows the list, and an existing name beats the half-typed one", M.nameSuggestions("sentry", null, [M.makeTarget(shop)], all).map(n => n.name + ":" + n.kind), ["SENTRY_DSN:wanted", "SENTRY:new"])
check("a typed name that matches nothing is offered as new, in capitals", M.nameSuggestions("my new-key", null, [M.makeTarget(shop)], all), [{ name: "MY_NEW_KEY", kind: "new", why: "new name" }])
check("a typed name that already exists is not offered twice", M.nameSuggestions("database_url", null, [M.makeTarget(shop)], all).map(n => n.name), ["DATABASE_URL"])
check("a name from a backup copy is not offered as this file's", M.nameSuggestions("", null, [M.makeTarget(next)], all).filter(n => n.name === "OLD").map(n => n.kind), ["elsewhere"])
check("a leading digit is dropped from a typed name", M.normalizeName("9lives"), "LIVES")

console.log("what a save will do")
const plan = M.savePlan("DATABASE_URL", [M.makeTarget(shop), M.makeTarget(bare)], { "/w/shop/.env": { git: "ignored", vcs: null }, "/w/apps/bare/.env": { git: "not-ignored", vcs: null } })
check("replacing a value and adding to .gitignore both ask first", [plan.replaces, plan.needsIgnore, plan.needsConfirm], [["shop"], [{ label: "apps/bare", base: ".env" }], true])
check("each step says what it does", plan.steps.map(s => s.does), ["replace the value of DATABASE_URL", "create .env and add DATABASE_URL"])
check("a file git has not been asked about is not called checked", M.savePlan("X", [M.makeTarget(shop)], {}).checked, false)
check("filling an empty name needs no question", M.savePlan("OPENROUTER_API_KEY", [M.makeTarget(shop)], { "/w/shop/.env": { git: "ignored", vcs: null } }).needsConfirm, false)
check("a tracked file is reported", M.savePlan("X", [M.makeTarget(shop)], { "/w/shop/.env": { git: "tracked", vcs: null } }).tracked, ["shop/.env"])

console.log("the key store")
const index = M.keyIndex(all)
check("names are listed once each, in order, without example files", index.map(k => k.name + ":" + k.places.length), ["ANTHROPIC_API_KEY:1", "DATABASE_URL:2", "OLD:1", "OPENROUTER_API_KEY:1", "SENTRY_DSN:0"].filter(x => !x.endsWith(":0")).concat(["SITE_URL:1"]))
check("git state that was never asked for stays unknown, not ignored", index.find(k => k.name === "SITE_URL").places[0].git, null)
check("unknown git state reads as not checked", M.gitLine(null, null).text, "git not checked")
check("search finds a name by any part", M.filterKeys(index, "api key").map(k => k.name), ["ANTHROPIC_API_KEY", "OPENROUTER_API_KEY"])

console.log("finding a project")
check("the last part of the path beats a match further up", M.filterProjects(all, "ba").map(p => p.label), ["apps/bare"])
check("letters in order still match", M.filterProjects(all, "sp").map(p => p.label), ["shop"])
check("no filter keeps the scan's order", M.filterProjects(all, "").map(p => p.label), ["shop", "api", "next", "apps/bare"])

console.log("\n" + pass + " passed, " + fail + " failed")
process.exit(fail ? 1 : 0)
