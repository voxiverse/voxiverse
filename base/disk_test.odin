package base

import "core:fmt"
import "core:os"
import "core:testing"

disk_scratch :: proc(name: string) -> string {
	dir := fmt.aprintf("build/test_disk_%s", name)
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

disk_read :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data) if err == nil else "<none>"
}

@(test)
test_disk_replace_round_trip :: proc(t: ^testing.T) {
	dir := disk_scratch("round")
	defer delete(dir)
	defer os.remove_all(dir)
	d := Disk{}
	path := fmt.tprintf("%s/a.txt", dir)
	testing.expect_value(t, disk_replace(&d, path, transmute([]u8)string("one")), Disk_Error.None)
	testing.expect_value(t, disk_replace(&d, path, transmute([]u8)string("two")), Disk_Error.None)
	testing.expect_value(t, disk_read(path), "two")
	testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", path)), "a temporary file is left")
}

// Torn at every operation, with and without a power cut: the old file or the
// new one, whole.
@(test)
test_disk_replace_is_atomic :: proc(t: ^testing.T) {
	dir := disk_scratch("atomic")
	defer delete(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/a.txt", dir)
	old := make([]u8, 3 * DISK_PIECE / 2) // (a write of two pieces)
	fresh := make([]u8, 2 * DISK_PIECE)
	defer delete(old)
	defer delete(fresh)
	for &b in old {b = 'o'}
	for &b in fresh {b = 'n'}
	sizes := [?]int{0, 0}
	for countdown in 1 ..= 12 {
		for power in 0 ..< 2 {
			d := Disk{}
			disk_replace(&d, path, old)
			faults := Disk_Faults {
				countdown  = countdown,
				rng        = rng_make(u64(countdown * 2 + power)),
				power_loss = power == 1,
			}
			d.faults = &faults
			err := disk_replace(&d, path, fresh)
			got := disk_read(path)
			testing.expectf(
				t,
				got == string(old) || got == string(fresh),
				"countdown %d power %d: the file is neither the old nor the new one (%d bytes)",
				countdown,
				power,
				len(got),
			)
			if got == string(old) {sizes[0] += 1} else {sizes[1] += 1}
			if err == .Crashed {
				testing.expect(t, faults.crashed, "crashed without the flag")
				// A dead process does nothing more.
				testing.expect_value(t, disk_remove(&d, path), Disk_Error.Crashed)
				testing.expect_value(t, disk_read(path) == "<none>", false)
			}
			disk_faults_destroy(&faults)
			os.remove(fmt.tprintf("%s.tmp", path))
		}
	}
	testing.expect(t, sizes[0] > 0 && sizes[1] > 0, "both outcomes should occur")
}

@(test)
test_disk_faults_are_seeded :: proc(t: ^testing.T) {
	dir := disk_scratch("seeded")
	defer delete(dir)
	defer os.remove_all(dir)
	data := make([]u8, 2 * DISK_PIECE)
	defer delete(data)
	lens: [2]int
	for run in 0 ..< 2 {
		faults := Disk_Faults {
			countdown = 2,
			rng       = rng_make(99),
		}
		d := Disk {
			faults = &faults,
		}
		path := fmt.tprintf("%s/f%d", dir, run)
		disk_write(&d, path, data)
		lens[run] = len(disk_read(path))
		disk_faults_destroy(&faults)
	}
	testing.expect_value(t, lens[0], lens[1])
}

@(test)
test_disk_counts_operations :: proc(t: ^testing.T) {
	dir := disk_scratch("count")
	defer delete(dir)
	defer os.remove_all(dir)
	faults := Disk_Faults{}
	d := Disk {
		faults = &faults,
	}
	path := fmt.tprintf("%s/a", dir)
	disk_replace(&d, path, transmute([]u8)string("x"))
	// create, one piece, sync; rename; directory sync.
	testing.expect_value(t, faults.ops, 5)
	testing.expect(t, !faults.crashed, "no fault was set")
	disk_mkdir(&d, fmt.tprintf("%s/sub", dir))
	link := fmt.tprintf("%s/sub/b", dir)
	testing.expect_value(t, disk_link(&d, path, link), Disk_Error.None)
	testing.expect_value(t, disk_read(link), "x")
	testing.expect_value(t, disk_truncate(&d, link, 0), Disk_Error.None)
	testing.expect_value(t, disk_read(link), "")
	testing.expect_value(t, disk_append(&d, link, transmute([]u8)string("yz"), true), Disk_Error.None)
	testing.expect_value(t, disk_read(link), "yz")
	disk_faults_destroy(&faults)
}
