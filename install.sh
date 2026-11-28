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

# Makes `dir` absolute. The name stays the user's (`pwd`, not `pwd -P`): with
# /home a symlink (Fedora Silverblue's /var/home) the messages and the PATH
# check would otherwise use a path the user does not know (MYP-580);
# `our_daemon` resolves symlinks itself. CDPATH unset: with it, cd prints the
# folder and `dir` would get it twice (MYP-461).
canonical_dir() {
    if [ -d "$dir" ]; then
        dir=$(CDPATH='' cd -- "$dir" && pwd)
    fi
}

# Whether `dir` is on PATH, under its own name or one that resolves to the
# same folder.
dir_on_path() {
    case ":$PATH:" in
        *":$dir:"*) return 0 ;;
    esac
    dir_real=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        entry_real=$(CDPATH='' cd -- "$entry" 2>/dev/null && pwd -P) || continue
        [ "$entry_real" != "$dir_real" ] || return 0
    done <<EOF
$(printf '%s\n' "$PATH" | tr ':' '\n')
EOF
    return 1
}

# The daemons running from `dir`, one pid a line: another installation's are
# left alone. One whose file was replaced since it started reads
# "... (deleted)".
our_daemon() {
    target="$dir/lumen-gtk"
    target_f=$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")
    for pid in $(pgrep -x lumen-gtk 2>/dev/null || true); do
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        case "$exe" in
            "$target" | "$target (deleted)" | "$target_f" | "$target_f (deleted)")
                say "$pid"
                ;;
        esac
    done
}

# Stops the daemons `our_daemon` finds: 0 once they are gone, 1 when there
# were none, 2 when one still runs after 5 s (its pids in $stuck). SIGTERM
# goes to the pid itself and quits it as `lumen --quit` does; --quit would
# reach whichever instance answers this shell's LUMEN_APP_ID, maybe another
# installation's.
stop_daemon() {
    pids=$(our_daemon)
    [ -n "$pids" ] || return 1
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    i=0
    while [ "$i" -lt 50 ]; do
        stuck=""
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then stuck="$stuck $pid"; fi
        done
        [ -n "$stuck" ] || return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 2
}

# stop_daemon, or the reason it did not stop, and out.
stop_daemon_or_die() {
    status=0
    stop_daemon || status=$?
    [ "$status" -ne 2 ] || die "the Lumen daemon (pid$stuck) did not stop in 5 s: quit it (kill$stuck), then run this again"
    return "$status"
}

if [ "${1:-}" = "--uninstall" ]; then
    canonical_dir
    stop_daemon_or_die || true
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
cleanup() {
    rm -rf "$tmp"
    rm -f \
        "$dir/.lumen.new.$$" \
        "$dir/.lumen-gtk.new.$$" \
        "$dir/.lumen.bak.$$" \
        "$dir/.lumen-gtk.bak.$$"
}
trap cleanup EXIT

say "Downloading Lumen $version..."
curl -fsSL -o "$tmp/$name.tar.gz" "$repo_url/download/v$version/$name.tar.gz" ||
    die "no release $version for $arch"
curl -fsSL -o "$tmp/SHA256SUMS" "$repo_url/download/v$version/SHA256SUMS" ||
    die "release $version has no SHA256SUMS"
want=$(grep " $name.tar.gz\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
[ -n "$want" ] || die "SHA256SUMS does not list $name.tar.gz"
[ "$(sha256 "$tmp/$name.tar.gz")" = "$want" ] || die "the download is damaged (checksum mismatch)"
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"

for prog in lumen lumen-gtk; do
    [ -f "$tmp/$name/$prog" ] && [ -s "$tmp/$name/$prog" ] ||
        die "incomplete release archive: missing $prog"
done

mkdir -p "$dir"
canonical_dir
# Stage both binaries inside $dir before touching the running installation.
for prog in lumen lumen-gtk; do
    cp "$tmp/$name/$prog" "$dir/.$prog.new.$$"
    chmod 755 "$dir/.$prog.new.$$"
done

restart=no
if stop_daemon_or_die; then restart=yes; fi

had_lumen=no
had_gtk=no
if [ -e "$dir/lumen" ]; then
    had_lumen=yes
    ln "$dir/lumen" "$dir/.lumen.bak.$$" 2>/dev/null || cp -p "$dir/lumen" "$dir/.lumen.bak.$$"
fi
if [ -e "$dir/lumen-gtk" ]; then
    had_gtk=yes
    ln "$dir/lumen-gtk" "$dir/.lumen-gtk.bak.$$" 2>/dev/null || cp -p "$dir/lumen-gtk" "$dir/.lumen-gtk.bak.$$"
fi

if ! mv -f "$dir/.lumen.new.$$" "$dir/lumen" || ! mv -f "$dir/.lumen-gtk.new.$$" "$dir/lumen-gtk"; then
    if [ "$had_lumen" = yes ] && [ -e "$dir/.lumen.bak.$$" ]; then
        mv -f "$dir/.lumen.bak.$$" "$dir/lumen" 2>/dev/null || true
    elif [ "$had_lumen" = no ]; then
        rm -f "$dir/lumen"
    fi
    if [ "$had_gtk" = yes ] && [ -e "$dir/.lumen-gtk.bak.$$" ]; then
        mv -f "$dir/.lumen-gtk.bak.$$" "$dir/lumen-gtk" 2>/dev/null || true
    elif [ "$had_gtk" = no ]; then
        rm -f "$dir/lumen-gtk"
    fi
    die "failed to replace lumen and lumen-gtk; restored previous installation"
fi
rm -f "$dir/.lumen.bak.$$" "$dir/.lumen-gtk.bak.$$"
say "Installed Lumen $version in $dir."

# Whether version $1 ("24.04", "12") is older than $2.$3; false when it is
# not a number.
version_before() {
    major=${1%%.*}
    minor=0
    case "$1" in
        *.*)
            rest=${1#*.}
            minor=${rest%%.*}
            ;;
    esac
    minor=${minor:-0}
    case "$major$minor" in
        *[!0-9]*) return 1 ;;
    esac
    [ -n "$major" ] || return 1
    [ "$major" -lt "$2" ] || { [ "$major" -eq "$2" ] && [ "$minor" -lt "$3" ]; }
}

# Returns 0 on the releases without libgtk4-layer-shell0: Ubuntu before 24.10
# and Debian before 13, and the distributions built on them (Mint, Pop!_OS,
# Zorin, elementary, LMDE), which name their base in os-release (MYP-581).
# $1 ID, $2 VERSION_ID, $3 UBUNTU_CODENAME, $4 DEBIAN_CODENAME or
# VERSION_CODENAME.
apt_lacks_layer_shell() {
    case "$3" in
        trusty | xenial | bionic | cosmic | disco | eoan | focal | groovy | hirsute | \
            impish | jammy | kinetic | lunar | mantic | noble) return 0 ;;
        ?*) return 1 ;;
    esac
    case "$4" in
        stretch | buster | bullseye | bookworm) return 0 ;;
    esac
    case "$1" in
        ubuntu) version_before "$2" 24 10 ;;
        debian | raspbian) version_before "$2" 13 0 ;;
        *) return 1 ;;
    esac
}

# lumen-gtk does not start when a library it links is missing.
if ! "$dir/lumen-gtk" --version >/dev/null 2>&1; then
    say ""
    say "Lumen needs GTK 4 (4.12 or newer) and gtk4-layer-shell, which are not installed:"
    os_id=$( (. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}") || true)
    os_like=$( (. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}") || true)
    os_version_id=$( (. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}") || true)
    os_ubuntu_codename=$( (. /etc/os-release 2>/dev/null && printf '%s' "${UBUNTU_CODENAME:-}") || true)
    os_debian_codename=$( (. /etc/os-release 2>/dev/null &&
        printf '%s' "${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}") || true)
    case " $os_id $os_like " in
        *" arch "*) say "  sudo pacman -S gtk4 gtk4-layer-shell" ;;
        *" fedora "*) say "  sudo dnf install gtk4 gtk4-layer-shell" ;;
        *" debian "* | *" ubuntu "*)
            if apt_lacks_layer_shell "$os_id" "$os_version_id" "$os_ubuntu_codename" "$os_debian_codename"; then
                say "  sudo apt install libgtk-4-1"
                say "  gtk4-layer-shell is not packaged before Ubuntu 24.10 and Debian 13, nor in the releases built on them;"
                say "  build it from source: https://github.com/wmww/gtk4-layer-shell"
            else
                say "  sudo apt install libgtk-4-1 libgtk4-layer-shell0"
            fi
            ;;
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

if ! dir_on_path; then
    say ""
    say "$dir is not on your PATH: add it, or call $dir/lumen."
fi

# daemon_started: true once a daemon of `dir` runs, waiting up to 5 s.
daemon_started() {
    i=0
    while [ "$i" -lt 50 ]; do
        [ -z "$(our_daemon)" ] || return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

if [ "$restart" = yes ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    # Not from this shell's folder (a USB stick it would keep busy, where
    # terminals it opens would start), nor with the terminal multiplexer's
    # variables, which every app it launches would inherit (MYP-564).
    (cd "${HOME:-/}" 2>/dev/null || cd /
        env -u TMUX -u TMUX_PANE -u STY setsid -f "$dir/lumen" --daemon >/dev/null 2>&1 </dev/null) || true
    say ""
    if daemon_started; then
        say "Restarted the Lumen daemon."
    else
        say "The daemon was stopped and did not start again: start it from your session (lumen --daemon)."
    fi
elif [ "$restart" = yes ]; then
    say ""
    say "The daemon was stopped: start it again from your session (lumen --daemon)."
else
    say ""
    say "Start it with your session and bind a key to it, as the README shows:"
    say "  https://github.com/Osmait/lumen#set-up"
fi
