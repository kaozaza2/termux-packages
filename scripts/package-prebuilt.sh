#!/usr/bin/env bash
# Wrap an already-built Android/arm64 binary into a Termux-installable .deb.
#
# Why not just run the build system: packages/opencode/build.sh cross-compiles
# with termux's own toolchain, which needs an x64 Linux host and tens of GB of
# disk. The binary is already built and released by kaozaza2/opencode-termux,
# so the only thing missing is the .deb wrapper. This produces that, and
# termux-apt-repo turns a directory of them into an APT repository.
#
# Usage:
#   scripts/package-prebuilt.sh <binary> <version> <outdir> [pkgname]
#
# The .deb installs to $PREFIX/bin, because Termux debs carry $PREFIX-relative
# paths in data.tar (./bin/<name>), not the Debian /usr layout.
#
# Written with ar+tar rather than dpkg-deb so it runs anywhere, and so the same
# code path is testable off-CI. A .deb is just an ar archive:
#   debian-binary   the string "2.0"
#   control.tar.gz  ./control
#   data.tar.gz     ./bin/<name>
set -euo pipefail

BINARY="${1:?usage: package-prebuilt.sh <binary> <version> <outdir> [pkgname]}"
VERSION="${2:?missing version}"
OUTDIR="${3:?missing outdir}"
PKGNAME="${4:-$(basename "$BINARY")}"

[[ -f "$BINARY" ]] || { echo "error: no such file: $BINARY" >&2; exit 1; }
for tool in ar tar gzip sha256sum; do
	command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# The install path is absolute, not $PREFIX-relative. Termux ships a stock dpkg
# with root "/", so data.tar carries the full path: the real Termux deb
# sl_5.05-1_aarch64.deb contains ./data/data/com.termux/files/usr/bin/sl.
# A ./bin/<name> entry would install into /bin, which is not writable and not
# on the user's PATH.
TERMUX_PREFIX="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}"
BINDIR="root${TERMUX_PREFIX}/bin"
mkdir -p "$STAGE/$BINDIR" "$STAGE/control"

install -m 755 "$BINARY" "$STAGE/$BINDIR/$PKGNAME"
SIZE_KB=$(( $(wc -c < "$STAGE/$BINDIR/$PKGNAME") / 1024 ))

cat > "$STAGE/control/control" <<EOF
Package: $PKGNAME
Version: $VERSION
Architecture: aarch64
Section: utils
Priority: optional
Maintainer: kaozaza2 <kaozaza2@users.noreply.github.com>
Installed-Size: $SIZE_KB
Homepage: https://opencode.ai
Depends: ca-certificates, git
Description: AI coding agent for the terminal
 Prebuilt bionic/arm64 build of opencode, cross-compiled from upstream with
 kaozaza2/opencode-termux and wrapped as a Termux package. The binary is
 standalone: the Bun runtime is embedded, so there is no runtime dependency on
 bun itself.
EOF

mkdir -p "$OUTDIR"
DEB="$OUTDIR/${PKGNAME}_${VERSION}_aarch64.deb"
# Must not exist beforehand: `ar r` treats an existing non-archive file as a
# corrupt archive and refuses to write it, rather than creating it.
TMPDEB="$STAGE/build.deb"

# Member order matters: debian-binary must come first. Compression is xz
# because that is what dpkg-deb produces and what termux-apt-repo assumes when
# it lists a deb's contents.
printf '2.0\n' > "$STAGE/debian-binary"
tar -C "$STAGE/control" -cJf "$STAGE/control.tar.xz" ./control
# Archive the whole absolute path from /, so entries read ./data/data/.../bin/.
tar -C "$STAGE/root" -cJf "$STAGE/data.tar.xz" "./${TERMUX_PREFIX#/}/bin"

rm -f "$DEB"
( cd "$STAGE" && ar rc "$TMPDEB" debian-binary control.tar.xz data.tar.xz )
mv -f "$TMPDEB" "$DEB"

echo "built $DEB"
echo "  package:  $PKGNAME $VERSION (aarch64)"
echo "  size:     $SIZE_KB KiB installed"
echo "  sha256:   $(sha256sum "$DEB" | cut -d' ' -f1)"
