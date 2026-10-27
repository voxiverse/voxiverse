# Telemetry: what is collected, where it goes, how to look at it

**What.** The server records events (what is built, broken, picked up, said as a *count*, where
players are every 10 s, how long a tick took, which overlays a client opens, frame times) into
`<universe>/telemetry/YYYY-MM-DD.jsonl` (see DEBUGGING.md, "Statistics and events"). Never a
name, never chat text, never an address: an event names its player by a number in the world.

**Consent.** (The question is not asked unless `telemetry.ask` is set to 1; until then, nothing is sent.) Nothing leaves the machine unless the player said yes to "Share anonymous play
data?" (asked once on the title screen, changeable in Options > Profile) or a server operator
started the server with `--telemetry host:port`. No consent: no connection at all.

**Transport.** The server's uploader (`server/collector/upload.odin`) sends its log, whole lines, in
batches of at most 30 KB over the game's own netcode (reliable UDP), after proving its account's
key as joining does. The collector keeps no source addresses. Unacknowledged batches are sent
again; a batch is written once however often it arrives.

**The collector** is `voxiverse-server --collector --universe <dir> [--port 27316]`. It writes
`<dir>/lake/dt=YYYY-MM-DD/source=server/HH.jsonl` (events, each with a `pid`: the first 8 bytes of
a salted hash of the account's public key; the salt is `<dir>/salt` and never leaves it) and
`.../source=report/<pid>-<ms>.txt` (reports a player sent with `report <note>`). Files are
append-only. Run it under a service manager on a small machine; back up `lake/` (rsync, or any
object store); to delete one player's data, find their `pid` and remove their lines.

**Looking.** `tools/lake-sync.sh host:/path/lake ./lake` pulls the lake;
`build analytics ./lake summary|sessions|economy|slow|launch|heat` answers the usual questions;
and DuckDB reads the files in place:

```sql
select k, count(*) from read_json_auto('lake/**/*.jsonl') group by 1 order by 2 desc;
select pid, count(*) filter (k = 'session_start') as sessions from read_json_auto('lake/**/*.jsonl') group by 1;
select item, sum(count) from read_json_auto('lake/**/*.jsonl') where k = 'item_picked' group by 1;
```

**Not yet:** crash reports sent by themselves (the report is a command today), a client's
events when it plays on someone else's server (they go to that server's log), encryption on the
wire (nothing sent is secret; if that changes, it is the netcode's, once).
