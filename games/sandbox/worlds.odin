package sandbox

import "common:worldgen"

// The creatures of each world class (common/worldgen/classes.odin; docs/world.md, "World
// classes"), by kind id: on a world of a class, a creature comes by itself (its kind's
// spawn rule) only if its kind is listed for the class (the server part's `spawned`
// refuses the rest). A world of no class (the home world, Earth, a world saved before
// classes) takes every kind, as before. The ground a kind comes on is still its own
// spawn rule's (the class's grounds are in pack/data/block_tags/creatures.json): each kind
// is listed only where its ground lies. A new creature belongs to the classes it is listed
// under here. The remains' machines (sentry, tender, bulwark) do not come by themselves,
// and a watcher comes only near remains (server/wild.odin), so where it is listed it
// waits for a world with remains. The blocks of a
// class (its ores and its rare resource) are the class's own data, worldgen.CLASSES.
CLASS_CREATURES := [worldgen.World_Class][]string {
	.None      = nil,
	// Earth's kin: all of them.
	.Temperate = {
		SHEEP_KIND,
		LOPER,
		TWITCHET,
		WHEELWING,
		GLASSFIN,
		DOMEBACK,
		HACKLEBIRD,
		SNOUTER,
		LONGSTRIDER,
		PITMAW,
		BARBCASTER,
		DUSKRUNNER,
		CRAGMAUL,
		WATCHER,
		SHAMBLER,
		SKITTER,
	},
	// Dry rock: the hardy birds and runners, the cragmaul by night, a watcher left there.
	.Canyon    = {HACKLEBIRD, TWITCHET, DUSKRUNNER, CRAGMAUL, WATCHER, PITMAW, GLASSFIN},
	// Snow and ice: what hunts there, fish under the ice.
	.Frozen    = {CRAGMAUL, WATCHER, PITMAW, GLASSFIN},
	// Islands: shore and sea life, small creatures on the land.
	.Ocean     = {GLASSFIN, BARBCASTER, HACKLEBIRD, TWITCHET, LOPER, PITMAW, SKITTER},
	// Ash and magma: the cragmaul, runners, machines.
	.Volcanic  = {CRAGMAUL, DUSKRUNNER, WATCHER, PITMAW},
	// Under the fungi: the small and the many-legged; no grazers.
	.Fungal    = {
		TWITCHET,
		WHEELWING,
		DOMEBACK,
		HACKLEBIRD,
		DUSKRUNNER,
		GLASSFIN,
		PITMAW,
		BARBCASTER,
		SHAMBLER,
		SKITTER,
	},
	// Airless: nothing lives there.
	.Moon      = nil,
	// Teeming.
	.Jungle    = {
		SHEEP_KIND,
		LOPER,
		SNOUTER,
		LONGSTRIDER,
		TWITCHET,
		WHEELWING,
		DOMEBACK,
		HACKLEBIRD,
		DUSKRUNNER,
		GLASSFIN,
		PITMAW,
		BARBCASTER,
		SHAMBLER,
		SKITTER,
	},
}

// The creatures' ids (pack/data/entities; the base pack's hostile two).
@(private = "file")
LOPER :: "sandbox:loper"
@(private = "file")
TWITCHET :: "sandbox:twitchet"
@(private = "file")
WHEELWING :: "sandbox:wheelwing"
@(private = "file")
GLASSFIN :: "sandbox:glassfin"
@(private = "file")
DOMEBACK :: "sandbox:domeback"
@(private = "file")
HACKLEBIRD :: "sandbox:hacklebird"
@(private = "file")
SNOUTER :: "sandbox:snouter"
@(private = "file")
LONGSTRIDER :: "sandbox:longstrider"
@(private = "file")
PITMAW :: "sandbox:pitmaw"
@(private = "file")
BARBCASTER :: "sandbox:barbcaster"
@(private = "file")
DUSKRUNNER :: "sandbox:duskrunner"
@(private = "file")
CRAGMAUL :: "sandbox:cragmaul"
@(private = "file")
WATCHER :: "sandbox:watcher"
@(private = "file")
SHAMBLER :: "voxiverse:shambler"
@(private = "file")
SKITTER :: "voxiverse:skitter"

// CLASS_NATIVES: the creatures each world class has of its own (pack/data/entities/
// natives.json), by kind id: one comes by itself on a world of its class and on no other,
// the home world neither. The moon has none living: its keepers' machines stand at its
// places (server/beyond.odin).
CLASS_NATIVES := [worldgen.World_Class][]string {
	.None      = nil,
	.Temperate = {"sandbox:thistlebuck"},
	.Canyon    = {"sandbox:sailback"},
	.Frozen    = {"sandbox:rimeclaw"},
	.Ocean     = {"sandbox:surfclaw", "sandbox:driftray"},
	.Volcanic  = {"sandbox:cinderhound"},
	.Fungal    = {"sandbox:sporemaw", "sandbox:lanternmoth"},
	.Moon      = nil,
	.Jungle    = {"sandbox:striper", "sandbox:leafwing"},
}

// native_class: the world class a creature of kind is native to (false: none, it is the
// home world's).
native_class :: proc(kind: string) -> (worldgen.World_Class, bool) {
	for natives, class in CLASS_NATIVES {
		for k in natives {if k == kind {return class, true}}
	}
	return .None, false
}

// class_has_creature: a creature of kind (its id) may come by itself on a world of class: a
// native on its own class alone, any other as CLASS_CREATURES lists it.
class_has_creature :: proc(class: worldgen.World_Class, kind: string) -> bool {
	if home, native := native_class(kind); native {return class == home}
	if class == .None {return true}
	for k in CLASS_CREATURES[class] {if k == kind {return true}}
	return false
}
