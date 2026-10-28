package game

import "core:hash"
import "core:testing"

@(private = "file")
Seen :: struct {
	records: [dynamic]Journal_Record,
}

@(private = "file")
collect :: proc(user: rawptr, rec: Journal_Record) {
	s := cast(^Seen)user
	append(&s.records, rec)
}

@(private = "file")
sample_segment :: proc(w: ^Writer) {
	journal_write_header(w, {seq = 7, first_age = 123_456_789_012, flags = 0})
	journal_write_record(w, Journal_Tick{age = 100, unix_ms = 1_700_000_000_000})
	journal_write_record(w, Journal_Actor{index = 1, kind = .Character, name = "mallory"})
	journal_write_record(
		w,
		Journal_Action {
			id = 5,
			actor = 1,
			system = .Command,
			age = 100,
			bypass = true,
			command = "fill 1 2 3 4 5 6 stone",
		},
	)
	changes := []Journal_Change {
		{0, .Air, .Stone, 5, .Command},
		{4095, .Stone, .Air, 5, .Liquid},
		{17, .Dirt, .Grass, 3, .Hand},
	}
	journal_write_record(w, Journal_Changes{chunk = {-3, 2, 40}, changes = changes})
	journal_write_record(w, Journal_Save{age = 101})
	journal_write_record(w, Journal_Params{age = 102})
}

@(test)
test_journal_records_round_trip :: proc(t: ^testing.T) {
	w: Writer
	writer_init(&w, context.temp_allocator)
	sample_segment(&w)
	seen := Seen {
		records = make([dynamic]Journal_Record, context.temp_allocator),
	}
	r := journal_read_segment(test_reg(), w.buf[:], collect, &seen)
	testing.expect_value(t, r.status, Segment_Status.Whole)
	testing.expect_value(t, r.valid_bytes, len(w.buf))
	testing.expect_value(t, r.header.seq, 7)
	testing.expect_value(t, r.header.first_age, 123_456_789_012)
	testing.expect_value(t, len(seen.records), 6)
	tick, _ := seen.records[0].(Journal_Tick)
	testing.expect_value(t, tick.unix_ms, 1_700_000_000_000)
	actor, _ := seen.records[1].(Journal_Actor)
	testing.expect_value(t, actor.name, "mallory")
	action, _ := seen.records[2].(Journal_Action)
	testing.expect_value(t, action.command, "fill 1 2 3 4 5 6 stone")
	testing.expect(t, action.bypass && action.system == .Command)
	ch, _ := seen.records[3].(Journal_Changes)
	testing.expect_value(t, ch.chunk, Chunk_Pos{-3, 2, 40})
	testing.expect_value(t, len(ch.changes), 3)
	testing.expect_value(t, ch.changes[1].index, 4095)
	testing.expect_value(t, ch.changes[2].action, 3)
	testing.expect_value(t, ch.changes[2].new, Block.Grass)
}

@(test)
test_journal_cut_at_every_byte :: proc(t: ^testing.T) {
	w: Writer
	writer_init(&w, context.temp_allocator)
	sample_segment(&w)
	// The offsets where a record ends.
	ends := make([dynamic]int, context.temp_allocator)
	for cut in JOURNAL_HEADER_SIZE ..= len(w.buf) {
		r := journal_read_segment(test_reg(), w.buf[:cut], nil)
		if r.status == .Whole {append(&ends, cut)}
	}
	testing.expect_value(t, len(ends), 7) // the header alone, and six records
	for cut in 0 ..< len(w.buf) {
		r := journal_read_segment(test_reg(), w.buf[:cut], nil)
		if cut < JOURNAL_HEADER_SIZE {
			testing.expect_value(t, r.status, Segment_Status.Bad_Header)
			continue
		}
		last := JOURNAL_HEADER_SIZE
		for e in ends {if e <= cut {last = e}}
		testing.expect_value(t, r.valid_bytes, last)
		testing.expect_value(
			t,
			r.status,
			Segment_Status.Whole if last == cut else Segment_Status.Torn,
		)
	}
}

@(test)
test_journal_flipped_bit_refused :: proc(t: ^testing.T) {
	w: Writer
	writer_init(&w, context.temp_allocator)
	sample_segment(&w)
	whole := len(w.buf)
	for i in 0 ..< whole {
		data := make([]u8, whole, context.temp_allocator)
		copy(data, w.buf[:])
		data[i] ~= 0x10
		r := journal_read_segment(test_reg(), data, nil)
		testing.expect(t, r.status != .Whole, "a flipped bit must not read as whole")
		if i >= JOURNAL_HEADER_SIZE {
			testing.expect(t, r.valid_bytes <= i, "the damaged record must not be accepted")
		}
	}
}

@(test)
test_journal_caps :: proc(t: ^testing.T) {
	w: Writer
	writer_init(&w, context.temp_allocator)
	journal_write_header(&w, {seq = 1})
	long := make([]u8, MAX_ACTION_COMMAND + 1, context.temp_allocator)
	for &c in long {c = 'a'}
	testing.expect(t, !journal_write_record(&w, Journal_Action{id = 1, command = string(long)}))
	testing.expect(t, !journal_write_record(&w, Journal_Actor{index = 1, name = string(long)}))
	many := make([]Journal_Change, MAX_CHANGES_PER_RECORD + 1, context.temp_allocator)
	testing.expect(t, !journal_write_record(&w, Journal_Changes{changes = many}))
	testing.expect(t, !journal_write_record(&w, Journal_Changes{}))
	testing.expect(
		t,
		journal_write_record(&w, Journal_Changes{changes = many[:MAX_CHANGES_PER_RECORD]}),
	)
	testing.expect_value(
		t,
		journal_read_segment(test_reg(), w.buf[:], nil).status,
		Segment_Status.Whole,
	)

	// A record that claims too much: a Changes count of 4097 (hand-made).
	bad: Writer
	writer_init(&bad, context.temp_allocator)
	journal_write_header(&bad, {seq = 1})
	payload: Writer
	writer_init(&payload, context.temp_allocator)
	write_svarint(&payload, 0)
	write_svarint(&payload, 0)
	write_svarint(&payload, 0)
	write_varint(&payload, MAX_CHANGES_PER_RECORD + 1)
	start := len(bad.buf)
	write_u8(&bad, u8(Journal_Record_Type.Changes))
	write_varint(&bad, u32(len(payload.buf)))
	append(&bad.buf, ..payload.buf[:])
	write_u32(&bad, crc32_of(bad.buf[start:]))
	r := journal_read_segment(test_reg(), bad.buf[:], nil)
	testing.expect_value(t, r.status, Segment_Status.Torn)
	testing.expect_value(t, r.valid_bytes, JOURNAL_HEADER_SIZE)
}

@(private = "file")
crc32_of :: proc(b: []u8) -> u32 {return hash.crc32(b)}
