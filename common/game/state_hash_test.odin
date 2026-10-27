package game

import "core:strings"
import "core:testing"

@(private = "file")
Inner :: struct {
	x: f32,
	n: [2]i16,
}

@(private = "file")
Sample :: struct {
	a:     u8,
	b:     u64, // (padding between a and b)
	inner: Inner,
	flag:  bool,
	items: []Inner,
	name:  string,
	maybe: Maybe(i32),
}

@(private = "file")
hash_of :: proc(v: ^Sample) -> u64 {
	h := hasher_make()
	hash_value(&h, v^)
	return hasher_finish(h)
}

@(test)
test_hash_changes_with_any_field :: proc(t: ^testing.T) {
	items := []Inner{{1, {2, 3}}, {4, {5, 6}}}
	base_value := Sample{1, 2, {3, {4, 5}}, true, items, "hi", 7}
	want := hash_of(&base_value)
	testing.expect_value(t, hash_of(&base_value), want)
	mutate :: proc(t: ^testing.T, v: Sample, want: u64, what: string) {
		v := v
		testing.expectf(t, hash_of(&v) != want, "hash did not change with %s", what)
	}
	v := base_value
	v.a = 9; mutate(t, v, want, "a")
	v = base_value; v.b = 3; mutate(t, v, want, "b")
	v = base_value; v.inner.x = 4; mutate(t, v, want, "inner.x")
	v = base_value; v.inner.n[1] = 0; mutate(t, v, want, "inner.n[1]")
	v = base_value; v.flag = false; mutate(t, v, want, "flag")
	v = base_value; v.items = items[:1]; mutate(t, v, want, "items length")
	v = base_value; v.name = "ho"; mutate(t, v, want, "name")
	v = base_value; v.maybe = nil; mutate(t, v, want, "maybe")
	other := []Inner{{1, {2, 3}}, {4, {5, 7}}}
	v = base_value; v.items = other; mutate(t, v, want, "an element")
}

@(test)
test_hash_negative_zero :: proc(t: ^testing.T) {
	a, b := f32(0), f32(0)
	b = -b
	ha, hb := hasher_make(), hasher_make()
	hash_value(&ha, a)
	hash_value(&hb, b)
	testing.expect(t, hasher_finish(ha) != hasher_finish(hb), "-0 and 0 hash alike")
}

@(test)
test_hash_ignores_padding :: proc(t: ^testing.T) {
	a, b: Sample
	raw_a, raw_b := ([^]u8)(&a), ([^]u8)(&b)
	for i in 0 ..< size_of(Sample) {raw_a[i], raw_b[i] = 0x00, 0xff}
	a = {1, 2, {3, {4, 5}}, true, nil, "", nil}
	b = {1, 2, {3, {4, 5}}, true, nil, "", nil}
	// (assigning a whole value may leave the padding as it was: set bytes again)
	raw_b[1] = 0x55
	testing.expect_value(t, hash_of(&a), hash_of(&b))
}

@(test)
test_hash_map_is_refused_with_path :: proc(t: ^testing.T) {
	Holder :: struct {
		inner: struct {
			table: map[int]int,
		},
	}
	// (not testing.expect_assert_message: its capture kills the runner on Windows)
	testing.expect_value(
		t,
		hash_refusal(Holder{}, "root"),
		"state hash: root.inner.table is a map: hash it by hand, in sorted order",
	)
	testing.expect_value(t, hash_refusal(Sample{}), "")
}

@(test)
test_dump_names_paths :: proc(t: ^testing.T) {
	items := []Inner{{1, {2, 3}}, {1.1, {5, 6}}}
	v := Sample{1, 2, {3, {4, 5}}, true, items, "hi", 7}
	b := strings.builder_make(context.temp_allocator)
	dump_value(&b, "s", v)
	text := strings.to_string(b)
	testing.expect(t, strings.contains(text, "s.a = 0x1 (1)\n"), text)
	testing.expect(t, strings.contains(text, "s.inner.n.y = 0x5 (5)\n"), text)
	testing.expect(t, strings.contains(text, "s.items[1].x = 0x3f8ccccd (1.1)\n"), text)
	testing.expect(t, strings.contains(text, "s.items.len = 2\n"), text)
}
