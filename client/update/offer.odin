package update

import "core:strings"

// Which release to offer: the newest one that is newer than this build and has a package
// for this computer, at addresses the updater trusts.

// Source: where releases are read from. Only these two are ever fetched: the list, and
// downloads whose address is exactly <download><tag>/<name>, which is how GitHub gives a
// release's files (it then redirects to its storage, over https).
Source :: struct {
	list:     string,
	download: string,
}

GITHUB :: Source {
	list     = "https://api.github.com/repos/voxiverse/voxiverse/releases?per_page=20",
	download = "https://github.com/voxiverse/voxiverse/releases/download/",
}

// Platform: what this build's packages are called (tools/build/package.odin names them
// voxiverse-<version>-<os>-<arch><ext>, a commit after the version for a pre-release).
Platform :: struct {
	os:   string,
	arch: string,
	ext:  string,
}

when ODIN_OS == .Windows {
	PLATFORM :: Platform{"windows", "arm64" when ODIN_ARCH == .arm64 else "x64", ".zip"}
} else when ODIN_OS == .Darwin {
	PLATFORM :: Platform{"macos", "arm64" when ODIN_ARCH == .arm64 else "x64", ".zip"}
} else {
	PLATFORM :: Platform{"linux", "arm64" when ODIN_ARCH == .arm64 else "x64", ".tar.gz"}
}

SUMS_NAME :: "SHA256SUMS"
ARCHIVE_SIZE_MAX :: 512 << 20 // a package of more is not believed (one is about 30 MB)

// Offer: a release to update to. Its strings point into the text the release was read
// from (offer_clone keeps them).
Offer :: struct {
	version: Version,
	text:    string, // the version as the tag has it: "0.5.3"
	tag:     string, // "v0.5.3"
	archive: Asset, // this platform's package
	sums:    Asset, // the release's SHA256SUMS
	folder:  string, // the folder the package holds: its name without the extension
}

// offer_choose: the newest release newer than current with a package for platform (and
// a SHA256SUMS), every address as source gives them; ok false when there is none. Drafts
// and tags that are no version (the rolling `playtest`) are passed over.
offer_choose :: proc(
	releases: Releases,
	current: Version,
	platform: Platform,
	source: Source,
) -> (
	best: Offer,
	ok: bool,
) {
	for rel in releases.list {
		if rel.draft || !strings.has_prefix(rel.tag, "v") {continue}
		v, v_ok := version_parse(rel.tag[1:])
		if !v_ok || !version_newer(v, current) {continue}
		if ok && !version_newer(v, best.version) {continue}
		offer := Offer {
			version = v,
			text    = rel.tag[1:],
			tag     = rel.tag,
		}
		found_archive, found_sums := false, false
		for a in rel.assets {
			if !url_is(a.url, source, rel.tag, a.name) {continue}
			if a.name == SUMS_NAME {
				offer.sums, found_sums = a, true
			} else if folder, is := archive_folder(a.name, offer.text, platform);
			   is && a.size > 0 && a.size <= ARCHIVE_SIZE_MAX {
				offer.archive, offer.folder, found_archive = a, folder, true
			}
		}
		if found_archive && found_sums {best, ok = offer, true}
	}
	return
}

// url_is: url is exactly source's address of a release's file: <download><tag>/<name>,
// with a tag and name of plain characters.
url_is :: proc(url: string, source: Source, tag, name: string) -> bool {
	if !plain(tag) || !plain(name) {return false}
	rest, cut := cut_prefix(url, source.download)
	if !cut {return false}
	rest, cut = cut_prefix(rest, tag)
	if !cut {return false}
	rest, cut = cut_prefix(rest, "/")
	return cut && rest == name
}

// archive_folder: name is platform's package of version (voxiverse-<version>-<os>-<arch>
// <ext>, or voxiverse-<version>-<commit>-<os>-<arch><ext> for a pre-release, the commit
// twelve hexadecimal digits), and the folder it holds.
archive_folder :: proc(name, version: string, platform: Platform) -> (folder: string, ok: bool) {
	stem, cut := cut_suffix(name, platform.ext)
	if !cut {return}
	middle: string
	middle, cut = cut_prefix(stem, "voxiverse-")
	if !cut {return}
	middle, cut = cut_prefix(middle, version)
	if !cut {return}
	tail := strings.concatenate({"-", platform.os, "-", platform.arch}, context.temp_allocator)
	middle, cut = cut_suffix(middle, tail)
	if !cut {return}
	if middle != "" {
		if len(middle) != 13 || middle[0] != '-' {return}
		for c in transmute([]u8)middle[1:] {if !is_hex(c) {return}}
	}
	return stem, true
}

@(private)
cut_prefix :: proc(s, prefix: string) -> (rest: string, ok: bool) {
	if !strings.has_prefix(s, prefix) {return s, false}
	return s[len(prefix):], true
}

@(private)
cut_suffix :: proc(s, suffix: string) -> (rest: string, ok: bool) {
	if !strings.has_suffix(s, suffix) {return s, false}
	return s[:len(s) - len(suffix)], true
}

// plain: a tag's or file's name as the releases have them: letters, digits and . _ - +,
// not empty, never "." or "..".
@(private)
plain :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 128 || s == "." || s == ".." {return false}
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-', '+':
		case:
			return false
		}
	}
	return true
}
