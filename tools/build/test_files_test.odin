package build

import "core:testing"

// Two test packages must never share a binary, a log or a timing file: run in parallel
// they overwrite each other (client/music and tools/music did, #101).
@(test)
test_test_packages_keep_their_own_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	seen := make(map[string]string)
	for pkg in TEST_PACKAGES {
		for file in ([]string{test_binary(pkg), test_log(pkg)}) {
			if other, taken := seen[file]; taken {
				testing.expectf(t, false, "%s and %s both keep %s", pkg, other, file)
			}
			seen[file] = pkg
		}
	}
}
