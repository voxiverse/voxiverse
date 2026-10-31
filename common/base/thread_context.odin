package base

import "base:runtime"
import "core:fmt"
import "core:os"

// thread_context is the context a thread we start should run in: the caller's
// own, except that under `odin test` a panic or failed assert on that thread ends
// the process. The runner's own assertion proc traps, and its signal handler
// ignores a trap on a thread the runner did not start (it returns, the trap
// runs again, and the thread spins at full CPU for ever, voxiverse#54), so a
// test's server, worker or writer thread must never inherit it.
thread_context :: proc() -> runtime.Context {
	ctx := context
	when ODIN_TEST {
		ctx.assertion_failure_proc = thread_assertion_failure
	}
	return ctx
}

@(private = "file")
thread_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	fmt.eprintfln("%s: %s (%v)", prefix, message, loc)
	fmt.eprintln("a thread outside the test runner failed: ending the run")
	os.exit(2)
}
