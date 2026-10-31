package build

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "common:base"
import "common:limited"

// Visual baselines (docs/debugging.md, "Visual baselines"): `build images`
// renders every scene of assets/baselines/images/scenes.txt with the game
// (`voxiverse --scene <name>`, client/scenes.odin) on lavapipe under
// xvfb-run, the same on every machine and never a window on anyone's desktop,
// and compares each picture with its baseline, <name>.png beside the scenes
// file. `--accept <scene|all>` makes what was rendered the baseline (review
// the pictures first); a scene's name alone renders and compares only that
// one. Pictures go to build/images/<scene>.png, a failure's difference to
// build/images/<scene>.diff.png and each run's log to build/images/<scene>.log.

IMAGES_DIR :: "assets/baselines/images"
IMAGES_SCENES :: IMAGES_DIR + "/scenes.txt"
IMAGES_OUT :: "build/images"

// A pixel differs when one of its channels differs by more than
// IMAGE_TOLERANCE (of 255). A scene fails when more than IMAGE_MAX_SHARE of
// its pixels differ, or when the mean absolute difference of its channels
// is above IMAGE_MAX_MEAN (of 255). Settled by measurement (docs/history.md,
// R1): four times the largest difference seen between runs, never below
// these.
IMAGE_TOLERANCE :: 8
IMAGE_MAX_SHARE :: 0.001
IMAGE_MAX_MEAN :: 0.5

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

// scenes_of: the scenes' names in a scenes file's text (client/scenes.odin
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

	// One at a time: the games share their log, settings and pipeline cache
	// next to the executable, and xvfb-run -a picks displays racily.
	jobs := make([]limited.Job, len(chosen))
	for name, i in chosen {
		for ext in ([]string{".png", ".diff.png"}) {
			os.remove(path_join({IMAGES_OUT, strings.concatenate({name, ext})}))
		}
		jobs[i] = {
			// (cloned: a slice literal here would be one array for every job)
			cmd   = slice.clone(
				[]string{"xvfb-run", "-a", "-s", "-screen 0 1280x720x24", exe, "--scene", name},
			),
			limit = IMAGE_SCENE_LIMIT,
			log   = path_join({IMAGES_OUT, strings.concatenate({name, ".log"})}),
			quiet = true,
		}
	}
	fmt.printfln("images %d scene(s) on lavapipe (%s)", len(chosen), filepath.base(icd))
	results := limited.run_parallel(jobs, 1)

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
		if accept {
			data, _ := os.read_entire_file_from_path(rendered_path, context.allocator)
			if werr := os.write_entire_file(baseline_path, data); werr != nil {
				fmt.printfln("%-14s FAIL: cannot write %s: %v", name, baseline_path, werr)
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
		if image_passes(d) {
			passed += 1
		} else {
			verdict = "FAIL"
			diff := image_diff_picture(baseline.rgba, rendered.rgba)
			out, _ := base.png_encode(rendered.width, rendered.height, diff)
			diff_path := path_join({IMAGES_OUT, strings.concatenate({name, ".diff.png"})})
			if werr := os.write_entire_file(diff_path, out); werr != nil {
				fmt.eprintfln("build: images: cannot write %s: %v", diff_path, werr)
			}
		}
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
