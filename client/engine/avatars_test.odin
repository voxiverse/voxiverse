package engine

import "core:testing"

import "client:render"
import "client:testkit"
import "common:game"

// The lights a player carries (game.item_light): a lamp in the hand shines from the hand as
// the lamp block does, one worn from the head; nothing carried, nothing.
@(test)
test_carried_lights :: proc(t: ^testing.T) {
	reg := testkit.test_reg()
	lamp, _ := game.registry_item(reg, "voxiverse:lamp")
	level, _ := game.item_light(reg, lamp)
	feet := [3]f64{10, 64, -3}
	lights := make([dynamic]render.Moving_Light, context.temp_allocator)
	worn: [game.WORN_SLOTS]game.Item
	for &w in worn {w = game.NO_ITEM}
	carried_lights(reg, &lights, feet, game.NO_ITEM, worn)
	testing.expect_value(t, len(lights), 0)
	carried_lights(reg, &lights, feet, lamp, worn)
	testing.expect_value(t, len(lights), 1)
	if len(lights) != 1 {return}
	testing.expect_value(t, lights[0].position, feet + {0, LIGHT_HAND, 0})
	testing.expect_value(t, lights[0].level, f32(level))
	testing.expect_value(t, lights[0].color, [3]f32{}) // (the scene's lamp's)
	clear(&lights)
	worn[0] = lamp
	carried_lights(reg, &lights, feet, game.NO_ITEM, worn)
	testing.expect_value(t, len(lights), 1)
	if len(lights) == 1 {testing.expect_value(t, lights[0].position, feet + {0, LIGHT_HEAD, 0})}
}
