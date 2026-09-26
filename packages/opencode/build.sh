TERMUX_PKG_HOMEPAGE=https://opencode.ai
TERMUX_PKG_DESCRIPTION="AI coding agent for the terminal"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@kaozaza2"
TERMUX_PKG_VERSION=2.0.18
TERMUX_PKG_SRCURL=git+https://github.com/anomalyco/opencode
# opencode tags releases as v<version>, which is also the branch default
# termux_git_clone_src would pick; set it explicitly so the intent is obvious.
TERMUX_PKG_GIT_BRANCH="v$TERMUX_PKG_VERSION"
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_TAG_TYPE="latest-release-tag"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_DEPENDS="ca-certificates, git"
# The only target the patches add is {os: linux, arch: arm64, android: true}.
# Bun publishes no armv7 runtime and there is no x64 bionic target, so this
# package exists for aarch64 only.
TERMUX_PKG_EXCLUDED_ARCHES="arm, i686, x86_64"

# One target, four names. The last two differ from the first two because
# build.ts derives the dist directory with targetName().replace("opencode","cli").
BUILD_TARGET="opencode-linux-arm64-android"
DIST_NAME="cli-linux-arm64-android"
ANDROID_BINARY="packages/cli/dist/${DIST_NAME}/bin/opencode"
# Only a bionic binary carries this program interpreter.
ANDROID_INTERP="/system/bin/linker64"

# The npm @opentui/core-linux-arm64 .so is a glibc build needing
# libm.so.6/libc.so.6/libdl.so.2 and cannot be dlopen()ed on bionic, so a bionic
# build is vendored next to this script. It is version-locked to
# @opentui/core because the JS half binds native entry points by symbol name: a
# blob from another version is missing calls rather than merely out of date.
VENDORED_SO="$TERMUX_PKG_BUILDER_DIR/libopentui.so"
VENDORED_SO_SHA256="04bc895da9ef3c8f540f1865bc112d8ac83ad786dc271c102f13c3a7a0a3e218"
VENDORED_OPENTUI_VERSION="0.5.12"

# Everything the cli compile imports. If any of these fails to resolve the
# failure surfaces much later as an opaque bundler error.
CLI_INPUTS=(
	"@opentui/core"
	"@opentui/core/parser.worker"
	"@opentui/solid"
	"@opentui/solid/bun-plugin"
	"@opencode-ai/pty"
	"@parcel/watcher"
	"web-tree-sitter"
	"web-tree-sitter/tree-sitter.wasm"
)

termux_step_make() {
	termux_setup_bun

	cd "$TERMUX_PKG_SRCDIR"
	check_bun_pin
	install_workspace
	prewarm_native_deps
	prepare_opentui_android
	compile
	assert_android_binary
}

termux_step_make_install() {
	install -Dm755 "$TERMUX_PKG_SRCDIR/${ANDROID_BINARY}" \
		"$TERMUX_PREFIX/bin/opencode"
}

# @opencode/script throws unless the running bun satisfies ^<packageManager>, and
# that pin moves upstream, so read it from the checkout instead of hardcoding it.
# A different patch release inside the range is fine; a different major.minor
# would fail deep inside @opencode/script, so reject it here.
check_bun_pin() {
	local want have
	want="$(bun -e '
		const pin = require("./package.json").packageManager
		if (!pin?.startsWith("bun@")) { console.error("no bun@ pin: " + pin); process.exit(1) }
		console.log(pin.slice(4).split(".").slice(0, 2).join("."))
	')" || {
		echo "ERROR: could not read the bun pin from package.json" >&2
		exit 1
	}
	have="$(bun --version | cut -d. -f1,2)"
	if [ "$have" != "$want" ]; then
		echo "ERROR: bun $have does not satisfy ^$want as required by the checkout" >&2
		exit 1
	fi
}

verify_cli_inputs() {
	local missing=0 dep
	for dep in "${CLI_INPUTS[@]}"; do
		if ! (cd packages/cli && bun -e "Bun.resolveSync('${dep}', process.cwd())" >/dev/null 2>&1); then
			echo "  unresolved: ${dep}" >&2
			missing=1
		fi
	done
	if [ ! -d node_modules/@opencode/script ]; then
		echo "  unresolved: @opencode/script (workspace package)" >&2
		missing=1
	fi
	return "$missing"
}

# Bun can report success while leaving store entries with a directory skeleton
# and no files, which surfaces much later as `Could not resolve X`. It happens
# where Bun's default hardlink backend is unreliable, Android's f2fs among them.
# Drop the empty entries and reinstall once with --backend=copyfile; if that
# does not help, fail loudly rather than handing on an opaque bundler error.
repair_install() {
	echo "=== Repairing a corrupt bun store ===" >&2
	local dir id
	for dir in node_modules/.bun/*/node_modules/*/ node_modules/.bun/*/node_modules/@*/*/; do
		[ -d "$dir" ] || continue
		[ "$(basename "$dir")" = ".bin" ] && continue
		[ -f "$dir/package.json" ] && continue
		# Layout is .bun/<id>/node_modules/<pkg>, so the entry name is two levels up.
		id="$(basename "$(dirname "$(dirname "$dir")")")"
		echo "  dropping empty store entry: $id" >&2
		rm -rf "$dir" 2>/dev/null || true
	done
	echo "  reinstalling with --backend=copyfile" >&2
	bun install --backend=copyfile >&2 || true
}

install_workspace() {
	echo "=== Installing workspace dependencies ==="
	# A non-zero exit is not automatically fatal (one bad package aborts the whole
	# workspace install), but every input the compile needs must be present.
	bun install || true

	if verify_cli_inputs; then
		echo "All CLI build inputs resolved."
		return
	fi
	repair_install
	if verify_cli_inputs; then
		echo "All CLI build inputs resolved after repair."
		return
	fi
	echo "ERROR: build inputs still missing after a repair attempt." >&2
	exit 1
}

# The only native deps build.ts installs with --os=* --cpu=*, which is what
# materialises the android @opentui packages.
prewarm_native_deps() {
	local core pty
	core="$(bun -e 'console.log(require("./packages/cli/package.json").dependencies["@opentui/core"])')"
	pty="$(bun -e 'console.log(require("./packages/cli/package.json").dependencies["@opencode-ai/pty"])')"
	bun install --os="*" --cpu="*" "@opentui/core@${core}"
	bun install --os="*" --cpu="*" "@opencode-ai/pty@${pty}"
}

prepare_opentui_android() {
	echo "=== Swapping @opentui/core-linux-arm64 libopentui.so for bionic ==="
	local pkg want have

	if [ ! -f "$VENDORED_SO" ]; then
		echo "ERROR: $VENDORED_SO is missing" >&2
		exit 1
	fi
	# A truncated or corrupted blob in git would otherwise surface on a phone as
	# an unrelated dlopen error.
	have="$(sha256sum "$VENDORED_SO" | cut -d' ' -f1)"
	if [ "$have" != "$VENDORED_SO_SHA256" ]; then
		echo "ERROR: vendored libopentui.so checksum mismatch" >&2
		echo "       expected $VENDORED_SO_SHA256" >&2
		echo "       got      $have" >&2
		exit 1
	fi

	# v2 pins @opentui/core as "catalog:", so the version lives in the root
	# workspace catalog rather than in the cli package.
	want="$(bun -e '
		const cli = require("./packages/cli/package.json")
		const root = require("./package.json")
		const dep = cli.dependencies["@opentui/core"]
		const v = dep && dep !== "catalog:" ? dep : root.workspaces?.catalog?.["@opentui/core"]
		if (!v || v === "catalog:") { console.error("cannot resolve @opentui/core"); process.exit(1) }
		console.log(v.replace(/^[\^~>=<\s]+/, ""))
	')"
	if [ "$want" != "$VENDORED_OPENTUI_VERSION" ]; then
		echo "ERROR: vendored libopentui.so is for @opentui/core $VENDORED_OPENTUI_VERSION," >&2
		echo "       but this checkout resolves $want." >&2
		echo "       Rebuild the blob and update VENDORED_OPENTUI_VERSION." >&2
		exit 1
	fi

	pkg="$(find node_modules/.bun -type d \
		-path '*@opentui+core-linux-arm64@*/node_modules/@opentui/core-linux-arm64' 2>/dev/null | head -1)"
	if [ -z "$pkg" ]; then
		echo "ERROR: @opentui/core-linux-arm64 not found in the bun store" >&2
		exit 1
	fi
	cp -f "$VENDORED_SO" "$pkg/libopentui.so"
	echo "  replaced $pkg/libopentui.so with the bionic build for @opentui/core $want"
}

compile() {
	# No --skip-install: build.ts's own `bun install --os=* --cpu=*` is what
	# materialises the android packages, and prewarm_native_deps already ran the
	# identical commands so they cannot re-extract a glibc .so over the bionic one.
	# --skip-web-ui because the embedded app assets are a brotli bundle costing
	# tens of MB and are only used by `opencode serve`'s browser UI.
	echo "=== Compiling $BUILD_TARGET ==="
	OPENCODE_VERSION="$TERMUX_PKG_VERSION" bun run packages/cli/script/build.ts \
		"--target=$BUILD_TARGET" --skip-web-ui
}

# A build can exit 0 having produced nothing, so check the output rather than
# trusting the exit status.
assert_android_binary() {
	local bin="$TERMUX_PKG_SRCDIR/${ANDROID_BINARY}"
	if [ ! -f "$bin" ]; then
		echo "ERROR: $ANDROID_BINARY was not produced" >&2
		echo "       The android target comes from 0001-android-target.patch" >&2
		find packages/cli/dist -maxdepth 3 >&2 2>/dev/null || true
		exit 1
	fi
	if ! grep -qa -- "$ANDROID_INTERP" "$bin"; then
		echo "ERROR: $bin is not an android binary (no $ANDROID_INTERP)" >&2
		exit 1
	fi
	echo "Verified: android binary with $ANDROID_INTERP interpreter"
}
