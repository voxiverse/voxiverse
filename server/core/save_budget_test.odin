package core

import "core:os"
import "core:testing"

// The scene: a server holding a lot (200 characters, 512 edited chunks, 100
// chests, 400 entities) saves as a running server does, then blocking. The
// test checks that it works; what it costs the tick is `build bench budgets`
// (server/core/budgets.odin).

@(test)
test_save_200_characters :: proc(t: ^testing.T) {
	dir := scratch_dir("budget")
	defer delete(dir)
	defer os.remove_all(dir)
	r, ok := budget_save(dir, BUDGET_COMMIT_SECONDS)
	testing.expect(t, ok, "the capture failed")
	testing.expect(t, r.committed, "the save never committed")
	testing.expect(t, r.blocking_ok, "the blocking save failed")
}
