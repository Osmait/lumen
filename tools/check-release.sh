#!/usr/bin/env bash
# Checks that release binaries run on other distributions than the one that
# built them:
#
#   tools/check-release.sh BIN_DIR [VERSION]
#
# - lumen is static: no interpreter, no shared library.
# - lumen-gtk asks the system only for GTK 4, gtk4-layer-shell, GLib and
#   libc (SQLite and Lua are built in), and for no glibc newer than 2.36.
# - both report VERSION, when given.

set -euo pipefail

dir=${1:?usage: tools/check-release.sh BIN_DIR [VERSION]}
want=${2:-}
max_glibc=2.36
allowed=(libgtk-4.so.1 libgdk_pixbuf-2.0.so.0 libgio-2.0.so.0 libgobject-2.0.so.0
    libglib-2.0.so.0 libgtk4-layer-shell.so.0 libm.so.6 libc.so.6 ld-linux-x86-64.so.2)
fail=0

bad() {
    echo "check-release: $*" >&2
    fail=1
}

if readelf -l "$dir/lumen" | grep -q INTERP || readelf -d "$dir/lumen" | grep -q NEEDED; then
    bad "lumen is not static"
fi

while read -r lib; do
    found=0
    for ok in "${allowed[@]}"; do [[ $lib == "$ok" ]] && found=1; done
    [[ $found == 1 ]] || bad "lumen-gtk needs $lib, which is not on the list"
done < <(readelf -d "$dir/lumen-gtk" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')

newest=$(objdump -T "$dir/lumen-gtk" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' |
    sort -t. -k1,1n -k2,2n -u | tail -1)
if [[ $(printf '%s\n%s\n' "$newest" "$max_glibc" | sort -t. -k1,1n -k2,2n | tail -1) != "$max_glibc" ]]; then
    bad "lumen-gtk needs glibc $newest, more than $max_glibc"
fi

if [[ -n $want ]]; then
    # An empty runtime dir: the client must not ask a daemon that is running.
    rt=$(mktemp -d)
    trap 'rm -rf "$rt"' EXIT
    got=$(XDG_RUNTIME_DIR=$rt "$dir/lumen" --version | head -1)
    [[ $got == "lumen $want" ]] || bad "lumen --version says '$got', not 'lumen $want'"
    got=$("$dir/lumen-gtk" --version)
    [[ $got == "$want" ]] || bad "lumen-gtk --version says '$got', not '$want'"
fi

if [[ $fail == 0 ]]; then
    echo "check-release: ok (glibc $newest, $(readelf -d "$dir/lumen-gtk" | grep -c NEEDED) libraries)"
fi
exit "$fail"
