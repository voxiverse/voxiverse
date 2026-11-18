#+build !darwin
package platform

import "core:sync"
import "core:thread"

import "common:base"

// On the output's own thread: native_audio_start opens the device and
// starts it, native_audio_run feeds it until a.stopping, and
// native_audio_stop closes whatever is open (after a failed start too).
// native_audio_wake ends a wait of the thread's early, and
// native_audio_free, once the thread has ended, frees what outlived it.

@(private)
native_audio_open :: proc(a: ^Audio_Output) -> string {
	a.thread = thread.create_and_start_with_data(a, audio_main, base.thread_context(), .High)
	if a.thread == nil {return audio_fail(a, "could not start the audio thread")}
	sync.sema_wait(&a.ready)
	if a.failure != "" {
		thread.join(a.thread)
		thread.destroy(a.thread)
		native_audio_free(a)
		a.thread = nil
	}
	return a.failure
}

@(private)
native_audio_close :: proc(a: ^Audio_Output) {
	if a.thread == nil {return}
	sync.atomic_store(&a.stopping, true)
	native_audio_wake(a)
	thread.join(a.thread)
	thread.destroy(a.thread)
	native_audio_free(a)
}

@(private = "file")
audio_main :: proc(data: rawptr) {
	base.thread_register("audio")
	defer base.thread_unregister()
	a := (^Audio_Output)(data)
	a.failure = native_audio_start(a)
	failed := a.failure != ""
	if failed {native_audio_stop(a)}
	sync.sema_post(&a.ready) // (a.failure is read, and a may be cleared, after this)
	if failed {return}
	native_audio_run(a)
	native_audio_stop(a)
}
