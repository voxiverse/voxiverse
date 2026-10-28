package sfx

import "base:runtime"
import "core:sync"

import "../../common/game"

@(private = "file")
shared_reg: ^game.Registry
@(private = "file")
shared_once: sync.Once

// test_reg: the base registry, built once for the tests of the package.
test_reg :: proc() -> ^game.Registry {
	sync.once_do(&shared_once, proc() {
		context.allocator = runtime.default_allocator()
		shared_reg = game.registry_base(runtime.default_allocator())
	})
	return shared_reg
}

test_blocks :: proc() -> ^game.Block_Table {
	return &test_reg().blocks
}
