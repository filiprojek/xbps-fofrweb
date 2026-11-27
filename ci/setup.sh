#!/bin/sh
# CI: a void-packages checkout as BUILD_DIR, configured like void-packages' own CI
# (common/travis/prepare.sh, set_mirror.sh) and bootstrapped through the overlay's
# ./xbps-src, which also allows restricted templates (XBPS_ALLOW_RESTRICTED). Runs as a non-root member of xbuilder in a
# privileged ghcr.io/void-linux/void-glibc-full container; BUILD_DIR comes from the workflow.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=config.sh
. "$here/config.sh"

if [ ! -x "$BUILD_DIR/xbps-src" ]; then
	git clone -q --depth 1 https://github.com/void-linux/void-packages.git "$BUILD_DIR"
	cat >> "$BUILD_DIR/etc/conf" <<-EOF
		XBPS_BUILD_ENVIRONMENT=void-packages-ci
		XBPS_CHROOT_CMD=uchroot
	EOF
	for f in "$BUILD_DIR"/etc/xbps.d/repos-remote*.conf; do
		sed -i 's:repo-default\.voidlinux\.org:repo-ci.voidlinux.org:g' "$f"
	done
fi
"$here/xbps-src" binary-bootstrap
