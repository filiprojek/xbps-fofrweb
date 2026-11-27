#!/bin/sh
# CI (weekly): ./xbps-src update-check for every source package. For a newer version, a
# branch update/<pkg> from origin/master with version bumped, revision=1 and the checksum
# from xgensum, a pull request (unless one is open already) and a run of check.yml on it:
# pull requests opened with GITHUB_TOKEN don't trigger pull_request workflows, dispatches do.
# When the checksum can't be generated, an issue instead. Needs gh (GH_TOKEN, GH_REPO) and
# a bootstrapped BUILD_DIR (ci/setup.sh), as the builder user in the Void container.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

open_count() { # <gh subcommand: pr|issue> <args>...: number of open matches
	what=$1
	shift
	gh "$what" list --state open "$@" --json number --jq length
}

for d in srcpkgs/*; do
	pkg=${d#srcpkgs/}
	if [ -L "$d" ] || [ ! -f "$d/template" ]; then continue; fi
	out=$(./xbps-src update-check "$pkg" 2>/dev/null || true)
	new=$(printf '%s\n' "$out" | sed -n "s/^$pkg-[^ ]* -> $pkg-//p" | sort -V | tail -n 1)
	[ -n "$new" ] || continue
	case $new in
	*[!A-Za-z0-9._+]*) echo "$pkg: skipping odd version '$new'"; continue ;;
	esac
	branch=update/$pkg
	if [ "$(open_count pr --head "$branch")" != 0 ]; then
		echo "$pkg: $new found, pull request for $branch already open"
		continue
	fi
	echo "$pkg: update to $new"
	git checkout -q -B "$branch" origin/master
	sed -i -e "s/^version=.*/version=$new/" -e 's/^revision=.*/revision=1/' "srcpkgs/$pkg/template"
	if xgensum -i "$pkg"; then
		git commit -q -a -m "$pkg: update to $new."
		git push -q -f origin "$branch"
		gh pr create --base master --head "$branch" --title "$pkg: update to $new" --body \
			"Found by \`xbps-src update-check\` (update-check workflow). Version and checksum are bumped; review the upstream changes and the build before merging."
		gh workflow run check.yml --ref "$branch"
	else
		git checkout -q -- "srcpkgs/$pkg/template"
		title="$pkg: update to $new needs a manual bump"
		if [ "$(open_count issue --search "in:title \"$title\"")" = 0 ]; then
			gh issue create --title "$title" --body \
				"\`xbps-src update-check\` reports $pkg $new, but \`xgensum\` could not generate the checksum (changed distfiles URL or build style?)."
		fi
	fi
	git checkout -q --detach origin/master
done
