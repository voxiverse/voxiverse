# Telemetry

This document describes what telemetry Voxiverse collects, where it is sent, and how to
examine it.

## What is collected

The server records events into `<universe>/telemetry/YYYY-MM-DD.jsonl` (see
[Statistics and events](debugging.md#statistics-and-events) in debugging.md). Events include:

- what is built, broken and picked up;
- what is said in chat, as a *count* only;
- where players are, every 10 s;
- how long a tick took;
- which overlays a client opens;
- frame times.

An event never contains a name, chat text or an address. An event identifies its player by a
number within the world.

## Consent

The consent question is not asked unless `telemetry.ask` is set to 1. Until then, nothing is
sent.

Nothing leaves the machine unless one of the following is true:

- the player answered yes to "Share anonymous play data?", which is asked once on the title
  screen and can be changed in Options > Profile; or
- a server operator started the server with `--telemetry host:port`.

Without consent, no connection is made at all.

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

## Querying the data

`build analytics --pull host:/path/lake` pulls the lake into `./lake`; it requires rsync.

`build analytics ./lake summary|sessions|economy|slow|launch|heat` answers the common
questions.

DuckDB reads the files in place:

```sql
select k, count(*) from read_json_auto('lake/**/*.jsonl') group by 1 order by 2 desc;
select pid, count(*) filter (k = 'session_start') as sessions from read_json_auto('lake/**/*.jsonl') group by 1;
select item, sum(count) from read_json_auto('lake/**/*.jsonl') where k = 'item_picked' group by 1;
```

## Not implemented

- Crash reports sent automatically. A report is currently a command.
- A client's events when it plays on another party's server. Those events go to that server's
  log.
- Encryption on the wire. Nothing sent is secret; if that changes, encryption belongs in the
  netcode, implemented once.
