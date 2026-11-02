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

// A failed package's report names its first error line, not the log's head.
@(test)
test_failure_excerpt_leads_with_the_first_error_line :: proc(t: ^testing.T) {
	log := "[INFO ] --- runner start\n[INFO ] pad connect\n[ERROR] [x_test.odin:9:test_a()] expected 1\n[ERROR] second\n[INFO ] tail"
	text := failure_excerpt(log, 1)
	testing.expect(
		t,
		strings.has_prefix(
			text,
			"first error line: [ERROR] [x_test.odin:9:test_a()] expected 1\n",
		),
		text,
	)
	testing.expect(t, strings.contains(text, "--- 2 error lines ---"), text)
	testing.expect(t, strings.contains(text, "[INFO ] tail"), text)
}

// A log with no cause line says so, and gives the status or the kill.
@(test)
test_failure_excerpt_without_error_line_says_so :: proc(t: ^testing.T) {
	log := "[INFO ] start\n[INFO ] pad connect\n"
	text := failure_excerpt(log, 11)
	testing.expect(t, strings.contains(text, "NO ERROR LINE"), text)
	testing.expect(t, strings.contains(text, "exit status 11"), text)
	text = failure_excerpt(log, -1)
	testing.expect(t, strings.contains(text, "NO ERROR LINE"), text)
	testing.expect(t, strings.contains(text, "time limit"), text)
}

// run_parallel reports a job's exit status through Job.status.
@(test)
test_parallel_job_reports_exit_status :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := "build/tmp/limited_status"
		os.make_directory_all(dir)
		defer os.remove_all(dir)
		status := -2
		jobs := []limited.Job {
			{
				cmd = {"sh", "-c", "exit 3"},
				log = "build/tmp/limited_status/a.log",
				quiet = true,
				status = &status,
			},
		}
		results := limited.run_parallel(jobs, 1, allocator = context.temp_allocator)
		testing.expect_value(t, results[0], limited.Run_Result.Failed)
		testing.expect_value(t, status, 3)
	}
}

// A run that dies with nothing said still names the tests it was running.
@(test)
test_failure_excerpt_names_the_unfinished_tests :: proc(t: ^testing.T) {
	log := "[INFO ] start\n[INFO ] Test #0 p.a changed state to Running.\n[INFO ] Test #1 p.b changed state to Running.\n[INFO ] Test #0 p.a changed state to Successful.\n[INFO ] Test #2 p.c changed state to Running.\n"
	text := failure_excerpt(log, 6)
	testing.expect(t, strings.contains(text, "(2)"), text)
	testing.expect(t, strings.contains(text, "  p.b\n  p.c\n"), text)
	testing.expect(t, !strings.contains(text, "  p.a\n"), text)
}
