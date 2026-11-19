#!/bin/bash

# Drives the overlay with real key presses on a private X display and takes a
# picture of each step. Nothing here reaches the desktop it is run from: the
# display is Xvfb, HOME is a temp directory holding made-up projects, and the
# clipboard programs are fakes that read and write a file.
#
# The overlay under test is Secrets.qml with one line removed, the layer-shell
# namespace, because Xvfb has no layer shell. Omarchy's own OverlayWindow is
# replaced by a plain window for the same reason; everything else, including
# the theme, the fonts and the two helper scripts, is the real thing.
#
# Usage: tests/ui.sh [OUTPUT_DIR]     (default: tests/shots)
#
# UI_SCALE=2 draws everything at twice the size, for pictures that will be
# enlarged. UI_ONLY=<scenario> runs one scenario and skips the checks.
# UI_LANG=<code> (de, ja, zh-CN ...) sets Omarchy's display language in the
# temp HOME, so the card is photographed in that language.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
out=${1:-$here/shots}
omarchy=${OMARCHY_PATH:-/usr/share/omarchy}
scale=${UI_SCALE:-1}
real_home=$HOME

for tool in xvfb-run xdotool import quickshell jq; do
  command -v "$tool" >/dev/null || { echo "ui.sh: needs $tool" >&2; exit 2; }
done

T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$out" "$T/shell/Ui" "$T/shell/plugin" "$T/fakebin" "$T/rt"
chmod 700 "$T/rt"
rm -f "$out"/*.png

# A shell root that looks like Omarchy's to the plugin: the real Commons, the
# real Ui parts, and a stand-in for the one that needs a layer shell.
ln -s "$omarchy/shell/Commons" "$T/shell/Commons"
for f in "$omarchy"/shell/Ui/*; do
  [[ ${f##*/} == OverlayWindow.qml ]] || ln -s "$f" "$T/shell/Ui/${f##*/}"
done
cat >"$T/shell/Ui/OverlayWindow.qml" <<'EOF'
import QtQuick
import Quickshell

FloatingWindow {
  property bool shown: false
  property int shownLayer: 0
  property int shownKeyboardFocus: 0
  visible: shown
  color: "#1a1d21"
  implicitWidth: 1280
  implicitHeight: 800
}
EOF
cat >"$T/shell/shell.qml" <<'EOF'
import Quickshell
import QtQuick
import "plugin" as Plugin

ShellRoot {
  Plugin.Secrets {
    Component.onCompleted: open(Quickshell.env("SECRETS_PAYLOAD") || "{}")
    onOpenedChanged: if (!opened) console.log("OVERLAY CLOSED")
  }
}
EOF
grep -v 'WlrLayershell.namespace' "$repo/Secrets.qml" >"$T/shell/plugin/Secrets.qml"
cp "$repo/Model.js" "$T/shell/plugin/"
cp -r "$repo/bin" "$repo/lib" "$repo/i18n" "$T/shell/plugin/"

cat >"$T/fakebin/wl-paste" <<'EOF'
#!/bin/bash
cat "$FAKE_CLIP" 2>/dev/null
EOF
cat >"$T/fakebin/wl-copy" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --clear ]]; then : >"$FAKE_CLIP"; else printf '%s\n' "$*" >"$FAKE_CLIP.args"; cat >"$FAKE_CLIP"; fi
EOF
cat >"$T/fakebin/notify-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_NOTES"
EOF
chmod +x "$T/fakebin/"*

# Made-up projects. The key is a made-up value with a real issuer's prefix.
KEY='sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdefTESTONLY00'
H="$T/home"
W="$H/Work"
mkdir -p "$W"/{storefront,api-gateway,mobile-app,billing-service,field-notes,next-site,monorepo/apps/web} \
  "$H/.local/state/omarchy" "$H/.config" "$H/Clients/acme-site"
printf 'DATABASE_URL=postgres://localhost/store\nSTRIPE_SECRET_KEY=sk_test_madeupmadeupmadeup\nOPENROUTER_API_KEY=\n' >"$W/storefront/.env"
printf 'OPENROUTER_API_KEY=\nSTRIPE_SECRET_KEY=\nSENTRY_DSN=\n' >"$W/storefront/.env.example"
printf 'ANTHROPIC_API_KEY=sk-ant-madeupmadeupmadeup\nOPENROUTER_API_KEY=sk-or-v1-anoldmadeupvalue000\n' >"$W/api-gateway/.env"
printf 'SENTRY_DSN=https://made.up/1\n' >"$W/monorepo/apps/web/.env"
printf 'STRIPE_SECRET_KEY=sk_test_madeupmadeupmadeup\n' >"$W/billing-service/.env"
printf 'NEXT_PUBLIC_SITE_URL=http://localhost:3000\nANTHROPIC_API_KEY=\n' >"$W/next-site/.env.local"
printf 'OLD_KEY=madeupmadeup\n' >"$W/next-site/.env.local.bak"
(cd "$W/next-site" && git init -q . && echo '.env*.local' >.gitignore)
(cd "$W/storefront" && git init -q . && echo .env >.gitignore)
(cd "$W/mobile-app" && git init -q .)
(cd "$W/billing-service" && git init -q .)
touch -d '5 minutes ago' "$W/storefront"
touch -d '1 hour ago' "$W/api-gateway"
touch -d '3 hours ago' "$W/mobile-app"
touch -d '1 day ago' "$W/billing-service"
touch -d '2 days ago' "$W/monorepo" "$W/monorepo/apps/web"
touch -d '9 days ago' "$W/field-notes"
touch -d '12 days ago' "$W/next-site"
jq -n --arg s "$KEY" '[{type:"text",text:"an earlier copy"},{type:"text",text:$s},{type:"text",text:"another earlier copy"}]' \
  >"$H/.local/state/omarchy/clipboard-history.json"

# Omarchy keeps the display language in one small file; no file is English.
[[ -n ${UI_LANG:-} ]] && mkdir -p "$H/.config/omarchy" && printf '%s\n' "$UI_LANG" >"$H/.config/omarchy/language"

# The real theme and fonts, read only, so the pictures look like the desktop.
[[ -e $real_home/.local/state/omarchy/current ]] && ln -s "$real_home/.local/state/omarchy/current" "$H/.local/state/omarchy/current"
[[ -e $real_home/.config/fontconfig ]] && ln -s "$real_home/.config/fontconfig" "$H/.config/fontconfig"
[[ -e $real_home/.local/share/fonts ]] && mkdir -p "$H/.local/share" && ln -s "$real_home/.local/share/fonts" "$H/.local/share/fonts"

cat >"$T/drive.sh" <<'EOF'
#!/bin/bash
# Runs inside Xvfb. $1 is the scenario.
set -uo pipefail
shot_n=0
shot() { shot_n=$((shot_n + 1)); sleep 0.5; import -window root "$OUT/$(printf '%s-%02d-%s' "$SCENARIO" "$shot_n" "$1").png"; }
key() { for k in "$@"; do xdotool key --delay 40 "$k"; sleep 0.12; done; }
type_() { xdotool type --delay 40 "$1"; sleep 0.2; }

quickshell -p "$SHELL_ROOT/shell.qml" >"$LOG" 2>&1 &
qs=$!
for _ in $(seq 60); do
  win=$(xdotool search --onlyvisible --pid "$qs" 2>/dev/null | head -n1)
  [[ -n $win ]] && break
  sleep 0.25
done
if [[ -z ${win:-} ]]; then echo "no window appeared"; kill "$qs" 2>/dev/null; exit 1; fi
xdotool windowfocus "$win" 2>/dev/null
sleep 1.2

case $SCENARIO in
take)
  shot projects
  type_ "sto"
  shot filtered
  key Return
  shot name
  key Return
  shot result
  key a
  shot another
  key Tab Down Tab
  shot marked
  key Return
  shot another-confirm
  key Return
  shot another-result
  key Return
  ;;
new)
  type_ "mobile"
  key Return
  shot name-for-new
  type_ "my new key"
  shot typed-name
  key Return
  shot confirm-gitignore
  key Return
  shot result
  key Return
  ;;
keys)
  shot keys
  type_ "stripe"
  shot filtered
  key Return
  shot places
  key c
  sleep 0.5
  ;;
folders)
  key ctrl+f
  shot folders
  key Down Down Down Down Return
  shot browse
  type_ "Cli"
  key Return
  shot inside
  key Tab
  shot added
  key Escape
  shot back
  ;;
local)
  type_ "next"
  shot project
  key Return
  shot name
  key Tab
  shot other-file
  key Tab Return
  shot result
  key Return
  ;;
film)
  # One run from the hotkey to the summary, a picture after every key.
  shot open
  key Tab; shot mark-one
  key Down; shot down-one
  key Down; shot down-two
  key Tab; shot mark-two
  key Return; shot name
  key Return; shot question
  key Return; shot saved
  key Return
  ;;
empty)
  shot notice
  key Return
  ;;
broken)
  # The save works, and the card must say plainly that the history was not checked.
  type_ "field"
  key Return Return
  sleep 1.5 # the helper tries the history file more than once before giving up
  shot result
  key Return
  ;;
esac
sleep 0.6
kill "$qs" 2>/dev/null
wait "$qs" 2>/dev/null
exit 0
EOF
chmod +x "$T/drive.sh"

real_config_before=$(ls -la "$real_home/.config/omarchy-secrets" 2>&1)

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok    $1"; }
no() { fail=$((fail + 1)); echo "  FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

scenario() {
  local name=$1 payload=$2
  env -u WAYLAND_DISPLAY -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
    HOME="$H" XDG_RUNTIME_DIR="$T/rt" QT_QPA_PLATFORM=xcb QT_SCALE_FACTOR="$scale" \
    PATH="$T/fakebin:$PATH" FAKE_CLIP="$T/clip" FAKE_NOTES="$T/notes" \
    SECRETS_PAYLOAD="$payload" SCENARIO="$name" OUT="$out" LOG="$T/log.$name" SHELL_ROOT="$T/shell" \
    OMARCHY_PATH="$omarchy" \
    xvfb-run -a -s "-screen 0 $((1280 * scale))x$((800 * scale))x24" "$T/drive.sh" >"$T/drive.$name" 2>&1
  local rc=$?
  check "$name: the overlay came up and was driven" "[[ $rc -eq 0 ]]"
  grep -E ' (WARN|ERROR).*(qml|Secrets|Model)' "$T/log.$name" | grep -v 'qt.qpa' | head -n 8
}

: >"$T/notes"

if [[ -n ${UI_ONLY:-} ]]; then
  printf '%s' "$KEY" >"$T/clip"
  [[ $UI_ONLY == broken ]] && printf 'not json' >"$H/.local/state/omarchy/clipboard-history.json"
  scenario "$UI_ONLY" "${UI_PAYLOAD:-{\}}"
  echo "$pass passed, $fail failed. Pictures: $out"
  exit $((fail > 0))
fi

echo "take: the key on the clipboard goes into a project, then two more"
printf '%s' "$KEY" >"$T/clip"
scenario take '{}'
check "storefront/.env holds the key under the suggested name" '[[ $(grep "^OPENROUTER_API_KEY=" "$W/storefront/.env") == "OPENROUTER_API_KEY=$KEY" ]]'
check "its other lines are untouched" 'grep -q "^DATABASE_URL=postgres://localhost/store$" "$W/storefront/.env" && grep -q "^STRIPE_SECRET_KEY=sk_test_madeupmadeupmadeup$" "$W/storefront/.env"'
check "the clipboard is cleared" '[[ ! -s $T/clip ]]'
check "only that copy left the clipboard history" '[[ $(jq -c "map(.text)" "$H/.local/state/omarchy/clipboard-history.json") == "[\"an earlier copy\",\"another earlier copy\"]" ]]'
check "save to another: api-gateway had its old value replaced" '[[ $(grep "^OPENROUTER_API_KEY=" "$W/api-gateway/.env") == "OPENROUTER_API_KEY=$KEY" ]]'
check "save to another: mobile-app got a new .env, mode 600" '[[ $(cat "$W/mobile-app/.env" 2>/dev/null) == "OPENROUTER_API_KEY=$KEY" && $(stat -c %a "$W/mobile-app/.env") == 600 ]]'
check "save to another: mobile-app's .env was added to .gitignore" 'git -C "$W/mobile-app" check-ignore -q .env'

echo "new: a typed name, in a project git does not ignore"
printf '%s' "Zq8w3kLm0pR5tY7uVb2nXc4dFg6hJ9aS" >"$T/clip"
rm -f "$W/mobile-app/.env" "$W/mobile-app/.gitignore"
scenario new '{}'
check "the typed name became MY_NEW_KEY" '[[ $(cat "$W/mobile-app/.env" 2>/dev/null) == "MY_NEW_KEY=Zq8w3kLm0pR5tY7uVb2nXc4dFg6hJ9aS" ]]'
check ".env was added to .gitignore before the key was written" '[[ $(cat "$W/mobile-app/.gitignore" 2>/dev/null) == ".env" ]]'

echo "keys: the key store lists names, and copies one marked sensitive"
: >"$T/clip"
scenario keys '{"mode":"keys"}'
check "the value reached the clipboard" '[[ $(cat "$T/clip") == "sk_test_madeupmadeupmadeup" ]]'
check "it was marked sensitive" '[[ $(cat "$T/clip.args" 2>/dev/null) == "--sensitive" ]]'
# The notification is in the language under test: the title is that language's
# copy.done.title, or its base language's (es for es-MX), or English.
ui_lang=${UI_LANG:-en}
said=$(jq -rn --arg k copy.done.title '[inputs | .[$k] | select(type == "string")][0]' \
  $(for c in "$ui_lang" "${ui_lang%%-*}" en; do [[ -r $repo/i18n/$c.json ]] && printf '%s ' "$repo/i18n/$c.json"; done))
said=${said//%1/STRIPE_SECRET_KEY}
check "a notification said so in the language under test, without the value" 'grep -qF "$said" "$T/notes" && ! grep -q madeup "$T/notes"'

echo "folders: a search folder is added from the browser"
printf '%s' "$KEY" >"$T/clip"
scenario folders '{}'
check "the config file lists the new folder" '[[ $(jq -c .roots "$H/.config/omarchy-secrets/config.json" 2>/dev/null) == "[\"~/Work\",\"~/Projects\",\"~/Code\",\"~/src\",\"~/Clients\"]" ]]'

echo "local: a project that keeps its keys in .env.local"
printf '%s' "sk-ant-api03-madeupmadeupmadeupmadeupmadeupmadeup" >"$T/clip"
scenario local '{}'
check "the key went into .env.local, filling the empty name" '[[ $(grep "^ANTHROPIC_API_KEY=" "$W/next-site/.env.local") == "ANTHROPIC_API_KEY=sk-ant-api03-madeupmadeupmadeupmadeupmadeupmadeup" ]]'
check "no .env was created beside it" '[[ ! -e $W/next-site/.env ]]'
check "the backup copy was not touched" '[[ $(cat "$W/next-site/.env.local.bak") == "OLD_KEY=madeupmadeup" ]]'

echo "empty: no key on the clipboard"
printf '%s' "just some words" >"$T/clip"
scenario empty '{}'
check "nothing was written anywhere new" '[[ ! -e $W/field-notes/.env ]]'

echo "broken: a clipboard history file that cannot be read"
printf '%s' "$KEY" >"$T/clip"
printf 'not json' >"$H/.local/state/omarchy/clipboard-history.json"
scenario broken '{}'
check "the key was still saved" '[[ $(cat "$W/field-notes/.env" 2>/dev/null) == "OPENROUTER_API_KEY=$KEY" ]]'
check "the history file it could not read was left exactly as it was" '[[ $(cat "$H/.local/state/omarchy/clipboard-history.json") == "not json" ]]'

echo "isolation"
check "the run left the real config folder alone" '[[ $real_config_before == "$(ls -la "$real_home/.config/omarchy-secrets" 2>&1)" ]]'

echo
echo "$pass passed, $fail failed. Pictures: $out"
[[ ${KEEP:-} ]] && { cp -r "$T" "${TMPDIR:-/tmp}/secrets-ui-last-run" 2>/dev/null; echo "kept: ${TMPDIR:-/tmp}/secrets-ui-last-run"; }
((fail == 0))
