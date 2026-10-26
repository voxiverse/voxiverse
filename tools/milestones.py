#!/usr/bin/env python3
"""Run PLAN.md's milestones back to back, each in a fresh Claude Code session.

    tools/milestones.py                  # until stopped
    tools/milestones.py -n 3             # at most three
    tools/milestones.py --yolo           # pass --dangerously-skip-permissions
    tools/milestones.py -- --model opus  # anything after -- goes to `claude`

Every iteration is a new `claude -p` conversation, so the context is empty each
time (the skill reads PLAN.md itself). When PLAN.md has no open milestone row, a
planning session adds one first. An iteration counts as progress only if it
made a new commit; two in a row that do not stop the loop, as does
`touch build/milestones/STOP`, a failing `claude`, or -n being reached.
Each session's output is kept in build/milestones/<time>-<n>.log.
"""

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOGS = REPO / "build" / "milestones"
STOP = LOGS / "STOP"

MILESTONE_PROMPT = "/next-milestone"
PLANNING_PROMPT = (
    "PLAN.md has no open milestone row. Plan the next one: read PLAN.md's "
    "'Ground rules', 'Layout', the deferred sections and the 'After' list, "
    "pick what pays off most for the foundations (the project's direction is an MMO RPG: "
    "measurement, character state, economy, multiplayer safety before trinkets), "
    "and write it as a new row in the milestones table plus a complete section "
    "(design decided, an exit check), sized as 'How a milestone is sized' says. "
    "Do not implement it. Commit as Voxiverse Admin with the Co-Authored-By line and push to main."
)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=REPO, check=True, capture_output=True, text=True
    ).stdout.strip()


def open_milestones() -> list[str]:
    """Rows of the milestone table (| M31 | <slice> | <check> |) after the last
    one marked done (the oldest rows were never marked).

    The cost table has rows that start the same way but a number in the second
    cell; those are not milestones."""
    rows = []
    for line in (REPO / "PLAN.md").read_text().splitlines():
        m = re.match(r"\|\s*(M\d+\w*)\s*\|\s*([^|]*)\|", line)
        if not m or re.fullmatch(r"\s*\d+\s*", m.group(2)):
            continue
        if "(done:" in line:
            rows.clear()
        else:
            rows.append(m.group(1))
    return rows


def run_claude(prompt: str, extra: list[str], log: Path) -> int:
    cmd = ["claude", "-p", prompt, *extra]
    print(f"  $ {' '.join(cmd[:3])} ... ({log.relative_to(REPO)})", flush=True)
    with log.open("w") as out:
        proc = subprocess.run(cmd, cwd=REPO, stdout=out, stderr=subprocess.STDOUT)
    return proc.returncode


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--max", type=int, default=0, help="stop after this many milestones (0: no limit)")
    ap.add_argument("--yolo", action="store_true", help="pass --dangerously-skip-permissions to claude (no prompts)")
    ap.add_argument("--pause", type=int, default=5, help="seconds between sessions")
    ap.add_argument("claude_args", nargs="*", help="after --: passed to claude")
    args = ap.parse_args()
    extra = list(args.claude_args)
    if args.yolo:
        extra.append("--dangerously-skip-permissions")

    LOGS.mkdir(parents=True, exist_ok=True)
    STOP.unlink(missing_ok=True)
    stalls = done = 0
    while not STOP.exists() and (args.max == 0 or done < args.max):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        before = git("rev-parse", "HEAD")
        if not open_milestones():
            print("no open milestone: planning one", flush=True)
            code = run_claude(PLANNING_PROMPT, extra, LOGS / f"{stamp}-plan.log")
            if code != 0 or not open_milestones():
                print(f"planning failed (exit {code}); stopping", file=sys.stderr)
                return 1
            continue
        which = open_milestones()[0]
        print(f"[{done + 1}] {which}", flush=True)
        code = run_claude(MILESTONE_PROMPT, extra, LOGS / f"{stamp}-{which}.log")
        after = git("rev-parse", "HEAD")
        if code != 0:
            print(f"claude exited {code}; stopping (see the log)", file=sys.stderr)
            return code
        if after == before:
            stalls += 1
            print(f"  no commit ({stalls} in a row)", flush=True)
            if stalls >= 2:
                print("two sessions without progress; stopping", file=sys.stderr)
                return 2
        else:
            stalls = 0
            done += 1
            print(f"  committed {after[:8]}: {git('log', '-1', '--format=%s')}", flush=True)
        time.sleep(args.pause)
    print("stopped" if STOP.exists() else f"{done} milestone(s) done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
