package client

import "core:fmt"
import "core:strings"

// The UI's strings (design.md, Language): every string the player reads goes
// through a key. `Text` names them, TEXT_EN is the English table, tr formats
// one: arguments are positional, {0}, {1}, ... Item and block names are not
// here: the registry (packs) gives them. Dev panels are not translated.

Text :: enum u16 {
	Screenshot_Saved,
	Title_Singleplayer,
	Title_Multiplayer,
	Options,
	Title_Quit_Game,
	Title_Version, // {0}: the version
	Game_Menu_Quit_To_Title,
	Game_Menu_Save_And_Quit,
	Game_Menu_Disconnect,
	Game_Menu_Open_To_LAN,
	Game_Menu_Open_To_LAN_Port,
	Universes_Delete_Named,
	Options_Press_For,
	Loading_Percent,
	Game_Menu_Game_Paused,
	Game_Menu_Game_Menu,
	Game_Menu_Back_To_Game,
	Inventory_Chest,
	Inventory_Pockets,
	Inventory_Catalog,
	Inventory_Sort,
	Statistics_Previous,
	Statistics_Next,
	Dial_Dial_A_World,
	Dial_Erase,
	Dial_Cancel,
	Quit_Quit_Voxiverse,
	Quit_Quit,
	Credits_Credits,
	Credits_Back,
	Multiplayer_Join_Server,
	Multiplayer_Direct_Connection,
	Multiplayer_Server_Address,
	Multiplayer_Choose_A_Name,
	Multiplayer_The_Name_Other_Players_See,
	Multiplayer_Letters_Digits_And_16_At,
	Multiplayer_Done,
	Options_Bindings_Keyboard_And_Gamepad,
	Options_Reset_Keys,
	Options_Reset_Pad_Buttons,
	Options_Button,
	Options_Key,
	Options_Start_Or_Escape_Leave_It,
	Title_Voxiverse,
	Universes_No_Saves_Yet_Create_New,
	Universes_Play_Selected_Save,
	Universes_Create_New_Save,
	Universes_Edit,
	Universes_Delete,
	Universes_Name,
	Universes_Fewer_Options,
	Universes_More_Options,
	Universes_Seed_Leave_Empty_For_A,
	Universes_Create_Save,
	Universes_Edit_Save,
	Universes_Open_Folder,
	Universes_Save,
	Universes_It_Will_Be_Lost_Forever,
}

@(rodata)
TEXT_EN := [Text]string {
	.Screenshot_Saved                       = "Screenshot saved",
	.Title_Singleplayer                     = "Singleplayer",
	.Title_Multiplayer                      = "Multiplayer",
	.Options                                = "Options",
	.Title_Quit_Game                        = "Quit Game",
	.Title_Version                          = "Voxiverse {0}",
	.Game_Menu_Quit_To_Title                = "Quit to Title",
	.Game_Menu_Save_And_Quit                = "Save and Quit to Title",
	.Game_Menu_Disconnect                   = "Disconnect",
	.Game_Menu_Open_To_LAN                  = "Open to LAN",
	.Game_Menu_Open_To_LAN_Port             = "Open to LAN: port {0}",
	.Universes_Delete_Named                 = "Delete \"{0}\"?",
	.Options_Press_For                      = "Press a {0} for {1}",
	.Loading_Percent                        = "{0}%",
	.Game_Menu_Game_Paused                  = "Game Paused",
	.Game_Menu_Game_Menu                    = "Game Menu",
	.Game_Menu_Back_To_Game                 = "Back to Game",
	.Inventory_Chest                        = "Chest",
	.Inventory_Pockets                      = "Pockets",
	.Inventory_Catalog                      = "Catalog",
	.Inventory_Sort                         = "Sort",
	.Statistics_Previous                    = "Previous",
	.Statistics_Next                        = "Next",
	.Dial_Dial_A_World                      = "Dial a world",
	.Dial_Erase                             = "Erase",
	.Dial_Cancel                            = "Cancel",
	.Quit_Quit_Voxiverse                    = "Quit Voxiverse?",
	.Quit_Quit                              = "Quit",
	.Credits_Credits                        = "Credits",
	.Credits_Back                           = "Back",
	.Multiplayer_Join_Server                = "Join Server",
	.Multiplayer_Direct_Connection          = "Direct Connection",
	.Multiplayer_Server_Address             = "Server Address",
	.Multiplayer_Choose_A_Name              = "Choose a Name",
	.Multiplayer_The_Name_Other_Players_See = "The name other players see",
	.Multiplayer_Letters_Digits_And_16_At   = "Letters, digits, _ and - (16 at most)",
	.Multiplayer_Done                       = "Done",
	.Options_Bindings_Keyboard_And_Gamepad  = "Bindings: Keyboard and Gamepad",
	.Options_Reset_Keys                     = "Reset Keys",
	.Options_Reset_Pad_Buttons              = "Reset Pad Buttons",
	.Options_Button                         = "button",
	.Options_Key                            = "key",
	.Options_Start_Or_Escape_Leave_It       = "Start or Escape: leave it as it is",
	.Title_Voxiverse                        = "Voxiverse",
	.Universes_No_Saves_Yet_Create_New      = "No saves yet: Create New Save to start one",
	.Universes_Play_Selected_Save           = "Play Selected Save",
	.Universes_Create_New_Save              = "Create New Save",
	.Universes_Edit                         = "Edit",
	.Universes_Delete                       = "Delete",
	.Universes_Name                         = "Name",
	.Universes_Fewer_Options                = "Fewer options",
	.Universes_More_Options                 = "More options",
	.Universes_Seed_Leave_Empty_For_A       = "Seed (leave empty for a random world)",
	.Universes_Create_Save                  = "Create Save",
	.Universes_Edit_Save                    = "Edit Save",
	.Universes_Open_Folder                  = "Open Folder",
	.Universes_Save                         = "Save",
	.Universes_It_Will_Be_Lost_Forever      = "It will be lost forever.",
}

// tr: the string for key with {n} replaced by args[n] (temp allocator).
tr :: proc(key: Text, args: ..any) -> string {
	text := TEXT_EN[key]
	if len(args) == 0 {return text}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '{' {
			if end := strings.index_byte(text[i:], '}'); end > 1 {
				n := 0
				digits := true
				for c in text[i + 1:i + end] {
					if c < '0' || c > '9' {digits = false; break}
					n = n * 10 + int(c - '0')
				}
				if digits && n < len(args) {
					fmt.sbprint(&b, args[n])
					i += end
					continue
				}
			}
		}
		strings.write_byte(&b, text[i])
	}
	return strings.to_string(b)
}
