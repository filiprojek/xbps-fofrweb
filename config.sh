# shellcheck shell=sh disable=SC2034
# Settings shared by repo.sh and xbps-src (sourced; $here is the repository). Precedence:
# environment, then config.local.sh (gitignored, see config.local.sh.example), then the
# defaults below.

# shellcheck disable=SC2154 # $here is set by the sourcing script
if [ -f "$here/config.local.sh" ]; then
	# shellcheck source=/dev/null
	. "$here/config.local.sh"
fi

VOID_PACKAGES=${VOID_PACKAGES:-$HOME/void-packages}            # void-packages clone: git objects, upstream remote
UPSTREAM=${UPSTREAM:-origin}                                   # its remote for void-linux/void-packages
BUILD_DIR=${BUILD_DIR:-$HOME/void-packages-fofrweb}            # worktree owned by xbps-src/repo.sh
ARCHS=${ARCHS:-x86_64 aarch64}
STAGING=${STAGING:-$HOME/.local/share/xbps-fofrweb/current}    # local copy of the published repo
REMOTE=${REMOTE:-}                                             # rsync target (host:dir or dir), required to publish
PASS_ENTRY=${PASS_ENTRY:-xbps/signing-key}                     # unencrypted RSA PEM inside pass
SIGNED_BY=${SIGNED_BY:-fofrweb.net xbps repository <admin@fofrweb.net>}
SIGNING_KEY_FILE=${SIGNING_KEY_FILE:-}                         # PEM file to use instead of pass

# Website (site/gen.py), uploaded with every publish/remove. SITE_REMOTE defaults to the
# directory above REMOTE, so the page is at the web root and the repository below it;
# empty (REMOTE without a parent directory, or SITE_REMOTE=) means no website
case ${REMOTE%/} in
*/*) _site_default=${REMOTE%/}; _site_default=${_site_default%/*} ;;
*) _site_default= ;;
esac
SITE_REMOTE=${SITE_REMOTE-$_site_default}
REPO_URL=${REPO_URL:-https://xbps.fofrweb.net/current}         # what clients put into xbps.d
SOURCE_URL=${SOURCE_URL:-https://github.com/fofrweb/xbps-packages}  # this repository on GitHub

# repo.sh release: packages built by GitHub CI, downloaded and verified with the gh CLI
GH=${GH:-gh}
GH_REPO=${GH_REPO:-${SOURCE_URL#https://github.com/}}               # owner/name on GitHub

# Serialises everything that rewrites or builds in the worktree (hostdir is gitignored there)
BUILD_LOCK=$BUILD_DIR/hostdir/.xbps-fofrweb.lock
