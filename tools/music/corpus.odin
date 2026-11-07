package music_tool

import "core:fmt"
import "core:os"
import "core:strings"

// The corpus list: public-domain MIDI files the ear is calibrated on, listed in
// corpus.txt and downloaded (not committed) into CORPUS_DOWNLOAD_DIR by
// `build music corpus`, each file pinned by its SHA-256.
CORPUS_LIST :: "tools/music/corpus.txt"
CORPUS_DOWNLOAD_DIR :: "build/tools/music-corpus"
CORPUS_BASE_URL :: "https://www.mutopiaproject.org/ftp/"

// The licences a line may carry: Mutopia's "Public Domain" and CC0. Never one
// with a non-commercial (or any other) clause.
CORPUS_LICENCES :: [?]string{"Public Domain", "CC0"}

Corpus_Entry :: struct {
	file:    string, // the path under CORPUS_BASE_URL
	source:  string, // the piece's page, where its licence was read
	licence: string,
	sha256:  string,
}

// corpus_local_name is the name a listed file is saved under: its path with
// "/" as "__" (so two pieces named alike in different folders do not clash).
corpus_local_name :: proc(file: string) -> string {
	s, _ := strings.replace_all(file, "/", "__")
	return s
}

// corpus_parse reads corpus.txt: `file<TAB>source page<TAB>licence<TAB>sha256`
// per line; blank lines and lines starting with # are skipped.
corpus_parse :: proc(text: string) -> (entries: [dynamic]Corpus_Entry, err: string) {
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		if len(strings.trim_space(line)) == 0 || line[0] == '#' {continue}
		cols := strings.split(line, "\t")
		if len(cols) != 4 {
			return nil, fmt.tprintf(
				"line %d: want 4 tab-separated columns, got %d",
				line_no,
				len(cols),
			)
		}
		e := Corpus_Entry{cols[0], cols[1], cols[2], cols[3]}
		if len(e.file) == 0 ||
		   strings.contains(e.file, "..") ||
		   !strings.has_suffix(e.file, ".mid") {
			return nil, fmt.tprintf("line %d: the file must be a .mid path without '..'", line_no)
		}
		if !strings.has_prefix(e.source, "https://") {
			return nil, fmt.tprintf("line %d: the source page must be an https URL", line_no)
		}
		allowed := false
		for l in CORPUS_LICENCES {
			if e.licence == l {allowed = true}
		}
		if !allowed {
			return nil, fmt.tprintf("line %d: licence '%s' is not allowed", line_no, e.licence)
		}
		if !is_sha256_hex(e.sha256) {
			return nil, fmt.tprintf("line %d: the hash must be 64 lowercase hex digits", line_no)
		}
		for prev in entries {
			if prev.file == e.file {
				return nil, fmt.tprintf("line %d: %s is listed twice", line_no, e.file)
			}
		}
		append(&entries, e)
	}
	return entries, ""
}

is_sha256_hex :: proc(s: string) -> bool {
	if len(s) != 64 {return false}
	for c in s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}
	}
	return true
}

// corpus_download fetches every listed file not yet in the directory and checks
// its SHA-256; a mismatch removes the file and fails. Files already present are
// checked too, so a damaged one is fetched again.
corpus_download :: proc() -> bool {
	text, rerr := os.read_entire_file_from_path(CORPUS_LIST, context.allocator)
	if rerr != nil {
		fmt.eprintfln("music: cannot read %s", CORPUS_LIST)
		return false
	}
	entries, perr := corpus_parse(string(text))
	if perr != "" {
		fmt.eprintfln("music: %s: %s", CORPUS_LIST, perr)
		return false
	}
	os.make_directory_all(CORPUS_DOWNLOAD_DIR)
	fetched, ok_all := 0, true
	for e in entries {
		path := strings.concatenate({CORPUS_DOWNLOAD_DIR, "/", corpus_local_name(e.file)})
		if data, err := os.read_entire_file_from_path(path, context.allocator);
		   err == nil && sha256_hex(data) == e.sha256 {
			continue
		}
		url := strings.concatenate({CORPUS_BASE_URL, e.file})
		if !run_command({"curl", "-fsSL", "--retry", "3", "-o", path, url}) {
			fmt.eprintfln("music: cannot fetch %s", url)
			os.remove(path)
			ok_all = false
			continue
		}
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil || sha256_hex(data) != e.sha256 {
			fmt.eprintfln("music: %s does not match its pinned SHA-256: refusing it", e.file)
			os.remove(path)
			ok_all = false
			continue
		}
		fetched += 1
	}
	fmt.printfln(
		"music: corpus: %d files listed, %d fetched, in %s",
		len(entries),
		fetched,
		CORPUS_DOWNLOAD_DIR,
	)
	return ok_all
}
