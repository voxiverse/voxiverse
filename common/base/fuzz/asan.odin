package fuzz

import "base:runtime"

import platform "common:platform"

// Under AddressSanitizer a bad access ends the process in the sanitizer's own report: the
// death callback is where the input is saved first.
asan_death :: proc "c" () {
	context = runtime.default_context()
	crash_hook("AddressSanitizer: a bad access (the report is above)")
}

asan_install :: proc() {
	platform.asan_set_death_callback(asan_death)
}
