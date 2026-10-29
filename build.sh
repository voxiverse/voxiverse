#!/bin/sh
# Voxiverse build entry. Everything lives in tools/build (run `./build.sh help`).
set -eu
cd "$(dirname "$0")"
command -v odin >/dev/null 2>&1 || {
	echo "build: 'odin' not found - install the toolchain with odinup (see README)" >&2
	exit 1
}
mkdir -p build/cache
# The driver is rebuilt only when what it was built from changed (it keeps the
# content key of its own sources: tools/build/cache.odin).
if ! build/build-driver self-fresh >/dev/null 2>&1; then
	: >build/cache/build-driver.started
	# Built under a name of its own and renamed over: another ./build.sh may be
	# starting the old one or building it too, and a rename is atomic where writing
	# over it is not.
	odin build tools/build -out:build/build-driver.new.$$ \
		-export-dependencies:json -export-dependencies-file:build/cache/build-driver.deps.json
	mv -f build/build-driver.new.$$ build/build-driver
	build/build-driver self-built
fi
exec build/build-driver "$@"
