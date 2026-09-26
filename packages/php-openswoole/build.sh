TERMUX_PKG_HOMEPAGE=https://openswoole.com
TERMUX_PKG_DESCRIPTION="PHP extension for async IO, coroutines, fibers and an HTTP server"
TERMUX_PKG_LICENSE="Apache-2.0"
TERMUX_PKG_LICENSE_FILE=LICENSE
TERMUX_PKG_MAINTAINER="@kaozaza2"
TERMUX_PKG_VERSION=26.2.0
TERMUX_PKG_SRCURL=https://github.com/openswoole/ext-openswoole/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=0dd86480a3e4f6ad5474bbdf441facc656dba668adceab93a35dbfe2e4d57e70
TERMUX_PKG_DEPENDS="openssl, php, zlib"
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_VERSION_REGEXP='\d+\.\d+\.\d+'
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="--enable-openswoole --with-openssl-dir=$TERMUX_PREFIX"

# The extension source is a phpize project, not an autotools or cmake one.
# phpize writes $TERMUX_PKG_SRCDIR/configure, and the configure dispatcher
# tests for that file before it looks at the root CMakeLists.txt, which
# upstream also ships for its cmake-based dev tooling. So phpize has to run
# before the configure step, which is what termux_step_pre_configure is for.
termux_step_pre_configure() {
	$TERMUX_PREFIX/bin/phpize
}

termux_step_post_make_install() {
	# PHP loads an extension only when an ini names it, and unlike the
	# extensions php builds itself (gd, ldap, pgsql, pdo_pgsql, sodium) this
	# one is not on that list. Write the ini so the extension is actually
	# loaded rather than merely installed.
	local extdir="$TERMUX_PREFIX/etc/php/conf.d"
	mkdir -p "$extdir"
	echo "extension=openswoole" > "$extdir/openswoole.ini"
}
