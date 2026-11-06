package platform_common

when .Address in ODIN_SANITIZER_FLAGS {
	foreign import asan_runtime "system:c"

	foreign asan_runtime {
		__sanitizer_set_death_callback :: proc "c" (callback: proc "c" ()) ---
	}

	// asan_set_death_callback makes AddressSanitizer call callback before the process ends in
	// its own report (the fuzz harness saves the input there).
	asan_set_death_callback :: proc(callback: proc "c" ()) {
		__sanitizer_set_death_callback(callback)
	}
} else {
	asan_set_death_callback :: proc(callback: proc "c" ()) {}
}
