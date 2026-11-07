package planet

import "core:os"
import "core:slice"
import "core:testing"

EARTH_CLIMATE :: "assets/planet/earth_climate.bin"

// test_earth_climate_file: the committed climate file decodes to exactly what planet_build
// and rivers_build make from the committed relief (stale means: run `./build.sh planet
// climate`).
@(test)
test_earth_climate_file :: proc(t: ^testing.T) {
	rdata, rerr := os.read_entire_file(EARTH_RELIEF, context.allocator)
	if rerr != nil {testing.fail_now(t, "assets/planet/earth_relief.bin is missing")}
	defer delete(rdata)
	relief, rok := relief_decode(rdata)
	defer relief_destroy(&relief)
	testing.expect(t, rok)
	data, err := os.read_entire_file(EARTH_CLIMATE, context.allocator)
	if err != nil {testing.fail_now(t, "assets/planet/earth_climate.bin is missing")}
	defer delete(data)

	p, rv, ok := climate_decode(data, relief)
	defer planet_destroy(&p)
	defer rivers_destroy(&rv)
	if !ok {
		testing.fail_now(
			t,
			"earth_climate.bin does not decode for the relief: stale, run ./build.sh planet climate",
		)
	}

	q := planet_build(relief)
	defer planet_destroy(&q)
	r := rivers_build(q.land, q.precip)
	defer rivers_destroy(&r)
	testing.expect_value(t, planet_hash(p), planet_hash(q))
	testing.expect(t, slice.equal(p.land.land_fraction, q.land.land_fraction))
	testing.expect(t, slice.equal(p.land.elevation, q.land.elevation))
	testing.expect(t, slice.equal(p.land.is_land, q.land.is_land))
	testing.expect(t, slice.equal(p.land.large_ocean, q.land.large_ocean))
	testing.expect(t, slice.equal(p.land.continentality, q.land.continentality))
	for m in 0 ..< 12 {
		testing.expect(t, slice.equal(p.temp.month[m], q.temp.month[m]))
		testing.expect(t, slice.equal(p.precip.month[m], q.precip.month[m]))
		testing.expect(t, slice.equal(p.winds[m], q.winds[m]))
	}
	testing.expect(t, slice.equal(p.koppen, q.koppen))
	testing.expect(t, slice.equal(rv.filled, r.filled))
	testing.expect(t, slice.equal(rv.next, r.next))
	testing.expect(t, slice.equal(rv.flow, r.flow))
	testing.expect(t, slice.equal(rv.lake, r.lake))
}

// test_climate_file_rejects: a file for another relief, another version or a damaged one
// does not decode.
@(test)
test_climate_file_rejects :: proc(t: ^testing.T) {
	relief := relief_make(64, 32)
	defer relief_destroy(&relief)
	for i in 0 ..< len(relief.elevation) {relief.elevation[i] = i16(i % 50 * 40 - 500)}
	p := planet_build(relief)
	defer planet_destroy(&p)
	rv := rivers_build(p.land, p.precip)
	defer rivers_destroy(&rv)
	data := climate_encode(relief, p, rv)
	defer delete(data)

	q, r, ok := climate_decode(data, relief)
	testing.expect(t, ok)
	testing.expect_value(t, planet_hash(q), planet_hash(p))
	planet_destroy(&q)
	rivers_destroy(&r)

	other := relief_make(64, 32)
	defer relief_destroy(&other)
	_, _, ok = climate_decode(data, other)
	testing.expect(t, !ok, "another relief")
	_, _, ok = climate_decode(data[:len(data) - 1], relief)
	testing.expect(t, !ok, "truncated")
	_, _, ok = climate_decode(data[:10], relief)
	testing.expect(t, !ok, "header cut")
	bad := slice.clone(data)
	defer delete(bad)
	bad[4] = 9
	_, _, ok = climate_decode(bad, relief)
	testing.expect(t, !ok, "another version")
}
