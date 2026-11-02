package script

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"

// The conformance suite: every file in testdata/conformance, in name order, each in a
// fresh VM, straight through and in slices of 7 units. Header comments say what to expect.

CONFORMANCE_FILES := #load_directory("testdata/conformance")

Conformance_Expect :: struct {
	lines:  [dynamic]string,
	errors: [dynamic]string,
	limit:  Limit_Kind,
	slice:  i64,
	memory: int,
}

conformance_expect :: proc(src: string) -> (e: Conformance_Expect, ok: bool) {
	e.lines = make([dynamic]string, context.temp_allocator)
	e.errors = make([dynamic]string, context.temp_allocator)
	rest := src
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		if !strings.has_prefix(l, "--! ") {continue}
		body := l[4:]
		switch {
		case strings.has_prefix(body, "expect: "):
			append(&e.lines, body[8:])
		case body == "expect:":
			append(&e.lines, "")
		case strings.has_prefix(body, "error: "):
			append(&e.errors, body[7:])
		case strings.has_prefix(body, "limit: "):
			switch body[7:] {
			case "instructions":
				e.limit = .Instructions
			case "memory":
				e.limit = .Memory
			case "call_depth":
				e.limit = .Call_Depth
			case:
				return e, false
			}
		case strings.has_prefix(body, "slice: "):
			e.slice = strconv.parse_i64(body[7:]) or_return
		case strings.has_prefix(body, "memory: "):
			e.memory = strconv.parse_int(body[8:]) or_return
		case body == "lua":
		case:
			return e, false
		}
	}
	return e, true
}

Conformance_Run :: struct {
	output:  string,
	status:  Run_Status,
	error:   Script_Error,
	text:    string, // the formatted error
	resumes: int,
}

// conformance_run compiles and runs one file with a slice, resuming until it ends.
conformance_run :: proc(name, src: string, slice: i64, memory: int) -> (r: Conformance_Run) {
	config := default_config()
	if memory > 0 {config.limits.memory = memory}
	vm, verr := vm_create(config, context.temp_allocator)
	if verr.kind != .None {
		r.status = .Error
		r.error = verr
		r.text = error_string(verr, context.temp_allocator)
		return
	}
	defer vm_destroy(vm)
	out := strings.builder_make(context.temp_allocator)
	fn, cerr := compile(vm, src, name, allocator = context.temp_allocator)
	if cerr.kind != .None {
		r.status = .Error
		r.error = cerr
		r.text = error_string(cerr, context.temp_allocator)
		return
	}
	res := call(vm, fn, nil, slice, context.temp_allocator)
	for {
		strings.write_string(&out, output_take(vm, context.temp_allocator))
		if res.status != .Suspended {break}
		r.resumes += 1
		res = resume(vm, nil, slice, context.temp_allocator)
	}
	r.output = strings.to_string(out)
	r.status = res.status
	r.error = res.error
	if res.status == .Error {r.text = error_string(res.error, context.temp_allocator)}
	if ok, problem := heap_check(vm); !ok {
		r.status = .Error
		r.text = fmt.tprintf("heap_check: %s", problem)
	}
	return
}

// conformance_check: what is wrong with a run, or "".
conformance_check :: proc(e: Conformance_Expect, r: Conformance_Run) -> string {
	want := strings.builder_make(context.temp_allocator)
	for l in e.lines {
		strings.write_string(&want, l)
		strings.write_byte(&want, '\n')
	}
	if r.output != strings.to_string(want) {
		return fmt.tprintf(
			"output:\n%s\nwanted:\n%s\n%s",
			r.output,
			strings.to_string(want),
			r.text,
		)
	}
	if len(e.errors) == 0 && e.limit == .None {
		if r.status != .Done {return fmt.tprintf("ended %v, not Done:\n%s", r.status, r.text)}
		return ""
	}
	if r.status != .Error {return fmt.tprintf("ended %v, wanted an error", r.status)}
	for want_err in e.errors {
		if !strings.contains(
			r.text,
			want_err,
		) {return fmt.tprintf("error lacks %q:\n%s", want_err, r.text)}
	}
	if e.limit != .None && (r.error.kind != .Limit || r.error.limit != e.limit) {
		return fmt.tprintf("wanted the %v limit, got:\n%s", e.limit, r.text)
	}
	if e.limit == .None &&
	   r.error.kind == .Limit {return fmt.tprintf("unexpected limit fault:\n%s", r.text)}
	return ""
}

@(test)
test_conformance :: proc(t: ^testing.T) {
	files := slice.clone(CONFORMANCE_FILES[:])
	defer delete(files)
	slice.sort_by(files, proc(a, b: runtime.Load_Directory_File) -> bool {return a.name < b.name})
	testing.expectf(
		t,
		len(files) >= 120,
		"%d conformance files; M51a has at least 120",
		len(files),
	)
	for f in files {
		src := string(f.data)
		e, ok := conformance_expect(src)
		if !testing.expectf(t, ok, "%s: a malformed '--!' header", f.name) {continue}
		straight := conformance_run(
			f.name,
			src,
			e.slice if e.slice > 0 else DEFAULT_SLICE,
			e.memory,
		)
		if problem := conformance_check(e, straight); problem != "" {
			testing.expectf(t, false, "%s: %s", f.name, problem)
			continue
		}
		// In slices of 7: the same output and the same end. A file that sets its own slice
		// tests suspension itself.
		if e.slice == 0 {
			sliced := conformance_run(f.name, src, 7, e.memory)
			if problem := conformance_check(e, sliced); problem != "" {
				testing.expectf(t, false, "%s (in slices of 7): %s", f.name, problem)
			}
			testing.expectf(
				t,
				sliced.output == straight.output,
				"%s: slices of 7 changed the output",
				f.name,
			)
		}
		free_all(context.temp_allocator)
	}
}
