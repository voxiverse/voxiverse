package build

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "common:base"
import "common:limited"

// Visual baselines (docs/debugging.md, "Visual baselines"): `build images`
// renders every scene of assets/baselines/images/scenes.txt with the game
// (`voxiverse --scene <name>`, client/autopilot/scene.odin) on lavapipe under
// xvfb-run, the same on every machine and never a window on anyone's desktop,
// and compares each picture with its baseline, <name>.png beside the scenes
// file. `--accept <scene|all>` makes what was rendered the baseline (review
// the pictures first); a scene's name alone renders and compares only that
// one. Pictures go to build/images/<scene>.png, a failure's difference to
// build/images/<scene>.diff.png and each run's log to build/images/<scene>.log; the game's own
// log, settings and pipeline cache are in build/images/<scene>.state/.
// Each scene also writes its counts, build/images/<scene>.counts, compared
// with <name>.counts beside the picture (and accepted with it): see Count.

IMAGES_DIR :: "assets/baselines/images"
IMAGES_SCENES :: IMAGES_DIR + "/scenes.txt"
IMAGES_OUT :: "build/images"

// A pixel differs when one of its channels differs by more than
// IMAGE_TOLERANCE (of 255). A scene fails when more than IMAGE_MAX_SHARE of
// its pixels differ, or when the mean absolute difference of its channels
// is above IMAGE_MAX_MEAN (of 255). Settled by measurement (by measurement): four times the largest difference seen between runs, never below
// these.
IMAGE_TOLERANCE :: 8
IMAGE_MAX_SHARE :: 0.001
IMAGE_MAX_MEAN :: 0.5

// images_width: how many scenes render at once (lavapipe draws on the CPU, so about
// half the cores, at most IMAGE_MAX_PARALLEL).
IMAGE_MAX_PARALLEL :: 6
images_width :: proc() -> int {
	return clamp(os.get_processor_core_count() / 2, 1, IMAGE_MAX_PARALLEL)
}

// IMAGE_SCENE_LIMIT: a scene still running at this is killed and fails.
IMAGE_SCENE_LIMIT :: 5 * time.Minute

// Image_Diff: how far two pictures of the same size are apart.
Image_Diff :: struct {
	share: f64, // of the pixels, those that differ (0..1)
	mean:  f64, // mean absolute difference of the colour channels, of 255
}

// image_diff compares two RGBA8 pictures of the same size (alpha is not compared).
image_diff :: proc(a, b: []u8) -> Image_Diff {
	assert(len(a) == len(b) && len(a) % 4 == 0)
	pixels := len(a) / 4
	if pixels == 0 {return {}}
	differing, total := 0, 0
	for p in 0 ..< pixels {
		largest := 0
		for c in 0 ..< 3 {
			d := abs(int(a[p * 4 + c]) - int(b[p * 4 + c]))
			total += d
			largest = max(largest, d)
		}
		if largest > IMAGE_TOLERANCE {differing += 1}
	}
	return {f64(differing) / f64(pixels), f64(total) / f64(pixels * 3)}
}

// image_passes: within the thresholds.
image_passes :: proc(d: Image_Diff) -> bool {
	return d.share <= IMAGE_MAX_SHARE && d.mean <= IMAGE_MAX_MEAN
}

// image_diff_picture: the baseline at a third of its brightness in grey,
// the pixels that differ in red.
image_diff_picture :: proc(baseline, rendered: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(baseline), allocator)
	for p in 0 ..< len(baseline) / 4 {
		i := p * 4
		largest := 0
		for c in 0 ..< 3 {largest = max(largest, abs(int(baseline[i + c]) - int(rendered[i + c])))}
		if largest > IMAGE_TOLERANCE {
			out[i], out[i + 1], out[i + 2] = 255, 0, 0
		} else {
			grey := u8((int(baseline[i]) + int(baseline[i + 1]) + int(baseline[i + 2])) / 9)
			out[i], out[i + 1], out[i + 2] = grey, grey, grey
		}
		out[i + 3] = 255
	}
	return out
}

// Scene counts: each scene also writes what
// its picture's frame drew, <scene>.counts, one `name value` a line
// (client/engine/screenshots.odin, scene_counts_text). The baseline's lines
// may add `~tolerance`: a count that depends on rasterization, which must be
// within it; every other count must be equal.

Count :: struct {
	name:      string,
	value:     i64,
	tolerance: i64, // 0: must be equal
}

// images_counts_parse reads a counts file's text; false (with the line) on
// a line that is not `name value [~tolerance]`, or a name given twice.
images_counts_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	counts: []Count,
	bad: string,
	ok: bool,
) {
	out := make([dynamic]Count, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" {continue}
		fields := strings.fields(l, context.temp_allocator)
		c: Count
		value_ok, tolerance_ok := false, true
		if len(fields) == 2 || len(fields) == 3 {
			c.name = fields[0]
			c.value, value_ok = strconv.parse_i64(fields[1])
			if len(fields) == 3 {
				tolerance_ok = strings.has_prefix(fields[2], "~")
				if tolerance_ok {c.tolerance, tolerance_ok = strconv.parse_i64(fields[2][1:])}
				tolerance_ok = tolerance_ok && c.tolerance >= 0
			}
		}
		for o in out {if o.name == c.name {value_ok = false}}
		if !value_ok || !tolerance_ok {
			delete(out)
			return nil, l, false
		}
		append(&out, c)
	}
	return out[:], "", true
}

// images_counts_compare: what differs between a baseline's counts and a
// run's, one line each (none: they match). A count missing on either side
// differs.
images_counts_compare :: proc(
	baseline, rendered: []Count,
	allocator := context.allocator,
) -> []string {
	out := make([dynamic]string, allocator)
	for b in baseline {
		found := false
		for r in rendered {
			if r.name != b.name {continue}
			found = true
			if abs(r.value - b.value) > b.tolerance {
				if b.tolerance == 0 {
					append(
						&out,
						fmt.aprintf(
							"%s %d, the baseline %d",
							b.name,
							r.value,
							b.value,
							allocator = allocator,
						),
					)
				} else {
					append(
						&out,
						fmt.aprintf(
							"%s %d, the baseline %d ~%d",
							b.name,
							r.value,
							b.value,
							b.tolerance,
							allocator = allocator,
						),
					)
				}
			}
		}
		if !found {append(&out, fmt.aprintf("%s missing (the baseline %d)", b.name, b.value, allocator = allocator))}
	}
	for r in rendered {
		found := false
		for b in baseline {if b.name == r.name {found = true}}
		if !found {append(&out, fmt.aprintf("%s %d, not in the baseline", r.name, r.value, allocator = allocator))}
	}
	return out[:]
}

// images_counts_check compares a scene's counts file with its baseline's
// (failures printed, one line each); false if they differ or cannot be read.
@(private = "file")
images_counts_check :: proc(name, rendered_path, baseline_path: string) -> bool {
	rendered_text, rerr := os.read_entire_file_from_path(rendered_path, context.allocator)
	if rerr != nil {
		fmt.printfln("%-14s FAIL: the scene wrote no %s", name, rendered_path)
		return false
	}
	baseline_text, berr := os.read_entire_file_from_path(baseline_path, context.allocator)
	if berr != nil {
		fmt.printfln(
			"%-14s FAIL: no baseline %s (build images --accept %s)",
			name,
			baseline_path,
			name,
		)
		return false
	}
	rendered, rbad, rok := images_counts_parse(string(rendered_text))
	if !rok {
		fmt.printfln("%-14s FAIL: %s: not a count: %q", name, rendered_path, rbad)
		return false
	}
	baseline, bbad, bok := images_counts_parse(string(baseline_text))
	if !bok {
		fmt.printfln("%-14s FAIL: %s: not a count: %q", name, baseline_path, bbad)
		return false
	}
	differ := images_counts_compare(baseline, rendered)
	for d in differ {fmt.printfln("%-14s FAIL: count %s", name, d)}
	return len(differ) == 0
}

// Picture: an RGBA8 picture read from a PNG.
Picture :: struct {
	width, height: int,
	rgba:          []u8,
}

picture_read :: proc(path: string) -> (p: Picture, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return}
	img, perr := png.load_from_bytes(data, {.alpha_add_if_missing})
	if perr != nil || img.channels != 4 || img.depth != 8 {
		if img != nil {image.destroy(img)}
		return
	}
	return {img.width, img.height, bytes.buffer_to_bytes(&img.pixels)}, true
}

// scenes_of: the scenes' names in a scenes file's text (client/autopilot/scene.odin
// reads the same form: `name: script` a line, '#' comments).
scenes_of :: proc(text: string) -> []string {
	names := make([dynamic]string)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		n, colon, _ := strings.partition(l, ":")
		if colon != "" {append(&names, strings.trim_space(n))}
	}
	return names[:]
}

// lavapipe_icd: Mesa's CPU Vulkan driver's manifest ("" if it is not installed).
lavapipe_icd :: proc() -> string {
	for dir in ([]string{"/usr/share/vulkan/icd.d", "/usr/local/share/vulkan/icd.d", "/etc/vulkan/icd.d"}) {
		entries, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil {continue}
		for e in entries {
			if strings.has_prefix(e.name, "lvp_icd") && strings.has_suffix(e.name, ".json") {
				return path_join({dir, e.name})
			}
		}
	}
	return ""
}

images :: proc(args: []string) -> bool {
	// (a run-time test, not `when`: the rest still compiles, and is checked, everywhere)
	if ODIN_OS != .Linux {
		fmt.eprintln(
			"build: images renders on lavapipe under xvfb-run, on Linux (CI's Linux job runs it for every change)",
		)
		return false
	}
	text, err := os.read_entire_file_from_path(IMAGES_SCENES, context.allocator)
	if err != nil {
		fmt.eprintfln("build: images: cannot read %s: %v", IMAGES_SCENES, err)
		return false
	}
	all := scenes_of(string(text))
	chosen := make([dynamic]string)
	accept := false
	for i := 0; i < len(args); i += 1 {
		name := args[i]
		if name == "--accept" {
			if i + 1 >= len(args) {
				fmt.eprintln("build: images --accept <scene|all>")
				return false
			}
			i += 1
			name = args[i]
			accept = true
			if name == "all" {
				append(&chosen, ..all)
				continue
			}
		}
		if !slice.contains(all, name) {
			fmt.eprintfln(
				"build: images: no scene '%s' in %s (there are: %s)",
				name,
				IMAGES_SCENES,
				strings.join(all, ", "),
			)
			return false
		}
		append(&chosen, name)
	}
	if len(chosen) == 0 {append(&chosen, ..all)}

	icd := lavapipe_icd()
	if icd == "" {
		fmt.eprintln(
			"build: images: lavapipe is not installed (Mesa's CPU Vulkan driver: mesa-vulkan-drivers)",
		)
		return false
	}
	// Every scene on lavapipe, whatever GPU the machine has.
	os.set_env("VK_DRIVER_FILES", icd)
	os.set_env("VK_ICD_FILENAMES", icd)
	exe := build_game({}) or_return
	os.make_directory_all(IMAGES_OUT)

	// In parallel: each scene has its own settings file, log and pipeline cache
	// (a directory under build/images, VX_SETTINGS and VX_STATE_DIR) and its own X
	// display (xvfb-run -n: -a picks displays racily when several start at once).
	// The display numbers start at a base that depends on this process, so two
	// builds on one machine rarely meet.
	display_base := 100 + (os.get_pid() % 150) * 20
	root, _ := os.get_working_directory(context.allocator)
	jobs := make([]limited.Job, len(chosen))
	for name, i in chosen {
		for ext in ([]string{".png", ".diff.png", ".counts"}) {
			os.remove(path_join({IMAGES_OUT, strings.concatenate({name, ext})}))
		}
		state := path_join({root, IMAGES_OUT, strings.concatenate({name, ".state"})})
		os.remove_all(state)
		os.make_directory_all(state)
		jobs[i] = {
			// (cloned: a slice literal here would be one array for every job)
			cmd   = slice.clone(
				[]string {
					"xvfb-run",
					"-n",
					fmt.tprintf("%d", display_base + i),
					"-s",
					"-screen 0 1280x720x24",
					"env",
					strings.concatenate({"VX_STATE_DIR=", state}),
					strings.concatenate({"VX_SETTINGS=", state, "/settings.cfg"}),
					exe,
					"--scene",
					name,
				},
			),
			limit = IMAGE_SCENE_LIMIT,
			log   = path_join({IMAGES_OUT, strings.concatenate({name, ".log"})}),
			quiet = true,
		}
	}
	fmt.printfln("images %d scene(s) on lavapipe (%s)", len(chosen), filepath.base(icd))
	results := limited.run_parallel(jobs, images_width())

	passed := 0
	for name, i in chosen {
		rendered_path := path_join({IMAGES_OUT, strings.concatenate({name, ".png"})})
		baseline_path := path_join({IMAGES_DIR, strings.concatenate({name, ".png"})})
		if results[i] != .Ok {
			fmt.printfln(
				"%-14s FAIL: the scene did not render (%v; its log: %s)",
				name,
				results[i],
				jobs[i].log,
			)
			continue
		}
		rendered, rendered_ok := picture_read(rendered_path)
		if !rendered_ok {
			fmt.printfln("%-14s FAIL: %s is not a picture", name, rendered_path)
			continue
		}
		rendered_counts := path_join({IMAGES_OUT, strings.concatenate({name, ".counts"})})
		baseline_counts := path_join({IMAGES_DIR, strings.concatenate({name, ".counts"})})
		if accept {
			data, _ := os.read_entire_file_from_path(rendered_path, context.allocator)
			if werr := os.write_entire_file(baseline_path, data); werr != nil {
				fmt.printfln("%-14s FAIL: cannot write %s: %v", name, baseline_path, werr)
				continue
			}
			counts, cerr := os.read_entire_file_from_path(rendered_counts, context.allocator)
			if cerr != nil {
				fmt.printfln("%-14s FAIL: the scene wrote no %s", name, rendered_counts)
				continue
			}
			if werr := os.write_entire_file(baseline_counts, counts); werr != nil {
				fmt.printfln("%-14s FAIL: cannot write %s: %v", name, baseline_counts, werr)
				continue
			}
			fmt.printfln("%-14s accepted (%s)", name, baseline_path)
			passed += 1
			continue
		}
		baseline, baseline_ok := picture_read(baseline_path)
		if !baseline_ok {
			fmt.printfln(
				"%-14s FAIL: no baseline %s (build images --accept %s)",
				name,
				baseline_path,
				name,
			)
			continue
		}
		if baseline.width != rendered.width || baseline.height != rendered.height {
			fmt.printfln(
				"%-14s FAIL: %dx%d, the baseline is %dx%d",
				name,
				rendered.width,
				rendered.height,
				baseline.width,
				baseline.height,
			)
			continue
		}
		d := image_diff(baseline.rgba, rendered.rgba)
		verdict := "PASS"
		// The counts after the picture's: a scene passes when both do.
		counts_pass := images_counts_check(name, rendered_counts, baseline_counts)
		if image_passes(d) && counts_pass {
			passed += 1
		} else if !image_passes(d) {
			verdict = "FAIL"
			diff := image_diff_picture(baseline.rgba, rendered.rgba)
			out, _ := base.png_encode(rendered.width, rendered.height, diff)
			diff_path := path_join({IMAGES_OUT, strings.concatenate({name, ".diff.png"})})
			if werr := os.write_entire_file(diff_path, out); werr != nil {
				fmt.eprintfln("build: images: cannot write %s: %v", diff_path, werr)
			}
		}
		if !counts_pass {verdict = "FAIL"}
		fmt.printfln(
			"%-14s %.3f%% of pixels differ, mean %.3f/255  %s",
			name,
			100 * d.share,
			d.mean,
			verdict,
		)
	}
	fmt.printfln("images %d of %d %s", passed, len(chosen), "accepted" if accept else "passed")
	return passed == len(chosen)
}
