"""Summarizes a Spall trace written by a `--profile` build (`build trace`):

- every scope, per thread: calls, total, p50, p99 and max (ms);
- a timeline, one row a second, of a few scopes' calls and time;
- the slowest frames (main thread) and server ticks, with what took the
  time inside them.

    python3 tools/debugger/spall_summary.py build/voxiverse.spall [scope ...]

The scopes for the timeline default to frame, server tick, generate chunk
and mesh chunk. The format is core:prof/spall's (as check_spall.py reads).
"""
import collections
import struct
import sys

TREES = 3
SLOWEST = 8


def read(path):
    data = open(path, 'rb').read()
    off = 32
    names, stacks, events = {}, collections.defaultdict(list), []
    while off < len(data):
        size, tid, _pid, _first = struct.unpack_from('<IIIQ', data, off)
        off += 20
        end = off + size
        while off < end:
            kind = data[off]
            if kind == 3:  # begin
                ts, nl, al = struct.unpack_from('<QBB', data, off + 1)
                args = data[off + 11 + nl:off + 11 + nl + al].decode()
                stacks[tid].append((data[off + 11:off + 11 + nl].decode(), ts, args))
                off += 11 + nl + al
            elif kind == 4:  # end
                (ts,) = struct.unpack_from('<Q', data, off + 1)
                off += 9
                if stacks[tid]:
                    name, begin, args = stacks[tid].pop()
                    events.append((tid, name, begin, ts, len(stacks[tid]), args))
            elif kind == 8:  # process name: what was profiled
                nl = data[off + 1]
                names['process'] = data[off + 2:off + 2 + nl].decode()
                off += 2 + nl
            elif kind == 9:  # thread name
                nl = data[off + 1]
                names[tid] = data[off + 2:off + 2 + nl].decode()
                off += 2 + nl
            elif kind == 7:  # padding
                (sz,) = struct.unpack_from('<I', data, off + 1)
                off += sz
            else:
                sys.exit(f"unknown event {kind} at {off}")
    return names, events


def ms(begin, end):
    return (end - begin) / 1e6


def tree(track, spans, depth, indent):
    """Prints the scopes one level below spans (merged by name), heaviest first, and
    below them in turn: where a slow frame's time went, however many calls it took."""
    lo, hi = min(b for b, _ in spans), max(e for _, e in spans)
    inner = {}
    for _t, n, ib, ie, d, _a in track:
        if d == depth + 1 and lo <= ib and ie <= hi and any(b <= ib and ie <= e for b, e in spans):
            total, calls, kids = inner.get(n, (0.0, 0, []))
            inner[n] = (total + ms(ib, ie), calls + 1, kids + [(ib, ie)])
    covered = sum(t for t, _c, _k in inner.values())
    for n, (total, calls, kids) in sorted(inner.items(), key=lambda kv: -kv[1][0]):
        if total < 0.1:
            continue
        times = f" x{calls}" if calls > 1 else ""
        print(f"    {'  ' * indent}{total:7.2f}  {n}{times}")
        if indent < 6:
            tree(track, kids, depth + 1, indent + 1)
    whole = sum(ms(b, e) for b, e in spans)
    if inner and whole - covered >= 0.1:
        print(f"    {'  ' * indent}{whole - covered:7.2f}  (untimed)")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    names, events = read(sys.argv[1])
    if not events:
        sys.exit("no events")
    print(f"trace:   {sys.argv[1]}")
    print(f"process: {names.get('process', '(not named: an older trace)')}")
    for tid, n in sorted((t, n) for t, n in names.items() if t != 'process' and n.startswith('GPU')):
        print(f"gpu:     {n}")
    print()
    watch = sys.argv[2:] or ['frame', 'server tick', 'generate chunk', 'mesh chunk']
    # Worker threads are numbered ("worldgen 1", "mesh 2"): one row per pool.
    def thread(tid):
        n = names.get(tid, str(tid))
        return n.rstrip('0123456789').rstrip() or n

    by = collections.defaultdict(list)
    for tid, name, b, e, _depth, _args in events:
        by[(thread(tid), name)].append(ms(b, e))
    print(f"{'thread':16} {'scope':26} {'calls':>7} {'total ms':>10} {'p50':>8} {'p99':>8} {'max':>8}")
    for (t, n), d in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        d.sort()
        print(f"{t[:16]:16} {n[:26]:26} {len(d):7} {sum(d):10.1f} {d[len(d) // 2]:8.3f} "
              f"{d[min(len(d) - 1, len(d) * 99 // 100)]:8.3f} {d[-1]:8.3f}")

    t0 = min(e[2] for e in events)
    seconds = int((max(e[3] for e in events) - t0) / 1e9) + 1
    per = collections.defaultdict(lambda: [0, 0.0])
    for _tid, name, b, e, _depth, _args in events:
        if name in watch:
            row = per[(int((b - t0) / 1e9), name)]
            row[0] += 1
            row[1] += ms(b, e)
    print("\nper second: calls and ms of " + ", ".join(watch))
    for s in range(seconds):
        cells = [f"{per[(s, w)][0]:6} {per[(s, w)][1]:8.1f}" for w in watch]
        print(f"{s:4}s " + " | ".join(cells))

    for thread_name, scope in (('main', 'frame'), ('server', 'server tick')):
        track = [e for e in events if names.get(e[0]) == thread_name]
        outer = sorted((e for e in track if e[1] == scope), key=lambda e: -ms(e[2], e[3]))
        if not outer:
            continue
        print(f"\nslowest {scope}s ({thread_name}): the scopes directly inside")
        for _tid, _n, b, e, depth, args in outer[:SLOWEST]:
            inner = collections.Counter()
            for _t, n, ib, ie, d, _a in track:
                if d == depth + 1 and ib >= b and ie <= e:
                    inner[n] += ms(ib, ie)
            covered = sum(inner.values())
            parts = ", ".join(f"{n} {v:.1f}" for n, v in inner.most_common(6))
            label = f"{args} " if args else ""
            print(f"  {ms(b, e):7.1f} ms {label}at {ms(t0, b) / 1000:6.2f}s: {parts}; untimed {ms(b, e) - covered:.1f}")
        # The slowest three as trees: every scope inside over 0.1 ms, by level.
        for _tid, _n, b, e, depth, args in outer[:TREES]:
            print(f"\n  {scope}{' ' + args if args else ''} ({ms(b, e):.1f} ms) as a tree (ms; scopes over 0.1 ms, calls merged):")
            tree(track, [(b, e)], depth, 1)


main()
