package game

import "core:testing"

// The shared components fit the store and carry values through a spawn and
// a table move.

@(test)
test_entity_components :: proc(t: ^testing.T) {
	table := entity_component_infos()
	for info, i in table {
		testing.expect(t, info.name != "", "every id has a component")
		testing.expect(t, info.size > 0 && info.size <= MAX_COMPONENT_SIZE)
		testing.expect(t, i < int(FIRST_SERVER_COMPONENT))
	}

	st: Entity_Store
	testing.expect(t, store_init(&st, table[:], nil, 8) == nil)
	defer store_destroy(&st)

	_, h, _ := store_spawn(&st, {int(C_TRANSFORM), int(C_HEALTH)}, Kind_Id(1))
	store_apply(&st)
	tr := store_get(&st, h, C_TRANSFORM, Transform)
	testing.expect(t, tr != nil)
	tr.position = {1, 2, 3}
	store_get(&st, h, C_HEALTH, Entity_Health).health = 4
	hurt := Hurt_By {
		action = 7,
		entity = 9,
		cause  = 2,
	}
	testing.expect(t, store_add(&st, h, C_HURT_BY, &hurt) == .None)
	store_apply(&st) // the row moves to another table
	testing.expect_value(t, store_get(&st, h, C_TRANSFORM, Transform).position, [3]f64{1, 2, 3})
	testing.expect_value(t, store_get(&st, h, C_HEALTH, Entity_Health).health, 4)
	testing.expect_value(t, store_get(&st, h, C_HURT_BY, Hurt_By).entity, Entity_Id(9))
	testing.expect(t, store_get(&st, h, C_FROZEN, Frozen) == nil)
}
