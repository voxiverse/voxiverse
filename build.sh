#!/bin/sh
# Voxiverse build entry. Everything lives in tools/build (run `./build.sh help`).
set -eu
cd "$(dirname "$0")"
git config core.hooksPath .githooks 2>/dev/null || true
command -v odin >/dev/null 2>&1 || {
	echo "build: 'odin' not found - install the toolchain with odinup (see README)" >&2
	exit 1
}
mkdir -p build
# The driver is rebuilt when missing or when its sources are newer.
rebuild=0
if [ ! -f build/build-driver ]; then
	rebuild=1
elif [ -n "$(find tools/build -newer build/build-driver 2>/dev/null)" ]; then
	rebuild=1
fi

if [ "$rebuild" -eq 1 ]; then
	# Built under a name of its own and renamed over: another ./build.sh may be
	# starting the old one or building it too, and a rename is atomic where writing
	# over it is not.
	odin build tools/build -out:build/build-driver.new.$$ -collection:client=client -collection:server=server -collection:common=common
	mv -f build/build-driver.new.$$ build/build-driver
fi
exec build/build-driver "$@"
