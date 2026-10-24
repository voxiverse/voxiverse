package game

import "core:testing"

@(test)
test_edit_rules :: proc(t: ^testing.T) {
	testing.expect(t, can_break(.Stone) && can_break(.Grass))
	testing.expect(t, !can_break(.Air) && !can_break(.Bedrock))
	testing.expect(t, can_place(.Lamp) && !can_place(.Air) && !can_place(.Bedrock))
	testing.expect(
		t,
		can_change(.Air) && can_change(.Dirt) && can_change(.Water) && !can_change(.Bedrock),
	)
	b, ok := block_by_name("gravel")
	testing.expect(t, ok && b == .Gravel)
	_, ok = block_by_name("gold")
	testing.expect(t, !ok)

	player := Player_State {
		position = {0.5, 10, 0.5}, // feet at y 10, head up to 11.8
	}
	testing.expect(t, !can_place_at(.Air, .Stone, {0, 10, 0}, player), "inside the player's feet")
	testing.expect(t, !can_place_at(.Air, .Stone, {0, 11, 0}, player), "inside the player's head")
	testing.expect(t, can_place_at(.Air, .Stone, {0, 9, 0}, player), "under the feet")
	testing.expect(t, can_place_at(.Air, .Stone, {0, 12, 0}, player), "above the head")
	testing.expect(t, can_place_at(.Air, .Stone, {1, 10, 0}, player), "beside")
	testing.expect(t, !can_place_at(.Stone, .Stone, {5, 5, 5}, player), "occupied")
	// Into water and tall grass too; a flower may go where the player stands.
	testing.expect(
		t,
		can_place_at(.Water, .Stone, {5, 5, 5}, player) &&
		can_place_at(.Tall_Grass, .Dirt, {5, 5, 5}, player),
	)
	testing.expect(t, can_place_at(.Air, .Poppy, {0, 10, 0}, player))
	testing.expect(
		t,
		!can_place_at(.Poppy, .Stone, {5, 5, 5}, player) &&
		!can_place_at(.Water, .Water, {5, 5, 5}, player),
	)

	eye := player_eye(player)
	testing.expect(t, in_reach(eye, {0, 6, 0}, 5)) // nearest point 5.62 - 1 ... below
	testing.expect(t, !in_reach(eye, {0, 0, 0}, 5))
	testing.expect(t, in_reach(eye, {4, 11, 0}, 5) && !in_reach(eye, {6, 11, 0}, 5))
}
