package game

import "core:testing"

@(test)
test_edit_rules :: proc(t: ^testing.T) {
	testing.expect(t, can_break(.Stone) && can_break(.Grass))
	testing.expect(t, !can_break(.Air) && !can_break(.Bedrock))

	player := Player_State {
		position = {0.5, 10, 0.5}, // feet at y 10, head up to 11.8
	}
	testing.expect(t, !can_place_at(.Air, {0, 10, 0}, player), "inside the player's feet")
	testing.expect(t, !can_place_at(.Air, {0, 11, 0}, player), "inside the player's head")
	testing.expect(t, can_place_at(.Air, {0, 9, 0}, player), "under the feet")
	testing.expect(t, can_place_at(.Air, {0, 12, 0}, player), "above the head")
	testing.expect(t, can_place_at(.Air, {1, 10, 0}, player), "beside")
	testing.expect(t, !can_place_at(.Stone, {5, 5, 5}, player), "occupied")

	eye := player_eye(player)
	testing.expect(t, in_reach(eye, {0, 6, 0}, 5)) // nearest point 5.62 - 1 ... below
	testing.expect(t, !in_reach(eye, {0, 0, 0}, 5))
	testing.expect(t, in_reach(eye, {4, 11, 0}, 5) && !in_reach(eye, {6, 11, 0}, 5))
}
