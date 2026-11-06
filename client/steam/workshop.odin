package steam

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "common:game"
import "server:packs"

// The Workshop (docs/packs.md, "Workshop packs"): the packs a player subscribed to, as one
// more pack source beside the local packs folder, and publishing a local pack. With Steam
// off there is no Workshop: both answer "nothing".
//
// Nothing a Workshop item holds is trusted more than a local pack: its folder is read by
// server/packs (symlinks and size limits refused) and the result goes through the same
// registry build, so a malformed item fails with the errors a local pack would.

MAX_WORKSHOP_ITEMS :: 256

// The item folder holds the pack as a sub-folder named by its namespace (Steam names the
// item's own folder by its id, and a pack's directory name is its namespace).
PREVIEW_FILE :: "preview.png"
MAX_PREVIEW_BYTES :: 1 << 20 // Steam's own limit for a preview image

Workshop_Item :: struct {
	id:  u64,
	dir: string, // the folder Steam installed it in
}

// Workshop_Pack: a pack read from a subscribed item.
Workshop_Pack :: struct {
	item:   u64,
	source: game.Pack_Source,
}

// Publish: what a pack publishes with. The strings are the caller's.
Publish :: struct {
	folder:      string, // the local pack's folder
	title:       string,
	description: string,
	preview:     string, // path of the preview image, "" when the pack has none
}

// workshop_items: the subscribed items that are installed. Strings are in `allocator`.
workshop_items :: proc(c: ^Client, allocator := context.allocator) -> []Workshop_Item {
	out := make([dynamic]Workshop_Item, allocator)
	switch c.kind {
	case .Off:
	case .Real:
		r := &c.real
		if r.ugc == nil || r.ugc_count == nil || r.ugc_subscribed == nil {break}
		if r.ugc_install_info == nil {break}
		ids: [MAX_WORKSHOP_ITEMS]u64
		n := int(r.ugc_subscribed(r.ugc, &ids[0], MAX_WORKSHOP_ITEMS))
		for id in ids[:min(n, MAX_WORKSHOP_ITEMS)] {
			folder: [1024]u8
			size: u64
			stamp: u32
			if !r.ugc_install_info(r.ugc, id, &size, &folder[0], len(folder), &stamp) {continue}
			end := 0
			for end < len(folder) && folder[end] != 0 {end += 1}
			append(&out, Workshop_Item{id, strings.clone(string(folder[:end]), allocator)})
		}
	case .Fake:
		for it in c.fake.script.items[:min(len(c.fake.script.items), MAX_WORKSHOP_ITEMS)] {
			append(&out, Workshop_Item{it.id, strings.clone(it.dir, allocator)})
		}
	}
	return out[:]
}

// workshop_packs: the packs of the subscribed items, read from disk and not yet checked:
// the caller builds the registry from them with the base pack and the local ones, which
// is where the pack's own errors come out. Errors here are about reading: an item with no
// pack folder, an unreadable one, a symlink, a file over the limits.
workshop_packs :: proc(
	c: ^Client,
	allocator := context.allocator,
) -> (
	found: []Workshop_Pack,
	errs: []game.Pack_Error,
) {
	context.allocator = allocator
	out := make([dynamic]Workshop_Pack)
	problems := make([dynamic]game.Pack_Error)
	for item in workshop_items(c, context.temp_allocator) {
		entries, err := os.read_all_directory_by_path(item.dir, context.temp_allocator)
		name := fmt.aprintf("workshop-%d", item.id)
		if err != nil {
			append(
				&problems,
				game.Pack_Error {
					pack = name,
					message = fmt.aprintf("cannot read the item: %v", err),
				},
			)
			continue
		}
		count := 0
		for e in entries {
			if e.type != .Directory {continue}
			count += 1
			path := filepath.join({item.dir, e.name}, context.temp_allocator) or_else ""
			src, read_errs := packs.pack_read_dir(path)
			append(&problems, ..read_errs)
			append(&out, Workshop_Pack{item.id, src})
		}
		if count == 0 {
			append(
				&problems,
				game.Pack_Error {
					pack = name,
					message = "holds no pack folder; an item is one folder named by the pack's namespace",
				},
			)
		}
	}
	return out[:], problems[:]
}

// workshop_publish_info: what the pack in `folder` publishes with: its pack.json's title
// and description and its preview image when it has one. Not ok (with the reason) when
// pack.json cannot be read or has no title.
workshop_publish_info :: proc(
	folder: string,
	allocator := context.allocator,
) -> (
	p: Publish,
	reason: string,
) {
	context.allocator = allocator
	path := filepath.join({folder, "pack.json"}, context.temp_allocator) or_else ""
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return {}, fmt.aprintf("cannot read %s: %v", path, err)}
	value, jerr, ok := game.json_parse(string(data), context.temp_allocator)
	if !ok {return {}, fmt.aprintf("%s:%d:%d: %s", path, jerr.line, jerr.column, jerr.message)}
	if value.kind != .Object {return {}, fmt.aprintf("%s is not an object", path)}
	for m in value.members {
		if m.value.kind != .String {continue}
		switch m.key {
		case "title":
			p.title = strings.clone(m.value.s)
		case "description":
			p.description = strings.clone(m.value.s)
		}
	}
	if p.title == "" {return {}, fmt.aprintf("%s has no title to publish under", path)}
	p.folder = strings.clone(folder)
	preview := filepath.join({folder, PREVIEW_FILE}, context.temp_allocator) or_else ""
	if info, stat_err := os.stat(preview, context.temp_allocator);
	   stat_err == nil && info.type == .Regular {
		if info.size > MAX_PREVIEW_BYTES {
			return {}, fmt.aprintf("%s is %d bytes; the preview limit is %d", preview, info.size, MAX_PREVIEW_BYTES)
		}
		p.preview = strings.clone(preview)
	}
	return p, ""
}

// workshop_publish sends a local pack to the Workshop. False when Steam is off or the
// call fails. (The real Steam does not publish yet: it says so in the log.)
workshop_publish :: proc(c: ^Client, p: Publish) -> bool {
	switch c.kind {
	case .Off:
	case .Real:
		log_off("publishing to the Workshop is not bound yet")
	case .Fake:
		if c.fake.script.fail_publish {return false}
		c.fake.published += 1
		c.fake.last_publish = p
		return true
	}
	return false
}
