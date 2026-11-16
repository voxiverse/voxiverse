package stopwatch

import "common:base"

// What Stopwatch's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Line, // {0}: your time, {1}: the record
	Line_Holder, // {0}: your time, {1}: the record, {2}: who broke it last
}

TEXT_EN := [Text]string {
	.Line        = "Stopwatch  {0}   record {1}",
	.Line_Holder = "Stopwatch  {0}   record {1} ({2})",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
