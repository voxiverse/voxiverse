#!/bin/sh
# Checks the gdb and lldb Odin printers against the known values in
# printer_test (strings, slices, dynamic arrays, maps incl. a deleted entry
# and over-cell-size values, unions, nil). Skips a debugger that isn't
# installed. Run after Odin upgrades: the map printer mirrors runtime layout.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build
odin build tools/debugger/printer_test -debug -out:build/printer_test
line=$(grep -n 'BREAK HERE' tools/debugger/printer_test/main.odin | cut -d: -f1)
fail=0
expect() { # file text
	grep -qF -- "$2" "$1" || { echo "printers: $1 lacks: $2"; fail=1; }
}
reject() { # file text
	if grep -qF -- "$2" "$1"; then echo "printers: $1 should not show: $2"; fail=1; fi
}

if command -v gdb >/dev/null 2>&1; then
	out=build/printers_gdb.txt
	gdb -q -batch -x tools/debugger/odin_gdb.py -ex "break main.odin:$line" -ex run \
		-ex 'set print pretty off' \
		-ex 'print name' -ex 'print empty' -ex 'print numbers' -ex 'print list' \
		-ex 'print shape' -ex 'print none' -ex 'print lookup' -ex 'print odd' -ex 'print big' \
		-ex 'print dense' \
		build/printer_test >"$out" 2>&1 || true
	expect "$out" '= "voxiverse"'
	expect "$out" '= ""'
	expect "$out" 'len=3 = {1, 2, 3}'
	expect "$out" 'len=3 cap=8 = {"a", "bb", "ccc"}'
	expect "$out" 'struct printer_test::Rect = {w = 2, h = 3}'
	expect "$out" '= nil'
	expect "$out" '["one"] = 1'
	expect "$out" '["two"] = 2'
	expect "$out" '["\001\002\003"] = 123'
	expect "$out" '["\a\b\t"] = 789'
	reject "$out" '\004\005\006'
	expect "$out" '[5] = "*"'
	expect "$out" '$10 = len=6 = {'
	for k in 0 2 4 6 8 10; do expect "$out" "[$((k * 1000))] = $k"; done
	for k in 1 3 5 7 9 11; do reject "$out" "[$((k * 1000))] = $k"; done # deleted (some tombstoned)
	echo "printers: gdb checked ($out)"
else
	echo "printers: gdb not installed, skipped"
fi

if command -v lldb >/dev/null 2>&1; then
	out=build/printers_lldb.txt
	lldb -b -o 'command script import tools/debugger/odin_lldb.py' -o "breakpoint set -f main.odin -l $line" \
		-o run -o 'frame variable name empty numbers list shape none lookup odd big dense' -o kill \
		build/printer_test >"$out" 2>&1 || true
	expect "$out" '(string) name = "voxiverse"'
	expect "$out" '(string) empty = ""'
	expect "$out" '([]int) numbers = len=3'
	expect "$out" '([dynamic]string) list = len=3 cap=8'
	expect "$out" '[2] = "ccc"'
	expect "$out" '(printer_test::Shape) shape = printer_test::Rect'
	expect "$out" '(printer_test::Shape) none = nil'
	expect "$out" '["one"] = 1'
	expect "$out" '["two"] = 2'
	expect "$out" '= 789'
	expect "$out" '= 123'
	reject "$out" '"] = 456' # (the source listing shows the line that sets it)
	expect "$out" '(map[int]int) dense = len=6'
	for k in 0 2 4 6 8 10; do expect "$out" "[$((k * 1000))] = $k"; done
	for k in 1 3 5 7 9 11; do reject "$out" "[$((k * 1000))] = $k"; done
	echo "printers: lldb checked ($out)"
else
	echo "printers: lldb not installed, skipped"
fi
exit $fail
