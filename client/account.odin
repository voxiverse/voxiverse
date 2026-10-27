package client

import "core:encoding/hex"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "core:mem/virtual"

import "../common/game"
import "ui"

// The player's account: a key pair made on first launch and kept beside the
// settings (account.key: the private key's 32 bytes in hex). Whoever has
// the file is the account: servers know its characters by it. Without a
// settings directory (VX_SETTINGS empty: tests, scripts) a new one is
// made each run.

ACCOUNT_FILE :: "account.key"

account_load :: proc(app: ^App) {
	settings, ok := settings_path()
	if !ok {
		app.account = game.account_key_make()
		return
	}
	path :=
		filepath.join(
			{filepath.dir(settings), ACCOUNT_FILE},
			context.temp_allocator,
		) or_else ACCOUNT_FILE
	if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
		seed, decoded := hex.decode(
			transmute([]u8)strings.trim_space(string(data)),
			context.temp_allocator,
		)
		if decoded && game.account_key_set(&app.account, seed) {return}
		log.errorf(
			"account file not understood, not replaced path=%s (a new account for this run)",
			path,
		)
		app.account = game.account_key_make()
		return
	}
	app.account = game.account_key_make()
	seed := game.account_key_seed(&app.account)
	text := hex.encode(seed[:], context.temp_allocator)
	os.make_directory_all(filepath.dir(settings))
	if err := os.write_entire_file(path, text); err != nil {
		log.warnf("account cannot be kept path=%s error=%v (a new account each run)", path, err)
	} else {
		log.infof(
			"account made path=%s account=%s",
			path,
			game.account_text(app.account.account)[:16],
		)
	}
}

// characters_screen: before joining a server, the account's characters
// there to play (the one named in the settings first), or a new one.
characters_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "characters")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	rows := len(s.characters) + 3
	column := ui.rect_center(ctx.screen, 360, f32(rows) * (t.row_height + t.spacing) + 80)
	ui.title(ctx, "Characters", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	chosen := ""
	for name in s.characters {
		if ui.button(ctx, name, ui.next(ctx)) {chosen = name}
	}
	if len(s.characters) == 0 {
		ui.label(ctx, "No characters here yet", ui.next(ctx), .Center, t.text_muted)
	}
	if len(app.new_character) == 0 && len(s.characters) == 0 {
		append(&app.new_character, player_name(&app.settings))
	}
	if ui.text_input(
		   ctx,
		   "new character",
		   &app.new_character,
		   ui.next(ctx),
		   "a new character's name",
	   ) ||
	   ui.button(ctx, "New Character", ui.next(ctx)) {
		name := string(app.new_character[:])
		if game.name_valid(name) {
			chosen = name
		} else {
			notice(s, "Names are 1 to 16 letters, digits, _ or -")
		}
	}
	if chosen != "" {
		s.config.name = strings.clone(chosen, virtual.arena_allocator(&s.arena))
		send_message(s, game.Choose{chosen})
		s.state = .Connecting
		clear(&app.new_character)
	}
}
