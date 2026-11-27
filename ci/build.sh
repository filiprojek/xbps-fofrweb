#!/bin/sh
# CI: build source packages for one arch with repo.sh build, in dependency order: those
# changed between two commits, or the given ones. Sets up BUILD_DIR (ci/setup.sh) only when
# there is something to build. The sorted list goes to $BUILD_DIR/packages.txt.
#
# Usage: ci/build.sh <arch> <base> <head>
#        ci/build.sh <arch> -- <pkg>...
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=config.sh
. "$here/config.sh"

[ $# -ge 2 ] || { echo "usage: $0 <arch> <base> <head> | <arch> -- <pkg>..." >&2; exit 2; }
arch=$1
shift
if [ "$1" = -- ]; then
	shift
	pkgs=$*
else
	pkgs=$(cd "$here" && ci/changed.sh "$1" "$2")
fi
if [ -z "$pkgs" ]; then
	echo "no source packages to build"
	exit 0
fi

"$here/ci/setup.sh"
# Package names contain no whitespace: the lists are split on purpose
# shellcheck disable=SC2086
sorted=$("$here/xbps-src" sort-dependencies $pkgs)
# shellcheck disable=SC2086
printf '%s\n' $sorted > "$BUILD_DIR/packages.txt"
# shellcheck disable=SC2086
echo "building for $arch:" $sorted
# shellcheck disable=SC2086
ARCHS=$arch "$here/repo.sh" build $sorted
