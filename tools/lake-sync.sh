#!/bin/sh
# Pull a collector's lake to a local directory, so the analytics tool (or
# DuckDB) reads it: tools/lake-sync.sh user@host:/srv/voxiverse/lake [./lake]
# Files are append-only (an hour's file only grows), so rsync is all it takes.
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <host:/path/to/lake> [local dir]" >&2; exit 2; }
src="$1"
dst="${2:-lake}"
mkdir -p "$dst"
exec rsync -a --partial "${src%/}/" "$dst/"
