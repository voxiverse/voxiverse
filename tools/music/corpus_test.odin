package music_tool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
CORPUS_TEXT :: #load("corpus.txt", string)

@(test)
test_corpus_list_parses :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	entries, err := corpus_parse(CORPUS_TEXT)
	testing.expectf(t, err == "", "corpus.txt: %s", err)
	testing.expect(t, len(entries) >= 50, "corpus.txt lists about 60 pieces")
}

@(test)
test_corpus_parse_rejects :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h := strings.repeat("ab", 32)
	good := fmt.tprintf("A/b.mid\thttps://x/1\tPublic Domain\t%s\n", h)
	_, err := corpus_parse(good)
	testing.expect_value(t, err, "")
	bad := []string {
		fmt.tprintf("A/b.mid\thttps://x/1\tPublic Domain\n"),
		fmt.tprintf("A/b.mid\thttps://x/1\tCC-BY-NC\t%s\n", h),
		fmt.tprintf("A/b.mid\thttps://x/1\tPublic Domain\t%s\n", strings.to_upper(h)),
		fmt.tprintf("A/b.mid\thttps://x/1\tPublic Domain\tabc\n"),
		fmt.tprintf("../b.mid\thttps://x/1\tPublic Domain\t%s\n", h),
		strings.concatenate({good, good}),
	}
	for b, i in bad {
		_, e := corpus_parse(b)
		testing.expectf(t, e != "", "bad line %d was accepted", i)
	}
}

// Parses every listed file the download step fetched. Absent directory: the
// step was not run (the Linux CI job runs it first), say so and skip.
@(test)
test_corpus_files_parse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	if !os.is_directory(CORPUS_DOWNLOAD_DIR) {
		fmt.println("music: corpus test skipped: run `./build.sh music corpus` to fetch the files")
		return
	}
	entries, _ := corpus_parse(CORPUS_TEXT)
	for e in entries {
		path := strings.concatenate({CORPUS_DOWNLOAD_DIR, "/", corpus_local_name(e.file)})
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if !testing.expectf(t, err == nil, "%s is missing: run ./build.sh music corpus", path) {
			continue
		}
		testing.expectf(t, sha256_hex(data) == e.sha256, "%s: hash differs from corpus.txt", path)
		_, msg, ok := midi_read(data)
		testing.expectf(t, ok, "%s: %s", path, msg)
	}
}
