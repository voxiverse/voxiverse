package game

import "core:strings"

// Formatted text: & codes, as servers have long written them. &0-&9 and
// &a-&f are the sixteen colours, &#rrggbb any colour, &l bold, &o italic,
// &n underlined, &m struck through, &r back to plain; && is an &. A colour
// clears the styles before it (so "&l&cX" is plain red: write the colour
// first). Anything else after & is just text.
//
// Each part of a line (a tag, a name, a message) is formatted on its own:
// format_join resets between parts, so nobody's formatting runs into the
// next part.

Text_Style :: struct {
	color:     [3]u8,
	colored:   bool, // else the text's default colour
	bold:      bool,
	italic:    bool,
	underline: bool,
	strike:    bool,
}

Span :: struct {
	text:  string, // a slice of the text parsed (escapes: "&" alone)
	style: Text_Style,
}

// Format_Kind: what a code does (permissions name these: chat.format.color...).
Format_Kind :: enum u8 {
	Color, // &0-&f
	Rgb, // &#rrggbb
	Style, // &l &o &n &m
}
Format_Kinds :: bit_set[Format_Kind]
FORMAT_ALL :: Format_Kinds{.Color, .Rgb, .Style}

@(rodata)
FORMAT_COLORS := [16][3]u8 {
	{0x00, 0x00, 0x00},
	{0x00, 0x00, 0xaa},
	{0x00, 0xaa, 0x00},
	{0x00, 0xaa, 0xaa},
	{0xaa, 0x00, 0x00},
	{0xaa, 0x00, 0xaa},
	{0xff, 0xaa, 0x00},
	{0xaa, 0xaa, 0xaa},
	{0x55, 0x55, 0x55},
	{0x55, 0x55, 0xff},
	{0x55, 0xff, 0x55},
	{0x55, 0xff, 0xff},
	{0xff, 0x55, 0x55},
	{0xff, 0x55, 0xff},
	{0xff, 0xff, 0x55},
	{0xff, 0xff, 0xff},
}

// Code: one & code at the start of s (s[0] == '&').
@(private = "file")
Code :: struct {
	length: int, // bytes, & included; 0: not a code
	kind:   Format_Kind,
	escape: bool, // &&
	reset:  bool, // &r
	color:  [3]u8,
	style:  u8, // 'l', 'o', 'n', 'm'
}

@(private = "file")
code_at :: proc(s: string) -> Code {
	if len(s) < 2 {return {}}
	c := s[1]
	switch c {
	case '&':
		return {length = 2, escape = true}
	case '0' ..= '9':
		return {length = 2, kind = .Color, color = FORMAT_COLORS[c - '0']}
	case 'a' ..= 'f':
		return {length = 2, kind = .Color, color = FORMAT_COLORS[c - 'a' + 10]}
	case 'A' ..= 'F':
		return {length = 2, kind = .Color, color = FORMAT_COLORS[c - 'A' + 10]}
	case 'l', 'o', 'n', 'm', 'L', 'O', 'N', 'M':
		return {length = 2, kind = .Style, style = c | 0x20}
	case 'r', 'R':
		return {length = 2, kind = .Style, reset = true}
	case '#':
		if len(s) < 8 {return {}}
		rgb: [3]u8
		for i in 0 ..< 6 {
			d, ok := hex_digit(s[2 + i])
			if !ok {return {}}
			rgb[i / 2] = rgb[i / 2] << 4 | d
		}
		return {length = 8, kind = .Rgb, color = rgb}
	}
	return {}
}

@(private = "file")
hex_digit :: proc(c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// format_parse appends text's spans to out (slices of text; empty spans are
// left out). Codes of kinds not in allowed stay as text.
format_parse :: proc(text: string, out: ^[dynamic]Span, allowed := FORMAT_ALL) {
	style: Text_Style
	start := 0
	flush :: proc(out: ^[dynamic]Span, text: string, style: Text_Style) {
		if len(text) > 0 {append(out, Span{text, style})}
	}
	i := 0
	for i < len(text) {
		if text[i] != '&' {
			i += 1
			continue
		}
		code := code_at(text[i:])
		if code.length == 0 || (!code.escape && code.kind not_in allowed) {
			i += 1
			continue
		}
		if code.escape {
			flush(out, text[start:i + 1], style) // up to and with one &
			i += 2
			start = i
			continue
		}
		flush(out, text[start:i], style)
		i += code.length
		start = i
		switch {
		case code.reset:
			style = {}
		case code.kind == .Color || code.kind == .Rgb:
			style = {
				color   = code.color,
				colored = true,
			}
		case code.style == 'l':
			style.bold = true
		case code.style == 'o':
			style.italic = true
		case code.style == 'n':
			style.underline = true
		case code.style == 'm':
			style.strike = true
		}
	}
	flush(out, text[start:], style)
}

// format_strip: text without its codes (allocated with allocator).
format_strip :: proc(text: string, allocator := context.temp_allocator) -> string {
	spans := make([dynamic]Span, context.temp_allocator)
	format_parse(text, &spans)
	b := strings.builder_make(allocator)
	for s in spans {strings.write_string(&b, s.text)}
	return strings.to_string(b)
}

// format_filter: text with the codes not in allowed escaped, so they show
// as written (a player without the permission for them).
format_filter :: proc(
	text: string,
	allowed: Format_Kinds,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(text) {
		if text[i] != '&' {
			strings.write_byte(&b, text[i])
			i += 1
			continue
		}
		code := code_at(text[i:])
		switch {
		case code.length == 0:
			strings.write_byte(&b, '&') // (text: shown as is either way)
			i += 1
		case code.escape || code.kind in allowed:
			strings.write_string(&b, text[i:i + code.length])
			i += code.length
		case:
			strings.write_string(&b, "&&") // shown as written
			i += 1
		}
	}
	return strings.to_string(b)
}

// format_join: the parts in a row, each formatted on its own (a reset
// before each but the first).
format_join :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for p, i in parts {
		if i > 0 {strings.write_string(&b, "&r")}
		strings.write_string(&b, p)
		// A lone & at the end would take the reset as its code: an & it is.
		trailing := 0
		for trailing < len(p) && p[len(p) - 1 - trailing] == '&' {trailing += 1}
		if trailing % 2 == 1 {strings.write_byte(&b, '&')}
	}
	return strings.to_string(b)
}
