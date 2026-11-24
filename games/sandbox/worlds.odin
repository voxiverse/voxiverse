package sandbox

import "common:worldgen"

// The creatures of each world class (common/worldgen/classes.odin; docs/world.md, "World
// classes"), by kind id: on a world of a class, a creature comes by itself (its kind's
// spawn rule) only if its kind is listed for the class (the server part's `spawned`
// refuses the rest). A world of no class (the home world, Earth, a world saved before
// classes) takes every kind, as before. The ground a kind comes on is still its own
// spawn rule's: a shambler listed for a frozen world comes only where that rule's ground
// lies. A new creature belongs to the classes it is listed under here. The blocks of a
// class (its ores and its rare resource) are the class's own data, worldgen.CLASSES.
CLASS_CREATURES := [worldgen.World_Class][]string {
	.None      = nil,
	.Temperate = {SHEEP_KIND, "voxiverse:shambler", "voxiverse:skitter"},
	.Canyon    = {"voxiverse:skitter"},
	.Frozen    = {"voxiverse:shambler"},
	.Ocean     = {"voxiverse:skitter"},
	.Volcanic  = {"voxiverse:skitter"},
	.Fungal    = {"voxiverse:shambler", "voxiverse:skitter"},
	.Moon      = nil,
	.Jungle    = {SHEEP_KIND, "voxiverse:shambler", "voxiverse:skitter"},
}

// class_has_creature: a creature of kind (its id) may come by itself on a world of class.
class_has_creature :: proc(class: worldgen.World_Class, kind: string) -> bool {
	if class == .None {return true}
	for k in CLASS_CREATURES[class] {if k == kind {return true}}
	return false
}
