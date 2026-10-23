package gpu

// RenderDoc does not support macOS (use Xcode's Metal debugger with MoltenVK).
@(private)
renderdoc_find_get_api :: proc() -> rawptr {
	return nil
}
