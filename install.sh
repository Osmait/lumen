#!/bin/sh
# Installs Lumen's latest release, or updates it:
#
#   curl -fsSL https://raw.githubusercontent.com/Osmait/lumen/main/install.sh | sh
#
# Options, as environment variables:
#   LUMEN_VERSION=0.1.0       a given release instead of the latest
#   LUMEN_INSTALL_DIR=DIR     where the two programs go (~/.local/bin)
# and as arguments (curl ... | sh -s -- --uninstall):
#   --uninstall               remove them (settings and data are kept)
#
# It installs into your home folder and never uses sudo. The system packages
# Lumen needs (GTK 4, gtk4-layer-shell) it checks for and names, for you to
# install.

set -eu

repo_url=${LUMEN_RELEASES_URL:-https://github.com/Osmait/lumen/releases}
dir=${LUMEN_INSTALL_DIR:-$HOME/.local/bin}

say() { printf '%s\n' "$*"; }
die() {
    printf 'lumen install: %s\n' "$*" >&2
    exit 1
}
has() { command -v "$1" >/dev/null 2>&1; }

# The daemon running from `dir`, if any: another installation's is left alone.
# One whose file was replaced since it started reads "... (deleted)".
our_daemon() {
    for pid in $(pgrep -x lumen-gtk 2>/dev/null || true); do
        case $(readlink "/proc/$pid/exe" 2>/dev/null) in
            "$dir/lumen-gtk" | "$dir/lumen-gtk (deleted)")
                say "$pid"
                return
                ;;
        esac
    done
}

stop_daemon() {
    pid=$(our_daemon)
    [ -n "$pid" ] || return 1
    "$dir/lumen" --quit >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    return 0
}

if [ "${1:-}" = "--uninstall" ]; then
    stop_daemon || true
    rm -f "$dir/lumen" "$dir/lumen-gtk"
    say "Removed lumen and lumen-gtk from $dir."
    say "Your settings (~/.config/lumen) and data (~/.local/share/lumen, ~/.cache/lumen) are kept."
    exit 0
fi
[ $# -eq 0 ] || die "unknown option $1 (the only one is --uninstall)"

[ "$(uname -s)" = Linux ] || die "Lumen runs on Linux (Wayland) only"
case $(uname -m) in
    x86_64) arch=x86_64 ;;
    *) die "no release for $(uname -m) yet: build it from source (see the README)" ;;
esac
has curl || die "curl is needed"
has tar || die "tar is needed"
if has sha256sum; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif has shasum; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    die "sha256sum is needed to check the download"
fi

if [ -n "${LUMEN_VERSION:-}" ]; then
    version=${LUMEN_VERSION#v}
else
    # The latest release's page is a redirect to its tag.
    latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$repo_url/latest") ||
        die "cannot reach $repo_url"
    version=${latest##*/v}
    case $version in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) die "cannot tell the latest version from $latest" ;;
    esac
fi

name=lumen-$version-$arch-linux
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading Lumen $version..."
curl -fsSL -o "$tmp/$name.tar.gz" "$repo_url/download/v$version/$name.tar.gz" ||
    die "no release $version for $arch"
curl -fsSL -o "$tmp/SHA256SUMS" "$repo_url/download/v$version/SHA256SUMS" ||
    die "release $version has no SHA256SUMS"
want=$(grep " $name.tar.gz\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
[ -n "$want" ] || die "SHA256SUMS does not list $name.tar.gz"
[ "$(sha256 "$tmp/$name.tar.gz")" = "$want" ] || die "the download is damaged (checksum mismatch)"
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"

restart=no
if stop_daemon; then restart=yes; fi
mkdir -p "$dir"
# Replaced, not written over: a running program keeps its old file.
for prog in lumen lumen-gtk; do
    cp "$tmp/$name/$prog" "$dir/.$prog.new"
    chmod 755 "$dir/.$prog.new"
    mv -f "$dir/.$prog.new" "$dir/$prog"
done
say "Installed Lumen $version in $dir."

# lumen-gtk does not start when a library it links is missing.
if ! "$dir/lumen-gtk" --version >/dev/null 2>&1; then
    say ""
    say "Lumen needs GTK 4 (4.12 or newer) and gtk4-layer-shell, which are not installed:"
    id=$( (. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-}" "${ID_LIKE:-}") || true)
    case " $id " in
        *" arch "*) say "  sudo pacman -S gtk4 gtk4-layer-shell" ;;
        *" fedora "*) say "  sudo dnf install gtk4 gtk4-layer-shell" ;;
        *" debian "* | *" ubuntu "*) say "  sudo apt install libgtk-4-1 libgtk4-layer-shell0" ;;
        *) say "  install your distribution's gtk4 and gtk4-layer-shell packages" ;;
    esac
    restart=no
fi

missing=""
for tool in wl-copy wl-paste wtype rg pdftotext unzip; do
    has "$tool" || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    say ""
    say "Optional tools not found:$missing"
    say "(clipboard history and paste: wl-clipboard, wtype; file contents: ripgrep,"
    say " poppler, unzip). See https://github.com/Osmait/lumen#requirements"
fi

case ":$PATH:" in
    *":$dir:"*) ;;
    *)
        say ""
        say "$dir is not on your PATH: add it, or call $dir/lumen."
        ;;
esac

if [ "$restart" = yes ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    setsid -f "$dir/lumen" --daemon >/dev/null 2>&1 </dev/null || true
    say ""
    say "Restarted the Lumen daemon."
elif [ "$restart" = yes ]; then
    say ""
    say "The daemon was stopped: start it again from your session (lumen --daemon)."
else
    say ""
    say "Start it with your session and bind a key to it, as the README shows:"
    say "  https://github.com/Osmait/lumen#set-up"
fi
