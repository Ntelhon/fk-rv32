#!/usr/bin/env bash
# Shallow-fetch a git repository at a pinned ref (tag or commit) with submodules.
#   fetch-src.sh <url> <ref> <dir>
# Does nothing if <dir> already exists.
set -euo pipefail

url=$1 ref=$2 dir=$3

if [ -e "$dir" ]; then
  echo "fetch-src: $dir already exists, skipping"
  exit 0
fi

tmp="$dir.tmp.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$(dirname "$dir")"
git init -q "$tmp"
git -C "$tmp" remote add origin "$url"
echo "fetch-src: $url @ $ref"
git -C "$tmp" fetch -q --depth 1 origin "$ref"
git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
git -C "$tmp" submodule -q update --init --recursive --depth 1
mv "$tmp" "$dir"
trap - EXIT
