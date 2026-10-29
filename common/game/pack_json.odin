package game

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Pack JSON: RFC 8259 plus // and /* */ comments and trailing commas, nothing
// else. Every value keeps its line and column (1-based, columns in bytes) so a
// pack's errors can point at the text. Objects keep their keys in source order
// (a slice, never a map), so nothing depends on map order. The reader is our
// own scanner: the refusals (unquoted keys, single quotes, JSON5 numbers, a
// key twice) need exact messages and positions.

JSON_MAX_DEPTH :: 32
JSON_MAX_STRING :: 4096
JSON_MAX_ENTRIES :: 4096
JSON_MAX_FILE :: 1 << 20

Json_Kind :: enum u8 {
	Null,
	Bool,
	Int,
	Float,
	String,
	Array,
	Object,
}

Json_Value :: struct {
	kind:    Json_Kind,
	line:    i32,
	column:  i32,
	b:       bool,
	i:       i64,
	f:       f64, // Int values set it too
	s:       string,
	items:   []Json_Value, // Array
	members: []Json_Member, // Object
}

Json_Member :: struct {
	key:        string,
	key_line:   i32,
	key_column: i32,
	value:      Json_Value,
}

Json_Error :: struct {
	line:    i32,
	column:  i32,
	message: string,
}

@(private = "file")
Json_Reader :: struct {
	text:      string,
	pos:       int,
	line:      i32,
	line_from: int, // offset of the current line's first byte
	err:       Json_Error,
	failed:    bool,
}

// json_parse: text as one value. On failure the error says what and where; the
// values are allocated with allocator.
json_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	value: Json_Value,
	err: Json_Error,
	ok: bool,
) {
	context.allocator = allocator
	r := Json_Reader {
		text = text,
		line = 1,
	}
	if len(text) > JSON_MAX_FILE {
		return {},
			{1, 1, fmt.aprintf("file is %d bytes; the limit is %d", len(text), JSON_MAX_FILE)},
			false
	}
	if strings.has_prefix(text, "\xEF\xBB\xBF") {r.pos = 3}
	value = json_read_value(&r, 1)
	if !r.failed {
		json_skip(&r)
		if !r.failed && r.pos < len(text) {
			json_fail(&r, "text after the value; a file holds one value")
		}
	}
	if r.failed {return {}, r.err, false}
	return value, {}, true
}

@(private = "file")
json_col :: proc(r: ^Json_Reader) -> i32 {
	return i32(r.pos - r.line_from) + 1
}

@(private = "file")
json_fail :: proc(r: ^Json_Reader, message: string, line: i32 = 0, column: i32 = 0) {
	if r.failed {return}
	r.failed = true
	r.err = {
		line    = line if line > 0 else r.line,
		column  = column if column > 0 else json_col(r),
		message = message,
	}
}

// json_skip: white space and comments.
@(private = "file")
json_skip :: proc(r: ^Json_Reader) {
	for r.pos < len(r.text) && !r.failed {
		c := r.text[r.pos]
		switch {
		case c == '\n':
			r.pos += 1
			r.line += 1
			r.line_from = r.pos
		case c == ' ' || c == '\t' || c == '\r':
			r.pos += 1
		case c == '/' && r.pos + 1 < len(r.text) && r.text[r.pos + 1] == '/':
			for r.pos < len(r.text) && r.text[r.pos] != '\n' {r.pos += 1}
		case c == '/' && r.pos + 1 < len(r.text) && r.text[r.pos + 1] == '*':
			line, col := r.line, json_col(r)
			r.pos += 2
			closed := false
			for r.pos < len(r.text) {
				if r.text[r.pos] == '*' && r.pos + 1 < len(r.text) && r.text[r.pos + 1] == '/' {
					r.pos += 2
					closed = true
					break
				}
				if r.text[r.pos] == '\n' {
					r.line += 1
					r.line_from = r.pos + 1
				}
				r.pos += 1
			}
			if !closed {json_fail(r, "comment is never closed; end it with */", line, col)}
		case:
			return
		}
	}
}

@(private = "file")
json_read_value :: proc(r: ^Json_Reader, depth: int) -> (v: Json_Value) {
	json_skip(r)
	if r.failed {return}
	v.line, v.column = r.line, json_col(r)
	if r.pos >= len(r.text) {
		json_fail(r, "the text ends where a value should be; write a value")
		return
	}
	if depth > JSON_MAX_DEPTH {
		json_fail(r, fmt.aprintf("nested deeper than %d levels; flatten it", JSON_MAX_DEPTH))
		return
	}
	c := r.text[r.pos]
	switch {
	case c == '{':
		return json_read_object(r, depth)
	case c == '[':
		return json_read_array(r, depth)
	case c == '"':
		s, ok := json_read_string(r)
		if ok {v.kind, v.s = .String, s}
		return
	case c == '\'':
		json_fail(r, "strings use double quotes")
		return
	case c == '-' || (c >= '0' && c <= '9') || c == '+' || c == '.':
		return json_read_number(r, v)
	}
	word_end := r.pos
	for word_end < len(r.text) && json_ident_byte(r.text[word_end]) {word_end += 1}
	word := r.text[r.pos:word_end]
	switch word {
	case "true":
		r.pos = word_end
		v.kind, v.b = .Bool, true
	case "false":
		r.pos = word_end
		v.kind = .Bool
	case "null":
		r.pos = word_end
		v.kind = .Null
	case "Infinity", "NaN":
		json_fail(r, "numbers are plain decimals")
	case:
		if word == "" {
			json_fail(r, fmt.aprintf("unexpected %q; write a value", r.text[r.pos:][:1]))
		} else {
			json_fail(r, fmt.aprintf("unexpected %q; strings are quoted", word))
		}
	}
	return
}

@(private = "file")
json_ident_byte :: proc(c: u8) -> bool {
	return(
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '_' ||
		c == '$' \
	)
}

@(private = "file")
json_read_number :: proc(r: ^Json_Reader, v: Json_Value) -> Json_Value {
	v := v
	start := r.pos
	end := start
	for end < len(r.text) {
		c := r.text[end]
		if (c >= '0' && c <= '9') ||
		   c == '.' ||
		   c == '-' ||
		   c == '+' ||
		   c == 'e' ||
		   c == 'E' ||
		   c == 'x' ||
		   c == 'X' ||
		   (c >= 'a' && c <= 'f') ||
		   (c >= 'A' && c <= 'F') {
			end += 1
		} else {
			break
		}
	}
	text := r.text[start:end]
	// RFC 8259: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
	i := 0
	n := len(text)
	if i < n && text[i] == '-' {i += 1}
	digits := i
	if i < n && text[i] == '0' {
		i += 1
	} else {
		for i < n && text[i] >= '0' && text[i] <= '9' {i += 1}
	}
	valid := i > digits
	is_float := false
	if valid && i < n && text[i] == '.' {
		i += 1
		f0 := i
		for i < n && text[i] >= '0' && text[i] <= '9' {i += 1}
		valid = i > f0
		is_float = true
	}
	if valid && i < n && (text[i] == 'e' || text[i] == 'E') {
		i += 1
		if i < n && (text[i] == '+' || text[i] == '-') {i += 1}
		e0 := i
		for i < n && text[i] >= '0' && text[i] <= '9' {i += 1}
		valid = i > e0
		is_float = true
	}
	if !valid || i != n {
		json_fail(r, "numbers are plain decimals")
		return v
	}
	r.pos = end
	if is_float {
		f, _ := strconv.parse_f64(text)
		v.kind, v.f = .Float, f
		return v
	}
	neg := text[0] == '-'
	mag := text[1:] if neg else text
	um := u64(0)
	ok := true
	for d in transmute([]u8)mag {
		dv := u64(d - '0')
		if um > (max(u64) - dv) / 10 {
			ok = false
			break
		}
		um = um * 10 + dv
	}
	if !ok || (neg && um > 1 << 63) || (!neg && um >= 1 << 63) {
		json_fail(r, "integer does not fit in 64 bits; use a smaller number", v.line, v.column)
		return v
	}
	iv := i64(0) - i64(um) if neg else i64(um)
	v.kind, v.i, v.f = .Int, iv, f64(iv)
	return v
}

@(private = "file")
json_read_string :: proc(r: ^Json_Reader) -> (s: string, ok: bool) {
	line, col := r.line, json_col(r)
	r.pos += 1 // the quote
	b: strings.Builder
	strings.builder_init(&b)
	for {
		if r.pos >= len(r.text) || r.text[r.pos] == '\n' {
			json_fail(r, "string is never closed; end it with a double quote", line, col)
			return
		}
		c := r.text[r.pos]
		if c == '"' {
			r.pos += 1
			break
		}
		if c < 0x20 {
			json_fail(r, "a control character in a string; write it as an escape")
			return
		}
		if c == '\\' {
			r.pos += 1
			if r.pos >= len(r.text) {continue}
			e := r.text[r.pos]
			switch e {
			case '"', '\\', '/':
				strings.write_byte(&b, e)
			case 'b':
				strings.write_byte(&b, 8)
			case 'f':
				strings.write_byte(&b, 12)
			case 'n':
				strings.write_byte(&b, 10)
			case 'r':
				strings.write_byte(&b, 13)
			case 't':
				strings.write_byte(&b, 9)
			case 'u':
				if r.pos + 4 >= len(r.text) {
					json_fail(r, "\\u needs four hex digits")
					return
				}
				code, hex_ok := strconv.parse_u64_of_base(r.text[r.pos + 1:][:4], 16)
				if !hex_ok {
					json_fail(r, "\\u needs four hex digits")
					return
				}
				strings.write_rune(&b, rune(code))
				r.pos += 4
			case:
				json_fail(r, fmt.aprintf("\\%c is not an escape; write \\\\ for a backslash", e))
				return
			}
			r.pos += 1
			continue
		}
		strings.write_byte(&b, c)
		r.pos += 1
		if strings.builder_len(b) > JSON_MAX_STRING {
			json_fail(
				r,
				fmt.aprintf("string is over %d bytes; shorten it", JSON_MAX_STRING),
				line,
				col,
			)
			return
		}
	}
	str := strings.to_string(b)
	if !utf8.valid_string(str) {
		json_fail(r, "string is not valid UTF-8", line, col)
		return
	}
	return str, true
}

@(private = "file")
json_read_array :: proc(r: ^Json_Reader, depth: int) -> (v: Json_Value) {
	v.kind = .Array
	v.line, v.column = r.line, json_col(r)
	r.pos += 1
	items: [dynamic]Json_Value
	for {
		json_skip(r)
		if r.failed {return}
		if r.pos >= len(r.text) {
			json_fail(r, "the array is never closed; end it with ]", v.line, v.column)
			return
		}
		if r.text[r.pos] == ']' {
			r.pos += 1
			break
		}
		if len(items) >= JSON_MAX_ENTRIES {
			json_fail(r, fmt.aprintf("array has over %d entries; split it", JSON_MAX_ENTRIES))
			return
		}
		append(&items, json_read_value(r, depth + 1))
		if r.failed {return}
		json_skip(r)
		if r.failed {return}
		if r.pos < len(r.text) && r.text[r.pos] == ',' {
			r.pos += 1
		} else if r.pos < len(r.text) && r.text[r.pos] != ']' {
			json_fail(r, "expected , or ]; separate the entries with commas")
			return
		}
	}
	v.items = items[:]
	return
}

@(private = "file")
json_read_object :: proc(r: ^Json_Reader, depth: int) -> (v: Json_Value) {
	v.kind = .Object
	v.line, v.column = r.line, json_col(r)
	r.pos += 1
	members: [dynamic]Json_Member
	for {
		json_skip(r)
		if r.failed {return}
		if r.pos >= len(r.text) {
			json_fail(r, "the object is never closed; end it with }", v.line, v.column)
			return
		}
		if r.text[r.pos] == '}' {
			r.pos += 1
			break
		}
		if len(members) >= JSON_MAX_ENTRIES {
			json_fail(r, fmt.aprintf("object has over %d keys; split it", JSON_MAX_ENTRIES))
			return
		}
		m: Json_Member
		m.key_line, m.key_column = r.line, json_col(r)
		switch c := r.text[r.pos]; {
		case c == '"':
			key, ok := json_read_string(r)
			if !ok {return}
			m.key = key
		case c == '\'':
			json_fail(r, "strings use double quotes")
			return
		case json_ident_byte(c):
			end := r.pos
			for end < len(r.text) && json_ident_byte(r.text[end]) {end += 1}
			json_fail(r, fmt.aprintf("keys are quoted: write \"%s\"", r.text[r.pos:end]))
			return
		case:
			json_fail(r, "expected a key in double quotes")
			return
		}
		for prev in members {
			if prev.key == m.key {
				json_fail(
					r,
					fmt.aprintf("\"%s\" is given twice (first on line %d)", m.key, prev.key_line),
					m.key_line,
					m.key_column,
				)
				return
			}
		}
		json_skip(r)
		if r.failed {return}
		if r.pos >= len(r.text) || r.text[r.pos] != ':' {
			json_fail(r, "expected : after the key")
			return
		}
		r.pos += 1
		m.value = json_read_value(r, depth + 1)
		if r.failed {return}
		append(&members, m)
		json_skip(r)
		if r.failed {return}
		if r.pos < len(r.text) && r.text[r.pos] == ',' {
			r.pos += 1
		} else if r.pos < len(r.text) && r.text[r.pos] != '}' {
			json_fail(r, "expected , or }; separate the entries with commas")
			return
		}
	}
	v.members = members[:]
	return
}
