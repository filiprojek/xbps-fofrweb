#!/bin/sh
# Void Linux package repository https://xbps.fofrweb.net/current: own packages and ones
# upstream won't take (not a mirror). Templates live in srcpkgs/ here (an overlay); ./xbps-src
# builds them in a void-packages worktree, this script indexes, signs and uploads them with
# rsync to REMOTE (config.sh), where a web server serves them as static files.
#
# Usage: ./repo.sh <command> [args]
#   setup                  create the build worktree from your void-packages clone, bootstrap it
#   update                 move the build worktree to upstream master, update its masterdir
#   import <branch> <pkg>  copy srcpkgs/<pkg> from a branch of your void-packages clone
#   build <pkg>...         build source packages for every arch in ARCHS
#   publish [<pkg>...]     add built packages (default: all of srcpkgs/) to the repository,
#                          sign and upload
#   release [<commit>]     the same with packages built by GitHub CI (build.yml) for a commit
#                          on origin/master (default: the newest successful CI build there),
#                          after verifying their build attestations
#   remove <name>...       drop packages (binary package names) from the repository, upload
#   pull                   refresh the local copy of the published repository
#   list                   show what the repository holds, per arch
#   site                   regenerate and upload only the website (also done by publish/remove)
#   keygen                 create the signing key in pass, print its fingerprint
#   fingerprint            print the signing key's fingerprint
#
# Settings: config.sh, each overridable from the environment.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
. "$here/config.sh"

key=
tmpkey=
sitedir=
dldir=
cleanup() {
	if [ -n "$tmpkey" ]; then rm -f "$tmpkey"; fi
	if [ -n "$sitedir" ]; then rm -rf "$sitedir"; fi
	if [ -n "$dldir" ]; then rm -rf "$dldir"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }
msg() { printf '==> %s\n' "$*"; }

need_build_dir() {
	[ -x "$BUILD_DIR/xbps-src" ] || die "no build worktree at $BUILD_DIR, run: $0 setup"
}

need_srcpkg() {
	[ -f "$here/srcpkgs/$1/template" ] ||
		die "srcpkgs/$1/template not found (give source packages, not subpackages)"
}

# Source packages of the overlay: directories in srcpkgs/ (subpackages are symlinks)
overlay_pkgs() {
	for d in "$here"/srcpkgs/*; do
		if [ ! -L "$d" ] && [ -f "$d/template" ]; then
			printf '%s\n' "${d##*/}"
		fi
	done
}

# Binary package names a source package produces: itself and its subpackage symlinks
pkg_names() {
	printf '%s\n' "$1"
	for l in "$here"/srcpkgs/*; do
		if [ -L "$l" ] && [ "$(readlink "$l")" = "$1" ]; then
			printf '%s\n' "${l##*/}"
		fi
	done
}

# Source package of a binary package name: itself, or the target of its subpackage symlink;
# empty when srcpkgs/ has no such package
source_of() {
	if [ -L "$here/srcpkgs/$1" ]; then
		readlink "$here/srcpkgs/$1"
	elif [ -f "$here/srcpkgs/$1/template" ]; then
		printf '%s\n' "$1"
	fi
}

is_noarch() { grep -Eq '^archs=["'\'']?noarch' "$here/srcpkgs/$1/template"; }

# Name and arch from a package file name: foo-1.2_1.x86_64.xbps -> foo / x86_64
# (Void versions contain no '-', so the name is everything before the last one)
file_name() { _b=${1##*/}; _v=${_b%.*.xbps}; printf '%s' "${_v%-*}"; }
file_arch() { _b=${1##*/}; _b=${_b%.xbps}; printf '%s' "${_b##*.}"; }

# Signing key: SIGNING_KEY_FILE, or a copy from pass on tmpfs, deleted on exit
with_key() {
	if [ -n "$key" ]; then return 0; fi
	if [ -n "$SIGNING_KEY_FILE" ]; then
		key=$SIGNING_KEY_FILE
		return 0
	fi
	tmpkey=$(runtime_tmp)
	pass show "$PASS_ENTRY" > "$tmpkey" ||
		die "pass show $PASS_ENTRY failed (YubiKey, gpg-agent forwarding?)"
	key=$tmpkey
}

runtime_tmp() {
	[ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] ||
		die "XDG_RUNTIME_DIR unset: refusing to put the signing key on a disk-backed directory"
	mktemp "$XDG_RUNTIME_DIR/xbps-fofrweb-key.XXXXXX"
}

# xbps fingerprint, as a client shows it when importing the key: MD5 of the public key in
# OpenSSH ssh-rsa form, i.e. ssh-keygen -l -E md5 (the key file must be mode 0600)
fingerprint() {
	ssh-keygen -y -f "$1" | ssh-keygen -l -E md5 -f - | sed -n 's/^[0-9]* MD5:\([0-9a-f:]*\) .*/\1/p'
}

remote_mkdir() {
	case $REMOTE in
	*:*) ssh "${REMOTE%%:*}" mkdir -p "${REMOTE#*:}" ;;
	*) mkdir -p "$REMOTE" ;;
	esac
}

cmd_setup() {
	[ ! -e "$BUILD_DIR" ] || die "$BUILD_DIR already exists"
	git -C "$VOID_PACKAGES" fetch -q "$UPSTREAM" master
	git -C "$VOID_PACKAGES" worktree add -q --detach "$BUILD_DIR" "$UPSTREAM/master"
	"$here/xbps-src" binary-bootstrap
	msg "build worktree ready: $BUILD_DIR"
}

cmd_update() {
	need_build_dir
	git -C "$VOID_PACKAGES" fetch -q "$UPSTREAM" master
	mkdir -p "$BUILD_DIR/hostdir"
	(
		flock 9
		# -f drops the overlay copied in by xbps-src; it copies it again on the next run
		git -C "$BUILD_DIR" checkout -q -f --detach "$UPSTREAM/master"
	) 9> "$BUILD_LOCK"
	"$here/xbps-src" bootstrap-update
	msg "build worktree at $(git -C "$BUILD_DIR" log --oneline -1)"
}

cmd_import() {
	[ $# -eq 2 ] || die "usage: import <branch> <pkg>"
	[ ! -e "$here/srcpkgs/$2" ] || die "srcpkgs/$2 already exists"
	git -C "$VOID_PACKAGES" cat-file -e "$1:srcpkgs/$2/template" 2>/dev/null ||
		die "no srcpkgs/$2/template on branch $1 of $VOID_PACKAGES"
	mkdir -p "$here/srcpkgs"
	git -C "$VOID_PACKAGES" archive "$1" "srcpkgs/$2" | tar -x -C "$here"
	msg "imported srcpkgs/$2 from $1 (subpackage symlinks are not copied)"
}

cmd_build() {
	[ $# -gt 0 ] || die "usage: build <pkg>..."
	for pkg; do need_srcpkg "$pkg"; done
	native=$(xbps-uhelper arch)
	for pkg; do
		for arch in $ARCHS; do
			# noarch: one build serves every arch
			if is_noarch "$pkg" && [ "$arch" != "$native" ]; then
				continue
			fi
			if [ "$arch" = "$native" ]; then set --; else set -- -a "$arch"; fi
			# a template's archs= may exclude this arch (e.g. archs="x86_64")
			if ! "$here/xbps-src" "$@" show-avail "$pkg" > /dev/null 2>&1; then
				msg "skipping $pkg for $arch: not available for that arch"
				continue
			fi
			msg "building $pkg for $arch"
			"$here/xbps-src" "$@" pkg "$pkg"
		done
	done
}

need_remote() {
	[ -n "$REMOTE" ] || die "REMOTE is not set (config.local.sh, see config.local.sh.example)"
}

cmd_pull() {
	need_remote
	mkdir -p "$STAGING"
	remote_mkdir
	rsync -rt --delete "$REMOTE/" "$STAGING/"
	sync_repodata "$REMOTE/" "$STAGING/"
}

# The indexes by content: rsync's quick check (size and mtime in seconds) misses a rewritten
# index of the same size within the same second
sync_repodata() {
	rsync -rtO --checksum --delay-updates --include='*-repodata' --exclude='*' "$1" "$2"
}

# In an order that keeps the served repository consistent for clients: new packages and
# signatures first (names are unique per version, so the quick check is safe), then the
# indexes, then deleting what they no longer list.
# -O: no times on directories, which only their owner may set (shared group directories)
push() {
	for r in "$STAGING"/*-repodata; do
		[ -f "$r" ] || die "no repodata in $STAGING, refusing to upload"
		break
	done
	msg "uploading to $REMOTE"
	rsync -rtO --delay-updates --exclude='*-repodata' "$STAGING/" "$REMOTE/"
	sync_repodata "$STAGING/" "$REMOTE/"
	rsync -rO --delete --existing --ignore-existing "$STAGING/" "$REMOTE/"
	push_site
}

# Website from the staged repodata, uploaded beside the repository directory. No --delete:
# SITE_REMOTE holds the repository directory itself. -O: SITE_REMOTE may belong to another
# user (e.g. root, writable through a group), and only the owner may set its times
push_site() {
	if [ -z "$SITE_REMOTE" ]; then return 0; fi
	sitedir=$(mktemp -d "${TMPDIR:-/tmp}/xbps-fofrweb-site.XXXXXX")
	python3 -I "$here/site/gen.py" --repo "$STAGING" --archs "$ARCHS" \
		--repo-url "$REPO_URL" --source-url "$SOURCE_URL" --srcpkgs "$here/srcpkgs" --out "$sitedir"
	msg "uploading website to $SITE_REMOTE"
	rsync -rtO --checksum --chmod=Fa+r --delay-updates "$sitedir/" "$SITE_REMOTE/"
}

cmd_site() {
	cmd_pull
	push_site
}

# Register the staged packages of one arch (and noarch), drop what is obsolete, sign
index_arch() {
	arch=$1
	set --
	for f in "$STAGING"/*."$arch".xbps "$STAGING"/*.noarch.xbps; do
		if [ -f "$f" ]; then set -- "$@" "$f"; fi
	done
	if [ $# -gt 0 ]; then
		XBPS_TARGET_ARCH=$arch xbps-rindex -a "$@"
	fi
	XBPS_TARGET_ARCH=$arch xbps-rindex -r "$STAGING"
	XBPS_TARGET_ARCH=$arch xbps-rindex -c "$STAGING"
	if [ -f "$STAGING/$arch-repodata" ]; then
		XBPS_TARGET_ARCH=$arch xbps-rindex --sign --signedby "$SIGNED_BY" --privkey "$key" "$STAGING"
	fi
}

sign_packages() {
	set --
	for f in "$STAGING"/*.xbps; do
		if [ -f "$f" ]; then set -- "$@" "$f"; fi
	done
	# existing signatures are kept, only new packages get one
	if [ $# -gt 0 ]; then
		xbps-rindex --sign-pkg --privkey "$key" "$@"
	fi
}

cmd_publish() {
	if [ $# -eq 0 ]; then
		# shellcheck disable=SC2046 # package names contain no whitespace
		set -- $(overlay_pkgs)
	fi
	[ $# -gt 0 ] || die "srcpkgs/ is empty, nothing to publish"
	for pkg; do need_srcpkg "$pkg"; done
	binpkgs=$BUILD_DIR/hostdir/binpkgs
	need_remote
	with_key
	cmd_pull
	found=
	for pkg; do
		for name in $(pkg_names "$pkg"); do
			# repository=nonfree templates land in binpkgs/nonfree/; here it is one repository
			for f in "$binpkgs"/*.xbps "$binpkgs"/nonfree/*.xbps; do
				[ -f "$f" ] && [ "$(file_name "$f")" = "$name" ] || continue
				case " $ARCHS noarch " in *" $(file_arch "$f") "*) ;; *) continue ;; esac
				found=1
				stage "$f"
			done
		done
	done
	[ -n "$found" ] || die "nothing built for: $* (run: $0 build $*)"
	index_sign_push
}

# A package file into the staged repository, unless that pkgver is there already
stage() {
	if [ ! -e "$STAGING/${1##*/}" ]; then
		cp "$1" "$STAGING/"
		msg "adding ${1##*/}"
	fi
}

index_sign_push() {
	for arch in $ARCHS; do index_arch "$arch"; done
	sign_packages
	push
}

# Packages built by .github/workflows/build.yml for a commit on origin/master. Each file must
# carry a GitHub build attestation from that workflow, for that commit, on master, made on a
# GitHub-hosted runner; any failure aborts before anything is staged. Signing stays local.
cmd_release() {
	[ $# -le 1 ] || die "usage: release [<commit>]"
	need_remote
	git -C "$here" fetch -q origin master
	if [ $# -eq 1 ]; then
		sha=$(git -C "$here" rev-parse -q --verify "$1^{commit}") || die "unknown commit: $1"
		run=$("$GH" run list -R "$GH_REPO" --workflow build.yml --commit "$sha" \
			--status success --limit 1 --json databaseId --jq '.[0].databaseId')
		[ -n "$run" ] || die "no successful build.yml run for $sha in $GH_REPO"
	else
		# CI builds only commits that change srcpkgs/, so not necessarily the tip
		line=$("$GH" run list -R "$GH_REPO" --workflow build.yml --branch master \
			--status success --limit 1 --json databaseId,headSha \
			--jq '.[0] | "\(.databaseId) \(.headSha)"')
		[ -n "$line" ] || die "no successful build.yml run on master in $GH_REPO"
		run=${line%% *} sha=${line#* }
	fi
	git -C "$here" merge-base --is-ancestor "$sha" origin/master ||
		die "$sha is not on origin/master: only merged commits are released"
	dldir=$(mktemp -d "${TMPDIR:-/tmp}/xbps-fofrweb-release.XXXXXX")
	msg "downloading packages of CI run $run (commit $sha)"
	"$GH" run download "$run" -R "$GH_REPO" -D "$dldir/run"
	find "$dldir/run" -type f -name '*.xbps' | sort > "$dldir/files"
	[ -s "$dldir/files" ] || die "CI run $run has no packages"
	while read -r f; do
		name=$(file_name "$f")
		case " $ARCHS noarch " in
		*" $(file_arch "$f") "*) ;;
		*) die "${f##*/}: arch $(file_arch "$f") is not in ARCHS" ;;
		esac
		src=$(source_of "$name")
		[ -n "$src" ] || die "${f##*/}: $name is not a package of srcpkgs/"
		"$GH" attestation verify "$f" -R "$GH_REPO" \
			--signer-workflow "$GH_REPO/.github/workflows/build.yml" \
			--source-ref refs/heads/master --source-digest "$sha" \
			--deny-self-hosted-runners > /dev/null ||
			die "attestation failed for ${f##*/}: not verified as built by build.yml from $sha on master"
		msg "verified ${f##*/}"
	done < "$dldir/files"
	with_key
	cmd_pull
	while read -r f; do stage "$f"; done < "$dldir/files"
	index_sign_push
}

cmd_remove() {
	[ $# -gt 0 ] || die "usage: remove <name>..."
	need_remote
	with_key
	cmd_pull
	for name; do
		gone=
		for f in "$STAGING"/*.xbps; do
			if [ -f "$f" ] && [ "$(file_name "$f")" = "$name" ]; then
				rm -f "$f" "$f.sig" "$f.sig2"
				msg "removing ${f##*/}"
				gone=1
			fi
		done
		[ -n "$gone" ] || die "$name is not in the repository"
	done
	for arch in $ARCHS; do index_arch "$arch"; done
	push
}

cmd_list() {
	cmd_pull
	for arch in $ARCHS; do
		printf '%s:\n' "$arch"
		if [ -f "$STAGING/$arch-repodata" ]; then
			XBPS_TARGET_ARCH=$arch xbps-query -i --repository="$STAGING" -Rs '*' | sed 's/^/  /'
		fi
	done
}

cmd_keygen() {
	store=${PASSWORD_STORE_DIR:-$HOME/.password-store}
	[ ! -e "$store/$PASS_ENTRY.gpg" ] || die "$PASS_ENTRY already exists in pass"
	tmpkey=$(runtime_tmp)
	openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$tmpkey"
	pass insert -m "$PASS_ENTRY" < "$tmpkey" > /dev/null
	msg "signing key stored in pass as $PASS_ENTRY"
	printf 'fingerprint: %s\n' "$(fingerprint "$tmpkey")"
}

cmd_fingerprint() {
	with_key
	fingerprint "$key"
}

if [ $# -eq 0 ]; then
	sed -n '/^# Usage:/,/^#$/{/^#$/d;s/^# \{0,1\}//;p;}' "$0"
	exit 2
fi
command=$1
shift
case $command in
setup | update | import | build | publish | release | remove | pull | list | site | keygen | fingerprint)
	"cmd_$command" "$@" ;;
*) die "unknown command: $command (run without arguments for help)" ;;
esac
