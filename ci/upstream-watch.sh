#!/bin/sh
# CI (weekly): which packages of srcpkgs/ now exist in official void-packages? With
# 20-fofrweb.conf clients get the official build of those, so they are candidates for removal
# here. Keeps one issue up to date with the list, and closes it when the list is empty.
# Needs gh (GH_TOKEN, GH_REPO).
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
title="Packages now in official Void"
upstream=repos/void-linux/void-packages/contents/srcpkgs

version_of() { # <template text on stdin>
	sed -n 's/^version=//p' | head -n 1
}

rows=
for d in srcpkgs/*; do
	name=${d#srcpkgs/}
	if [ ! -L "$d" ] && [ ! -f "$d/template" ]; then continue; fi
	src=$name
	if [ -L "$d" ]; then src=$(readlink "$d"); fi
	ours=$(version_of < "srcpkgs/$src/template")
	# a directory comes back as an array, a subpackage symlink as an object with its target
	kind=$(gh api "$upstream/$name" --jq 'if type == "array" then "dir" else .target // .type end' \
		2>/dev/null) || continue
	if [ "$kind" != dir ]; then src=$kind; else src=$name; fi
	theirs=$(gh api "$upstream/$src/template" -H 'Accept: application/vnd.github.raw' | version_of)
	rows="$rows| \`$name\` | $ours | $theirs |
"
done

number=$(gh issue list --state open --search "in:title \"$title\"" --json number --jq '.[0].number // empty')
if [ -z "$rows" ]; then
	echo "no package of srcpkgs/ is in void-packages"
	if [ -n "$number" ]; then
		gh issue close "$number" --comment "None of these packages are in void-packages any more."
	fi
	exit 0
fi

body="These packages of \`srcpkgs/\` now exist in [void-packages](https://github.com/void-linux/void-packages). Clients with \`20-fofrweb.conf\` install the official build, so consider removing them here (\`./repo.sh remove\`, then delete the template).

| Package | Here | void-packages |
|---|---|---|
$rows
Updated by the upstream-watch workflow."
printf '%s' "$rows"
if [ -n "$number" ]; then
	gh issue edit "$number" --body "$body"
else
	gh issue create --title "$title" --body "$body"
fi
