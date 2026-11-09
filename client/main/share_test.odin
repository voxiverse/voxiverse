package main

import "core:strings"
import "core:testing"

import "client:engine"
import "common:game"
import "common:worldgen"

@(test)
test_share_code_earth :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app := f.app
	app.session.state = .Playing
	app.session.welcome.address = game.earth_address()
	// Everest's neighbourhood, as the scratch Earth universe's player would see it.
	cx, cz := worldgen.planet_block_of(27.98, 86.92)
	app.session.prediction.state.position = {f64(cx) + 0.5, 64, f64(cz) + 0.5}
	code := engine.share_code(app)
	testing.expectf(t, strings.has_prefix(code, "@Earth 27.98"), "%q", code)
	parsed, ok := game.share_parse(code)
	testing.expect(t, ok && parsed.earth)
	testing.expectf(
		t,
		abs(parsed.lat - 27.98) < 0.02 && abs(parsed.lon - 86.92) < 0.02,
		"%v, %v",
		parsed.lat,
		parsed.lon,
	)
}

@(test)
test_share_code_alien :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app := f.app
	app.session.state = .Playing
	alien := game.address_derive(0x5eed)
	app.session.welcome.address = alien
	app.session.prediction.state.position = {56.5, 10.0, 40.5}
	code := engine.share_code(app)
	latin := game.address_latin(alien)
	testing.expectf(
		t,
		strings.has_prefix(code, strings.concatenate({"@", latin, " "}, context.temp_allocator)),
		"%q",
		code,
	)
	parsed, ok := game.share_parse(code)
	testing.expect(t, ok && !parsed.earth && parsed.address == alien)
	testing.expect_value(t, parsed.x, 56.5)
	testing.expect_value(t, parsed.y, 10.0)
	testing.expect_value(t, parsed.z, 40.5)
}
