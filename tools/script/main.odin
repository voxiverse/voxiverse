package script_tool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "common:script"

// The script tool.
//
//	build script run <file> [--slice N] [--memory N] [--disasm]
//	build script disasm <file>

usage :: proc() {
	fmt.eprintln("usage: script run <file> [--slice N] [--memory N] [--disasm]")
	fmt.eprintln("       script disasm <file>")
	os.exit(2)
}

main :: proc() {
	args := os.args[1:]
	if len(args) < 2 {usage()}
	command := args[0]
	file := ""
	slice: i64 = script.DEFAULT_SLICE
	memory := script.DEFAULT_LIMITS.memory
	list := false
	for i := 1; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--slice", "--memory":
			if i + 1 >= len(args) {usage()}
			n, ok := strconv.parse_i64(args[i + 1])
			if !ok || n <= 0 {
				fmt.eprintfln("script: %s needs a positive number, got %q", a, args[i + 1])
				os.exit(2)
			}
			if a == "--slice" {slice = n} else {memory = int(n)}
			i += 1
		case "--disasm":
			list = true
		case:
			if strings.has_prefix(a, "--") || file != "" {usage()}
			file = a
		}
	}
	if file == "" {usage()}
	if command != "run" && command != "disasm" {usage()}
	data, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {
		fmt.eprintfln("script: cannot read %s: %v", file, err)
		os.exit(1)
	}
	config := script.default_config()
	config.limits.memory = memory
	vm, verr := script.vm_create(config)
	if verr.kind != .None {
		fmt.eprintln(script.error_string(verr))
		os.exit(1)
	}
	defer script.vm_destroy(vm)
	fn, cerr := script.compile(vm, string(data), file)
	if cerr.kind != .None {
		fmt.eprint(script.error_string(cerr))
		os.exit(1)
	}
	if command == "disasm" || list {
		b := strings.builder_make()
		script.disasm(vm, fn, &b)
		fmt.print(strings.to_string(b))
		if command == "disasm" {return}
	}
	r := script.call(vm, fn, nil, slice)
	for {
		fmt.print(script.output_take(vm, context.temp_allocator))
		free_all(context.temp_allocator)
		if r.status != .Suspended {break}
		r = script.resume(vm, nil, slice)
	}
	if r.status == .Error {
		fmt.eprint(script.error_string(r.error))
		os.exit(1)
	}
}
