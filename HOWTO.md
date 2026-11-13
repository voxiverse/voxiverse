# Flood: how to play the prototype

**Host:** `./build.sh run` drops you straight into a Flood round and opens the world to
the LAN on UDP 27315 (the next free port up to a few above if taken; the chat says which).
Or run a dedicated server: `./build.sh serve -- --universe build/flood-universe` (UDP 27315).
Friends outside your LAN need the port forwarded (UDP 27315) or a shared VPN (Tailscale etc.).

**Join:** a friend runs `./build.sh run -- --exec "join <host-ip>"` (or opens the console
with `~` and types `join <host-ip>[:port]`). Joining mid-round: you spectate until the next.
Two clients on one machine: give the second its own settings, e.g.
`VX_SETTINGS=/tmp/p2.cfg build/voxiverse --exec "join 127.0.0.1"`.

**Play:** survival kit every round: rocket launcher (in hand), grapple, rifles, jump boots.
Climb to the glowing lamp platform before the water reaches you; head under water 2 s and
you are out (you fly as a spectator). Round won when everyone still in stands on the goal.
No damage except drowning. Each round has a hidden rule; it is revealed at the end.

**Console** (`~`, server commands start with `/`):
- `/flood` shows the round; `/flood restart` starts a new round (new seed, random rule)
- `/flood rule baseline|tide|rot|heavy` starts a new round under that rule; `random` clears it
- F3 shows the debug overlay: the first (orange) line is the round, rule included

**Tuning:** all constants are at the top of `server/core/flood.odin` (`FLOOD_*`): arena size
and height, goal height, countdown/reveal/grace/drown seconds, seconds per water layer per
rule, tide amplitude/period, rot delay/spread/splash, heavy-blast radius and throw. The arena
generator is `arena_template` in the same file. HUD: `client/hud/flood.odin`.
