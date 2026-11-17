package update

import "core:strings"
import "core:testing"

// The shape of GitHub's reply, cut down: the rolling playtest release, a draft, a
// pre-release tag whose packages carry a commit, notes with escapes, and the objects the
// reader passes over (author, uploader, reactions).
RELEASES_SAMPLE :: `[
  {
    "url": "https://api.github.com/repos/voxiverse/voxiverse/releases/1",
    "tag_name": "v0.5.1",
    "name": "Pre-Alpha 5.1",
    "draft": false,
    "prerelease": true,
    "author": {"login": "someone", "id": 1, "site_admin": false},
    "assets": [
      {"name": "SHA256SUMS", "size": 295, "uploader": {"login": "x"},
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.5.1/SHA256SUMS"},
      {"name": "voxiverse-0.5.1-linux-x64.tar.gz", "size": 28007639,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.5.1/voxiverse-0.5.1-linux-x64.tar.gz"},
      {"name": "voxiverse-0.5.1-windows-x64.zip", "size": 27971781,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.5.1/voxiverse-0.5.1-windows-x64.zip"},
      {"name": "voxiverse-0.5.1-macos-arm64.zip", "size": 30767229,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.5.1/voxiverse-0.5.1-macos-arm64.zip"}
    ],
    "body": "Notes with \"quotes\", a \\ and \u00e9, [links](x) and {braces} [ ] ,",
    "reactions": {"+1": 3, "total_count": 3.0e0}
  },
  {
    "tag_name": "playtest",
    "draft": false,
    "assets": [
      {"name": "voxiverse-0.3.0+75-afaf329e8a0a-linux-x64.tar.gz", "size": 26837740,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/playtest/voxiverse-0.3.0+75-afaf329e8a0a-linux-x64.tar.gz"}
    ]
  },
  {
    "tag_name": "v0.6.0",
    "draft": true,
    "assets": [
      {"name": "SHA256SUMS", "size": 295,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.6.0/SHA256SUMS"},
      {"name": "voxiverse-0.6.0-linux-x64.tar.gz", "size": 1,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.6.0/voxiverse-0.6.0-linux-x64.tar.gz"}
    ]
  },
  {
    "tag_name": "v0.4.0-flood.5",
    "draft": false,
    "assets": [
      {"name": "SHA256SUMS", "size": 358,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.4.0-flood.5/SHA256SUMS"},
      {"name": "voxiverse-0.4.0-flood.5-36a1d4fdb8aa-linux-x64.tar.gz", "size": 27011652,
       "browser_download_url": "https://github.com/voxiverse/voxiverse/releases/download/v0.4.0-flood.5/voxiverse-0.4.0-flood.5-36a1d4fdb8aa-linux-x64.tar.gz"}
    ]
  }
]`

LINUX :: Platform{"linux", "x64", ".tar.gz"}

@(test)
test_releases_read :: proc(t: ^testing.T) {
	r, ok := releases_read(RELEASES_SAMPLE)
	defer releases_destroy(&r)
	testing.expect(t, ok)
	testing.expect_value(t, len(r.list), 4)
	testing.expect_value(t, r.list[0].tag, "v0.5.1")
	testing.expect_value(t, r.list[0].draft, false)
	testing.expect_value(t, len(r.list[0].assets), 4)
	testing.expect_value(t, r.list[0].assets[1].name, "voxiverse-0.5.1-linux-x64.tar.gz")
	testing.expect_value(t, r.list[0].assets[1].size, 28007639)
	testing.expect_value(t, r.list[1].tag, "playtest")
	testing.expect_value(t, len(r.list[1].assets), 1)
	testing.expect_value(t, r.list[2].draft, true)
	testing.expect_value(t, len(r.list[3].assets), 2)
}

// The newest release newer than this build is offered, with its package for this
// computer and its SHA256SUMS; one equal or older is not; a draft and the playtest
// release never are.
@(test)
test_offer_newer_release :: proc(t: ^testing.T) {
	r, _ := releases_read(RELEASES_SAMPLE)
	defer releases_destroy(&r)
	current, _ := version_parse("0.5.0")
	offer, ok := offer_choose(r, current, LINUX, GITHUB)
	testing.expect(t, ok)
	testing.expect_value(t, offer.text, "0.5.1")
	testing.expect_value(t, offer.archive.name, "voxiverse-0.5.1-linux-x64.tar.gz")
	testing.expect_value(t, offer.folder, "voxiverse-0.5.1-linux-x64")
	testing.expect_value(t, offer.sums.name, "SHA256SUMS")
	for equal_or_newer in ([]string{"0.5.1", "0.5.2", "1.0.0"}) {
		v, _ := version_parse(equal_or_newer)
		_, offered := offer_choose(r, v, LINUX, GITHUB)
		testing.expectf(t, !offered, "an update was offered to %s", equal_or_newer)
	}
	// A pre-release before its numbers' release: the release is newer.
	flood, _ := version_parse("0.4.0-flood.4")
	offer, ok = offer_choose(r, flood, LINUX, GITHUB)
	testing.expect(t, ok)
	testing.expect_value(t, offer.text, "0.5.1")
}

// A release without a package for this computer is passed over for an older one that
// has one; a package for another, or at an address not GitHub's, is none.
@(test)
test_offer_skips_other_platforms :: proc(t: ^testing.T) {
	r, _ := releases_read(RELEASES_SAMPLE)
	defer releases_destroy(&r)
	current, _ := version_parse("0.3.0")
	offer, ok := offer_choose(r, current, Platform{"linux", "arm64", ".tar.gz"}, GITHUB)
	testing.expect(t, !ok, "an offer for linux arm64, which no release has")
	// v0.5.1 without its Linux package: v0.4.0-flood.5 is what is left.
	text, _ := strings.replace_all(
		RELEASES_SAMPLE,
		"download/v0.5.1/voxiverse-0.5.1-linux-x64.tar.gz",
		"download/v0.5.1/../voxiverse-0.5.1-linux-x64.tar.gz",
		context.temp_allocator,
	)
	r2, _ := releases_read(text)
	defer releases_destroy(&r2)
	offer, ok = offer_choose(r2, current, LINUX, GITHUB)
	testing.expect(t, ok)
	testing.expect_value(t, offer.text, "0.4.0-flood.5")
	testing.expect_value(t, offer.folder, "voxiverse-0.4.0-flood.5-36a1d4fdb8aa-linux-x64")
	// Another source's addresses are not GitHub's.
	_, ok = offer_choose(r, current, LINUX, Source{download = "https://example.com/"})
	testing.expect(t, !ok)
}

@(test)
test_url_is :: proc(t: ^testing.T) {
	good := "https://github.com/voxiverse/voxiverse/releases/download/v0.5.1/a.zip"
	testing.expect(t, url_is(good, GITHUB, "v0.5.1", "a.zip"))
	bad := []string {
		"http://github.com/voxiverse/voxiverse/releases/download/v0.5.1/a.zip",
		"https://github.com/voxiverse/voxiverse/releases/download/v0.5.1/a.zip?x",
		"https://github.com/voxiverse/voxiverse/releases/download/v0.5.2/a.zip",
		"https://github.com/voxiverse/other/releases/download/v0.5.1/a.zip",
		"https://github.com.evil/voxiverse/voxiverse/releases/download/v0.5.1/a.zip",
		"https://github.com/voxiverse/voxiverse/releases/download/v0.5.1//a.zip",
	}
	for url in bad {testing.expectf(t, !url_is(url, GITHUB, "v0.5.1", "a.zip"), "%s", url)}
	testing.expect(t, !url_is(good, GITHUB, "v0.5.1/..", "a.zip"))
	testing.expect(
		t,
		!url_is(
			"https://github.com/voxiverse/voxiverse/releases/download/../x",
			GITHUB,
			"..",
			"x",
		),
	)
}

// Not one JSON array within the caps: nothing is used.
@(test)
test_releases_refuse :: proc(t: ^testing.T) {
	bad := []string {
		"",
		"{}",
		"\"text\"",
		"[",
		"[}",
		"[1,]",
		"[{\"a\":1,}]",
		"[{\"a\" 1}]",
		"[{1:2}]",
		"[] []",
		"[01]",
		"[tru]",
		"[\"\x01\"]",
		"[\"\\x\"]",
		"[\"\\u12\"]",
		"<html>rate limited</html>",
	}
	for text in bad {
		r, ok := releases_read(text)
		releases_destroy(&r)
		testing.expectf(t, !ok, "%q was read", text)
	}
	deep := strings.repeat("[", JSON_DEPTH_MAX + 1, context.temp_allocator)
	r, ok := releases_read(deep)
	releases_destroy(&r)
	testing.expect(t, !ok, "nesting past the cap")
	empty: Releases
	empty, ok = releases_read(" [ ] ")
	defer releases_destroy(&empty)
	testing.expect(t, ok)
	testing.expect_value(t, len(empty.list), 0)
}
