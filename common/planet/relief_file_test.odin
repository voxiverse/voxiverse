package planet

import "core:os"
import "core:testing"

EARTH_RELIEF :: "assets/planet/earth_relief.bin"

// The hash of the 2 097 152 elevations of assets/planet/earth_relief.bin.
EARTH_RELIEF_HASH :: u64(0xb87d89e12c27e75e)

@(test)
test_earth_relief_file :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(EARTH_RELIEF, context.allocator)
	if err != nil {
		testing.fail_now(
			t,
			"assets/planet/earth_relief.bin is missing (run the tests from the repository root)",
		)
	}
	defer delete(data)
	r, ok := relief_decode(data)
	defer relief_destroy(&r)
	testing.expect(t, ok)
	testing.expect_value(t, r.width, RELIEF_WIDTH)
	testing.expect_value(t, r.height, RELIEF_HEIGHT)
	testing.expect_value(t, len(r.elevation), 2097152)
	testing.expect_value(t, relief_hash(r), EARTH_RELIEF_HASH)

	elevation_at :: proc(r: Relief, lat, lon: f64) -> int {
		i, j := relief_cell_of(r, lat, lon)
		return int(relief_at(r, i, j))
	}
	// Cells average about 20 km: Everest's cell is lower than its summit.
	testing.expect(t, elevation_at(r, 27.99, 86.93) > 5000)
	testing.expect(t, elevation_at(r, 11.35, 142.2) < -7000) // the Mariana trench
	testing.expect(t, elevation_at(r, 31.5, 35.5) < 0) // the Dead Sea

	// Tibet (30-36 N, 80-95 E) averages above 4 500 m.
	sum, n := 0, 0
	for j in 0 ..< r.height {
		lat := relief_cell_lat(r, j)
		if lat < 30 || lat > 36 {continue}
		for i in 0 ..< r.width {
			lon := relief_cell_lon(r, i)
			if lon < 80 || lon > 95 {continue}
			sum += int(relief_at(r, i, j))
			n += 1
		}
	}
	testing.expect(t, n > 0 && sum / n > 4500)
}
