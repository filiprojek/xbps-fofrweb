#!/bin/sh
# Source packages changed between two commits, one per line: every srcpkgs/<name>/... path
# that differs counts for <name>; a subpackage symlink counts for its source package;
# packages without a template at <head> (deleted) are skipped. Reads git objects only, so the
# working tree may be anywhere. Feed the result to ./xbps-src sort-dependencies.
#
# Usage: ci/changed.sh <base> <head>     (run inside the repository)
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <base> <head>" >&2; exit 2; }
base=$1 head=$2

git diff --name-only --no-renames "$base" "$head" -- srcpkgs/ |
	cut -d/ -f2 | sort -u |
	while read -r name; do
		[ -n "$name" ] || continue
		# a symlink in the tree is mode 120000; its blob is the target
		if git ls-tree "$head" "srcpkgs/$name" | grep -q '^120000 '; then
			name=$(git cat-file -p "$head:srcpkgs/$name")
		fi
		if git cat-file -e "$head:srcpkgs/$name/template" 2>/dev/null; then
			printf '%s\n' "$name"
		fi
	done | sort -u
