"""Checks a Spall trace written by a `--profile` build: well-formed, every
begin has an end, and GPU sections sit on the CPU timeline (calibration).

    python3 tools/debugger/check_spall.py build/voxiverse.spall

Exits non-zero on any problem. The format is core:prof/spall's.
"""
import struct, sys, collections
data = open(sys.argv[1], 'rb').read()
magic, version, scale, _ = struct.unpack_from('<QQdQ', data, 0)
print(f"header: magic={magic:#x} version={version} scale={scale}")
off = 32
tracks = collections.defaultdict(list)   # tid -> list of (name, begin, end)
names = {}
problems = 0
while off < len(data):
    size, tid, pid, first_ts = struct.unpack_from('<IIIQ', data, off); off += 20
    end_off = off + size
    stack = tracks.setdefault(('stack', tid), [])
    while off < end_off:
        t = data[off]
        if t == 3:
            ts, nl, al = struct.unpack_from('<QBB', data, off + 1)
            name = data[off + 11: off + 11 + nl].decode()
            stack.append((name, ts)); off += 11 + nl + al
        elif t == 4:
            (ts,) = struct.unpack_from('<Q', data, off + 1); off += 9
            if not stack: problems += 1; continue
            name, b = stack.pop(); tracks[tid].append((name, b, ts, len(stack)))
        elif t == 9:
            nl = data[off + 1]; names[tid] = data[off + 2: off + 2 + nl].decode(); off += 2 + nl
        elif t == 7:
            (sz,) = struct.unpack_from('<I', data, off + 1); off += sz
        else:
            print("unknown event", t, "at", off); problems += 1; break
for key, stack in list(tracks.items()):
    if isinstance(key, tuple) and stack: print("unclosed:", key, stack); problems += 1
for tid, evs in tracks.items():
    if isinstance(tid, tuple): continue
    counts = collections.Counter(e[0] for e in evs)
    print(f"track {names.get(tid, tid)!r}: {len(evs)} events: " + ", ".join(f"{n}x{c}" for n, c in counts.most_common(6)))
# GPU frames must lie inside CPU time: each GPU 'frame' should end within the CPU run, and
# start after the CPU frame whose commands it executed began.
cpu = [e for tid, evs in tracks.items() if not isinstance(tid, tuple) and names.get(tid) == 'main' for e in evs if e[0] == 'frame']
gpu = [e for tid, evs in tracks.items() if not isinstance(tid, tuple) and names.get(tid, '').startswith('GPU') for e in evs if e[0] == 'frame']
cpu.sort(key=lambda e: e[1]); gpu.sort(key=lambda e: e[1])
inside = sum(1 for g in gpu if any(c[1] <= g[1] and g[2] <= c[2] + 50_000_000 for c in cpu))
print(f"CPU frames {len(cpu)}, GPU frames {len(gpu)}; GPU frames starting after a CPU frame began and ending within 50 ms of it: {inside}/{len(gpu)}")
if gpu:
    durs = sorted((g[2]-g[1])/1e6 for g in gpu); print(f"GPU frame duration ms: min {durs[0]:.3f} median {durs[len(durs)//2]:.3f} max {durs[-1]:.3f}")
    nested = [e for tid, evs in tracks.items() if not isinstance(tid, tuple) and names.get(tid, '').startswith('GPU') for e in evs if e[0] == 'triangle']
    ok_nest = sum(1 for t in nested if t[3] == 1 and any(g[1] <= t[1] and t[2] <= g[2] for g in gpu))
    print(f"GPU 'triangle' sections nested inside a GPU 'frame': {ok_nest}/{len(nested)}")
if not gpu:
    print("no GPU frames in the trace"); problems += 1
elif nested and ok_nest != len(nested):
    print("GPU sections are not nested in their frames"); problems += 1
elif 'GPU (calibrated)' in names.values() and inside != len(gpu):
    print("calibrated GPU events are not aligned with CPU frames"); problems += 1
elif 'GPU (calibrated)' not in names.values():
    print("GPU timestamps not calibrated on this machine: alignment not checked")
print("problems:", problems)
sys.exit(1 if problems else 0)
