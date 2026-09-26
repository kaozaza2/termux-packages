#!/usr/bin/env bash
# Fetch the upstream termux/termux-packages package definitions and expose them
# where the build system expects to find them.
#
# Why this exists: this repository carries only the packages that upstream does
# not ship. The build system still needs upstream's definitions, because
# scripts/buildorder.py resolves every TERMUX_PKG_DEPENDS against the package
# directories on disk and hard-fails on anything it cannot find. So the
# definitions are fetched at build time rather than committed.
#
# Run this once after cloning, and again whenever you want to pick up upstream
# changes:
#
#     ./scripts/setup-upstream.sh
#
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/termux/termux-packages.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The clone lives one level below the tracked placeholder: git refuses to add
# files inside a directory that contains a .git, so a .gitkeep cannot sit in
# $UPSTREAM_DIR itself.
UPSTREAM_ROOT="$REPO_ROOT/.upstream-packages"
UPSTREAM_DIR="$UPSTREAM_ROOT/termux-packages"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

mkdir -p "$UPSTREAM_DIR"

# Not `git clone`: $UPSTREAM_DIR holds a tracked .gitkeep, and clone refuses a
# non-empty destination. init + fetch handles a fresh dir and an existing one.
if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
	git init -q "$UPSTREAM_DIR"
fi
if ! git -C "$UPSTREAM_DIR" remote get-url origin >/dev/null 2>&1; then
	git -C "$UPSTREAM_DIR" remote add origin "$UPSTREAM_URL"
fi

log "Fetching upstream termux-packages (${UPSTREAM_BRANCH})..."
git -C "$UPSTREAM_DIR" fetch -q --depth 1 origin "$UPSTREAM_BRANCH"
git -C "$UPSTREAM_DIR" checkout -q -B "$UPSTREAM_BRANCH" FETCH_HEAD

[[ -f "$UPSTREAM_DIR/build-package.sh" ]] || {
	echo "error: $UPSTREAM_DIR does not look like a termux-packages checkout" >&2
	exit 1
}

# Link the upstream package directories into place. packages/ is deliberately
# absent: that directory belongs to this repository and holds only the packages
# added here, so it is reachable as "packages" in repo.json while upstream's
# copy is reachable as "upstream-packages".
link_dir() {
	local name="$1"
	local upstream_name="${2:-$1}"
	local target=".upstream-packages/termux-packages/$upstream_name"
	if [[ -L "$REPO_ROOT/$name" ]]; then
		ln -sfn "$target" "$REPO_ROOT/$name"
	elif [[ -e "$REPO_ROOT/$name" ]]; then
		echo "error: $REPO_ROOT/$name exists and is not a symlink" >&2
		exit 1
	else
		ln -s "$target" "$REPO_ROOT/$name"
	fi
}

# packages/ belongs to this repository, so upstream's copy is linked under a
# different name, which is the extra repo.json key.
link_dir upstream-packages packages
link_dir x11-packages
link_dir root-packages
# disabled-packages is not a repo.json key; build-package.sh looks it up by name
# for the -D flag, so keeping the original name preserves that.
link_dir disabled-packages

log "Upstream ready: $(git -C "$UPSTREAM_DIR" rev-parse --short HEAD)"
log "Linked: upstream-packages x11-packages root-packages disabled-packages"
