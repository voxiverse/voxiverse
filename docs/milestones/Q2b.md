# Q2b: the stateful targets: a fuzzed seat, a fuzzed server, the commands (the rest of Q2)

**Why.** Q2 (history.md) fuzzed every decoder that takes bytes alone: `net.client_decode`,
`net.server_decode`, `net.state`, `net.packets`, `net.handshake` and `text.parsers`. What is
left are the three targets that need a running server: decoding followed by *handling*. The
stepped server, its seat and the test client that talks to it (`Session`, the "mirror": `mirror_tick`,
`mirror_send`, `session_start`, `session_step`, `session_land`) live in `server/determinism_test.odin`,
a test file a fuzz target cannot import. This row therefore starts by moving the mirror and the
session out of the test file (into `server/harness_client.odin`, no new behaviour; the tests
keep using them), then builds the three targets on it.

**What this builds on:** Q1 and Q2 (`common/base/fuzz`, `tools/fuzz`, `common/game/fuzz_net.odin`
for the generators of valid messages, `server/fuzz.odin`); T2's harness (`server/harness.odin`);
the session and mirror above; the client session's receive path (`client/session_net.odin`:
`receive`, `welcome`, `packs_begin`, `packs_part`; `client/state_apply.odin`: `apply_received`);
the commands (`server/admin.odin`: `admin`, `command_usage`; `commands_people.odin`,
`commands_places.odin`, `commands_world.odin`; `rollback.odin`'s `parse_where`); the ledger's
`audit`.

**The targets** (as in Q1: a `fuzz_<thing>` beside the code, listed in the package's
`*_fuzz_targets`, registered in `tools/fuzz/targets.odin`, a smoke test in the package's
`fuzz_test.odin`):

| Target | What one case does | Generator |
|---|---|---|
| `net.server_session` | a stepped server (`harness_start`, flat world) with one fuzzed seat: the case is a sequence of client messages (each a valid message with one to three fields mutated, or raw mutated bytes; framed by a length byte), sent one a tick for up to 64 ticks, then `harness_step` | sequences recorded from the scripted session (`build determinism`'s), cut at random points |
| `net.client_session` | a headless client session (`client` package, no window, no GPU: the session's receive path only) fed a sequence of server messages and records as the server would send them, mutated as above, including the pack phase (`Packs`, `Pack_Part` with wrong sizes, hashes and order) | the messages a stepped server sends one client over its first 200 ticks |
| `commands.player` | `admin` with the bytes as one command line, by a guest (no permissions) and by an operator, on a stepped server | a command name from `command_usage`'s list and arguments drawn from each command's usage shape (numbers at the edges, `~` coordinates, selectors, ids known and unknown, very long words) |

The contract is Q1's (no panic, no bounds failure, no leak, the allocation cap, the time
limit), plus, for the stateful targets (`net.server_session`, `net.client_session`,
`commands.player`), invariants checked after every case:

- the server: still stepping (a further `harness_step` succeeds); its state hash computes;
  the item ledger's audit balances (M31: no items made by a refusal); the fuzzed seat was
  kicked with a logged reason or is still connected, never a half-removed client (its
  handle valid or freed, never dangling); no other seat (a second, well-behaved seat runs a
  scripted walk) is kicked or desynced (its prediction checks pass);
- the client: the session either fails with a reason shown to the player (`fail`) or keeps
  running; its replica's pools are within their caps; no file is written outside the pack
  cache directory (the pack phase's archives land only under `packs_cache_dir()`, a test
  directory here);
- commands: an operator's command that changes the world is journaled with the operator as
  its actor; a guest's changes nothing (the state hash before and after is equal unless the
  command is one a guest may run, by the permissions table).

A case's cost is kept small: the stepped server is built once per run and reset between
cases from a snapshot of its fresh state (M46b's save capture of one tick restored into a
fresh `Harness`), so a case is milliseconds, not a world generation. If that restore is not
cheap enough for 2 000 smoke cases in under a minute on CI's runner, the target builds a
fresh harness every 50 cases and runs those 50 on it (the invariants still checked after each
case).

**Steps, in order:**

1. Move the mirror and the session out of `determinism_test.odin` into `server/harness_client.odin`
   (the tests unchanged in behaviour; `build determinism` unchanged).
2. `commands.player` (the smallest: one seat, one line of text); fix what it finds.
3. `net.server_session` with its invariants and the reset; fix what it finds.
4. `net.client_session`; fix what it finds.
5. `docs/fuzzing.md`'s table gains the targets.

**Left out:** as in Q2 (real UDP sockets, M55's transport, script messaging and client scripts,
the dissector).

**Open questions:** none.

**Tests:** each target's smoke test and the regression replay; `./build.sh fuzz --smoke`.

**Exit check:** `./build.sh fuzz --smoke` passes with the new targets, and
`./build.sh fuzz --sanitize --seconds 60 net.server_session net.client_session commands.player`
finds nothing (every failure found on the way fixed with its regression file); the suite,
`build check`, `build determinism` and CI green.

**Check by hand:** none.
