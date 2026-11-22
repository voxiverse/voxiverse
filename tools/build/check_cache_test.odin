package build

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// The fixture: base under voxel under leaf under leaf/server, other on base alone, and
// loader on no package but the files it #loads (one by name, a folder by a prefix).
@(private = "file")
CACHE_DIR :: "build/tmp/check_cache_test"

@(private = "file")
CACHE_PACKAGES :: []string {
	"common/base",
	"common/voxel",
	"games/leaf",
	"games/leaf/server",
	"games/other",
	"games/loader",
}

@(private = "file")
cache_write :: proc(dir, path, text: string) {
	full := path_join({dir, path})
	os.make_directory_all(filepath.dir(full))
	_ = os.write_entire_file(full, transmute([]u8)text)
}

@(private = "file")
cache_fixture :: proc(dir: string) {
	os.remove_all(dir)
	cache_write(
		dir,
		"common/base/base.odin",
		"package base\n\nvalue :: proc() -> int {return 1}\n",
	)
	cache_write(
		dir,
		"common/voxel/voxel.odin",
		"package voxel\n\nimport \"common:base\"\n\nsize :: proc() -> int {return base.value() + 1}\n",
	)
	cache_write(
		dir,
		"games/leaf/leaf.odin",
		"package leaf\n\nimport \"common:voxel\"\n\nleaf :: proc() -> int {return voxel.size()}\n",
	)
	cache_write(
		dir,
		"games/leaf/server/server.odin",
		"package leaf_server\n\nimport \"games:leaf\"\n\nserve :: proc() -> int {return leaf.leaf()}\n",
	)
	cache_write(
		dir,
		"games/other/other.odin",
		"package other\n\nimport \"common:base\"\n\nother :: proc() -> int {return base.value()}\n",
	)
	cache_write(
		dir,
		"games/loader/loader.odin",
		"package loader\n\nNAME :: \"a.txt\"\nDATA :: #load(\"data.txt\")\nASSET :: #load(\"assets/\" + NAME)\n",
	)
	cache_write(dir, "games/loader/data.txt", "data")
	cache_write(dir, "games/loader/assets/a.txt", "a")
}

// cache_jobs: a check job a fixture package, through the fixture's collections.
@(private = "file")
cache_jobs :: proc(dir: string) -> []Check_Job {
	jobs := make([]Check_Job, len(CACHE_PACKAGES))
	for pkg, i in CACHE_PACKAGES {
		folder := path_join({dir, pkg})
		jobs[i] = Check_Job {
			label  = folder,
			pkg    = folder,
			target = host_target(),
			cmd    = slice.clone(
				[]string {
					"odin",
					"check",
					folder,
					"-no-entry-point",
					"-vet",
					strings.concatenate({"-collection:common=", dir, "/common"}),
					strings.concatenate({"-collection:games=", dir, "/games"}),
				},
			),
		}
	}
	return jobs
}

// cache_changed: the fixture packages whose job inputs differ from before's, read afresh.
@(private = "file")
cache_changed :: proc(dir: string, before: []Digest) -> []string {
	inputs := check_inputs_make()
	changed := make([dynamic]string)
	for job, i in cache_jobs(dir) {
		d, exact := job_inputs_digest(&inputs, job.pkg, job.cmd)
		if !exact || d != before[i] {append(&changed, job.pkg[len(dir) + 1:])}
	}
	return changed[:]
}

@(private = "file")
cache_digests :: proc(dir: string) -> []Digest {
	inputs := check_inputs_make()
	digests := make([]Digest, len(CACHE_PACKAGES))
	for job, i in cache_jobs(dir) {
		exact: bool
		digests[i], exact = job_inputs_digest(&inputs, job.pkg, job.cmd)
		assert(exact, job.pkg)
	}
	return digests
}

// A job's inputs change exactly when a file it reads does: its own package's, a package
// it imports however far down, a file it #loads, a file in a folder it #loads by prefix.
// Nothing changed is nothing to check again; a leaf changes it and what imports it;
// common/base changes everything over it.
@(test)
test_check_inputs_follow_imports_and_loads :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := CACHE_DIR + "/inputs"
	cache_fixture(dir)
	defer os.remove_all(dir)
	expect_changed :: proc(
		t: ^testing.T,
		dir: string,
		before: []Digest,
		want: []string,
		what: string,
	) {
		got := cache_changed(dir, before)
		testing.expectf(t, slice.equal(got, want), "%s: %v changed, not %v", what, got, want)
	}
	before := cache_digests(dir)
	expect_changed(t, dir, before, {}, "nothing edited")

	cache_write(
		dir,
		"games/leaf/leaf.odin",
		"package leaf\n\nimport \"common:voxel\"\n\nleaf :: proc() -> int {return voxel.size() + 1}\n",
	)
	expect_changed(t, dir, before, {"games/leaf", "games/leaf/server"}, "a leaf edited")

	before = cache_digests(dir)
	cache_write(
		dir,
		"common/base/base.odin",
		"package base\n\nvalue :: proc() -> int {return 2}\n",
	)
	expect_changed(
		t,
		dir,
		before,
		{"common/base", "common/voxel", "games/leaf", "games/leaf/server", "games/other"},
		"common/base edited",
	)

	before = cache_digests(dir)
	cache_write(dir, "common/base/more.odin", "package base\n")
	expect_changed(
		t,
		dir,
		before,
		{"common/base", "common/voxel", "games/leaf", "games/leaf/server", "games/other"},
		"a file added to common/base",
	)

	before = cache_digests(dir)
	cache_write(dir, "games/loader/data.txt", "data changed")
	expect_changed(t, dir, before, {"games/loader"}, "a #loaded file edited")
	before = cache_digests(dir)
	cache_write(dir, "games/loader/assets/a.txt", "a changed")
	expect_changed(t, dir, before, {"games/loader"}, "a file under a #load prefix edited")
	before = cache_digests(dir)
	cache_write(dir, "games/loader/assets/b.txt", "b")
	expect_changed(t, dir, before, {"games/loader"}, "a file added under a #load prefix")

	// A #load whose path starts with no literal cannot be followed: never skipped.
	cache_write(dir, "games/other/load.odin", "package other\n\nPATH :: \"x\"\nX :: #load(PATH)\n")
	inputs := check_inputs_make()
	jobs := cache_jobs(dir)
	for job in jobs {
		_, exact := job_inputs_digest(&inputs, job.pkg, job.cmd)
		testing.expectf(
			t,
			exact == (job.pkg != path_join({dir, "games/other"})),
			"%s: exact %v",
			job.pkg,
			exact,
		)
	}
}

// The reading of a source file is not thrown off by a quote in a character literal or a
// comment, finds an import's path past a comment or a line break, and takes no other
// literal for one.
@(test)
test_source_refs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	refs := source_refs(
		"c := '\"'\n// don't \"\n/* a /* nested */ \" */\nimport b \"common:base\"\nimport /* c */\n\t\"common:voxel\"\nimport \"rel\"\nS :: \"common:game\"\nX :: #load_directory(`dir`)\nY :: #load(\"pre/\" + Z)\n",
	)
	testing.expect(
		t,
		slice.equal(refs.collection_paths[:], []string{"common:base", "common:voxel"}),
		"the imports through a collection, and no other literal",
	)
	testing.expect(t, slice.equal(refs.imports[:], []string{"rel"}), "the relative import")
	testing.expect_value(t, len(refs.loads), 2)
	if len(refs.loads) == 2 {
		testing.expect_value(t, refs.loads[0], Load_Ref{"dir", false})
		testing.expect_value(t, refs.loads[1], Load_Ref{"pre/", true})
	}
	testing.expect(t, refs.exact)
	testing.expect(t, !source_refs("X :: #load(NAME)\n").exact, "a load from a constant")
	testing.expect(t, !source_refs("X :: #load(\"a\" /* x */ )\n").exact, "a comment in a load")
}

// Passes are kept whole: a digest with leading zeros reads back as written.
@(test)
test_check_passes_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	path := CACHE_DIR + "/passes/passes"
	os.make_directory_all(filepath.dir(path))
	defer os.remove_all(filepath.dir(path))
	passes := check_passes_read(path, false)
	append(&passes.now, Digest(0x0f), Digest(1) << 127)
	check_passes_write(&passes, path)
	again := check_passes_read(path, false)
	testing.expect(t, again.before[0x0f] && again.before[Digest(1) << 127], "a pass lost")
	testing.expect_value(t, len(again.order), 2)
}

// End to end, with the compiler: what passed is not checked again; an edit to a
// dependency that breaks the package over it fails that package, whose own files did not
// change, and a failure is never kept, so it fails again.
@(test)
test_check_cached_catches_a_break_through_a_dependency :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := CACHE_DIR + "/cached"
	cache_fixture(dir)
	defer os.remove_all(dir)
	passes := check_passes_read("", false)
	ok, ran := check_cached(cache_jobs(dir), &passes)
	testing.expect(t, ok, "the fixture fails")
	testing.expect_value(t, ran, len(CACHE_PACKAGES))

	again := Check_Passes{}
	for d in passes.now {again.before[d] = true}
	ok, ran = check_cached(cache_jobs(dir), &again)
	testing.expect(t, ok)
	testing.expect_value(t, ran, 0)

	// voxel adds 1 to base.value(), other returns it as an int: it is a string now. Only
	// common/base is edited, and what is over it fails, again and again.
	cache_write(
		dir,
		"common/base/base.odin",
		"package base\n\nvalue :: proc() -> string {return \"1\"}\n",
	)
	for want in ([]int{5, 4}) {
		retry := Check_Passes{}
		for d in again.now {retry.before[d] = true}
		jobs := cache_jobs(dir)
		ok, ran = check_cached(jobs, &retry)
		testing.expect(t, !ok, "a break in common/voxel through common/base passed")
		testing.expect_value(t, ran, want) // all but the loader, then all but base, which passed
		for job in jobs {
			if job.pkg == path_join({dir, "common/voxel"}) {
				testing.expect(t, !slice.contains(retry.now[:], job.inputs), "a failure kept")
			}
		}
		again = retry
	}

	// --all runs every job, passed or not.
	all := Check_Passes {
		all = true,
	}
	for d in passes.now {all.before[d] = true}
	cache_write(
		dir,
		"common/base/base.odin",
		"package base\n\nvalue :: proc() -> int {return 1}\n",
	)
	ok, ran = check_cached(cache_jobs(dir), &all)
	testing.expect(t, ok)
	testing.expect_value(t, ran, len(CACHE_PACKAGES))
}

// A per-file check (the format check, the source lints) skips a file only as it passed
// it: the same contents, path, kind and driver, and never with --all.
@(test)
test_file_passed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	passes := Check_Passes {
		driver = 7,
		known  = true,
	}
	text := transmute([]u8)string("package a\n")
	d, passed := file_passed(&passes, "lint source client", "client/a/a.odin", text)
	testing.expect(t, !passed, "passed with nothing kept")
	file_pass(&passes, d)
	again := Check_Passes {
		driver = 7,
		known  = true,
	}
	for kept in passes.now {again.before[kept] = true}
	_, passed = file_passed(&again, "lint source client", "client/a/a.odin", text)
	testing.expect(t, passed, "not skipped as it passed")
	edited := transmute([]u8)string("package a // edited\n")
	_, passed = file_passed(&again, "lint source client", "client/a/a.odin", edited)
	testing.expect(t, !passed, "skipped with its contents edited")
	_, passed = file_passed(&again, "lint source server", "client/a/a.odin", text)
	testing.expect(t, !passed, "skipped for another check")
	_, passed = file_passed(&again, "lint source client", "client/b/a.odin", text)
	testing.expect(t, !passed, "skipped at another path")
	again.driver = 8
	_, passed = file_passed(&again, "lint source client", "client/a/a.odin", text)
	testing.expect(t, !passed, "skipped by another driver")
	again.driver, again.all = 7, true
	_, passed = file_passed(&again, "lint source client", "client/a/a.odin", text)
	testing.expect(t, !passed, "skipped with --all")
	unknown := Check_Passes{}
	d, passed = file_passed(&unknown, "lint source client", "client/a/a.odin", text)
	testing.expect(t, !passed && d == 0, "skipped or kept with the driver unread")
}
