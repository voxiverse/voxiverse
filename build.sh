#!/bin/sh
# Voxiverse build entry. Everything lives in tools/build (run `./build.sh help`).
set -eu
cd "$(dirname "$0")"
command -v odin >/dev/null 2>&1 || {
	echo "build: 'odin' not found - install the toolchain with odinup (see README)" >&2
	exit 1
}
mkdir -p build
odin build tools/build -out:build/build-driver
exec build/build-driver "$@"
