package build

import "core:os"
import "core:strings"
import "core:testing"

import "common:limited"

// A parallel job's output reaches its log on every OS, with a real child process (the
// smoke suite's run_parallel tests do not run on Windows). On Windows the log once had
// to be opened inheritable for the child to write to it at all: without that, check's
// formatting step saw every file as empty.
@(test)
test_parallel_job_output_reaches_its_log :: proc(t: ^testing.T) {
	dir := "build/tmp/limited_test"
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	jobs := []limited.Job {
		{cmd = {"odin", "version"}, log = "build/tmp/limited_test/out.log", quiet = true},
		{
			cmd = {"odin", "version"},
			log = "build/tmp/limited_test/split.log",
			errors = "build/tmp/limited_test/split.err",
			quiet = true,
		},
	}
	results := limited.run_parallel(jobs, 2, allocator = context.temp_allocator)
	for job, i in jobs {
		testing.expect_value(t, results[i], limited.Run_Result.Ok)
		out, err := os.read_entire_file_from_path(job.log, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expectf(
			t,
			strings.contains(string(out), "odin version"),
			"%s holds %q, not the child's output",
			job.log,
			string(out),
		)
	}
}
