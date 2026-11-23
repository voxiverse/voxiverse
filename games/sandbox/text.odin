package sandbox

import "common:base"

// What the sandbox's HUD and screens say, by key (docs/games.md, "What a game's HUD says"):
// the English table, its own, so a translation is a table of the same keys beside it and no
// shared file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Market_Hud, // {0}: the town, {1}: the key that opens its market
	Market_Title, // {0}: the town
	Market_Cash, // {0}: silver
	Market_Good,
	Market_Price,
	Market_Stock,
	Market_Cargo,
	Market_News, // {0}: days
	Market_News_Unknown,
	Market_Buy,
	Market_Sell,
	Market_Quantity, // {0}: units
	Market_Close,
	Market_Less,
	Market_More,
	Market_Not_Traded,
	Market_Refused_Bad_Quantity,
	Market_Refused_No_Market,
	Market_Refused_No_Cash,
	Market_Refused_No_Cargo,
	Market_Refused_No_Stock,
	Market_Refused_Away,
	Ruin_Countdown, // {0}: seconds to the first wave
	Ruin_Wave, // {0}: the wave, {1}: the fight's waves, {2}: creatures still to kill
	Ruin_Break, // {0}: the wave held, {1}: the fight's waves, {2}: seconds to the next
	Craft_Title,
	Craft_Output, // {0}: how many, {1}: the item
	Craft_Hand,
	Craft_Fabricator,
	Craft_Seconds, // {0}: seconds
	Craft_Input, // {0}: the item, {1}: carried, {2}: needed
	Craft_Near,
	Craft_Far,
	Craft_Making, // {0}: the item, {1}: percent
	Craft_Idle,
	Craft_Make,
	Craft_Close,
	Craft_Outposts,
	Craft_No_Outposts,
	Craft_Outpost, // {0} {1} {2}: where
	Craft_Outpost_Mine,
	Craft_Outpost_Home,
	Craft_Hud, // {0}: the item, {1}: percent
}

TEXT_EN := [Text]string {
	.Market_Hud                  = "Market of {0}   {1}: trade",
	.Market_Title                = "Market of {0}",
	.Market_Cash                 = "Silver: {0}",
	.Market_Good                 = "Good",
	.Market_Price                = "Price",
	.Market_Stock                = "Stock",
	.Market_Cargo                = "Cargo",
	.Market_News                 = "news {0} days old",
	.Market_News_Unknown         = "no news",
	.Market_Buy                  = "Buy",
	.Market_Sell                 = "Sell",
	.Market_Quantity             = "Quantity: {0}",
	.Market_Close                = "Close",
	.Market_Less                 = "-",
	.Market_More                 = "+",
	.Market_Not_Traded           = "not traded",
	.Market_Refused_Bad_Quantity = "That quantity cannot be traded.",
	.Market_Refused_No_Market    = "This town does not trade in that.",
	.Market_Refused_No_Cash      = "Not enough silver.",
	.Market_Refused_No_Cargo     = "You do not carry that much.",
	.Market_Refused_No_Stock     = "The market has too little.",
	.Market_Refused_Away         = "You are not in a town.",
	.Ruin_Countdown              = "THE RUIN WAKES   the first wave in {0} s",
	.Ruin_Wave                   = "RUIN   wave {0} of {1}   {2} creatures left",
	.Ruin_Break                  = "RUIN   wave {0} of {1} held   the next in {2} s",
	.Craft_Title                 = "Fabrication",
	.Craft_Output                = "{0} x {1}",
	.Craft_Hand                  = "by hand",
	.Craft_Fabricator            = "fabricator",
	.Craft_Seconds               = "{0} s",
	.Craft_Input                 = "{0} {1}/{2}",
	.Craft_Near                  = "A fabricator is near.",
	.Craft_Far                   = "No fabricator near: by hand only.",
	.Craft_Making                = "Making {0}: {1}%",
	.Craft_Idle                  = "Nothing being made.",
	.Craft_Make                  = "Make",
	.Craft_Close                 = "Close",
	.Craft_Outposts              = "Outposts in this world",
	.Craft_No_Outposts           = "None yet: make a beacon and place it.",
	.Craft_Outpost               = "{0} {1} {2}",
	.Craft_Outpost_Mine          = "yours",
	.Craft_Outpost_Home          = "respawn",
	.Craft_Hud                   = "Making {0}  {1}%",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
