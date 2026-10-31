package fuzz

import "base:runtime"

// Under AddressSanitizer a bad access ends the process in the sanitizer's own report: the
// death callback is where the input is saved first.
asan_death :: proc "c" () {
	context = runtime.default_context()
	crash_hook("AddressSanitizer: a bad access (the report is above)")
}

when .Address in ODIN_SANITIZER_FLAGS {
	foreign import asan_runtime "system:c"

	foreign asan_runtime {
		__sanitizer_set_death_callback :: proc "c" (callback: proc "c" ()) ---
	}

	asan_install :: proc() {
		__sanitizer_set_death_callback(asan_death)
	}
} else {
	asan_install :: proc() {}
}
