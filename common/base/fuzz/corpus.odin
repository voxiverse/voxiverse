package fuzz

import "core:fmt"
import "core:os"
import "core:path/filepath"

// The corpus: inputs with distinct outcome signatures, at most CORPUS_MAX in memory.
CORPUS_MAX :: 4096

Corpus :: struct {
	inputs: [dynamic][]u8,
	seen:   map[u64]struct{},
}

corpus_init :: proc(c: ^Corpus) {
	c.inputs = make([dynamic][]u8)
	c.seen = make(map[u64]struct{})
}

corpus_destroy :: proc(c: ^Corpus) {
	for i in c.inputs {delete(i)}
	delete(c.inputs)
	delete(c.seen)
}

// corpus_offer keeps a copy of data if its signature is new; reports whether it did.
corpus_offer :: proc(c: ^Corpus, data: []u8, signature: u64) -> bool {
	if signature in c.seen {return false}
	c.seen[signature] = {}
	if len(c.inputs) >= CORPUS_MAX {return true} 	// counted, not kept
	append(&c.inputs, clone_bytes(data))
	return true
}

clone_bytes :: proc(data: []u8) -> []u8 {
	out := make([]u8, len(data))
	copy(out, data)
	return out
}

// corpus_write writes the corpus out (by hand, to grow the committed seeds).
corpus_write :: proc(c: ^Corpus, dir: string) {
	os.make_directory_all(dir)
	for input, i in c.inputs {
		name := fmt.tprintf("%s-%04d.bin", filepath.base(dir), i)
		_ = os.write_entire_file_from_bytes(join({dir, name}), input)
	}
}
