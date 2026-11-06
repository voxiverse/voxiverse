package main

import "core:fmt"
import "core:os"
import "core:testing"

import "client:engine"
import "client:ui"

CRASH_ROOT :: "build/test/crash_offer"

// crash_offer_setup: a title screen over a crashes directory holding the named bundles.
@(private = "file")
crash_offer_setup :: proc(f: ^Overlay_Fixture, names: []string) {
	os.remove_all(CRASH_ROOT)
	for n in names {os.make_directory_all(fmt.tprintf("%s/%s", CRASH_ROOT, n))}
	f.app.session = nil
	f.app.screen = .Title
	engine.crash_offer_root(f.app, CRASH_ROOT)
	pad_connect(f.app, .Xbox) // (focus shows once a pad is the device)
}

@(private = "file")
seen :: proc(name: string) -> bool {
	return os.exists(fmt.tprintf("%s/%s/seen", CRASH_ROOT, name))
}

@(test)
test_an_unseen_bundle_opens_the_dialog_and_close_marks_it :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer os.remove_all(CRASH_ROOT)
	crash_offer_setup(&f, {"2026-01-01_10-00-00-1"})
	engine.crash_offer_update(f.app)
	testing.expect(t, engine.overlay_is_open(&f.app.overlays, .Crash_Report), "no dialog")
	pad_frame(f.app)
	testing.expect_value(t, ui.focused_label(&f.app.ui), "Close")
	_, found := ui.find_widget(&f.app.ui, "Open folder")
	testing.expect(t, found, "no Open folder button")

	pad_tap(f.app, .A) // (Close is lit)
	testing.expect(t, !engine.overlay_is_open(&f.app.overlays, .Crash_Report))
	testing.expect(t, seen("2026-01-01_10-00-00-1"), "no seen file")

	// A second start shows nothing.
	f.app.crash_offer.checked = false
	engine.crash_offer_update(f.app)
	testing.expect(t, !engine.overlay_is_open(&f.app.overlays, .Crash_Report), "shown twice")
}

@(test)
test_several_unseen_bundles_name_the_newest_and_the_rest :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer os.remove_all(CRASH_ROOT)
	crash_offer_setup(
		&f,
		{"2026-01-01_10-00-00-1", "2026-03-01_10-00-00-3", "2026-02-01_10-00-00-2"},
	)
	engine.crash_offer_update(f.app)
	o := &f.app.crash_offer
	testing.expect_value(t, o.earlier, 2)
	testing.expect_value(t, string(o.newest[:o.newest_n]), CRASH_ROOT + "/2026-03-01_10-00-00-3")
	pad_frame(f.app)
	pad_tap(f.app, .A)
	for n in ([]string{"2026-01-01_10-00-00-1", "2026-02-01_10-00-00-2", "2026-03-01_10-00-00-3"}) {
		testing.expectf(t, seen(n), "%s was left unseen", n)
	}
}

@(test)
test_the_crash_dialog_is_reachable_and_closable_by_pad :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer os.remove_all(CRASH_ROOT)
	crash_offer_setup(&f, {"2026-01-01_10-00-00-1"})
	engine.crash_offer_update(f.app)
	pad_frame(f.app)
	testing.expect_value(t, ui.focused_label(&f.app.ui), "Close")
	pad_go(f.app, .Left)
	testing.expect_value(t, ui.focused_label(&f.app.ui), "Open folder")
	pad_go(f.app, .Right)
	testing.expect_value(t, ui.focused_label(&f.app.ui), "Close")
	pad_tap(f.app, .B) // B closes it as Escape does
	testing.expect(t, !engine.overlay_is_open(&f.app.overlays, .Crash_Report))
	testing.expect(t, seen("2026-01-01_10-00-00-1"), "B did not mark it seen")
}

@(test)
test_no_dialog_for_scripts_or_without_bundles :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer os.remove_all(CRASH_ROOT)
	crash_offer_setup(&f, {})
	engine.crash_offer_update(f.app)
	testing.expect(t, !engine.overlay_is_open(&f.app.overlays, .Crash_Report), "shown for none")
	crash_offer_setup(&f, {"2026-01-01_10-00-00-1"})
	f.app.scripted = true
	engine.crash_offer_update(f.app)
	testing.expect(t, !engine.overlay_is_open(&f.app.overlays, .Crash_Report), "shown to a script")
}
