# Network debugging and the state model

Client and server communicate only through messages, so the network is where to look when
they disagree. This document lists the tools for watching, degrading, capturing and
replaying that traffic, and describes the state model the server reports the world with.
The netcode itself is described in [design.md](design.md).

## Tools

| Tool | Description |
|---|---|
| F3 `player:` line | Walking or flying, inputs not yet acknowledged by the server, prediction corrections so far, and the visual offset still fading. Corrections should remain near 0: each one means client and server disagreed. |
| F3 `net:` line | Round trip (one ping per second; includes the server's tick wait), bytes per second in each direction, and the most frequent message kind. |
| `set debug.net_latency_ms 150`, `net_jitter_ms`, `net_bandwidth_kbps` | Simulates a slower connection, live. In your own world (the in-process pipe) the stream remains reliable and ordered, as the protocol requires. |
| `set debug.net_loss 10`, `net_duplicate 10` | In a remote game, drops or repeats that percentage of the packets you send (latency and jitter also apply, and jitter reorders), which the reliability layer (`common/netcode/`) must handle. The dedicated server's `Config.conditions` does the same on its side (tests). |
| F3 `server:` line, remote | The link: address, round trip, packets in each direction, reliable records resent, duplicates received. |
| `set debug.net_capture 1` (next remote game), `voxiverse-server --capture file.pcap` | Writes every UDP packet to a pcap file. Open it in Wireshark with `tools/wireshark/voxiverse.lua` (copy it to your Lua plugins folder, or run `wireshark -X lua_script:tools/wireshark/voxiverse.lua build/net.pcap`) to see handshakes, acks, records and the game messages in them. `lua tools/wireshark/check.lua file.pcap` decodes a capture without Wireshark. CI does both. |
| `set debug.net_trace 1` (next world) / `net_trace` (now) | Records every message in both directions to `build/net.trace`. |
| `build netdump [file]` | Prints a trace, decoded by the game's own decoders: `-kind:chunk` (`-kind:list` lists them), `-sender:client`, `-from:2 -to:3` (seconds into the session), `-limit:20`, or `-summary` for counts and bytes per kind (`state` and `snapshot` split by the state and event kinds they carry). Fails if any message does not decode. |
| `build replay [file]` | Feeds the trace's client messages to a fresh server with the same seed, view distance and timing (`-speed:4` for faster; `-out:` names the answers' trace). Whatever the server did with them (assert, crash, disconnect) happens again outside the game; its answers go to `build/replay.trace`. Exits non-zero if the server failed or disconnected the client. The replay joins as an account of its own. |

Replays repeat the server's *inputs*, not its exact output. Chunk generation runs on worker
threads, so chunks can arrive in a slightly different order.

## The state model

What the server reports about the world besides chunks (the player, other players, entities,
the inventory, rules, health, the clock, chat, notices, blocks that changed) is the **state
model** (`common/game/state_kinds.odin`). It consists of *records* of typed kinds under a
key, and one-off *events*, encoded by a single codec derived from the value types
(`common/game/schema.odin`).

Records are deltas against one of two baselines:

- what the client was last sent (`state` messages, reliable);
- the newest snapshot the client acknowledged (`snapshot` messages, unreliable: the player's
  motion and other players' and entities' positions).

A new replicated value is a struct plus an entry in `state_kinds.odin`. Afterwards,
`build schema` regenerates the Wireshark dissector's table; the test
`test_dissector_schema_current` fails while it is stale. A client whose schema hash differs is
refused when joining.

A message that fails to decode, or whose values are out of range, is refused as malformed.
An aim pitch beyond `PITCH_LIMIT` (`Fire`, and therefore any aim computed straight up or
down) is such a message: clamp an aim before sending it.

## Market messages

`Market_View` (server to client, kind 43) and `Market_Trade` (client to server, kind 28) carry
a player's market ([world.md](world.md), the economy). A view is about 190 bytes (name, silver,
and 8 goods of 17 bytes), sent on arrival at a town, when its content changes (at most once a
second) and in answer to each trade; a refusal is 2 bytes. Walking out of a town sends one
refusal, `Away`, so the client knows to close its market screen. Only a player within a town's trade
radius is sent any, so the baseline scenarios, which are not on a planet, are unchanged.

## Bandwidth baselines

`server/core/bandwidth_test.odin` measures the exact bytes of a scripted session and of a crowd of
100 sheep. `assets/baselines/net/bandwidth.txt` holds the numbers, which are rewritten with
`-define:VX_BANDWIDTH_ACCEPT=true`:

```sh
ODIN_TEST_NAMES=core.test_bandwidth_accept ./build.sh test server/core
```

## Multiplayer tests

`server/core/party_test.odin` (`test_party_six_clients`, `test_party_eight_clients`) runs a
stepped server over real UDP with bots from `net_test.odin`'s `Net_Client`, for 6 000 ticks;
each takes a few seconds. `build bench party` runs the same kind of crowd as a benchmark
([benchmarking.md](benchmarking.md)).

Odin compiles every `.odin` file of a package into every build of it; only `@(test)`
procedures are dropped. Anything in a `_test.odin` file at package level that has an effect
(an `@(init)`, a global set at startup) therefore belongs inside `when ODIN_TEST`, as
`server/core/kit_test.odin`'s does.
