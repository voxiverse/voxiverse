package game

import "core:strings"
import "core:testing"

// A game's entity data goes to text and back field by field, by name: a field the text
// lacks stays zero, and what the type does not have, or a value out of a field's range, is
// refused.
@(test)
test_entity_data_round_trip :: proc(t: ^testing.T) {
	Mood :: enum u8 {
		Calm,
		Scared,
		Hungry,
	}
	Gene :: enum u8 {
		A,
		B,
		C,
	}
	Record :: struct {
		mood:  Mood,
		genes: bit_set[Gene;u8],
		home:  [2]i16,
		timer: i32,
		ready: bool,
		speed: f32,
		inner: struct {
			count: u16,
		},
	}
	testing.expect_value(t, entity_data_plain(Record), "")
	testing.expect(t, entity_data_plain(struct {
				name: string,
			}) != "", "a string was taken")
	testing.expect(t, entity_data_plain([80]u8) != "", "a record over the size was taken")
	r := Record {
		mood = .Scared,
		genes = {.A, .C},
		home = {-3, 40},
		timer = -7,
		ready = true,
		speed = 1.5,
		inner = {count = 9},
	}
	b := strings.builder_make(context.temp_allocator)
	entity_data_write(&b, Record, &r, "data")
	text := strings.to_string(b)
	testing.expect_value(
		t,
		text,
		" data.mood=Scared data.genes=5 data.home.0=-3 data.home.1=40 data.timer=-7 data.ready=true data.speed=1.5 data.inner.count=9",
	)
	back: Record
	for field in strings.fields(text, context.temp_allocator) {
		name, _, value := strings.partition(field, "=")
		testing.expectf(
			t,
			entity_data_read(Record, &back, name[len("data."):], value),
			"%s",
			field,
		)
	}
	testing.expect_value(t, back, r)
	testing.expect(t, !entity_data_read(Record, &back, "gone", "1"), "a field the type lacks")
	testing.expect(t, !entity_data_read(Record, &back, "mood", "Angry"), "an enum's unknown name")
	testing.expect(t, !entity_data_read(Record, &back, "home.0", "40000"), "past an i16")
	testing.expect(t, !entity_data_read(Record, &back, "inner.count", "-1"), "below a u16")
}
