package protocol

import "common:game"

// How client and server talk, above the rules they share: the messages, records and
// events, the schema, the transport. For now this names what a game replicates (its
// records' kinds, their keys, what its client part receives) as the games will take
// it from here; the protocol itself moves here from common/game next.

Game_Kinds :: game.Game_Kinds
Received :: game.Received
key_player :: game.key_player
key_entity :: game.key_entity
game_kind :: game.game_kind
game_schema :: game.game_schema
edit_plain :: game.edit_plain
