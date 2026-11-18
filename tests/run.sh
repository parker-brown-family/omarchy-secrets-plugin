#!/bin/bash

# Tests for bin/secret-take and bin/secret-keys. Nothing here touches the real
# clipboard, the real clipboard history, the real config or the desktop:
# wl-paste, wl-copy and notify-send are replaced by fakes on PATH, and HOME
# points at a temp directory.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
take="$here/../bin/secret-take"
keys="$here/../bin/secret-keys"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT

mkdir -p "$root/fakebin"
cat >"$root/fakebin/wl-paste" <<'EOF'
#!/bin/bash
cat "$FAKE_CLIP" 2>/dev/null
EOF
cat >"$root/fakebin/wl-copy" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --clear ]]; then
  : >"$FAKE_CLIP"
else
  printf '%s\n' "$*" >"$FAKE_CLIP.args"
  cat >"$FAKE_CLIP"
fi
EOF
cat >"$root/fakebin/notify-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_NOTES"
EOF
chmod +x "$root/fakebin/"*

export PATH="$root/fakebin:$PATH"
export FAKE_CLIP="$root/clip"
export FAKE_NOTES="$root/notes"
export HOME="$root/home"
unset XDG_STATE_HOME XDG_CONFIG_HOME
export GIT_CONFIG_NOSYSTEM=1
hist="$HOME/.local/state/omarchy/clipboard-history.json"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
no() { fail=$((fail + 1)); echo "  FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

fresh() {
  work="$root/work.$RANDOM$RANDOM"
  mkdir -p "$work" "$HOME/.local/state/omarchy"
  cd "$work" || exit 1
  : >"$FAKE_NOTES"
  rm -f "$hist"
}
copy() { printf '%s' "$1" >"$FAKE_CLIP"; }
history_with() {
  jq -n --arg s "$1" '[{type:"text",text:"keep one"},{type:"text",text:($s + "\n")},{type:"image",path:"/x.png",mime:"image/png"},{type:"text",text:"keep two"}]' >"$hist.new"
  mv -f "$hist.new" "$hist"
}
history_without() {
  jq -n '[{type:"text",text:"keep one"},{type:"image",path:"/x.png",mime:"image/png"},{type:"text",text:"keep two"}]' >"$hist"
}

KEY='sk-or-v1-0123456789abcdefTESTONLY'

echo "adds a key to a new .env"
fresh; copy "$KEY"; history_with "$KEY"
out=$("$take" OPENROUTER_API_KEY 2>&1); rc=$?
check "exits 0" '[[ $rc -eq 0 ]]'
check "the file holds exactly the line" '[[ $(cat .env) == "OPENROUTER_API_KEY=$KEY" ]]'
check "a new file is mode 600" '[[ $(stat -c %a .env) == 600 ]]'
check "the clipboard is cleared" '[[ ! -s $FAKE_CLIP ]]'
check "the history entry is removed" '[[ $(jq length "$hist") -eq 3 ]] && ! grep -q "$KEY" "$hist"'
check "the other history entries survive in order" '[[ $(jq -r "map(.text // .path) | join(\",\")" "$hist") == "keep one,/x.png,keep two" ]]'
check "output never contains the key" '[[ $out != *"$KEY"* ]]'
check "notifications never contain the key" '! grep -q "$KEY" "$FAKE_NOTES"'
check "output says what happened" '[[ $out == *"added OPENROUTER_API_KEY"* && $out == *"clipboard: cleared"* && $out == *"history: removed 1 entry"* ]]'
check "no temp file is left behind" '[[ -z $(ls -A | grep -v "^\.env$") ]]'

echo "replaces an existing line and keeps the rest"
fresh; copy "$KEY"
printf 'FIRST=1\nexport OPENROUTER_API_KEY=old-value\n# a comment\nLAST=2' >.env
chmod 640 .env
out=$("$take" OPENROUTER_API_KEY 2>&1); rc=$?
check "exits 0" '[[ $rc -eq 0 ]]'
check "the line is replaced in place, export kept" '[[ $(cat .env) == "FIRST=1"$'"'"'\n'"'"'"export OPENROUTER_API_KEY=$KEY"$'"'"'\n'"'"'"# a comment"$'"'"'\n'"'"'"LAST=2" ]]'
check "the old value is gone" '! grep -q old-value .env'
check "the existing file mode is kept" '[[ $(stat -c %a .env) == 640 ]]'
check "output says replaced" '[[ $out == *"replaced OPENROUTER_API_KEY"* ]]'
check "a missing history file is reported as missing, not as zero" '[[ $out == *"history: no history file"* ]]'

echo "a key with shell-special characters round-trips"
fresh; odd='p@ss$HOME#x&y;z!1'; copy "$odd"
"$take" DB_PASSWORD >/dev/null 2>&1; rc=$?
check "exits 0" '[[ $rc -eq 0 ]]'
check "sourcing the file gives the same value back" '[[ $(set -a; . ./.env; printf %s "$DB_PASSWORD") == "$odd" ]]'

echo "refuses a file git would commit"
fresh; copy "$KEY"; git init -q .
out=$("$take" OPENROUTER_API_KEY 2>&1); rc=$?
check "exits 3" '[[ $rc -eq 3 ]]'
check "nothing is written" '[[ ! -e .env ]]'
check "the clipboard is left alone" '[[ $(cat "$FAKE_CLIP") == "$KEY" ]]'
echo .env >.gitignore
"$take" OPENROUTER_API_KEY >/dev/null 2>&1; rc=$?
check "works once .env is ignored" '[[ $rc -eq 0 && -s .env ]]'

echo "refuses a clipboard that is not a key"
for bad in "" "two words here" $'line one\nline two' "short" "has'quote-in-it"; do
  fresh; copy "$bad"
  "$take" SOME_KEY >/dev/null 2>&1; rc=$?
  check "exits 4 and writes nothing for: ${bad:0:14}" '[[ $rc -eq 4 && ! -e .env ]]'
done

echo "refuses a bad name"
fresh; copy "$KEY"
"$take" "not a name" >/dev/null 2>&1; rc=$?
check "exits 2 and writes nothing" '[[ $rc -eq 2 && ! -e .env ]]'

echo "--wait takes the next key copied, not what was already there"
fresh; copy "https://example.com/already-on-the-clipboard"; history_without
(
  sleep 0.5; copy "some words copied first"
  sleep 0.5; copy "$KEY"
  sleep 0.4; history_with "$KEY"
) &
out=$("$take" --wait 10 OPENROUTER_API_KEY 2>&1); rc=$?
wait
check "exits 0" '[[ $rc -eq 0 ]]'
check "the key that was copied later is the one saved" '[[ $(cat .env) == "OPENROUTER_API_KEY=$KEY" ]]'
check "the person was asked to copy it" 'grep -q "Copy OPENROUTER_API_KEY now" "$FAKE_NOTES"'
check "a history entry written after the copy is still removed" '[[ $out == *"history: removed 1 entry"* ]] && ! grep -q "$KEY" "$hist"'

echo "--wait gives up without writing"
fresh; copy "nothing useful"
out=$("$take" --wait 1 OPENROUTER_API_KEY 2>&1); rc=$?
check "exits 4 and writes nothing" '[[ $rc -eq 4 && ! -e .env ]]'

echo "fills in an empty placeholder and says so"
fresh; copy "$KEY"; printf 'A=1\nOPENROUTER_API_KEY=\nB=2\n' >.env
out=$("$take" OPENROUTER_API_KEY 2>&1)
check "the placeholder line is filled in place" '[[ $(cat .env) == "A=1"$'"'"'\n'"'"'"OPENROUTER_API_KEY=$KEY"$'"'"'\n'"'"'"B=2" ]]'
check "output says filled in, not replaced" '[[ $out == *"filled in OPENROUTER_API_KEY"* ]]'

echo "saves one key into several projects at once"
fresh; copy "$KEY"; history_with "$KEY"; mkdir a b
out=$("$take" OPENROUTER_API_KEY --file a/.env --file b/.env --file a/.env 2>&1); rc=$?
check "exits 0" '[[ $rc -eq 0 ]]'
check "both files hold the key" '[[ $(cat a/.env) == "OPENROUTER_API_KEY=$KEY" && $(cat b/.env) == "OPENROUTER_API_KEY=$KEY" ]]'
check "a file named twice is written once" '[[ $(grep -c "OPENROUTER_API_KEY in" <<<"$out") -eq 2 ]]'
check "the clipboard is cleared and the history entry removed" '[[ ! -s $FAKE_CLIP && $out == *"history: removed 1 entry"* ]]'

echo "several projects: one refusal stops them all"
fresh; copy "$KEY"; mkdir a b; git init -q b
out=$("$take" OPENROUTER_API_KEY --file a/.env --file b/.env 2>&1); rc=$?
check "exits 3" '[[ $rc -eq 3 ]]'
check "neither file is written" '[[ ! -e a/.env && ! -e b/.env ]]'
check "the clipboard still holds the key" '[[ $(cat "$FAKE_CLIP") == "$KEY" ]]'

echo "--ignore adds the file to .gitignore, then saves"
fresh; copy "$KEY"; git init -q .; printf 'node_modules' >.gitignore
out=$("$take" OPENROUTER_API_KEY --ignore 2>&1); rc=$?
check "exits 0" '[[ $rc -eq 0 ]]'
check ".gitignore keeps its line and gains .env" '[[ $(cat .gitignore) == "node_modules"$'"'"'\n'"'"'".env" ]]'
check "git now ignores the file" 'git check-ignore -q .env'
check "the key is saved" '[[ $(cat .env) == "OPENROUTER_API_KEY=$KEY" ]]'
check "output says the .gitignore was changed" '[[ $out == *"gitignore: added .env"* ]]'
copy "$KEY"
"$take" OPENROUTER_API_KEY --ignore >/dev/null 2>&1
check "a second save does not add the line twice" '[[ $(grep -c "^\.env$" .gitignore) -eq 1 ]]'

echo "--ignore creates a .gitignore when there is none"
fresh; copy "$KEY"; git init -q .
"$take" OPENROUTER_API_KEY --ignore >/dev/null 2>&1; rc=$?
check "exits 0 with a one-line .gitignore" '[[ $rc -eq 0 && $(cat .gitignore) == ".env" ]]'

echo "refuses a file git already tracks, even with --ignore"
fresh; copy "$KEY"; git init -q .; echo "PUBLIC=1" >.env
git add .env; git -c user.name=t -c user.email=t@example.com commit -qm init
out=$("$take" OPENROUTER_API_KEY --ignore 2>&1); rc=$?
check "exits 3" '[[ $rc -eq 3 ]]'
check "the file is unchanged" '[[ $(cat .env) == "PUBLIC=1" ]]'
check "no .gitignore is created" '[[ ! -e .gitignore ]]'
check "the message says tracked" '[[ $out == *"already tracks"* ]]'

echo "--from copies a key from one project to another"
fresh; copy "something else entirely"; history_with "$KEY"; mkdir src dst
printf '# keys\nexport OPENROUTER_API_KEY="%s" # main\nODD='"'"'p@ss$HOME#x'"'"'\nBARE=abc123 # note\nEMPTY=\n' "$KEY" >src/.env
out=$("$take" OPENROUTER_API_KEY --from src/.env --file dst/.env 2>&1); rc=$?
check "exits 0" '[[ $rc -eq 0 ]]'
check "the destination holds the same value" '[[ $(cat dst/.env) == "OPENROUTER_API_KEY=$KEY" ]]'
check "the clipboard is not touched" '[[ $(cat "$FAKE_CLIP") == "something else entirely" ]]'
check "the history is not touched" '[[ $(jq length "$hist") -eq 4 ]]'
check "output never contains the key" '[[ $out != *"$KEY"* ]]'
"$take" ODD --from src/.env --file dst/.env >/dev/null 2>&1
check "a single-quoted value round-trips" '[[ $(set -a; . dst/.env; printf %s "$ODD") == "p@ss\$HOME#x" ]]'
"$take" BARE --from src/.env --file dst/.env >/dev/null 2>&1
check "a bare value loses its trailing comment" '[[ $(grep "^BARE=" dst/.env) == "BARE=abc123" ]]'
"$take" MISSING --from src/.env --file dst/.env >/dev/null 2>&1; rc=$?
check "a name that is not in the source exits 4" '[[ $rc -eq 4 ]] && ! grep -q MISSING dst/.env'
"$take" EMPTY --from src/.env --file dst/.env >/dev/null 2>&1; rc=$?
check "an empty value in the source exits 4" '[[ $rc -eq 4 ]] && ! grep -q EMPTY dst/.env'

echo "--json reports the outcome without the key"
fresh; copy "$KEY"; history_with "$KEY"
out=$("$take" OPENROUTER_API_KEY --json 2>/dev/null); rc=$?
check "exits 0 with one JSON object" '[[ $rc -eq 0 ]] && jq -e ".ok == true" <<<"$out" >/dev/null'
check "it names the file, the action and the clean-up" '[[ $(jq -r "[.results[0].action, .clipboard, .history, (.historyRemoved|tostring), .hint] | join(\",\")" <<<"$out") == "added,cleared,removed,1,sk-or-" ]]'
check "it never contains the key" '[[ $out != *"$KEY"* ]]'
check "no notification is sent" '[[ ! -s $FAKE_NOTES ]]'
fresh; copy "two words"
out=$("$take" OPENROUTER_API_KEY --json 2>/dev/null); rc=$?
check "a refusal is JSON too" '[[ $rc -eq 4 && $(jq -r ".ok, .error" <<<"$out" | tr "\n" ,) == "false,no-key," ]]'
fresh; copy "$KEY"
out=$("$take" --from nowhere/.env X --json 2>/dev/null); rc=$?
check "a key that came from a file reports the history as untouched, not as zero" '[[ $rc -ne 0 ]] || [[ $(jq -r .historyRemoved <<<"$out") == null ]]'

echo "history removal is surgical"
fresh; copy "$KEY"
jq -n --arg s "$KEY" '[{type:"text",text:"keep one"},{type:"text",text:("curl -H \"Authorization: Bearer " + $s + "\"")},{type:"text",text:$s},{type:"text",text:("  " + $s + "\n")},{type:"image",path:"/x.png",mime:"image/png"}]' >"$hist"
chmod 644 "$hist"
out=$("$take" OPENROUTER_API_KEY 2>&1)
check "both exact copies go, counted" '[[ $out == *"history: removed 2 entries"* ]]'
check "a longer entry that merely contains the key stays" '[[ $(jq length "$hist") -eq 3 ]] && jq -e ".[1].text | startswith(\"curl\")" "$hist" >/dev/null'
check "the file keeps its mode and its two-space layout" '[[ $(stat -c %a "$hist") == 644 && $(sed -n 2p "$hist") == "  {" ]]'
fresh; copy "$KEY"; history_without; before=$(stat -c %i:%y "$hist")
out=$("$take" OPENROUTER_API_KEY 2>&1)
check "with no matching entry the file is not rewritten at all" '[[ $out == *"history: no matching entry found"* && $(stat -c %i:%y "$hist") == "$before" ]]'
fresh; copy "$KEY"; echo "not json" >"$hist"
out=$("$take" OPENROUTER_API_KEY 2>&1); rc=$?
check "an unreadable history is reported as not checked, and left alone" '[[ $rc -eq 0 && $out == *"history: NOT CHECKED"* && $(cat "$hist") == "not json" ]]'

echo "secret-keys peek describes the clipboard without showing it"
fresh; copy "$KEY"
out=$("$keys" peek)
check "a key: length, safe prefix and a likely name" '[[ $(jq -r "[.ok, .length, .hint, .guess] | map(tostring) | join(\",\")" <<<"$out") == "true,33,sk-or-,OPENROUTER_API_KEY" ]]'
check "never the key" '[[ $out != *"$KEY"* ]]'
copy "Zq8w3kLm0pR5tY7uVb2nXc4dFg6hJ9aS"; out=$("$keys" peek)
check "an unknown issuer: four characters at most and no guess" '[[ $(jq -r "[.hint, (.guess|tostring)] | join(\",\")" <<<"$out") == "Zq8w,null" ]]'
copy "abcdefgh1"; out=$("$keys" peek)
check "a short key shows one character" '[[ $(jq -r .hint <<<"$out") == "a" ]]'
copy "two words"; check "not a key: says why" '[[ $("$keys" peek | jq -r "[.ok, .reason] | map(tostring) | join(\",\")") == "false,spaces" ]]'
copy ""; check "an empty clipboard says empty" '[[ $("$keys" peek | jq -r .reason) == "empty" ]]'

echo "secret-keys scan finds projects and names, never values"
fresh; W="$HOME/Work"; mkdir -p "$W/alpha" "$W/beta" "$W/mono/apps/web" "$W/deep/1/2/3/4/5" "$W/alpha/node_modules/pkg" "$W/alpha/.hidden"
printf 'OPENROUTER_API_KEY=%s\nEMPTY_ONE=\nexport QUOTED="x y"\n# COMMENTED=1\n' "$KEY" >"$W/alpha/.env"
printf 'OPENROUTER_API_KEY=\nSTRIPE_SECRET_KEY=\n' >"$W/alpha/.env.example"
printf 'WEB_KEY=%s\n' "$KEY" >"$W/mono/apps/web/.env"
printf 'TOO_DEEP=%s\n' "$KEY" >"$W/deep/1/2/3/4/5/.env"
printf 'DEP=%s\n' "$KEY" >"$W/alpha/node_modules/pkg/.env"
printf 'HID=%s\n' "$KEY" >"$W/alpha/.hidden/.env"
touch -d '2020-01-01' "$W/beta"; touch -d '2021-01-01' "$W/mono"; touch -d '2022-01-01' "$W/deep"; touch -d '2019-01-01' "$W/mono/apps/web"; touch -d '2023-01-01' "$W/alpha"
out=$("$keys" scan); rc=$?
check "exits 0 with JSON" '[[ $rc -eq 0 ]] && jq -e . <<<"$out" >/dev/null'
check "never a value" '[[ $out != *"$KEY"* && $out != *"x y"* ]]'
check "projects are newest first, a nested one named by its path" '[[ $(jq -r "[.projects[].label] | join(\",\")" <<<"$out") == "alpha,deep,mono,beta,mono/apps/web" ]]'
check "a project with no .env is listed with no files" '[[ $(jq -r ".projects[] | select(.label == \"beta\") | .files | length" <<<"$out") -eq 0 ]]'
check "names are listed with whether each has a value" '[[ $(jq -c "[.projects[0].files[0].names[] | [.name, .set]]" <<<"$out") == "[[\"OPENROUTER_API_KEY\",true],[\"EMPTY_ONE\",false],[\"QUOTED\",true]]" ]]'
check "an example file is marked as one, after the real file" '[[ $(jq -c "[.projects[0].files[] | [.base, .example]]" <<<"$out") == "[[\".env\",false],[\".env.example\",true]]" ]]'
check "dependencies, hidden folders and anything past the depth are left out" '[[ $out != *DEP* && $out != *HID* && $out != *TOO_DEEP* ]]'
check "search folders that do not exist are reported as missing" '[[ $(jq -c "[.roots[] | [(.path | sub(\".*/\"; \"\")), .exists]]" <<<"$out") == "[[\"Work\",true],[\"Projects\",false],[\"Code\",false],[\"src\",false]]" ]]'
check "without a config file it says so" '[[ $(jq -r .configured <<<"$out") == false ]]'
(cd "$W/alpha" && git init -q . && echo .env >.gitignore)
out=$("$keys" scan --git)
check "--git says how git treats each file" '[[ $(jq -r ".projects[] | select(.label == \"alpha\") | .files[0].git" <<<"$out") == ignored && $(jq -r ".projects[] | select(.label == \"mono/apps/web\") | .files[0].git" <<<"$out") == not-git ]]'

echo "secret-keys folders keeps the search folders"
out=$("$keys" folders depth 8); out=$("$keys" scan)
check "a deeper search finds the deeper project" '[[ $out == *TOO_DEEP* ]]'
mkdir -p "$HOME/Elsewhere/proj"; echo "ELSE_KEY=12345678" >"$HOME/Elsewhere/proj/.env"
out=$("$keys" folders add "$HOME/Elsewhere"); out=$("$keys" folders add "$HOME/Elsewhere")
check "a folder is added once, and written with ~" '[[ $(jq -c .roots "$HOME/.config/omarchy-secrets/config.json") == "[\"~/Work\",\"~/Projects\",\"~/Code\",\"~/src\",\"~/Elsewhere\"]" ]]'
check "its projects are found" '[[ $("$keys" scan) == *ELSE_KEY* ]]'
out=$("$keys" folders remove "~/Elsewhere")
check "a removed folder is no longer searched" '[[ $("$keys" scan) != *ELSE_KEY* && $(jq -r "[.roots[].path] | length" <<<"$out") -eq 4 ]]'
"$keys" folders add "$HOME/no-such-folder" >/dev/null 2>&1; rc=$?
check "a folder that does not exist is refused" '[[ $rc -eq 2 ]]'
check "dirs lists the folders inside one" '[[ $("$keys" dirs "$W" | jq -c .dirs) == "[\"alpha\",\"beta\",\"deep\",\"mono\"]" ]]'

echo "secret-keys has, names, check and copy"
cd "$W/alpha" || exit 1
"$keys" has OPENROUTER_API_KEY; a=$?; "$keys" has EMPTY_ONE; b=$?; "$keys" has NOPE; c=$?; "$keys" has X --file nowhere/.env; d=$?
check "has: 0 for a value, 1 for empty, absent or no file" '[[ $a -eq 0 && $b -eq 1 && $c -eq 1 && $d -eq 1 ]]'
check "has prints nothing" '[[ -z $("$keys" has OPENROUTER_API_KEY) ]]'
check "names lists the names only" '[[ $("$keys" names | tr "\n" ,) == "OPENROUTER_API_KEY,EMPTY_ONE,QUOTED," ]]'
check "check reports a file that exists and is ignored" '[[ $("$keys" check .env | jq -c ".[0] | [.exists, .git]") == "[true,\"ignored\"]" ]]'
check "check reports a file that does not exist yet and is not ignored" '[[ $("$keys" check .env.local | jq -c ".[0] | [.exists, .git]") == "[false,\"not-ignored\"]" ]]'
mkdir -p "$W/hgproj/.hg"
check "check names another version control system it cannot vouch for" '[[ $("$keys" check "$W/hgproj/.env" | jq -c ".[0] | [.git, .vcs]") == "[\"not-git\",\"Mercurial\"]" ]]'
copy "old clipboard"; out=$("$keys" copy OPENROUTER_API_KEY 2>&1); rc=$?
check "copy puts the value on the clipboard" '[[ $rc -eq 0 && $(cat "$FAKE_CLIP") == "$KEY" ]]'
check "copy marks it sensitive" '[[ $(cat "$FAKE_CLIP.args") == "--sensitive" ]]'
check "copy never prints the key" '[[ $out != *"$KEY"* ]]'
"$keys" copy EMPTY_ONE >/dev/null 2>&1; rc=$?
check "copy refuses an empty value" '[[ $rc -eq 2 ]]'

echo "refuses a file it cannot write"
fresh; copy "$KEY"; echo "A=1" >.env; chmod 400 .env
out=$("$take" OPENROUTER_API_KEY 2>&1); rc=$?
check "a read-only file exits 5 and is left as it was" '[[ $rc -eq 5 && $(cat .env) == "A=1" && $(stat -c %a .env) == 400 ]]'
check "the clipboard still holds the key" '[[ $(cat "$FAKE_CLIP") == "$KEY" ]]'

echo "a file name with pattern characters is taken literally by git"
fresh; copy "$KEY"; git init -q .; mkdir 'we[i]rd'; echo '.env' >.gitignore; echo "X=1" >weird.txt
"$take" OPENROUTER_API_KEY --file 'we[i]rd/.env' >/dev/null 2>&1; rc=$?
check "saves into a folder named with brackets" '[[ $rc -eq 0 && -s "we[i]rd/.env" ]]'

echo "a broken config file is never written over"
fresh; mkdir -p "$HOME/.config/omarchy-secrets"; echo '{ "roots": [ half' >"$HOME/.config/omarchy-secrets/config.json"
mkdir -p "$HOME/Elsewhere"; "$keys" folders add "$HOME/Elsewhere" >/dev/null 2>&1; rc=$?
check "folders add refuses and leaves the file as it was" '[[ $rc -eq 2 && $(cat "$HOME/.config/omarchy-secrets/config.json") == "{ \"roots\": [ half" ]]'
check "scan still works, on the defaults" '[[ $("$keys" scan | jq -r ".roots | length") -eq 4 ]]'
rm -f "$HOME/.config/omarchy-secrets/config.json"

echo "no part of a key is ever a command argument"
fresh; copy "$KEY"; history_with "$KEY"
real_jq=$(command -v jq)
cat >"$root/fakebin/jq" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$root/jq-args"
exec "$real_jq" "\$@"
EOF
chmod +x "$root/fakebin/jq"; : >"$root/jq-args"
"$take" OPENROUTER_API_KEY --json >/dev/null 2>&1; copy "$KEY"; "$keys" peek >/dev/null 2>&1
rm -f "$root/fakebin/jq"
check "jq was run, and never saw the key or its first characters in its arguments" '[[ -s $root/jq-args ]] && ! grep -q "sk-or" "$root/jq-args"'

echo
echo "$pass passed, $fail failed"
((fail == 0))
