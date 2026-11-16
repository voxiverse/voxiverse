package hamlet

import "common:base"

// What Hamlet's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format). (Why a placement is
// refused is the rules' own word, both sides': rules.odin.)

Text :: enum u8 {
	Milestone, // {0}: people
	Short_Of_Stock,
	Tool_Look,
	Tool_Road,
	Tool_Zone,
	Tool_Lumber,
	Tool_Quarry,
	Tool_Farm,
	Tool_Store,
	Tool_Well,
	Tool_Market,
	Tool_Demolish,
	All_Milestones,
	Next_Milestone, // {0}: people
	Status, // {0}: day, {1}: people, {2}: homes, {3}: workers, {4}: jobs, {5}: wood, {6}: stone, {7}: food, {8}: happiness, {9}: the next milestone
	Overlay_None,
	Overlay_Roads,
	Overlay_Happy,
	Pause,
	Speed, // {0}: times
	Workplace, // {0}: its name, {1}: workers, {2}: jobs
	Hint_Look,
	Hint_Road,
	Hint_Zone,
	Hint_Build, // {0}: the building, {1}: wood, {2}: stone
	Hint_Demolish,
}

TEXT_EN := [Text]string {
	.Milestone      = "{0} PEOPLE LIVE IN HAMLET",
	.Short_Of_Stock = "Not enough in stock",
	.Tool_Look      = "Look",
	.Tool_Road      = "Road",
	.Tool_Zone      = "Zone",
	.Tool_Lumber    = "Lumber",
	.Tool_Quarry    = "Quarry",
	.Tool_Farm      = "Farm",
	.Tool_Store     = "Store",
	.Tool_Well      = "Well",
	.Tool_Market    = "Market",
	.Tool_Demolish  = "Demolish",
	.All_Milestones = "all milestones reached",
	.Next_Milestone = "next: {0}",
	.Status         = "HAMLET  day {0}   people {1} / homes {2}   jobs {3}/{4}   wood {5}  stone {6}  food {7}   happy {8}%   {9}",
	.Overlay_None   = "Overlay",
	.Overlay_Roads  = "Roads",
	.Overlay_Happy  = "Happy",
	.Pause          = "Pause",
	.Speed          = "{0}x",
	.Workplace      = "{0} {1}/{2}",
	.Hint_Look      = "Pan: WASD, the edges, the middle button   Zoom: the wheel   Turn: F5, Shift and the wheel",
	.Hint_Road      = "Road: drag along the ground (an L: across, then along); roads are free",
	.Hint_Zone      = "Zone for homes: drag (left: zone, right: clear); houses grow by a road with water near",
	.Hint_Build     = "{0}: {1} wood, {2} stone; click to place, right button turns it; it must touch a road",
	.Hint_Demolish  = "Demolish: click a road, a zone or a building (half its cost comes back)",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
