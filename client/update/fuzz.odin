package update

import "base:runtime"
import "core:fmt"
import "core:strings"

import "common:base"
import "common:base/fuzz"

// The updater's targets (docs/fuzzing.md): what GitHub sends it. update.releases reads a
// list of releases and chooses what to offer from it; update.sums reads a SHA256SUMS.

update_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "update.releases",
			run = fuzz_releases,
			seeds = "testdata/fuzz/update.releases",
			dictionary = {
				"\"tag_name\"",
				"\"assets\"",
				"\"draft\"",
				"\"name\"",
				"\"size\"",
				"\"browser_download_url\"",
				"\"SHA256SUMS\"",
				"\\u0000",
				"[",
				"{",
				"]",
				"}",
				",",
				":",
			},
			max_len = 1 << 16,
			generate = fuzz_releases_generate,
		},
		{
			name = "update.sums",
			run = fuzz_sums,
			seeds = "testdata/fuzz/update.sums",
			dictionary = {"  ", " *", "\n", "\r\n", FUZZ_ARCHIVE},
			max_len = 1 << 12,
			generate = fuzz_sums_generate,
		},
	}
	return targets[:]
}

FUZZ_ARCHIVE :: "voxiverse-0.5.1-linux-x64.tar.gz"

fuzz_releases :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	text := string(data)
	r, ok := releases_read(text, allocator)
	defer releases_destroy(&r)
	if !ok {return fuzz.sig_mix(1, fuzz.sig_bucket(len(text)))}
	if len(r.list) > RELEASES_MAX {fuzz.fail("%d releases kept", len(r.list))}
	for rel in r.list {
		if len(rel.assets) > ASSETS_MAX {fuzz.fail("%d assets kept", len(rel.assets))}
	}
	current, _ := version_parse("0.5.0")
	offer, offered := offer_choose(r, current, Platform{"linux", "x64", ".tar.gz"}, GITHUB)
	if offered {
		// What it promised: newer, its package and sums at GitHub's addresses of its tag.
		if !version_newer(offer.version, current) {fuzz.fail("offered %s", offer.text)}
		if !url_is(offer.archive.url, GITHUB, offer.tag, offer.archive.name) ||
		   !url_is(offer.sums.url, GITHUB, offer.tag, SUMS_NAME) {
			fuzz.fail("an address not GitHub's: %s", offer.archive.url)
		}
		if offer.archive.size <= 0 || offer.archive.size > ARCHIVE_SIZE_MAX {
			fuzz.fail("size %d", offer.archive.size)
		}
	}
	return fuzz.sig_mix(2, u64(len(r.list)), u64(len(r.assets)), u64(offered))
}

fuzz_releases_generate :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	releases := base.rng_int_max(rng, 4)
	for i in 0 ..< releases {
		if i > 0 {strings.write_string(&b, ",")}
		version := fmt.tprintf(
			"0.%d.%d%s",
			base.rng_int_max(rng, 8),
			base.rng_int_max(rng, 3),
			"-rc.1" if base.rng_int_max(rng, 4) == 0 else "",
		)
		tag := strings.concatenate({"v", version}, context.temp_allocator)
		fmt.sbprintf(
			&b,
			`{{"tag_name":"%s","draft":%s,"body":"notes \"%d\" é","author":{{"id":1}},"assets":[`,
			tag,
			"true" if base.rng_int_max(rng, 5) == 0 else "false",
			i,
		)
		names := []string {
			SUMS_NAME,
			fmt.tprintf("voxiverse-%s-linux-x64.tar.gz", version),
			fmt.tprintf("voxiverse-%s-windows-x64.zip", version),
		}
		for name, j in names {
			if j > 0 {strings.write_string(&b, ",")}
			fmt.sbprintf(
				&b,
				`{{"name":"%s","size":%d,"browser_download_url":"%s%s/%s"}}`,
				name,
				base.rng_int_max(rng, 1 << 20),
				GITHUB.download,
				tag,
				name,
			)
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]")
	append(out, ..transmute([]u8)strings.to_string(b))
}

fuzz_sums :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	d, ok := sums_find(string(data), FUZZ_ARCHIVE)
	return fuzz.sig_mix(3, u64(ok), u64(d[0]) if ok else 0, fuzz.sig_bucket(len(data)))
}

fuzz_sums_generate :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	b := strings.builder_make(context.temp_allocator)
	for name in ([]string{FUZZ_ARCHIVE, "voxiverse-0.5.1-windows-x64.zip"}) {
		for _ in 0 ..< 32 {fmt.sbprintf(&b, "%02x", base.rng_int_max(rng, 256))}
		fmt.sbprintf(&b, "%s%s\n", " *" if base.rng_int_max(rng, 4) == 0 else "  ", name)
	}
	append(out, ..transmute([]u8)strings.to_string(b))
}
