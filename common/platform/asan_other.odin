#+build !linux
package platform_common

// asan_set_death_callback: only the Linux build links the sanitizer's callback hook.
asan_set_death_callback :: proc(callback: proc "c" ()) {}
