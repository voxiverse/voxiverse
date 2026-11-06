# Telemetry

This document describes what telemetry Voxiverse collects, where it is sent, and how to
examine it.

## What is collected

The server records events into `<universe>/telemetry/YYYY-MM-DD.jsonl` (see
[Statistics and events](server.md#statistics-and-events) in server.md). Events include:

- what is built, broken and picked up;
- what is said in chat, as a *count* only;
- where players are, every 10 s;
- how long a tick took;
- which overlays a client opens, and for how long;
- frame times, which a client reports to its server every minute.

An event never contains a name, chat text or an address. An event identifies its player by a
number within the world.

## Consent

The consent question ("Help improve Voxiverse?") is asked once, on the title screen, only when
`telemetry.ask` is set to 1; it is off by default. Unanswered, nothing is sent.

Nothing leaves the machine unless one of the following is true:

- the player answered Share to the question, or turned "Share play data" on in Options >
  Profile (the `share_data` setting), and plays in a saved universe of their own: that
  universe's server then uploads its log to the collector named by the `collector` setting
  (default `collector.voxiverse.net:27316`); or
- a server operator started the server with `--telemetry host:port`.

Without consent, no connection to a collector is made at all.

## Transport

The server's uploader (`server/collector/upload.odin`) sends its log as whole lines, in
batches of at most 30 KB, over the game's own netcode (reliable UDP). It first proves its
account's key in the same way as joining a server does. The collector keeps no source
addresses. Unacknowledged batches are sent again; a batch is written once, however often it
arrives.

## The collector

Run the collector with:

```sh
voxiverse-server --collector --universe <dir> [--port 27316]
```

The collector writes:

| Path | Contents |
|---|---|
| `<dir>/lake/dt=YYYY-MM-DD/source=server/HH.jsonl` | Events. Each carries a `pid`: the first 8 bytes of a salted hash of the account's public key. The salt is `<dir>/salt` and never leaves that directory. |
| `.../source=report/<pid>-<ms>.txt` | Reports a player sent with `report <note>`. |

Files are append-only.

### Operation

- Run the collector under a service manager on a small machine.
- Back up `lake/` (with rsync, or to any object store).
- To delete one player's data, find their `pid` and remove their lines.

## Developer chat

The collector also carries a player's notes to the developers and the developers' replies
back, over the same netcode and the same proof of key (Hello, Challenge, Proof). Nothing
about an account is trusted before it has proved its key. Only accounts listed as admins
are heard; a separate program (not in this repository) reads the messages and writes the
replies. These files are the whole interface to it. Everything below is under `<dir>` (the
collector's `--universe` directory).

### Admins

`<dir>/admins.cfg`: one account public key in hex (64 digits) per line; `#` starts a comment
(a whole line or the end of one). A line that is not a key is logged and skipped. The file
is read at start and again within a second of it changing.

### Messages in

`Dev_Message` carries `id` (a number the client picks and keeps when it sends the message
again), `text` (UTF-8, at most 4000 bytes), the game's `version`, and optional context:
`universe`, `world`, a position and a tick. The collector answers with `Dev_Ack { id, ok,
reason }`:

- From an admin account it writes `<dir>/devchat/<account hex>/in/<unix ms>-<8 hex>.json`
  and acknowledges it. The 8 hex digits are the `id`; a message sent again with the same
  `id` is acknowledged and not written again.
- From any other account it refuses with `ok` false and a reason, and stores nothing. So does
  an empty text.
- A text over 4000 bytes is not a valid message: the collector refuses it and drops the
  connection. Nothing is stored.
- Messages and fetches share the rate limit of batches (12 per 10 s).

The file is one JSON object; `universe`, `world`, `position` and `tick` are present only
when the game sent them:

```json
{"id": "abcd1234", "time": 1700000000000, "text": "...", "version": "0.26",
 "universe": "Home", "world": "A1", "position": [1, -2, 3], "tick": 99}
```

### Replies out

`Dev_Fetch { after_id }` asks for the replies after `after_id` (`""`: all), and `Dev_Replies`
answers with at most 8 of them; fewer than 8 means there are no more (otherwise fetch again
with the last `id`). An account that is not an admin gets none.

The replies are the files `<dir>/devchat/<account hex>/out/*.json`, taken in file-name order
(bytewise) when the name, without `.json`, sorts after `after_id`. Write a file under a
temporary name outside `out/` and move it in, so it is never read half written. Each holds
one JSON object:

```json
{"id": "0001", "time": 1700000000000, "text": "...", "link": "https://..."}
```

| Field | Rule |
|---|---|
| `id` | string, 1 to 64 bytes, equal to the file name without `.json` |
| `time` | unix ms, greater than 0 |
| `text` | UTF-8, 1 to 4000 bytes |
| `link` | optional string, at most 256 bytes |

A file that is not valid JSON or breaks a rule is skipped and logged, never sent. Other files
in `out/` (without the `.json` suffix) are ignored.

## Querying the data

`build analytics --pull host:/path/lake` pulls the lake into `./lake`; it requires rsync.

`build analytics ./lake summary|sessions|economy|faucets|slow|launch|heat` answers the common
questions.

DuckDB reads the files in place:

```sql
select k, count(*) from read_json_auto('lake/**/*.jsonl') group by 1 order by 2 desc;
select pid, count(*) filter (k = 'session_start') as sessions from read_json_auto('lake/**/*.jsonl') group by 1;
select item, sum(count) from read_json_auto('lake/**/*.jsonl') where k = 'item_picked' group by 1;
```

## Scope

- Crash reports are not sent automatically. A player sends a note with the `report <note>`
  console command (needs "Share play data" on, in a saved universe).
- A client's events while it plays on another party's server go to that server's log, not to
  the player's own collector.
- Nothing on the wire is encrypted. Nothing sent is secret; encryption, if it were needed,
  belongs in the netcode, implemented once.
