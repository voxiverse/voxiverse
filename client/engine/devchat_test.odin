package engine

import "core:testing"

import "common:base"

// With the setting empty, or in a benchmark or a check, developer chat never
// starts: no thread, no socket. (Its sending, offline queue and replies are
// the collector package's tests, on the simulated network.)
@(test)
test_devchat_stays_off :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	devchat_sync(app)
	testing.expect(t, !app.devchat.running, "developer chat started with the setting empty")

	base.var_text_set(&app.settings.devchat, "127.0.0.1:27316")
	app.benchmark = true
	devchat_sync(app)
	testing.expect(t, !app.devchat.running, "developer chat started in a benchmark")
	devchat_stop(app)

	_, ok := devchat_endpoint("")
	testing.expect(t, !ok, "an empty address resolved")
	ep, ok2 := devchat_endpoint("127.0.0.1")
	testing.expect(
		t,
		ok2 && ep.port == DEVCHAT_PORT,
		"a bare host did not get the collector's port",
	)
}
