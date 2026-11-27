#!/bin/sh
# Offline test. Part 1: the ./xbps-src shim against a fake void-packages worktree (stub
# xbps-src that logs its calls): xdistdir/xtools see the overlay, the overlay is copied
# into the worktree correctly, repo.sh build calls it per arch.
# Part 2: repo.sh publish/remove with dummy packages (x86_64, aarch64, noarch) made by
# xbps-create, a throwaway signing key and a local directory instead of the server; at the end the
# result is served over HTTP and xbps-install -S checks the signature like a client.
# Part 3: the website, generated on publish/remove beside the repository directory.
# Part 4: repo.sh release with a stub gh (CI run lookup, artifact download, attestation
# verification) and ci/changed.sh on a git fixture.
# Needs xbps, xtools, git, openssl, ssh-keygen (openssh), rsync, python3 (3.14+). Touches neither pass, the server
# nor GitHub.
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
cp -R "$here/site" "$here/ci" "$o/"
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
mkdir -p "$b/etc"
echo XBPS_CHROOT_CMD=uchroot > "$b/etc/conf" # a worktree setting the shim must keep
# Stub xbps-src: logs "<dir>|<args>"; show-avail says a package is unavailable for an arch
# when "<arch> <pkg>" is a line of $STUB_LOG.unavail
cat > "$b/xbps-src" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$PWD" "$*" >> "$STUB_LOG"
arch=$(xbps-uhelper arch)
if [ "$1" = -a ]; then arch=$2; shift 2; fi
if [ "$1" = show-avail ]; then
	if grep -qx "$arch $2" "$STUB_LOG.unavail" 2>/dev/null; then exit 1; fi
fi
exit 0
EOF
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
# restricted templates allowed through etc/conf (the build chroot starts with env -i, so an
# environment variable doesn't reach it), added once, the worktree's own settings kept
[ "$(grep -cx 'XBPS_ALLOW_RESTRICTED=yes' "$b/etc/conf")" = 1 ] ||
	{ cat "$b/etc/conf"; fail "etc/conf: XBPS_ALLOW_RESTRICTED=yes not set exactly once"; }
grep -qx 'XBPS_CHROOT_CMD=uchroot' "$b/etc/conf" || fail "etc/conf: existing settings lost"
ok "xbps-src: overlay replaces upstream dir, shlibs appended once, args passed, restricted allowed"

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

# 5b. a package not available for an arch (archs="x86_64") is skipped there, not an error
: > "$STUB_LOG"
echo "aarch64 hello" > "$STUB_LOG.unavail"
"$o/repo.sh" build hello > "$t/out" 2>&1 || { cat "$t/out"; fail "build failed on an unavailable arch"; }
grep -qx "$b|pkg hello" "$STUB_LOG" || fail "native build skipped too"
if grep -q -- '-a aarch64 pkg hello' "$STUB_LOG"; then fail "built for an arch the package excludes"; fi
grep -q 'skipping hello for aarch64' "$t/out" || { cat "$t/out"; fail "skip not reported"; }
rm "$STUB_LOG.unavail"
ok "repo.sh build: arch the package excludes skipped"

# Part 2: publishing
binpkgs=$b/hostdir/binpkgs
mkdir -p "$binpkgs" "$t/destdir/usr/share/hello"
echo hi > "$t/destdir/usr/share/hello/hi"
mkpkg() { # <pkgver> <arch> [short_desc]
	(cd "$binpkgs" && xbps-create -q -A "$2" -n "$1" -s "${3:-test package $1}" "$t/destdir")
}
# Markup in a description must reach the page as text, not as HTML
export ODD_DESC='data </script><b>"bold"</b> & more'
site_has() { # <python expression over p = {name: entry} of packages.json>
	python3 -I -c '
import json, os, sys
p = {e["name"]: e for e in json.load(open(sys.argv[1]))["packages"]}
sys.exit(0 if eval(sys.argv[2]) else 1)' "$t/packages.json" "$1"
}
openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SIGNING_KEY_FILE"
repo() { "$o/repo.sh" "$@" > "$t/out" 2>&1 || { cat "$t/out"; fail "repo.sh $*"; }; }

# 6. first publish: both arches, subpackage, noarch, signatures
for a in "$native" aarch64; do mkpkg hello-1.0_1 "$a"; mkpkg hello-doc-1.0_1 "$a"; done
mkpkg hello-data-1.0_1 noarch "$ODD_DESC"
repo publish
for f in "$native-repodata" aarch64-repodata "hello-1.0_1.$native.xbps" hello-1.0_1.aarch64.xbps \
	"hello-doc-1.0_1.$native.xbps" hello-data-1.0_1.noarch.xbps hello-1.0_1.aarch64.xbps.sig2; do
	have "$f"
done
ok "publish: both arches, subpackage, noarch, signatures"

# 6b. the website beside the repository (SITE_REMOTE defaults to REMOTE's parent): package
# data per arch, the signing key fingerprint, request link, markup escaped
fp=$("$o/repo.sh" fingerprint)
[ -f "$t/index.html" ] || fail "no index.html beside the repository"
[ -f "$t/packages.json" ] || fail "no packages.json beside the repository"
lacks index.html
site_has 'sorted(p) == ["hello", "hello-data", "hello-doc"]' || { cat "$t/packages.json"; fail "site package names"; }
site_has "sorted(p['hello']['archs']) == sorted(['$native', 'aarch64'])" || fail "site: hello archs"
site_has "p['hello-doc']['source'] == 'hello'" || fail "site: hello-doc source package"
site_has "p['hello-data']['archs'] == ['noarch']" || fail "site: hello-data noarch"
site_has "p['hello-data']['desc'] == os.environ['ODD_DESC']" || fail "site: description not verbatim"
grep -q "$fp" "$t/index.html" || fail "fingerprint $fp not on the page"
grep -q 'hello-data' "$t/index.html" || fail "package data not embedded in the page"
grep -q '/issues/new' "$t/index.html" || fail "no package request link"
if grep -q '</script><b>' "$t/index.html"; then fail "description markup not escaped"; fi
ok "site: index.html + packages.json beside the repository, fingerprint, links, escaping"

# 6c. latest first: newest package file (time it was added) shown, the rest collapsed
touch -d '2020-01-01 12:00 UTC' "$STAGING"/*.xbps
touch -d '2021-06-01 12:00 UTC' "$STAGING/hello-data-1.0_1.noarch.xbps"
python3 -I "$o/site/gen.py" --repo "$STAGING" --archs "$native aarch64" --repo-url http://x \
	--source-url http://x --srcpkgs "$o/srcpkgs" --out "$t/gen" --latest 1
head=$(sed '/<details/q' "$t/gen/index.html")
rest=$(sed -n '/<details/,$p' "$t/gen/index.html")
case $head in *'id="hello-data"'*) ;; *) fail "newest package not listed before the collapsed part" ;; esac
case $head in *'id="hello-doc"'*) fail "older package not collapsed" ;; esac
case $rest in *'id="hello-doc"'*) ;; *) fail "older package missing from the collapsed part" ;; esac
case $rest in *'id="hello-data"'*) fail "newest package listed twice" ;; esac
grep -q '2021-06-01' "$t/gen/index.html" || fail "date of the newest package not shown"
python3 -I -c 'import json,sys; p={e["name"]: e for e in json.load(open(sys.argv[1]))["packages"]}; sys.exit(not p["hello-data"]["updated"].startswith("2021-06-01"))' \
	"$t/gen/packages.json" || fail "packages.json: updated"
ok "site: latest package first with its date, the rest collapsed"

# 6d. an unsigned repository (empty index-meta.plist) still gets a page
mkdir -p "$t/unsigned"
cp "$STAGING/hello-data-1.0_1.noarch.xbps" "$t/unsigned/"
XBPS_TARGET_ARCH=$native xbps-rindex -a "$t/unsigned/hello-data-1.0_1.noarch.xbps" > /dev/null
python3 -I "$o/site/gen.py" --repo "$t/unsigned" --archs "$native" --repo-url http://x \
	--source-url http://x --out "$t/gen-unsigned" || fail "gen.py on an unsigned repository"
grep -q 'not signed yet' "$t/gen-unsigned/index.html" || fail "unsigned repository not marked as such"
ok "site: unsigned repository"

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
site_has '"hello-doc" not in p' || fail "site still lists hello-doc after remove"
site_has "p['hello']['versions'] == {'$native': '1.1_1', 'aarch64': '1.0_1'}" ||
	{ cat "$t/packages.json"; fail "site: versions per arch"; }
ok "remove: subpackage gone on both arches, site updated"

# 9. index contents per arch
repo list
grep -q 'hello-1.1_1' "$t/out" || { cat "$t/out"; fail "list lacks hello-1.1_1"; }
grep -q 'hello-1.0_1' "$t/out" || { cat "$t/out"; fail "list lacks aarch64 hello-1.0_1"; }
if grep -q 'hello-doc' "$t/out"; then cat "$t/out"; fail "list still shows hello-doc"; fi
ok "list: $native at 1.1, aarch64 at 1.0, hello-doc gone"

# 9b. a restricted template with repository=nonfree: xbps-src puts it in binpkgs/nonfree/,
# publish takes it from there into the one public repository, like any other package
mkdir -p "$o/srcpkgs/hello-nonfree" "$binpkgs/nonfree"
printf 'pkgname=hello-nonfree\nversion=1.0\nrevision=1\nrestricted=yes\nrepository=nonfree\n' \
	> "$o/srcpkgs/hello-nonfree/template"
mkpkg hello-nonfree-1.0_1 "$native"
mv "$binpkgs/hello-nonfree-1.0_1.$native.xbps" "$binpkgs/nonfree/"
repo publish hello-nonfree
have "hello-nonfree-1.0_1.$native.xbps"
have "hello-nonfree-1.0_1.$native.xbps.sig2"
lacks nonfree
site_has "'hello-nonfree' in p" || fail "restricted package not on the website"
ok "publish: restricted package from binpkgs/nonfree/, signed, on the website"

# Part 4: repo.sh release. The overlay gets an origin with master; a stub gh serves one CI
# run per commit ($t/gh/run-<sha> holds its id; $t/gh/run-default "<id> <sha>" is the newest
# successful run on master), downloads $t/gh/artifacts/<id>/ and fails attestation for files
# listed in $t/gh/bad. Every gh call is logged.
gitq init -q --bare "$t/origin.git"
gitq -C "$o" remote add origin "$t/origin.git"
gitq -C "$o" push -q origin HEAD:refs/heads/master
sha=$(git -C "$o" rev-parse HEAD)
mkdir -p "$t/gh" "$t/bin"
: > "$t/gh/bad"
cat > "$t/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_STUB/log"
case "$1 $2" in
"run list")
	case " $* " in
	*" --commit "*)
		while [ $# -gt 0 ]; do
			if [ "$1" = --commit ] && [ -f "$GH_STUB/run-$2" ]; then cat "$GH_STUB/run-$2"; fi
			shift
		done ;;
	*) if [ -f "$GH_STUB/run-default" ]; then cat "$GH_STUB/run-default"; fi ;;
	esac ;;
"run download")
	id=$3
	while [ $# -gt 0 ]; do [ "$1" = -D ] && dir=$2; shift; done
	cp -R "$GH_STUB/artifacts/$id/." "$dir/" ;;
"attestation verify")
	! grep -qx "${3##*/}" "$GH_STUB/bad" ;;
*) echo "gh stub: unexpected: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$t/bin/gh"
export GH="$t/bin/gh" GH_STUB="$t/gh" GH_REPO=test/repo
artifact() { # <run id> <pkgver> <arch>: a package built "by CI" for that run
	mkdir -p "$t/gh/artifacts/$1/binpkgs-$3"
	mkpkg "$2" "$3"
	mv "$binpkgs/$2.$3.xbps" "$t/gh/artifacts/$1/binpkgs-$3/"
}
rel_fails() { # <why> <args>...: release must fail and upload nothing new
	why=$1; shift
	if "$o/repo.sh" release "$@" > "$t/out" 2>&1; then cat "$t/out"; fail "release accepted: $why"; fi
	lacks "hello-1.2_1.$native.xbps"
}
echo 42 > "$t/gh/run-$sha"
echo "42 $sha" > "$t/gh/run-default"
artifact 42 hello-1.2_1 "$native"
artifact 42 hello-1.2_1 aarch64
artifact 42 hello-nonfree-1.1_1 "$native" # restricted: released like any other

# 12. a failed attestation stops the release before anything is staged or uploaded
echo "hello-1.2_1.aarch64.xbps" > "$t/gh/bad"
rel_fails "failed attestation"
grep -q 'attestation failed\|not verified' "$t/out" || { cat "$t/out"; fail "no attestation error shown"; }
[ ! -e "$STAGING/hello-1.2_1.$native.xbps" ] || fail "staged despite a failed attestation"
: > "$t/gh/bad"
ok "release: failed attestation, nothing uploaded"

# 13. packages that are not in the overlay are refused, even when attested
artifact 42 evil-1.0_1 "$native"
rel_fails "package not in srcpkgs/"
grep -q 'evil' "$t/out" || { cat "$t/out"; fail "foreign package not named"; }
rm "$t/gh/artifacts/42/binpkgs-$native/evil-1.0_1.$native.xbps"
ok "release: package not in the overlay refused"

# 14. a commit that is not on origin/master is refused
gitq -C "$o" commit -q --allow-empty -m unpushed
unpushed=$(git -C "$o" rev-parse HEAD)
echo 42 > "$t/gh/run-$unpushed"
rel_fails "commit not on origin/master" "$unpushed"
# the same when it is the newest CI build (e.g. its commit was force-pushed away)
echo "42 $unpushed" > "$t/gh/run-default"
rel_fails "newest CI build not on origin/master"
echo "42 $sha" > "$t/gh/run-default"
gitq -C "$o" reset -q --hard "$sha"
ok "release: commit not on origin/master refused"

# 15. no successful CI run (for the commit, or at all)
rm "$t/gh/run-$sha" "$t/gh/run-default"
rel_fails "no CI run for the commit" "$sha"
rel_fails "no CI run at all"
echo 42 > "$t/gh/run-$sha"
echo "42 $sha" > "$t/gh/run-default"
ok "release: no CI run refused"

# 16. without arguments: the newest successful CI build on master is published and signed;
# attestation checked against the master build of exactly its commit, on GitHub-hosted runners
: > "$t/gh/log"
repo release
have "hello-1.2_1.$native.xbps"
have "hello-1.2_1.$native.xbps.sig2"
have hello-1.2_1.aarch64.xbps.sig2
lacks "hello-1.1_1.$native.xbps"
have "hello-nonfree-1.1_1.$native.xbps.sig2"
for want in "--source-digest $sha" "--source-ref refs/heads/master" \
	"--signer-workflow test/repo/.github/workflows/build.yml" "--deny-self-hosted-runners"; do
	[ "$(grep -c -- "attestation verify .*$want" "$t/gh/log")" = 3 ] ||
		{ cat "$t/gh/log"; fail "attestation not verified with $want for all three files"; }
done
site_has "p['hello']['versions'] == {'$native': '1.2_1', 'aarch64': '1.2_1'}" ||
	{ cat "$t/out" "$t/packages.json"; fail "site not updated by release"; }
ok "release: verified CI build published, signed, site updated"

# 17. ci/changed.sh: changed source packages between two commits (subpackage -> source,
# files/ count, deleted packages skipped)
c=$t/changed
mkdir -p "$c/srcpkgs/a" "$c/srcpkgs/b/files" "$c/srcpkgs/d"
for p in a b d; do echo "pkgname=$p" > "$c/srcpkgs/$p/template"; done
echo x > "$c/srcpkgs/b/files/x"
gitq -C "$c" init -q
gitq -C "$c" add -A
gitq -C "$c" commit -q -m base
base=$(git -C "$c" rev-parse HEAD)
echo 'version=2' >> "$c/srcpkgs/a/template"
echo y > "$c/srcpkgs/b/files/x"
mkdir -p "$c/srcpkgs/e" && echo pkgname=e > "$c/srcpkgs/e/template"
ln -s e "$c/srcpkgs/e-devel"
git -C "$c" rm -q -r srcpkgs/d
gitq -C "$c" add -A
gitq -C "$c" commit -q -m change
got=$(cd "$c" && "$o/ci/changed.sh" "$base" HEAD | tr '\n' ' ')
[ "$got" = "a b e " ] || fail "ci/changed.sh: got '$got', want 'a b e '"
ok "ci/changed.sh: a b e (subpackage resolved, deleted skipped)"

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
