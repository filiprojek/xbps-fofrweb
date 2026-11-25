#!/bin/sh
# Offline test. Part 1: the ./xbps-src shim against a fake void-packages worktree (stub
# xbps-src that logs its calls): xdistdir/xtools see the overlay, the overlay is copied
# into the worktree correctly, repo.sh build calls it per arch.
# Part 2: repo.sh publish/remove with dummy packages (x86_64, aarch64, noarch) made by
# xbps-create, a throwaway signing key and a local directory instead of the server; at the end the
# result is served over HTTP and xbps-install -S checks the signature like a client.
# Needs xbps, xtools, git, openssl, rsync, python3. Touches neither pass nor the server.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/xbps-fofrweb-test.XXXXXX")
t=$(cd "$t" && pwd -P)
http_pid=
cleanup() {
	if [ -n "$http_pid" ]; then kill "$http_pid" 2>/dev/null || true; fi
	rm -rf "$t"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
have() { [ -f "$t/served/$1" ] || fail "$1 missing on the server"; }
lacks() { [ ! -e "$t/served/$1" ] || fail "$1 still on the server"; }
gitq() { git -c user.name=test -c user.email=test@example.invalid "$@" > /dev/null; }

native=$(xbps-uhelper arch)
export BUILD_DIR="$t/build" STAGING="$t/staging" REMOTE="$t/served" ARCHS="$native aarch64"
export SIGNING_KEY_FILE="$t/key.pem" SIGNED_BY="test <test@example.invalid>"
export STUB_LOG="$t/stub.log"

# Overlay: the scripts and fake templates (hello + subpackage hello-doc, noarch hello-data)
o=$t/overlay
mkdir -p "$o/srcpkgs/hello" "$o/srcpkgs/hello-data" "$o/common"
cp "$here/repo.sh" "$here/xbps-src" "$here/config.sh" "$here/.gitignore" "$o/"
printf 'pkgname=hello\nversion=1.0\nrevision=1\n' > "$o/srcpkgs/hello/template"
ln -s hello "$o/srcpkgs/hello-doc"
printf 'pkgname=hello-data\nversion=1.0\nrevision=1\narchs=noarch\n' > "$o/srcpkgs/hello-data/template"
printf 'libhello.so.1 hello-1.0_1\n' > "$o/common/shlibs"
gitq -C "$o" init -q
gitq -C "$o" add -A
gitq -C "$o" commit -q -m overlay

# Fake worktree: upstream hello with a patch the overlay doesn't have, another package,
# common/ with shlibs, environment, cross-profiles, and a stub xbps-src
b=$t/build
mkdir -p "$b/srcpkgs/hello/patches" "$b/srcpkgs/other" "$b/common/environment" "$b/common/cross-profiles"
printf 'pkgname=hello\nversion=0.9\nrevision=1\n' > "$b/srcpkgs/hello/template"
echo patch > "$b/srcpkgs/hello/patches/upstream.patch"
printf 'pkgname=other\nversion=1\nrevision=1\n' > "$b/srcpkgs/other/template"
printf 'libc.so.6 glibc-2.41_1\n' > "$b/common/shlibs"
# shellcheck disable=SC2016 # $PWD/$* belong to the stub, expanded when it runs
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$PWD" "$*" >> "$STUB_LOG"\n' > "$b/xbps-src"
chmod +x "$b/xbps-src"
echo /hostdir > "$b/.gitignore"
gitq -C "$b" init -q
gitq -C "$b" add -A
gitq -C "$b" commit -q -m upstream

# 1. xtools find the overlay as the void-packages tree, also from a subdirectory
[ "$(cd "$o" && xdistdir)" = "$o" ] || fail "xdistdir in the overlay: $(cd "$o" && xdistdir 2>&1)"
[ "$(cd "$o/srcpkgs/hello" && xdistdir)" = "$o" ] || fail "xdistdir from srcpkgs/hello"
[ "$("$o/xbps-src" -H /x show-var XBPS_DISTDIR)" = "$o" ] || fail "show-var with flags"
[ ! -s "$STUB_LOG" ] || fail "show-var XBPS_DISTDIR reached the real xbps-src"
ok "xdistdir resolves to the overlay"

# 2. other commands: overlay copied over upstream, arguments passed through in the worktree
"$o/xbps-src" show hello
grep -qx "$b|show hello" "$STUB_LOG" || { cat "$STUB_LOG"; fail "stub not called in the worktree"; }
cmp -s "$o/srcpkgs/hello/template" "$b/srcpkgs/hello/template" || fail "overlay template not copied"
[ ! -e "$b/srcpkgs/hello/patches" ] || fail "upstream patches survived the overlay"
[ "$(readlink "$b/srcpkgs/hello-doc")" = hello ] || fail "subpackage symlink not copied"
[ -f "$b/srcpkgs/other/template" ] || fail "unrelated upstream package touched"
"$o/xbps-src" show hello
[ "$(grep -c '^libhello' "$b/common/shlibs")" = 1 ] || fail "overlay shlibs not appended exactly once"
grep -q '^libc.so.6' "$b/common/shlibs" || fail "upstream shlibs lost"
ok "xbps-src: overlay replaces upstream dir, shlibs appended once, args passed"

# 3. helper symlinks for xi / xgensum, ignored by git
[ "$(readlink "$o/hostdir")" = "$b/hostdir" ] || fail "hostdir link"
[ "$(readlink "$o/common/environment")" = "$b/common/environment" ] || fail "environment link"
[ "$(readlink "$o/common/cross-profiles")" = "$b/common/cross-profiles" ] || fail "cross-profiles link"
[ -z "$(git -C "$o" status --porcelain)" ] || { git -C "$o" status --short; fail "links not ignored"; }
ok "symlinks hostdir, common/environment, common/cross-profiles (gitignored)"

# 4. xlint by package name reads the overlay template
out=$(cd "$o" && xlint hello 2>&1 || true)
case $out in
*"srcpkgs/hello/template"* | *"hello:"*) ;;
*) printf '%s\n' "$out"; fail "xlint hello did not lint the overlay template" ;;
esac
ok "xlint hello lints srcpkgs/hello/template"

# 5. repo.sh build: native build, cross build, noarch only once
: > "$STUB_LOG"
"$o/repo.sh" build hello hello-data > /dev/null
grep -qx "$b|pkg hello" "$STUB_LOG" || fail "no native build of hello"
grep -qx "$b|-a aarch64 pkg hello" "$STUB_LOG" || fail "no aarch64 build of hello"
grep -qx "$b|pkg hello-data" "$STUB_LOG" || fail "no build of hello-data"
if grep -q 'aarch64 pkg hello-data' "$STUB_LOG"; then fail "noarch hello-data built twice"; fi
ok "repo.sh build: $native + aarch64, noarch once"

# Part 2: publishing
binpkgs=$b/hostdir/binpkgs
mkdir -p "$binpkgs" "$t/destdir/usr/share/hello"
echo hi > "$t/destdir/usr/share/hello/hi"
mkpkg() { # <pkgver> <arch>
	(cd "$binpkgs" && xbps-create -q -A "$2" -n "$1" -s "test package $1" "$t/destdir")
}
openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SIGNING_KEY_FILE"
repo() { "$o/repo.sh" "$@" > "$t/out" 2>&1 || { cat "$t/out"; fail "repo.sh $*"; }; }

# 6. first publish: both arches, subpackage, noarch, signatures
for a in "$native" aarch64; do mkpkg hello-1.0_1 "$a"; mkpkg hello-doc-1.0_1 "$a"; done
mkpkg hello-data-1.0_1 noarch
repo publish
for f in "$native-repodata" aarch64-repodata "hello-1.0_1.$native.xbps" hello-1.0_1.aarch64.xbps \
	"hello-doc-1.0_1.$native.xbps" hello-data-1.0_1.noarch.xbps hello-1.0_1.aarch64.xbps.sig2; do
	have "$f"
done
ok "publish: both arches, subpackage, noarch, signatures"

# 7. update only the native arch: its old file goes, aarch64 and noarch stay
mkpkg hello-1.1_1 "$native"
repo publish hello
have "hello-1.1_1.$native.xbps"
have "hello-1.1_1.$native.xbps.sig2"
lacks "hello-1.0_1.$native.xbps"
lacks "hello-1.0_1.$native.xbps.sig2"
have hello-1.0_1.aarch64.xbps
have hello-data-1.0_1.noarch.xbps
ok "update: obsolete $native removed, other arch and noarch kept"

# 8. remove a subpackage on every arch
repo remove hello-doc
lacks "hello-doc-1.0_1.$native.xbps"
lacks hello-doc-1.0_1.aarch64.xbps
have "hello-1.1_1.$native.xbps"
ok "remove: subpackage gone on both arches"

# 9. index contents per arch
repo list
grep -q 'hello-1.1_1' "$t/out" || { cat "$t/out"; fail "list lacks hello-1.1_1"; }
grep -q 'hello-1.0_1' "$t/out" || { cat "$t/out"; fail "list lacks aarch64 hello-1.0_1"; }
if grep -q 'hello-doc' "$t/out"; then cat "$t/out"; fail "list still shows hello-doc"; fi
ok "list: $native at 1.1, aarch64 at 1.0, hello-doc gone"

# 10. a client syncs over HTTP: signed repository, key fingerprint as repo.sh reports it
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -m http.server -b 127.0.0.1 -d "$t" "$port" > /dev/null 2>&1 &
http_pid=$!
sleep 1
mkdir -p "$t/root"
yes | XBPS_ARCH=$native xbps-install -r "$t/root" -C /dev/null -i \
	-R "http://127.0.0.1:$port/served" -S > "$t/out" 2>&1 || { cat "$t/out"; fail "xbps-install -S"; }
fp=$("$o/repo.sh" fingerprint)
[ -f "$t/root/var/db/xbps/keys/$fp.plist" ] ||
	{ cat "$t/out"; ls "$t/root/var/db/xbps/keys" 2>&1; fail "imported key is not $fp"; }
ok "client sync: signature accepted, key fingerprint $fp"

# 11. the client verifies a package signature on download
XBPS_ARCH=$native xbps-install -r "$t/root" -C /dev/null -i -R "http://127.0.0.1:$port/served" \
	-y -D hello > "$t/out" 2>&1 || { cat "$t/out"; fail "download hello"; }
grep -qi 'verif' "$t/out" || { cat "$t/out"; fail "no signature verification in output"; }
ok "client download: package signature verified"
