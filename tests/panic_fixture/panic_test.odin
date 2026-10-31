package panic_fixture

// Not run with the smoke suite: smoke's test_panic_in_a_server_thread_fails_fast runs it on
// purpose. A test with a server running whose worker thread panics must fail the run in
// seconds, not spin (voxiverse#54).

import "common:base"
import "core:testing"
import "core:time"
import "server:core"

@(test)
test_worker_panics_with_a_server_running :: proc(t: ^testing.T) {
	config := core.Config {
		seed        = 3,
		view_radius = 2,
		view_height = 1,
		workers     = 1,
	}
	s: core.Server
	if !testing.expect(t, core.start(&s, config, {})) {return}
	defer core.stop(&s)
	jobs: base.Jobs
	base.jobs_init(&jobs, "fixture", 2)
	defer base.jobs_destroy(&jobs)
	base.jobs_submit(&jobs, proc(_: rawptr) {panic("the worker panics on purpose")}, nil)
	time.sleep(60 * time.Second) // the run must end long before this
}
