#!/usr/bin/env bash
# End-to-end tests: a second, isolated Lumen driven through its command line.
#
#   tools/e2e.sh [path/to/lumen]        (zig build e2e runs it)
#
# Isolation: its own app id (LUMEN_APP_ID, so it never talks to the session's
# daemon), a fake $HOME with known files, apps (.desktop) and a script
# command, its own caches and database, and LUMEN_TEST=1 (no keyboard grab,
# no clipboard watcher, no Hyprland queries). It needs a Wayland session: the
# window shows up for a few seconds while the tests type into it.
#
# State is read with `lumen --dump` (view, rows, selection, detail, panel)
# and keys are sent with `lumen --key`.

set -uo pipefail

BIN=$(realpath "${1:-zig-out/bin/lumen}")
[[ -x "$BIN" ]] || { echo "no lumen binary at $BIN" >&2; exit 2; }
[[ -n "${WAYLAND_DISPLAY:-}" ]] || { echo "e2e: no Wayland session, skipping"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/lumen-e2e.XXXXXX")
H=$T/home
PASS=0
FAIL=0
DAEMON=

cleanup() {
    [[ -n "$DAEMON" ]] && kill "$DAEMON" 2>/dev/null
    rm -rf "$T"
}
# TERM too: `timeout` kills with SIGTERM, and bash skips EXIT traps then,
# which once left a test window on screen that could not be closed.
trap cleanup EXIT
trap 'exit 130' INT TERM

# ----------------------------------------------------------------- fixture
mkdir -p "$H/Projects/demo/src" "$H/notes" "$H/.config/lumen/scripts" "$T/share/applications" "$T/data" "$T/cache"
cat >"$H/Projects/demo/src/main.zig" <<'EOF'
const std = @import("std");

pub fn main() void {
    std.debug.print("hello from the e2e fixture\n", .{});
}
EOF
printf '# Demo\n\nThe quick zebrafish jumps over the lazy axolotl.\n' >"$H/notes/zebrafish.md"
printf 'package demo\n\nfunc Handler() {}\n' >"$H/Projects/demo/handler.go"
printf 'fn main() {\n    println!("rust main in the fixture");\n}\n' >"$H/Projects/demo/src/lib.rs"
# Spanish, and the file names Linux allows but UIs trip on.
printf 'La acción del camión y el Ñandú.\n' >"$H/notes/español.txt"
printf 'invalid utf8 name marker\n' >"$H/notes/bad-$(printf '\xff\xfe')-name.txt"
printf 'newline name gnuword\n' >"$H/notes/line1
line2.txt"
printf 'fifo victim fifoword\n' >"$H/notes/victim.txt"
cat >"$H/.config/lumen/scripts/hello.sh" <<'EOF'
#!/bin/sh
# @lumen.schemaVersion 1
# @lumen.title Say Hello E2E
# @lumen.mode silent
# @lumen.packageName Fixture
true
EOF
chmod +x "$H/.config/lumen/scripts/hello.sh"
# Lua: init.lua (a theme, a keymap) and an extension with each kind of
# command; a Lua action leaves a file behind to prove it ran.
mkdir -p "$H/.config/lumen/extensions/fixture" "$H/.config/lumen/extensions/broken"
cat >"$H/.config/lumen/init.lua" <<'EOF'
lumen.theme { id = "e2e-night", name = "E2E Night", bg = "#101820", fg = "#e0e0e0", accent = "#33aaff" }
lumen.keymap("ctrl+g", "fixture.fruits")
EOF
echo "local out = '$T/ext-ran'" >"$H/.config/lumen/extensions/fixture/init.lua"
cat >>"$H/.config/lumen/extensions/fixture/init.lua" <<'EOF'
local lumen = require("lumen")
return lumen.extension {
  title = "Fixture", icon = "🧪",
  commands = {
    { name = "fruits", title = "Fixture Fruits", detail = true, items = {
        { title = "Mango", subtitle = "sweet", detail = "a mango detail", actions = {
            lumen.action.copy("mango"),
            { title = "Record Mango", run = function(row)
                lumen.exec { "sh", "-c", 'printf %s "$1" > "$2"', "sh", row.title, out }
              end },
          } },
        "Kiwi",
    } },
    { name = "echo", title = "Fixture Echo", search = function(q) return { "echo: " .. q } end },
  },
}
EOF
echo 'return lumen.extension { commands = { { name = "x", title = "X" } } }' >"$H/.config/lumen/extensions/broken/init.lua"
# Apps that record what they were asked to open, for Default Apps / Open With.
mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$@" >>"%s/opened"\n' "$T" >"$T/bin/pdf-viewer-e2e"
cp "$T/bin/pdf-viewer-e2e" "$T/bin/text-opener-e2e"
chmod +x "$T/bin/"*
printf '[Desktop Entry]\nType=Application\nName=PDF Viewer E2E\nExec=%s/bin/pdf-viewer-e2e %%f\nMimeType=application/pdf;\n' "$T" >"$T/share/applications/pdf-viewer-e2e.desktop"
printf '[Desktop Entry]\nType=Application\nName=Text Opener E2E\nExec=%s/bin/text-opener-e2e %%f\nMimeType=text/plain;text/markdown;\n' "$T" >"$T/share/applications/text-opener-e2e.desktop"
printf '%%PDF-1.4\n%%%%EOF\n' >"$H/notes/quarterly-report.pdf"
# The MIME database, so file types are recognised (the system's apps stay out).
[[ -d /usr/share/mime ]] && ln -s /usr/share/mime "$T/share/mime"
for app in "Firefox E2E:Web Browser:browser;internet;" "Kitty E2E:Terminal:shell;tty;"; do
    IFS=: read -r name generic kw <<<"$app"
    id=$(tr 'A-Z ' 'a-z-' <<<"$name")
    printf '[Desktop Entry]\nType=Application\nName=%s\nGenericName=%s\nExec=true\nKeywords=%s\n' "$name" "$generic" "$kw" \
        >"$T/share/applications/$id.desktop"
done
# GIO finds the apps for a type through mimeinfo.cache (packages keep the
# system's up to date).
command -v update-desktop-database >/dev/null && update-desktop-database "$T/share/applications"

L() {
    env -u HYPRLAND_INSTANCE_SIGNATURE \
        HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$T/cache" \
        XDG_DATA_DIRS="$T/share" LUMEN_TEST=1 LUMEN_APP_ID=dev.osmait.LumenE2E "$BIN" "$@"
}

# --------------------------------------------------------------- asserting
ok() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && sed 's/^/         /' <<<"$2"; }

# expect "description" grep-pattern: the current dump matches.
expect() {
    local d; d=$(L --dump)
    if grep -qE -- "$2" <<<"$d"; then ok "$1"; else ko "$1 (no /$2/)" "$d"; fi
}
expect_not() {
    local d; d=$(L --dump)
    if grep -qE -- "$2" <<<"$d"; then ko "$1 (found /$2/)" "$d"; else ok "$1"; fi
}
# wait_for pattern [seconds]: polls the dump (indexes build in the background).
wait_for() {
    local deadline=$((SECONDS + ${2:-15}))
    while ((SECONDS < deadline)); do
        L --dump | grep -qE -- "$1" && return 0
        sleep 0.2
    done
    return 1
}
query() { L --view "$1" --query "$2"; sleep 0.15; }
# Content results arrive from a worker thread: poll for them.
expect_soon() {
    if wait_for "$2" "${3:-3}"; then ok "$1"; else ko "$1 (no /$2/)" "$(L --dump)"; fi
}

# ------------------------------------------------------------------- start
L --daemon &
DAEMON=$!
for _ in $(seq 50); do L --dump >/dev/null 2>&1 && break; sleep 0.1; done
echo "lumen e2e: $BIN (pid $DAEMON), fixture $T"

echo "indexes"
L --view files
if wait_for 'Type to search [0-9]+ files' 20; then ok "file index ready"; else ko "file index ready" "$(L --dump)"; fi
L --view contents
if wait_for 'Search inside [0-9]+ files' 20; then ok "content index ready"; else ko "content index ready" "$(L --dump)"; fi

echo "root"
query root "fire"
expect "app found by name" '> Firefox E2E \| Web Browser \| Application'
query root "internet"
expect "app found by keyword" 'Firefox E2E'
query root "2+3*4"
expect "calculator" '# Calculator'
expect "calculator answer" 'primary: Copy Answer'
query root "10 km to mi"
expect "unit conversion" '10 km to mi \| km \| mi'
query root "hello e2e"
expect "script command listed" 'Say Hello E2E \| Fixture \| Script'
query root "left half"
expect "window command listed" '> Left Half'
query root "zebrafish"
expect "files section in root" '# Files'
expect "file in root results" 'zebrafish.md'
query root "zzqxjvw"
expect "no results" 'No Results'

echo "keyboard"
query root "e2e"
selected() { L --dump | sed -n 's/^  > \([^|]*\) |.*/\1/p'; }
first=$(selected)
L --key down
second=$(selected)
if [[ -n "$second" && "$second" != "$first" ]]; then ok "down moves the selection ($first -> $second)"; else ko "down moves the selection" "$(L --dump)"; fi
L --key up; L --key up
if [[ "$(selected)" == "$first" ]]; then ok "up stops at the first row"; else ko "up stops at the first row" "$(L --dump)"; fi
L --key ctrl+k
expect "action panel opens" '^panel:'
expect "action panel lists app actions" 'Open Application \[↵\]'
L --key escape
expect_not "escape closes the panel" '^panel:'
L --key escape
expect "escape clears the query" '^query: $'
query root "search files"
L --key enter
expect "enter on a view command opens it" '^view: files'
L --key backspace
expect "backspace on empty query goes back" '^view: root'

echo "files"
query files "main"
expect "file by name" '> main.zig \| ~/Projects/demo/src'
expect "zig logo" 'main.zig .*logo:zig'
expect "detail kind" 'Kind = ZIG file'
expect "detail where" 'Where = ~/Projects/demo/src'
query files "handler go"
expect "multi-word query" 'handler.go .*logo:go'
L --key ctrl+k
expect "file actions" 'Show in Folder'
L --key escape
printf 'brand new\n' >"$H/notes/fresh-capybara.txt"
L --view files --query "capybara"
if wait_for 'fresh-capybara.txt' 10; then ok "new file appears (inotify)"; else ko "new file appears (inotify)" "$(L --dump)"; fi
rm "$H/notes/fresh-capybara.txt"
L --view files --query "capybara"
sleep 0.5
L --view files --query "capybar"
L --view files --query "capybara"
if wait_for 'No Results' 10; then ok "deleted file disappears"; else ko "deleted file disappears" "$(L --dump)"; fi

echo "contents"
query contents "zebrafish"
expect_soon "word inside a file" '> zebrafish.md \|  \| line 3'
expect_soon "match count in detail" 'Matches = line 3'
query contents "fn main"
expect_soon "phrase in code" 'main.zig|lib.rs'
query contents "ze"
expect "needs 3 characters" 'Type at least 3 characters'
query contents "axolotl zebrafish"
expect_soon "all words must be present" 'zebrafish.md'
query contents "zebrafish unicorn"
expect_soon "missing word excludes the file" 'No Results'
query contents "rust main"
wait_for 'lib.rs' 3
L --key ctrl+k
expect "content hit actions" 'Open at Line \[↵\]'
L --key escape

echo "edge cases"
query files "bad name"
expect "invalid UTF-8 name shown with U+FFFD" 'bad-\xEF\xBF\xBD\xEF\xBF\xBD-name.txt|bad-��-name.txt'
query files "line2"
expect "newline in a name shown on one line" 'line1 line2.txt'
query contents "gnuword"
expect_soon "file with a newline in its name is content-searchable" 'line1 line2.txt'
query contents "invalid utf8 name marker"
expect_soon "file with an invalid UTF-8 name is content-searchable" 'bad-'
rm "$H/notes/victim.txt"; mkfifo "$H/notes/victim.txt"
query contents "fifoword"
if timeout 5 bash -c "$(declare -f L); H='$H' T='$T' BIN='$BIN'; L --dump >/dev/null"; then ok "a file turned into a FIFO does not freeze search"; else ko "a file turned into a FIFO does not freeze search"; fi
query files "victim"
if timeout 5 bash -c "$(declare -f L); H='$H' T='$T' BIN='$BIN'; L --dump >/dev/null"; then ok "nor its preview"; else ko "nor its preview"; fi
query contents "accion"
expect_soon "accent-insensitive content search" 'español.txt'
query contents "ÑANDÚ"
expect_soon "case folds beyond ASCII" 'español.txt'
query files "espanol"
expect "accent-insensitive file names" 'español.txt'

echo "clipboard"
printf 'e2e clipboard entry 42' | env CLIPBOARD_STATE=data XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$H/.config" HOME="$H" "$BIN" --clip-store
printf 'e2e second entry' | env CLIPBOARD_STATE=data XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$H/.config" HOME="$H" "$BIN" --clip-store
printf 'secret' | env CLIPBOARD_STATE=sensitive XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$H/.config" HOME="$H" "$BIN" --clip-store
L --view clipboard; sleep 0.2
expect "clipboard lists entries, newest first" '> e2e second entry'
expect "older entry listed" 'e2e clipboard entry 42'
expect_not "password-manager copies are skipped" 'secret'
query clipboard "42"
expect "clipboard filter" '> e2e clipboard entry 42'
expect "clipboard detail" 'Characters = 22'

echo "windows"
L --view windows; sleep 0.2
expect "windows view opens without Hyprland" '^view: windows'

echo "frecency"
query root "kitty e2e"
L --key enter
sleep 0.3
L --show; sleep 0.2
expect "used app shows up in suggestions" '# Suggestions'
L --hide

echo "settings"
C="$H/.config/lumen/settings.conf"
opened() { grep -c "$1" "$T/opened" 2>/dev/null || echo 0; }
L --view settings; sleep 0.2
expect "settings list with current values" 'Theme \|  \| Lumen Dark'
expect "settings grouped in sections" '# Clipboard'
expect "first row selected" '> Theme'
query settings "files in main"
L --key enter; sleep 0.2
expect "a toggle switches in place" '> Show Files in Main Search \|  \| Off'
grep -q '^files_in_root = false' "$C" && ok "the change is saved to settings.conf" || ko "the change is saved to settings.conf" "$(cat "$C" 2>&1)"
[[ $(stat -c %a "$C") == 600 ]] && ok "settings.conf is owner-only" || ko "settings.conf is owner-only"
query root "zebrafish"
expect_not "files hidden from the main search when off" '# Files'
query settings "files in main"
L --key enter; sleep 0.2
query root "zebrafish"
expect "and back when on" '# Files'

query settings "text size"
L --key enter; sleep 0.2
expect "a choice opens its values" '^view: choose'
expect "the current value is marked and selected" '> Default \|  \| ✓'
L --key down; L --key enter; sleep 0.2
expect "picking returns to settings, on the same row" '> Text Size \|  \| Large'
grep -q '^text_size = large' "$C" && ok "choice saved" || ko "choice saved" "$(cat "$C")"
L --key escape; sleep 0.1
expect "escape from settings goes back to the main view" '^view: root'

query themes "nord"
expect "themes have previews" 'Nord \|  \|  \| swatch:nord'
L --key enter; sleep 0.2
grep -q '^theme = nord' "$C" && ok "theme chosen" || ko "theme chosen" "$(cat "$C")"
L --view settings; sleep 0.2
expect "settings show the theme" 'Theme \|  \| Nord'
L --view themes; sleep 0.2
expect "change theme starts on the current theme" '> Nord \|  \| ✓'
L --key down; sleep 0.1
L --key escape; sleep 0.1
grep -q '^theme = nord' "$C" && ok "a previewed theme is not saved" || ko "a previewed theme is not saved"

sed -i 's/^theme = .*/theme = dracula/' "$C"
L --hide; L --view settings; sleep 0.2
expect "hand edits are read when the window opens" 'Theme \|  \| Dracula'
printf 'garbage line\n\x00\xff\ntext_size = enormous\ntheme = no-such-theme\n[open-with]\npdf = ;rm -rf /\n' >"$C"
L --hide; L --view settings; sleep 0.2
expect "a broken file falls back to defaults" 'Text Size \|  \| Default'
expect "an unknown theme falls back to the default" 'Theme \|  \| no-such-theme|Theme \|  \| Lumen Dark'

query default_apps "pdf"
expect "default apps list file kinds" 'PDF Documents'
L --key enter; sleep 0.2
expect "apps declaring the type come first" '# Recommended'
expect "the system default is offered" 'System Default'
query choose "pdf viewer"
L --key enter; sleep 0.2
grep -q '^pdf = pdf-viewer-e2e.desktop' "$C" && ok "default app saved" || ko "default app saved" "$(cat "$C")"
L --view default_apps; sleep 0.2
expect "default apps show the choice" 'PDF Documents \|  \| PDF Viewer E2E'
query files "quarterly report"
L --key enter
for _ in $(seq 30); do [[ $(opened quarterly-report.pdf) -gt 0 ]] && break; sleep 0.1; done
grep -q 'pdf-viewer-e2e .*quarterly-report.pdf' "$T/opened" 2>/dev/null && ok "files open with the chosen app" || ko "files open with the chosen app" "$(cat "$T/opened" 2>&1)"

query files "zebrafish.md"
L --key ctrl+o; sleep 0.2
expect "open with lists apps for one file" 'title: Open zebrafish.md With'
query choose "text opener"
L --key enter
for _ in $(seq 30); do [[ $(opened zebrafish.md) -gt 0 ]] && break; sleep 0.1; done
grep -q 'text-opener-e2e .*zebrafish.md' "$T/opened" 2>/dev/null && ok "open with opens the file once" || ko "open with opens the file once" "$(cat "$T/opened" 2>&1)"
grep -q '^markdown' "$C" && ko "open once does not change the default" || ok "open once does not change the default"
query files "zebrafish.md"
L --key ctrl+o; sleep 0.2
query choose "text opener"
L --key ctrl+enter; sleep 0.3
grep -q '^markdown = text-opener-e2e.desktop' "$C" && ok "open and always use remembers the kind" || ko "open and always use remembers the kind" "$(cat "$C")"

query settings "clipboard history"
L --key enter; sleep 0.2
expect "clipboard history off" 'Clipboard History \|  \| Off'
printf 'copied while history is off' | env CLIPBOARD_STATE=data XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$H/.config" HOME="$H" "$BIN" --clip-store
L --view clipboard; sleep 0.2
expect_not "nothing is recorded while off" 'copied while history is off'
query settings "clipboard history"
L --key enter; sleep 0.2

query settings "reset all"
L --key enter; sleep 0.1
expect "reset asks for a second enter" 'primary: Press ↵ again'
L --key enter; sleep 0.2
grep -q '^theme = lumen-dark' "$C" && ! grep -q '^pdf' "$C" && ok "reset restores the defaults" || ko "reset restores the defaults" "$(cat "$C")"
L --key escape; L --key backspace; sleep 0.1
expect "backspace leaves settings" '^view: root'

echo "extensions (Lua)"
query root "fixture fruits"
expect "extension command in root" '> Fixture Fruits \| Fixture \| Command \| emoji:🧪'
query root "failed to load"
expect "broken extension reported" 'Extension "broken" failed to load .*give it items, search or run'
L --command fixture.fruits; sleep 0.4
expect "command lists its items" '^title: Fixture Fruits'
expect "item with subtitle" '> Mango \| sweet'
expect "items without icon wear the command's" 'Kiwi .*emoji:🧪'
expect "detail pane shows the item's detail" 'text = a mango detail'
L --command fixture.fruits --query kiw; sleep 0.3
expect "list commands filter as you type" '> Kiwi'
expect_not "filtered out" 'Mango'
L --command fixture.fruits; sleep 0.3
L --key ctrl+k
expect "action panel lists the item's actions" 'Record Mango \[Ctrl ↵\]'
L --key escape
L --key ctrl+enter
if wait_for '^visible: false' 3 && [[ "$(cat "$T/ext-ran" 2>/dev/null)" == Mango ]]; then ok "Lua action ran and closed the window"; else ko "Lua action ran and closed the window" "$(L --dump; cat "$T/ext-ran" 2>&1)"; fi
L --command fixture.echo --query "hi there"
expect_soon "search commands get the query" '> echo: hi there'
query root ""
L --key ctrl+g; sleep 0.3
expect "keymap from init.lua opens a command" '^title: Fixture Fruits'
query themes "e2e night"
expect "theme from init.lua in Change Theme" 'E2E Night .*swatch:e2e-night'
sed -i 's/Fixture Fruits/Fixture Fruit Bowl/' "$H/.config/lumen/extensions/fixture/init.lua"
L --hide; L --query "fruit bowl"
expect_soon "edited extensions reload when the window opens" '> Fixture Fruit Bowl'
L --hide

echo "latency (lumen --stats)"
stats=$(L --stats)
# p95 includes the cold instance's first frame (GL context, icon theme);
# p50 is what typing feels like.
check() {
    local view=$1 col=$2 label=$3 limit=$4 v
    v=$(awk -v v="$view" -v c="$col" '$1 == v { print $c }' <<<"$stats")
    if [[ -z "$v" ]]; then ko "$view: no samples"; return; fi
    if awk -v p="$v" -v l="$limit" 'BEGIN { exit !(p < l) }'; then ok "$view $label ${v} ms < $limit ms"; else ko "$view $label ${v} ms >= $limit ms" "$stats"; fi
}
check root 3 p50 20; check root 4 p95 150
check files 3 p50 30; check files 4 p95 150
check contents 3 p50 40; check contents 4 p95 200

echo "quit"
L --quit
for _ in $(seq 50); do kill -0 "$DAEMON" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$DAEMON" 2>/dev/null; then ko "daemon exits on --quit"; else ok "daemon exits on --quit"; DAEMON=; fi
[[ -f "$T/cache/lumen/files.idx" ]] && ok "file index saved" || ko "file index saved"
[[ -f "$T/cache/lumen/content.idx" ]] && ok "content index saved" || ko "content index saved"
[[ $(stat -c %a "$T/cache/lumen") == 700 ]] && ok "cache dir is owner-only" || ko "cache dir is owner-only ($(stat -c %a "$T/cache/lumen"))"
[[ $(stat -c %a "$T/cache/lumen/content.idx") == 600 ]] && ok "index files are owner-only" || ko "index files are owner-only ($(stat -c %a "$T/cache/lumen/content.idx"))"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
