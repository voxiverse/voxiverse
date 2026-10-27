package server

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../common/game"

// pack_read_dir: a pack's directory as files in memory, for game.registry_build.
// The directory's name is the pack's namespace. Symlinks are refused (a pack
// reads only what is inside its directory), and so are files past the limits
// registry_build would refuse anyway (they are not read at all).
pack_read_dir :: proc(
	dir: string,
	allocator := context.allocator,
) -> (
	src: game.Pack_Source,
	errs: []game.Pack_Error,
) {
	context.allocator = allocator
	clean := strings.trim_right(dir, "/\\")
	src.namespace = filepath.base(clean)
	files := make([dynamic]game.Pack_File)
	problems := make([dynamic]game.Pack_Error)
	total := 0
	pack_walk(clean, "", src.namespace, &files, &problems, &total)
	src.files = files[:]
	return src, problems[:]
}

@(private = "file")
pack_walk :: proc(
	root, rel, ns: string,
	files: ^[dynamic]game.Pack_File,
	problems: ^[dynamic]game.Pack_Error,
	total: ^int,
) {
	here := root if rel == "" else strings.concatenate({root, "/", rel}, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(here, context.temp_allocator)
	if err != nil {
		append(
			problems,
			game.Pack_Error {
				pack = ns,
				message = fmt.aprintf("cannot read the directory: %v", err),
			},
		)
		return
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for e in entries {
		path :=
			e.name if rel == "" else strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		#partial switch e.type {
		case .Symlink:
			append(
				problems,
				game.Pack_Error {
					pack = ns,
					file = path,
					message = "is a symbolic link; a pack holds plain files and directories only",
				},
			)
		case .Directory:
			if len(files) >= game.MAX_PACK_FILES {return}
			pack_walk(root, path, ns, files, problems, total)
		case .Regular:
			if len(files) >= game.MAX_PACK_FILES {
				append(
					problems,
					game.Pack_Error {
						pack = ns,
						message = fmt.aprintf(
							"over %d files; the limit is %d",
							game.MAX_PACK_FILES,
							game.MAX_PACK_FILES,
						),
					},
				)
				return
			}
			if e.size > game.JSON_MAX_FILE || total^ + int(e.size) > game.MAX_PACK_BYTES {
				// Not read: say so here, the registry would refuse it too.
				append(
					problems,
					game.Pack_Error {
						pack = ns,
						file = path,
						message = fmt.aprintf(
							"file is %d bytes; the limits are %d for a file and %d for a pack",
							e.size,
							game.JSON_MAX_FILE,
							game.MAX_PACK_BYTES,
						),
					},
				)
				continue
			}
			data, read_err := os.read_entire_file(e.fullpath, context.allocator)
			if read_err != nil {
				append(
					problems,
					game.Pack_Error {
						pack = ns,
						file = path,
						message = fmt.aprintf("cannot be read: %v", read_err),
					},
				)
				continue
			}
			total^ += len(data)
			append(files, game.Pack_File{path, data})
		case:
			append(
				problems,
				game.Pack_Error {
					pack = ns,
					file = path,
					message = "is not a plain file or directory",
				},
			)
		}
	}
}
