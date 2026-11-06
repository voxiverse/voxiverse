package console

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "client:engine"
import "client:steam"

// workshop_publish <namespace>: publish the pack in the local packs folder to the Steam
// Workshop (docs/packs.md, "Workshop packs"). Its title, description and preview come from
// the pack itself (steam.workshop_publish_info).
register_workshop_command :: proc(c: ^engine.Console) {
	console_register(
		c,
		{
			"workshop_publish",
			"workshop_publish <namespace>: publish a pack of the local packs folder to the Steam Workshop",
			proc(app: ^engine.App, args: []string) {
				print :: proc(app: ^engine.App, text: string) {
					engine.console_print(&app.console, text, .Warning)
				}
				namespace := args[0]
				if namespace == "" ||
				   strings.contains_any(namespace, "/\\:") ||
				   namespace == ".." ||
				   namespace == "." {
					print(
						app,
						"workshop_publish: the namespace is a pack's folder name, nothing more",
					)
					return
				}
				if !steam.on(&app.steam) {
					print(
						app,
						"workshop_publish: Steam is off; there is no Workshop to publish to",
					)
					return
				}
				local := engine.local_packs_dir()
				if local == "" {
					print(app, "workshop_publish: the user data folder is unknown")
					return
				}
				folder := filepath.join({local, namespace}, context.temp_allocator) or_else ""
				info, reason := steam.workshop_publish_info(folder, context.temp_allocator)
				if reason != "" {
					print(app, fmt.tprintf("workshop_publish: %s", reason))
					return
				}
				if !steam.workshop_publish(&app.steam, info) {
					print(
						app,
						fmt.tprintf(
							"workshop_publish: %s was not published; the log says why",
							namespace,
						),
					)
					return
				}
				engine.console_print(
					&app.console,
					fmt.tprintf("workshop_publish: %s published as \"%s\"", namespace, info.title),
				)
			},
		},
		args = {1, 1},
	)
}
