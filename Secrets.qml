import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The secrets overlay: a centred card, like the clipboard manager's.
//
// It never holds a key. It passes names and file paths to bin/secret-take and
// bin/secret-keys, and shows what they report back.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^(file|qs):\/\//, "").replace(/\/$/, ""))
  readonly property string keysBin: pluginDir + "/bin/secret-keys"
  readonly property string takeBin: pluginDir + "/bin/secret-take"

  // Shares the [menu] surface tokens, as the clipboard manager and the emoji
  // picker do, so a theme that styles the menu styles this too.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  property color warnColor: Commons.Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.title + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int headerHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
  property int lineHeight: Style.font.caption + Style.spacing.lg

  // ------------------------------------------------------------------ state

  // projects | name | confirm | result | keys | places | folders | browse | notice
  property string view: "projects"
  property string backView: "projects"
  property string filterText: ""
  property int selectedIndex: 0

  property var scan: ({ projects: [], roots: [], depth: 4, configured: false, config: "" })
  property bool scanLoaded: false
  // The scan asks git only once the key store has been opened; it is slower.
  property bool wantGit: false
  property bool scanPending: false
  property int scanSeq: 0
  // null until the clipboard has been looked at; that is not "no key".
  property var peek: null
  property var marked: ({})
  // A project folder mapped to the file chosen in it, when not the usual one.
  property var fileChoice: ({})
  property var targets: []
  property var checks: ({})
  property string keyName: ""
  // Where the key comes from when it is not the clipboard: {file, label, name}.
  property var source: null
  property var plan: null
  property var result: null
  property var activeKey: null
  property var browse: ({ path: "", parent: "", dirs: [] })
  property var notice: ({ title: "", lines: [], back: "" })
  property string busy: ""

  property var rowData: []
  property var detail: []
  property string titleText: ""
  property string chipText: ""
  property string chipTone: "plain"
  property string placeholder: ""
  property string hints: ""
  readonly property bool filterable: view === "projects" || view === "name" || view === "keys" || view === "browse"
  readonly property string shownFilter: view === "name" ? Model.normalizeName(filterText) : filterText

  // ---------------------------------------------------------- shell contract

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    root.opened = true
    root.reset()
    if (payload.mode === "keys") {
      root.view = "keys"
      root.wantGit = true
    } else {
      root.view = "projects"
      root.runPeek()
    }
    // The last list is shown at once; this brings it up to date behind it.
    root.loadScan()
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "brownfamilysports.secrets")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function reset() {
    root.filterText = ""
    root.selectedIndex = 0
    root.peek = null
    root.marked = ({})
    root.fileChoice = ({})
    root.targets = []
    root.checks = ({})
    root.keyName = ""
    root.source = null
    root.wantGit = false
    root.plan = null
    root.result = null
    root.activeKey = null
    root.busy = ""
    root.backView = "projects"
  }

  // -------------------------------------------------------------- processes

  Component {
    id: runner

    Process {
      id: proc
      property var done: null
      property string out: ""
      property int code: -1
      property bool exited: false
      property bool drained: false

      function finish() {
        if (!exited || !drained) return
        var cb = done
        done = null
        if (cb) cb(code, out)
        proc.destroy()
      }

      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: { proc.out = text; proc.drained = true; proc.finish() }
      }
      onExited: function(exitCode, exitStatus) { proc.code = exitCode; proc.exited = true; proc.finish() }
    }
  }

  // Runs a helper and hands its exit code and output to `done`. Arguments are
  // names and paths only; a key is never among them.
  function run(argv, done) {
    var p = runner.createObject(root, { command: argv, done: done })
    p.running = true
  }

  function parse(text, fallback) {
    try { return JSON.parse(text) } catch (e) { return fallback }
  }

  function runPeek() {
    root.run([root.keysBin, "peek"], function(code, out) {
      root.peek = root.parse(out, { ok: false, reason: "unreadable" })
      if (!root.opened) return
      if (!root.peek.ok && !root.source && (root.view === "projects" || root.view === "name"))
        root.showNotice("No key on the clipboard", [
          root.peekReason(root.peek.reason),
          "Press Copy on the site that shows the key, then press this hotkey again."
        ], "")
      root.rebuild()
    })
  }

  // What the cursor is on, so it can stay there when a fresh list arrives.
  function cursorKey() {
    var current = root.rowData[root.selectedIndex]
    if (!current) return ""
    if (current.kind === "project") return "p:" + current.project.dir
    if (current.kind === "key") return "k:" + current.key.name
    return ""
  }

  function loadScan() {
    var argv = [root.keysBin, "scan"]
    if (root.wantGit) argv.push("--git")
    var seq = ++root.scanSeq
    root.scanPending = true
    root.run(argv, function(code, out) {
      if (seq !== root.scanSeq) return
      root.scanPending = false
      var parsed = root.parse(out, null)
      if (!parsed) return
      var keep = root.cursorKey()
      root.scan = parsed
      root.scanLoaded = true
      if (!root.opened) return
      root.rebuild()
      if (!keep || keep === root.cursorKey()) return
      for (var i = 0; i < root.rowData.length; i++) {
        var row = root.rowData[i]
        if ((row.kind === "project" && "p:" + row.project.dir === keep) || (row.kind === "key" && "k:" + row.key.name === keep)) {
          root.selectedIndex = i
          root.rebuild()
          return
        }
      }
    })
  }

  function runChecks() {
    var files = root.targets.map(function(t) { return t.path })
    if (files.length === 0) return
    root.run([root.keysBin, "check"].concat(files), function(code, out) {
      var list = root.parse(out, [])
      var next = ({})
      for (var k in root.checks) next[k] = root.checks[k]
      for (var i = 0; i < list.length; i++) next[list[i].file] = list[i]
      root.checks = next
      if (!root.opened) return
      root.rebuild()
      if (root.busy === "checking") { root.busy = ""; root.proceed() }
    })
  }

  // ------------------------------------------------------------- view logic

  function peekReason(reason) {
    if (reason === "empty") return "The clipboard is empty."
    if (reason === "lines") return "The clipboard holds several lines, which is not a key."
    if (reason === "spaces") return "The clipboard holds text with spaces in it, which is not a key."
    if (reason === "quote") return "The clipboard holds something with a single quote in it, which a .env file cannot carry safely."
    if (reason === "short") return "The clipboard holds fewer than 8 characters, which is too short to be a key."
    return "The clipboard could not be read."
  }

  function showNotice(title, lines, back) {
    root.notice = { title: title, lines: lines, back: back }
    root.go("notice")
  }

  function go(next) {
    root.view = next
    root.filterText = ""
    root.selectedIndex = 0
    root.rebuild()
  }

  function projectSub(project) {
    var usual = Model.saveFiles(project)[0]
    var where = Model.shortPath(project.root, root.home)
    if (!usual.file) return where + " · no .env yet"
    return where + " · " + usual.base + " · " + Model.plural(usual.file.names.length, "key", "keys")
  }

  function fileLines(project) {
    var lines = [{ text: Model.shortPath(project.dir, root.home), tone: "strong" }]
    if (project.files.length === 0)
      lines.push({ text: "No .env yet. One will be created, readable by you alone.", tone: "plain" })
    for (var f = 0; f < project.files.length; f++) {
      var file = project.files[f]
      lines.push({ text: "", tone: "plain" })
      lines.push({ text: file.base + (file.example ? "  (example file)" : file.backup ? "  (backup copy)" : ""), tone: "strong" })
      if (file.names.length === 0) lines.push({ text: "no names in it", tone: "dim" })
      for (var n = 0; n < file.names.length; n++)
        lines.push({ text: (file.names[n].set ? "● " : "○ ") + file.names[n].name + (file.names[n].set || file.example ? "" : "   empty"), tone: file.names[n].set ? "plain" : "dim" })
    }
    return lines
  }

  function planLines(plan) {
    var lines = []
    for (var i = 0; i < plan.steps.length; i++) {
      var s = plan.steps[i]
      if (i > 0) lines.push({ text: "", tone: "plain" })
      lines.push({ text: s.label + "/" + s.base, tone: "strong" })
      lines.push({ text: s.does, tone: "plain" })
      lines.push({ text: s.git.text, tone: s.git.tone === "warn" || s.git.tone === "bad" ? "warn" : "dim" })
    }
    return lines
  }

  function rebuild() {
    var rows = [], data = [], detail = []
    var chip = "", tone = "plain"
    if (root.source) chip = "from " + root.source.label
    else if (root.peek === null) chip = "reading clipboard…"
    else if (root.peek.ok) chip = root.peek.hint + "•••• · " + root.peek.length + " characters"
    else { chip = "no key on the clipboard"; tone = "warn" }

    if (root.view === "projects") {
      root.titleText = root.source ? "Send " + root.source.name + " to" : "Save copied key to"
      root.placeholder = "Search projects"
      var count = Object.keys(root.marked).length
      root.hints = "↵ choose" + (count ? " " + count + " marked" : "") + "   Tab mark several   Ctrl+K key store   Ctrl+F folders   Esc close"
      var projects = Model.filterProjects(root.scan.projects, root.filterText)
      // The project the key is coming from is not somewhere to send it.
      if (root.source) projects = projects.filter(function(pr) { return Model.makeTarget(pr, root.fileChoice[pr.dir]).path !== root.source.file })
      for (var i = 0; i < projects.length; i++) {
        rows.push({ title: projects[i].label, sub: root.projectSub(projects[i]), tone: "plain", marked: root.marked[projects[i].dir] === true })
        data.push({ kind: "project", project: projects[i] })
      }
      if (root.scanLoaded) {
        rows.push({ title: "+ Add a folder to search", sub: Model.plural(root.scan.roots.length, "folder", "folders") + " searched today", tone: "dim", marked: false })
        data.push({ kind: "addFolder" })
      }
    } else if (root.view === "name") {
      root.titleText = "Name the key for " + (root.targets.length === 1 ? root.targets[0].label + "/" + root.targets[0].base : Model.plural(root.targets.length, "project", "projects"))
      root.placeholder = "Type a name, or pick one"
      var others = root.targets.length === 1 ? Model.saveFiles(root.targets[0].project).length - 1 : 0
      root.hints = "↵ save   ↑↓ pick" + (others > 0 ? "   Tab other file" : "") + "   Esc back"
      var names = Model.nameSuggestions(root.filterText, root.peek && root.peek.ok ? root.peek.guess : null, root.targets, root.scan.projects)
      for (var n = 0; n < names.length; n++) {
        rows.push({ title: names[n].name, sub: names[n].why, tone: names[n].kind === "replace" ? "warn" : "plain", marked: false })
        data.push({ kind: "name", name: names[n].name })
      }
    } else if (root.view === "confirm") {
      root.titleText = "Before saving " + root.keyName
      root.placeholder = ""
      root.hints = "↵ go ahead   Esc back"
      var p = root.plan
      for (var r = 0; r < p.replaces.length; r++) {
        rows.push({ title: "Replace the value in " + p.replaces[r], sub: "It already has a value there. The old one is not kept.", tone: "warn", marked: false })
        data.push({ kind: "info" })
      }
      for (var g = 0; g < p.needsIgnore.length; g++) {
        rows.push({ title: "Add " + p.needsIgnore[g].base + " to .gitignore in " + p.needsIgnore[g].label, sub: "git does not ignore it there today, so the key could be committed.", tone: "warn", marked: false })
        data.push({ kind: "info" })
      }
      for (var v = 0; v < p.otherVcs.length; v++) {
        rows.push({ title: "Not checked: " + p.otherVcs[v], sub: "This plugin only checks git. Keeping the file out of that system is yours to do.", tone: "warn", marked: false })
        data.push({ kind: "info" })
      }
    } else if (root.view === "result") {
      var res = root.result
      root.placeholder = ""
      if (res && res.ok) {
        root.titleText = "Saved " + res.name
        root.hints = "↵ done   A save it to another project"
        for (var s = 0; s < res.results.length; s++) {
          var one = res.results[s]
          rows.push({ title: Model.shortPath(one.file, root.home), sub: (one.action === "replaced" ? "old value replaced" : one.action === "filled" ? "empty placeholder filled in" : "added") + (one.ignoreAdded ? " · " + Model.baseName(one.file) + " added to .gitignore" : ""), tone: "plain", marked: true })
          data.push({ kind: "info" })
        }
        if (res.source === "clipboard") {
          rows.push(res.clipboard === "cleared" ? { title: "Clipboard cleared", sub: "The key is no longer on it.", tone: "plain", marked: true }
            : res.clipboard === "changed" ? { title: "Clipboard left alone", sub: "Something newer had been copied since.", tone: "plain", marked: false }
            : { title: "Clipboard STILL HOLDS THE KEY", sub: "It could not be cleared. Copy something else over it.", tone: "warn", marked: false })
          data.push({ kind: "info" })
          rows.push(res.history === "removed" ? { title: "Removed from clipboard history", sub: Model.plural(res.historyRemoved, "entry", "entries") + " removed. Every other entry is untouched.", tone: "plain", marked: true }
            : res.history === "none" ? { title: "Clipboard history had no copy of it", sub: "Looked, and found nothing to remove.", tone: "plain", marked: false }
            : res.history === "no-file" ? { title: "No clipboard history on this machine", sub: "There was no history file to look in.", tone: "plain", marked: false }
            : { title: "Clipboard history NOT checked", sub: "It could not be read or safely edited. Open it (Super+Ctrl+V) and delete the entry.", tone: "warn", marked: false })
          data.push({ kind: "info" })
        } else {
          rows.push({ title: "Clipboard not used", sub: "The key went from one file to the other.", tone: "plain", marked: false })
          data.push({ kind: "info" })
        }
      } else {
        root.titleText = "Not saved"
        root.hints = "↵ close   Esc back"
        rows.push({ title: "Nothing was written", sub: res && res.message ? res.message : "The helper gave no reason.", tone: "warn", marked: false })
        data.push({ kind: "info" })
      }
    } else if (root.view === "keys") {
      root.titleText = "Key store"
      root.placeholder = "Search names"
      root.hints = "↵ open   Ctrl+F folders   Esc close"
      chip = root.scanLoaded ? "names and places only" : "looking…"
      tone = "plain"
      var index = Model.filterKeys(Model.keyIndex(root.scan.projects), root.filterText)
      for (var k = 0; k < index.length; k++) {
        var empty = index[k].places.filter(function(pl) { return !pl.set }).length
        var exposed = index[k].places.filter(function(pl) { return pl.git === "not-ignored" || pl.git === "tracked" }).length
        rows.push({ title: index[k].name, sub: Model.plural(index[k].places.length, "project", "projects") + (empty ? " · " + empty + " empty" : "") + (exposed ? " · " + exposed + " not ignored by git" : ""), tone: exposed ? "warn" : "plain", marked: false })
        data.push({ kind: "key", key: index[k] })
      }
    } else if (root.view === "places") {
      root.titleText = root.activeKey.name
      root.placeholder = ""
      root.hints = "↵ send to another project   C copy to clipboard   Esc back"
      chip = "the value is never shown"
      tone = "plain"
      for (var pl = 0; pl < root.activeKey.places.length; pl++) {
        var place = root.activeKey.places[pl], gl = Model.gitLine(place.git, place.vcs, root.scanPending)
        rows.push({ title: place.label + "/" + place.base, sub: (place.set ? "has a value" : "empty") + (place.backup ? " · backup copy" : "") + " · " + gl.text, tone: gl.tone === "warn" || gl.tone === "bad" ? "warn" : "plain", marked: false })
        data.push({ kind: "place", place: place })
      }
    } else if (root.view === "folders") {
      root.titleText = "Search folders"
      root.placeholder = ""
      root.hints = "↵ add   Del remove   ← → depth   Esc back"
      chip = root.scan.configured ? "" : "defaults, nothing saved yet"
      tone = "plain"
      for (var f = 0; f < root.scan.roots.length; f++) {
        var rt = root.scan.roots[f]
        var inside = root.scan.projects.filter(function(pr) { return pr.root === rt.path })
        var withKeys = inside.filter(function(pr) { return pr.files.some(Model.isSaveable) }).length
        rows.push({ title: Model.shortPath(rt.path, root.home), sub: rt.exists ? Model.plural(inside.length, "project", "projects") + " · " + withKeys + " with a .env" : "not on this machine, skipped", tone: rt.exists ? "plain" : "dim", marked: false })
        data.push({ kind: "root", path: rt.path })
      }
      rows.push({ title: "+ Add a folder", sub: "Its sub-folders become projects.", tone: "dim", marked: false })
      data.push({ kind: "addFolder" })
      rows.push({ title: "Depth: " + root.scan.depth, sub: "How many folders down to look for a project nested inside another.", tone: "plain", marked: false })
      data.push({ kind: "depth" })
    } else if (root.view === "browse") {
      root.titleText = "Add " + Model.shortPath(root.browse.path, root.home)
      root.placeholder = "Search folders here"
      root.hints = "Tab add this folder   ↵ open   ← up   Esc back"
      chip = ""
      var q = root.filterText.toLowerCase()
      for (var d = 0; d < root.browse.dirs.length; d++) {
        if (q && root.browse.dirs[d].toLowerCase().indexOf(q) < 0) continue
        rows.push({ title: root.browse.dirs[d], sub: "", tone: "plain", marked: false })
        data.push({ kind: "dir", path: root.browse.path + "/" + root.browse.dirs[d] })
      }
    } else if (root.view === "notice") {
      root.titleText = root.notice.title
      root.placeholder = ""
      root.hints = (root.notice.back ? "↵ back" : "↵ close") + "   Ctrl+K key store   Esc close"
      for (var l = 0; l < root.notice.lines.length; l++) {
        rows.push({ title: root.notice.lines[l], sub: "", tone: l === 0 ? "warn" : "plain", marked: false })
        data.push({ kind: "info" })
      }
    }

    if (root.view === "result" || root.view === "notice") chip = ""
    if (root.busy === "saving") root.hints = "saving…"
    else if (root.busy === "checking") root.hints = "checking git…"

    root.chipText = chip
    root.chipTone = tone
    root.rowData = data
    displayModel.clear()
    for (var m = 0; m < rows.length; m++) displayModel.append(rows[m])
    if (root.selectedIndex >= rows.length) root.selectedIndex = Math.max(0, rows.length - 1)

    // The right-hand pane explains the selected row.
    var current = data[root.selectedIndex]
    if (root.view === "projects") {
      if (current && current.kind === "project") detail = root.fileLines(current.project)
      else if (current) detail = root.scan.roots.map(function(rt) { return { text: Model.shortPath(rt.path, root.home) + (rt.exists ? "" : "   not found"), tone: rt.exists ? "plain" : "dim" } })
      else if (!root.scanLoaded) detail = [{ text: "Looking for projects…", tone: "dim" }]
    } else if (root.view === "name") {
      if (current) detail = root.planLines(Model.savePlan(current.name, root.targets, root.checks))
    } else if (root.view === "confirm") {
      detail = root.planLines(root.plan)
    } else if (root.view === "result") {
      detail = [
        { text: "The key was never shown, typed or put in a command.", tone: "dim" },
        { text: "", tone: "plain" },
        { text: "Agents read it from the project's .env, as before.", tone: "dim" }
      ]
    } else if (root.view === "keys") {
      if (current) {
        detail = [{ text: current.key.name, tone: "strong" }]
        for (var c = 0; c < current.key.places.length; c++) {
          var cp = current.key.places[c], cg = Model.gitLine(cp.git, cp.vcs, root.scanPending)
          detail.push({ text: "", tone: "plain" })
          detail.push({ text: (cp.set ? "● " : "○ ") + cp.label + "/" + cp.base, tone: "plain" })
          detail.push({ text: (cp.set ? "has a value" : "empty") + (cp.backup ? " · backup copy" : "") + " · " + cg.text, tone: cg.tone === "warn" || cg.tone === "bad" ? "warn" : "dim" })
        }
      } else if (root.scanLoaded) {
        detail = [{ text: root.filterText ? "No name matches." : "No keys found in the search folders.", tone: "dim" }]
      }
    } else if (root.view === "places") {
      detail = [
        { text: "↵  Send to another project", tone: "strong" },
        { text: "Copied from this file straight into the other. The clipboard is not used.", tone: "dim" },
        { text: "", tone: "plain" },
        { text: "C  Copy to the clipboard", tone: "strong" },
        { text: "Marked sensitive, so clipboard history keeps no copy. Paste it where it is needed.", tone: "dim" }
      ]
    } else if (root.view === "folders") {
      detail = [
        { text: "Every folder directly inside a search folder is a project. Deeper folders count when they hold a .env.", tone: "plain" },
        { text: "", tone: "plain" },
        { text: "Hidden folders and dependency folders such as node_modules are skipped.", tone: "dim" },
        { text: "", tone: "plain" },
        { text: "Kept in " + Model.shortPath(root.scan.config, root.home), tone: "dim" }
      ]
    } else if (root.view === "browse") {
      detail = [
        { text: Model.shortPath(root.browse.path, root.home), tone: "strong" },
        { text: "", tone: "plain" },
        { text: "Tab adds this folder to the search. Its " + Model.plural(root.browse.dirs.length, "sub-folder becomes a project", "sub-folders become projects") + ".", tone: "plain" }
      ]
    }
    root.detail = detail
    Qt.callLater(function() { if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.selectedIndex = Math.max(0, Math.min(displayModel.count - 1, root.selectedIndex + delta))
    root.rebuild()
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.rebuild()
  }

  function toggleMark() {
    var current = root.rowData[root.selectedIndex]
    if (root.view !== "projects" || !current || current.kind !== "project") return
    var next = ({})
    for (var k in root.marked) next[k] = true
    if (next[current.project.dir]) delete next[current.project.dir]
    else next[current.project.dir] = true
    root.marked = next
    root.rebuild()
  }

  function openBrowser(path) {
    root.run([root.keysBin, "dirs", path || root.home], function(code, out) {
      var parsed = root.parse(out, null)
      if (!parsed) return
      root.browse = parsed
      root.go("browse")
    })
  }

  function changeFolders(args) {
    root.run([root.keysBin, "folders"].concat(args), function(code, out) {
      root.loadScan()
      root.go("folders")
    })
  }

  function activate() {
    if (root.busy) return
    var current = root.rowData[root.selectedIndex]

    if (root.view === "projects") {
      if (!current) return
      if (current.kind === "addFolder") { root.backView = "projects"; root.openBrowser(root.home); return }
      var chosen = root.scan.projects.filter(function(p) { return root.marked[p.dir] === true })
      if (chosen.length === 0) chosen = [current.project]
      chosen = chosen.map(function(p) { return Model.makeTarget(p, root.fileChoice[p.dir]) })
      if (root.source) chosen = chosen.filter(function(t) { return t.path !== root.source.file })
      if (chosen.length === 0) return
      root.targets = chosen
      root.checks = ({})
      root.runChecks()
      if (root.source) { root.keyName = root.source.name; root.proceed() }
      else root.go("name")
    } else if (root.view === "name") {
      if (!current) return
      root.keyName = current.name
      root.proceed()
    } else if (root.view === "confirm") {
      root.save()
    } else if (root.view === "result") {
      root.dismiss()
    } else if (root.view === "keys") {
      if (!current) return
      root.activeKey = current.key
      root.go("places")
    } else if (root.view === "places") {
      if (!current) return
      if (!current.place.set) { root.showNotice(root.activeKey.name + " is empty there", ["There is no value in " + current.place.label + "/" + current.place.base + " to send."], "places"); return }
      root.source = { file: current.place.file, label: current.place.label, name: root.activeKey.name }
      root.marked = ({})
      root.go("projects")
    } else if (root.view === "folders") {
      if (current && current.kind === "addFolder") root.openBrowser(root.home)
    } else if (root.view === "browse") {
      if (current) root.openBrowser(current.path)
    } else if (root.view === "notice") {
      if (root.notice.back) root.go(root.notice.back)
      else root.dismiss()
    }
  }

  // Decide what stands between a chosen name and the save: nothing, a
  // question for the person, or a refusal.
  function proceed() {
    var plan = Model.savePlan(root.keyName, root.targets, root.checks)
    if (!plan.checked) { root.busy = "checking"; root.rebuild(); return }
    root.plan = plan
    if (plan.tracked.length > 0) {
      root.showNotice("git already tracks " + plan.tracked.join(", "), [
        "A key saved there would be committed, and adding the file to .gitignore would not change that.",
        "Stop tracking it first, with git rm --cached, then save again."
      ], root.source ? "projects" : "name")
      return
    }
    if (plan.needsConfirm) root.go("confirm")
    else root.save()
  }

  function save() {
    var argv = [root.takeBin, root.keyName, "--json"]
    if (root.plan && root.plan.needsIgnore.length > 0) argv.push("--ignore")
    if (root.source) argv.push("--from", root.source.file)
    for (var i = 0; i < root.targets.length; i++) argv.push("--file", root.targets[i].path)
    root.busy = "saving"
    root.rebuild()
    root.run(argv, function(code, out) {
      root.busy = ""
      root.result = root.parse(out, { ok: false, message: "The helper exited with status " + code + " and no report." })
      root.loadScan()
      if (root.opened) root.go("result")
    })
  }

  function saveToAnother() {
    var res = root.result
    if (!res || !res.ok) return
    var file = res.results[0].file
    var label = Model.baseName(file.replace(/\/[^\/]*$/, ""))
    for (var i = 0; i < root.targets.length; i++) if (root.targets[i].path === file) label = root.targets[i].label
    root.source = { file: file, label: label, name: res.name }
    root.marked = ({})
    root.go("projects")
  }

  function copyPlace() {
    var current = root.rowData[root.selectedIndex]
    if (!current || current.kind !== "place") return
    if (!current.place.set) { root.showNotice(root.activeKey.name + " is empty there", ["There is no value in " + current.place.label + "/" + current.place.base + " to copy."], "places"); return }
    var name = root.activeKey.name
    root.run([root.keysBin, "copy", name, "--file", current.place.file], function(code, out) {
      if (code !== 0) { root.showNotice("Not copied", ["The clipboard could not be reached."], "places"); return }
      Quickshell.execDetached(["notify-send", "--app-name=Secrets", "Copied " + name, "On the clipboard, marked sensitive. Clipboard history keeps no copy."])
      root.dismiss()
    })
  }

  // In the name step, Tab moves the key to the project's next file, for a
  // project that keeps its keys somewhere other than .env.
  function cycleFile() {
    if (root.targets.length !== 1) return
    var target = root.targets[0], files = Model.saveFiles(target.project)
    if (files.length < 2) return
    var at = 0
    for (var i = 0; i < files.length; i++) if (files[i].path === target.path) at = i
    var next = files[(at + 1) % files.length]
    var choice = ({})
    for (var k in root.fileChoice) choice[k] = root.fileChoice[k]
    choice[target.dir] = next.path
    root.fileChoice = choice
    root.targets = [Model.makeTarget(target.project, next.path)]
    root.runChecks()
    root.rebuild()
  }

  function back() {
    if (root.filterable && root.filterText) { root.setFilter(""); return }
    if (root.view === "name") root.go("projects")
    else if (root.view === "confirm") root.go(root.source ? "projects" : "name")
    else if (root.view === "places") root.go("keys")
    else if (root.view === "projects" && root.source) { root.source = null; root.go(root.activeKey ? "places" : "result") }
    else if (root.view === "folders") root.go(root.backView)
    else if (root.view === "browse") root.go("folders")
    else if (root.view === "result" && root.result && !root.result.ok) root.go(root.source ? "projects" : "name")
    else root.dismiss()
  }

  ListModel { id: displayModel }

  // Warm the list when the shell loads the plugin, so the first press of the
  // hotkey opens on it.
  Component.onCompleted: root.loadScan()

  function toneColor(tone, selected) {
    if (tone === "warn") return root.warnColor
    return selected ? root.selectedText : root.foreground
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-secrets"

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          var plain = (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
          var typed = plain && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127

          if (event.key === Qt.Key_Escape) {
            root.back()
          } else if (ctrl && event.key === Qt.Key_K) {
            root.source = null
            root.activeKey = null
            root.wantGit = true
            root.loadScan()
            root.go("keys")
          } else if (ctrl && event.key === Qt.Key_F) {
            if (root.view !== "folders" && root.view !== "browse") root.backView = root.view === "keys" || root.view === "places" ? "keys" : "projects"
            root.go("folders")
          } else if (root.filterable && Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
          } else if (event.key === Qt.Key_Home) {
            root.select(-displayModel.count)
          } else if (event.key === Qt.Key_End) {
            root.select(displayModel.count)
          } else if (event.key === Qt.Key_Tab) {
            if (root.view === "projects") root.toggleMark()
            else if (root.view === "name") root.cycleFile()
            else if (root.view === "browse") root.changeFolders(["add", root.browse.path])
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate()
          } else if (root.view === "browse" && (Util.readingKey(event) === Qt.Key_Left || (event.key === Qt.Key_Backspace && !root.filterText))) {
            if (root.browse.parent && root.browse.parent !== root.browse.path) root.openBrowser(root.browse.parent)
          } else if (root.view === "browse" && Util.readingKey(event) === Qt.Key_Right) {
            root.activate()
          } else if (root.view === "folders" && event.key === Qt.Key_Delete) {
            var row = root.rowData[root.selectedIndex]
            if (row && row.kind === "root") root.changeFolders(["remove", row.path])
          } else if (root.view === "folders" && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
            var depth = root.scan.depth + (Util.readingKey(event) === Qt.Key_Right ? 1 : -1)
            if (depth >= 1 && depth <= 8) root.changeFolders(["depth", String(depth)])
          } else if (root.view === "result" && plain && event.key === Qt.Key_A) {
            root.saveToAnother()
          } else if (root.view === "places" && plain && event.key === Qt.Key_C) {
            root.copyPlace()
          } else if (root.filterable && typed) {
            root.setFilter(root.filterText + event.text)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // What this step is, and what is on the clipboard.
        Item {
          width: parent.width
          height: root.lineHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: chip.left
            anchors.rightMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            text: root.titleText
            color: root.selectedText
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            elide: Text.ElideMiddle
          }

          Rectangle {
            id: chip
            visible: root.chipText.length > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: chipLabel.implicitWidth + Style.spacing.controlPaddingX * 2
            height: parent.height
            radius: root.cornerRadius
            color: Util.alpha(root.chipTone === "warn" ? root.warnColor : root.foreground, 0.1)

            Text {
              id: chipLabel
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: root.chipText
              color: root.chipTone === "warn" ? root.warnColor : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // The filter, drawn the way the clipboard manager draws its own.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.shownFilter || root.placeholder
            visible: root.filterable
            color: root.foreground
            opacity: root.shownFilter ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Rectangle {
            visible: !root.filterable
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: Style.normalBorderWidth
            color: Util.alpha(root.border, 0.28)
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.lineHeight * 2 - root.headerHeight - root.contentSpacing * 3

          Item {
            id: listPane
            width: parent.width * 0.55
            height: parent.height
            clip: true

            ListView {
              id: resultList
              anchors.fill: parent
              anchors.rightMargin: root.contentMargin
              model: displayModel
              clip: true
              spacing: Style.space(4)
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                id: row
                required property int index
                required property string title
                required property string sub
                required property string tone
                required property bool marked

                readonly property bool hasCursor: index === root.selectedIndex
                readonly property bool oneLine: sub.length === 0

                width: ListView.view.width
                height: root.rowHeight
                radius: root.cornerRadius
                color: hasCursor ? root.selectedBackground : "transparent"

                Text {
                  id: tick
                  textFormat: Text.PlainText
                  visible: row.marked
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "✓"
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                Column {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(12) + (row.marked ? tick.implicitWidth + Style.space(8) : 0)
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: row.title
                    color: root.toneColor(row.tone, row.hasCursor)
                    opacity: row.tone === "dim" ? 0.72 : 1
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    elide: Text.ElideMiddle
                    wrapMode: row.oneLine ? Text.Wrap : Text.NoWrap
                    maximumLineCount: row.oneLine ? 2 : 1
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: !row.oneLine
                    width: parent.width
                    text: row.sub
                    color: root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.selectedIndex = row.index
                    root.rebuild()
                    root.activate()
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: displayModel.count === 0
              anchors.centerIn: parent
              width: parent.width - 2 * root.contentMargin
              text: root.view === "name" ? "Type a name for the key." : !root.scanLoaded ? "Looking…" : root.filterText ? "Nothing matches " + root.filterText + "." : "Nothing here yet."
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }

          Item {
            anchors.left: listPane.right
            anchors.right: parent.right
            height: parent.height
            clip: true

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.normalBorderWidth
              color: Util.alpha(root.border, 0.28)
            }

            Flickable {
              id: detailFlick
              anchors.fill: parent
              anchors.leftMargin: root.contentMargin
              contentHeight: detailColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: detailColumn
                width: detailFlick.width
                spacing: Style.space(3)

                Repeater {
                  model: root.detail

                  Text {
                    required property var modelData
                    textFormat: Text.PlainText
                    width: detailColumn.width
                    text: modelData.text
                    color: modelData.tone === "warn" ? root.warnColor : modelData.tone === "strong" ? root.selectedText : root.foreground
                    opacity: modelData.tone === "dim" ? 0.6 : 1
                    font.family: root.fontFamily
                    font.pixelSize: modelData.tone === "strong" ? Style.font.title : Style.font.body
                    wrapMode: Text.Wrap
                  }
                }
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          height: root.lineHeight
          text: root.hints
          color: root.foreground
          opacity: 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }
}
