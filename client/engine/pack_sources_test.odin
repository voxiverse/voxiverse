package engine

import "core:fmt"
import "core:os"
import "core:testing"

import "client:steam"

// A subscribed Workshop item is a candidate named by its namespace and its item; with
// Steam off there are none from it.
@(test)
test_workshop_items_are_pack_candidates :: proc(t: ^testing.T) {
	root := "build/test_pack_sources"
	os.remove_all(root)
	defer os.remove_all(root)
	item := fmt.tprintf("%s/77", root)
	testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/wsmod", item)), nil)
	manifest := `{"format": 1, "namespace": "wsmod", "version": "1.0.0", "title": "W", "requires": ["voxiverse"]}`
	testing.expect_value(
		t,
		os.write_entire_file(fmt.tprintf("%s/wsmod/pack.json", item), transmute([]u8)manifest),
		nil,
	)

	c: steam.Client
	testing.expect(t, steam.open_fake(&c, {items = {{77, item}}}))
	defer steam.shutdown(&c)
	found := pack_candidates(&c, context.temp_allocator)
	workshop := 0
	for f in found {
		if f.source.namespace == "wsmod" {
			workshop += 1
			testing.expect_value(t, f.origin, "Workshop item 77")
			testing.expect_value(t, len(f.problems), 0)
		}
	}
	testing.expect_value(t, workshop, 1)

	for f in pack_candidates(nil, context.temp_allocator) {
		testing.expect(t, f.source.namespace != "wsmod", "Steam off still found a Workshop pack")
	}
}
