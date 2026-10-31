package engine

import "client:platform"
import "core:strings"

TOAST_MAX :: 4

Toast :: struct {
	text:     string, // heap
	age:      f32,
	on_click: proc(app: ^App), // nil: not clickable
}

Toasts :: struct {
	list: [dynamic]Toast, // oldest first
}

// toast shows a notice (a Text key and its arguments); on_click runs when it is clicked.
toast :: proc(app: ^App, key: Text, args: ..any, on_click: proc(app: ^App) = nil) {
	toast_push(&app.toasts, tr(key, ..args), on_click)
}

toast_push :: proc(t: ^Toasts, text: string, on_click: proc(app: ^App) = nil) {
	append(&t.list, Toast{text = strings.clone(text), on_click = on_click})
	for len(t.list) > TOAST_MAX {
		delete(t.list[0].text)
		ordered_remove(&t.list, 0)
	}
}

// open_screenshots: the folder the screenshots go in, in the file manager.
open_screenshots :: proc(app: ^App) {
	platform.open_folder(path_next_to_exe("screenshots"))
}
