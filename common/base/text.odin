package base

import "core:fmt"
import "core:strings"

// Text tables: what a player reads, by key, in one table per language, so the words live
// apart from the code that shows them. The engine keeps its own (client/engine/text.odin)
// and each game its own in its shared package (docs/games.md): an enum of keys and the
// English table, [Key]string, formatted with text_format.

// text_format: text with {0}, {1}... replaced by args[0], args[1]... as fmt.print writes
// them (temp allocator); a brace that names no argument stays as it is.
text_format :: proc(text: string, args: ..any) -> string {
	if len(args) == 0 {return text}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '{' {
			if end := strings.index_byte(text[i:], '}'); end > 1 {
				n := 0
				digits := true
				for c in text[i + 1:i + end] {
					if c < '0' || c > '9' {digits = false; break}
					n = n * 10 + int(c - '0')
				}
				if digits && n < len(args) {
					fmt.sbprint(&b, args[n])
					i += end
					continue
				}
			}
		}
		strings.write_byte(&b, text[i])
	}
	return strings.to_string(b)
}

// text_missing: the first key of a table with no text (false: every key has its own), for
// the test every table has.
text_missing :: proc(table: [$K]string) -> (key: K, missing: bool) {
	for text, k in table {if text == "" {return k, true}}
	return
}
