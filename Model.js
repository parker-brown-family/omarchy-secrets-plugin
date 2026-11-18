// Pure functions behind the overlay: which projects match a filter, which
// names to offer for a key, and which key lives where. No values are ever
// handled here; the scan this works from carries names and places only.

function baseName(path) {
  return String(path || "").replace(/\/+$/, "").replace(/^.*\//, "")
}

function shortPath(path, home) {
  var p = String(path || "")
  if (home && p === home) return "~"
  if (home && p.indexOf(home + "/") === 0) return "~" + p.slice(home.length)
  return p
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many)
}

// Files a key can be saved to: example files are templates and backup copies
// are leftovers, so neither is offered.
function isSaveable(file) {
  return !file.example && !file.backup
}

// The files in a project a key can go to, the usual one first: .env, then
// .env.local, then any other. A .env that does not exist yet is offered last.
function saveFiles(project) {
  function rank(f) { return f.base === ".env" ? 0 : f.base === ".env.local" ? 1 : 2 }
  var real = project.files.filter(isSaveable).sort(function(a, b) {
    return rank(a) - rank(b) || (a.base < b.base ? -1 : a.base > b.base ? 1 : 0)
  })
  var out = real.map(function(f) { return { path: f.file, base: f.base, file: f } })
  if (!real.some(function(f) { return f.base === ".env" }))
    out.push({ path: project.dir + "/.env", base: ".env", file: null })
  return out
}

// One place a key is going: a project and the file in it. `path` picks a file
// other than the usual one; `file` is null when the file does not exist yet.
function makeTarget(project, path) {
  var files = saveFiles(project), pick = files[0]
  for (var i = 0; i < files.length; i++) if (files[i].path === path) pick = files[i]
  return { project: project, label: project.label, dir: project.dir, path: pick.path, base: pick.base, file: pick.file }
}

function namesIn(file) {
  return file && file.names ? file.names : []
}

// How well a project label answers a filter: lower is better, -1 is no match.
// The last path part starting with the filter beats the filter appearing
// anywhere, which beats its letters merely appearing in order.
function matchRank(label, query) {
  var l = label.toLowerCase(), q = query.toLowerCase()
  if (!q) return 0
  var last = l.replace(/^.*\//, "")
  if (last.indexOf(q) === 0) return 0
  if (l.indexOf(q) === 0) return 1
  if (l.indexOf(q) >= 0) return 2
  var at = 0
  for (var i = 0; i < q.length; i++) {
    at = l.indexOf(q[i], at)
    if (at < 0) return -1
    at++
  }
  return 3
}

// Projects answering a filter, best match first; within a rank the scan's own
// order (most recently changed first) is kept.
function filterProjects(projects, query) {
  var q = String(query || "").trim()
  var ranked = []
  for (var i = 0; i < projects.length; i++) {
    var rank = matchRank(projects[i].label, q)
    if (rank >= 0) ranked.push({ rank: rank, order: i, project: projects[i] })
  }
  ranked.sort(function(a, b) { return a.rank - b.rank || a.order - b.order })
  return ranked.map(function(r) { return r.project })
}

// What a person types becomes a variable name: capitals, digits and
// underscores, never starting with a digit.
function normalizeName(text) {
  var s = String(text || "").toUpperCase().replace(/[^A-Z0-9_]+/g, "_")
  return s.replace(/^[0-9]+/, "")
}

function isName(text) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(String(text || ""))
}

// Names to offer for the key being saved, most likely first, each with the
// reason it is offered. `targets` are the places it is going (makeTarget).
//
//   1. what the key's own prefix says it is
//   2. names waiting empty in a target file
//   3. names a target project's example file lists and the target file lacks
//   4. names a target file already holds (saving replaces the value)
//   5. names other projects use, most used first
//
// A typed filter narrows the list. A typed name that is not in it is offered
// as a new name, after any existing names it matches.
function nameSuggestions(query, guess, targets, projects) {
  var rows = [], seen = {}
  function add(name, kind, why) {
    if (!name || seen[name]) return
    seen[name] = true
    rows.push({ name: name, kind: kind, why: why })
  }
  var many = targets.length > 1
  function where(target) { return many ? " in " + target.label : "" }

  if (guess) add(guess, "guess", "what this key looks like")

  var t, i, file, names
  for (t = 0; t < targets.length; t++) {
    names = namesIn(targets[t].file)
    for (i = 0; i < names.length; i++)
      if (!names[i].set) add(names[i].name, "empty", "waiting empty" + where(targets[t]))
  }
  for (t = 0; t < targets.length; t++) {
    var have = {}
    names = namesIn(targets[t].file)
    for (i = 0; i < names.length; i++) have[names[i].name] = true
    var files = targets[t].project.files
    for (var f = 0; f < files.length; f++) {
      file = files[f]
      if (!file.example) continue
      for (i = 0; i < file.names.length; i++)
        if (!have[file.names[i].name])
          add(file.names[i].name, "wanted", "listed in " + file.base + where(targets[t]) + ", not set")
    }
  }
  for (t = 0; t < targets.length; t++) {
    names = namesIn(targets[t].file)
    for (i = 0; i < names.length; i++)
      if (names[i].set) add(names[i].name, "replace", "has a value" + where(targets[t]) + " · will be replaced")
  }

  var index = keyIndex(projects)
  index.sort(function(a, b) { return b.places.length - a.places.length || (a.name < b.name ? -1 : 1) })
  for (i = 0; i < index.length; i++)
    add(index[i].name, "elsewhere", "used in " + plural(index[i].places.length, "project", "projects"))

  var q = normalizeName(query)
  if (!q) return rows
  var out = []
  for (i = 0; i < rows.length; i++) {
    var at = rows[i].name.indexOf(q)
    if (at >= 0) out.push({ at: at === 0 ? 0 : 1, order: i, row: rows[i] })
  }
  out.sort(function(a, b) { return a.at - b.at || a.order - b.order })
  out = out.map(function(o) { return o.row })
  // Existing names that match come first, so Enter on a half-typed name
  // picks the real one; the typed text as a new name is always the last row.
  if (isName(q) && !seen[q]) out.push({ name: q, kind: "new", why: "new name" })
  return out
}

// Every key name with the places it is stored, example files left out.
function keyIndex(projects) {
  var byName = {}, order = []
  for (var p = 0; p < projects.length; p++) {
    var project = projects[p]
    for (var f = 0; f < project.files.length; f++) {
      var file = project.files[f]
      if (file.example) continue
      for (var n = 0; n < file.names.length; n++) {
        var name = file.names[n].name
        if (!byName[name]) { byName[name] = { name: name, places: [] }; order.push(name) }
        byName[name].places.push({
          label: project.label, dir: project.dir, file: file.file, base: file.base,
          set: file.names[n].set, backup: file.backup === true,
          // Absent when the scan did not ask git; that is not the same as ignored.
          git: file.git === undefined ? null : file.git,
          vcs: file.vcs === undefined ? null : file.vcs
        })
      }
    }
  }
  order.sort()
  return order.map(function(name) { return byName[name] })
}

function filterKeys(index, query) {
  var q = String(query || "").trim().toUpperCase().replace(/[\s-]+/g, "_")
  if (!q) return index
  var starts = [], contains = []
  for (var i = 0; i < index.length; i++) {
    var at = index[i].name.toUpperCase().indexOf(q)
    if (at === 0) starts.push(index[i])
    else if (at > 0) contains.push(index[i])
  }
  return starts.concat(contains)
}

// One line on how git treats a file, and whether it needs a person's eye.
function gitLine(git, vcs, pending) {
  if ((git === null || git === undefined) && pending) return { text: "checking git…", tone: "plain" }
  if (git === "ignored") return { text: "ignored by git", tone: "ok" }
  if (git === "not-ignored") return { text: "NOT ignored by git", tone: "warn" }
  if (git === "tracked") return { text: "tracked by git: would be committed", tone: "bad" }
  if (git === "not-git" && vcs) return { text: "under " + vcs + ", which this plugin does not check", tone: "warn" }
  if (git === "not-git") return { text: "not in a git repository", tone: "plain" }
  return { text: "git not checked", tone: "plain" }
}

// What saving NAME into each target will do, from the scan and the git check.
// `checks` maps a file path to {exists, git, vcs}; a file missing from it has
// not been checked yet and says so.
function savePlan(name, targets, checks) {
  var steps = [], needsIgnore = [], tracked = [], replaces = [], otherVcs = []
  for (var t = 0; t < targets.length; t++) {
    var target = targets[t], check = checks[target.path]
    var existing = null, names = namesIn(target.file)
    for (var i = 0; i < names.length; i++) if (names[i].name === name) existing = names[i]
    var does
    if (!target.file) does = "create " + target.base + " and add " + name
    else if (existing && existing.set) { does = "replace the value of " + name; replaces.push(target.label) }
    else if (existing) does = "fill in " + name
    else does = "add " + name
    var step = { label: target.label, base: target.base, file: target.path, does: does, git: null }
    if (!check) step.git = { text: "checking git…", tone: "plain" }
    else {
      step.git = gitLine(check.git, check.vcs)
      if (check.git === "not-ignored") {
        needsIgnore.push({ label: target.label, base: target.base })
        step.git = { text: "will add " + target.base + " to .gitignore first", tone: "warn" }
      }
      if (check.git === "tracked") tracked.push(target.label + "/" + target.base)
      if (check.git === "not-git" && check.vcs) otherVcs.push(target.label + " (" + check.vcs + ")")
    }
    steps.push(step)
  }
  return {
    steps: steps, needsIgnore: needsIgnore, tracked: tracked, replaces: replaces, otherVcs: otherVcs,
    checked: steps.every(function(s) { return s.git.text !== "checking git…" }),
    needsConfirm: needsIgnore.length > 0 || replaces.length > 0 || otherVcs.length > 0
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    baseName: baseName, shortPath: shortPath, plural: plural, isSaveable: isSaveable,
    saveFiles: saveFiles, makeTarget: makeTarget, matchRank: matchRank, filterProjects: filterProjects,
    normalizeName: normalizeName, isName: isName, nameSuggestions: nameSuggestions,
    keyIndex: keyIndex, filterKeys: filterKeys, gitLine: gitLine, savePlan: savePlan
  }
}
