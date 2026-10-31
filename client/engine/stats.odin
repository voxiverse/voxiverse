package engine

import "common:game"
import "core:strings"
import "core:time"

// Stats_Data: the page of counters the server last sent.
Stats_Data :: struct {
	lines: [dynamic]string, // "name value" (heap)
	page:  int,
	pages: int,
}

stats_data_clear :: proc(d: ^Stats_Data) {
	for l in d.lines {delete(l)}
	clear(&d.lines)
}

// stats_data_take keeps a Stats_Page.
stats_data_take :: proc(d: ^Stats_Data, p: game.Stats_Page) {
	stats_data_clear(d)
	d.page, d.pages = int(p.page), int(p.pages)
	rest := p.text
	for line in strings.split_lines_iterator(&rest) {
		if len(line) > 0 {append(&d.lines, strings.clone(line))}
	}
}

Stats_View :: struct {
	filter:   [dynamic]u8,
	asked:    string, // the filter last asked for (heap)
	asked_at: time.Tick,
	page:     int,
	first:    int, // the first row shown
	selected: int, // the row the pad's focus is on
	expanded: map[string]bool, // heap, keys owned
}
