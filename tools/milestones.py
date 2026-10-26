#!/usr/bin/env python3
"""Run PLAN.md's milestones back to back, each in a fresh Claude Code session.

    tools/milestones.py                  # until stopped
    tools/milestones.py -n 3             # at most three
    tools/milestones.py --dry-run        # say what would run next, run nothing
    tools/milestones.py --yolo           # pass --dangerously-skip-permissions
    tools/milestones.py -- --effort high # anything after -- goes to `claude`

Why a loop outside Claude: one long session re-reads its whole conversation on
every step (PLAN.md measured 4.2 billion tokens over M19-M21). Every iteration
here is a new `claude -p` conversation with an empty context; the skill reads
PLAN.md itself.

Each round:
  1. the first open row of PLAN.md's milestone table is the target;
  2. if it has no section of its own ("## M<n>" or "### M<n>"), a planning
     session (the strongest model) writes one first and commits it;
  3. a milestone session runs /next-milestone, told it is unattended: an open
     design question is settled by the plan's principles and written into the
     section, never asked.
With no open row at all, a planning session adds one.

It stops on: `touch build/milestones/STOP`, -n reached, a failing `claude` that
is not a usage limit, or two sessions in a row without a new commit. A usage
limit is waited out (--limit-wait minutes, tried again, as often as it takes).
Each session's output is kept in build/milestones/<time>-<what>.log.
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

UNATTENDED = (
    "You are running unattended in a loop; nobody is there to answer. Where the "
    "section leaves a decision open, decide it from PLAN.md's principles and "
    "decisions, write the decision into the section, and go on. Never stop to ask. "
    "If the milestone outgrows the session, follow step 4 (commit what works, "
    "write the rest as a new milestone) and finish normally."
)
SECTION_PROMPT = (
    "PLAN.md's milestone {which} has a table row but no section of its own. Write "
    "it: read PLAN.md's 'Ground rules', 'Layout', 'Nomenclature', 'How a milestone is "
    "sized' and everything it says about {which} (the audio milestones, the foundation "
    "arc). Look at the code it will touch. Write a complete section ('## {which}: ...') "
    "after the table: why, the design decided (formats, numbers, names, files, the "
    "order of the steps), what is left out, the tests, the exit check. Settle every "
    "design question yourself from the plan's decisions and principles. Do not implement "
    "it. Commit as Voxiverse Admin with the Co-Authored-By line and push to main. " + UNATTENDED
)
PLANNING_PROMPT = (
    "PLAN.md has no open milestone row. Plan the next one: read PLAN.md's 'Ground "
    "rules', 'Layout', the foundation arc, the deferred sections and the 'After' list, "
    "pick what pays off most for the foundations (the direction: gameplay written for "
    "each player by agents, so the engine, safety and measurement before content), and "
    "write it as a new row in the milestones table plus a complete section sized as "
    "'How a milestone is sized' says. Do not implement it. Commit as Voxiverse Admin "
    "with the Co-Authored-By line and push to main. " + UNATTENDED
)
LIMIT_WORDS = re.compile(r"usage limit|limit reached|rate limit|overloaded|resets? (at|in)", re.I)


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


def has_section(which: str) -> bool:
    pattern = re.compile(rf"^#{{2,3}} {re.escape(which)}\b", re.M)
    return bool(pattern.search((REPO / "PLAN.md").read_text()))


def run_claude(prompt: str, extra: list[str], log: Path, wait: int) -> int:
    """One session; a usage limit is waited out and the session started again."""
    cmd = ["claude", "-p", prompt, *extra]
    while True:
        print(f"  $ claude -p ... ({log.relative_to(REPO)})", flush=True)
        with log.open("w") as out:
            code = subprocess.run(cmd, cwd=REPO, stdout=out, stderr=subprocess.STDOUT).returncode
        if code == 0:
            return 0
        tail = log.read_text()[-2000:]
        if not LIMIT_WORDS.search(tail) or STOP.exists():
            return code
        print(f"  limit hit; waiting {wait} min, then again", flush=True)
        for _ in range(wait * 6):
            if STOP.exists():
                return code
            time.sleep(10)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--max", type=int, default=0, help="stop after this many milestones (0: no limit)")
    ap.add_argument("--dry-run", action="store_true", help="print what would run next and stop")
    ap.add_argument("--yolo", action="store_true", help="pass --dangerously-skip-permissions to claude (no prompts)")
    ap.add_argument("--pause", type=int, default=5, help="seconds between sessions")
    ap.add_argument("--limit-wait", type=int, default=30, help="minutes to wait after a usage limit")
    ap.add_argument("--model", default="sonnet", help="model for milestone sessions")
    ap.add_argument("--plan-model", default="opus", help="model for planning sessions")
    ap.add_argument("--allow-dirty", action="store_true", help="start with uncommitted changes")
    ap.add_argument("claude_args", nargs="*", help="after --: passed to claude")
    args = ap.parse_args()
    extra = list(args.claude_args)
    if args.yolo:
        extra.append("--dangerously-skip-permissions")

    rows = open_milestones()
    if args.dry_run:
        if not rows:
            print("no open milestone: a planning session would add one")
        else:
            first = rows[0]
            print(f"next: {first} ({'has' if has_section(first) else 'needs'} a section); open: {' '.join(rows)}")
        return 0
    if git("status", "--porcelain") and not args.allow_dirty:
        print("uncommitted changes; commit or stash them first (or --allow-dirty)", file=sys.stderr)
        return 1

    LOGS.mkdir(parents=True, exist_ok=True)
    STOP.unlink(missing_ok=True)
    stalls = done = 0
    while not STOP.exists() and (args.max == 0 or done < args.max):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        before = git("rev-parse", "HEAD")
        rows = open_milestones()
        if not rows:
            print("no open milestone: planning one", flush=True)
            code = run_claude(PLANNING_PROMPT, ["--model", args.plan_model, *extra], LOGS / f"{stamp}-plan.log", args.limit_wait)
            if code != 0 or not open_milestones():
                print(f"planning failed (exit {code}); stopping", file=sys.stderr)
                return 1
            continue
        which = rows[0]
        if not has_section(which):
            print(f"{which} has no section: writing it", flush=True)
            prompt = SECTION_PROMPT.format(which=which)
            code = run_claude(prompt, ["--model", args.plan_model, *extra], LOGS / f"{stamp}-{which}-section.log", args.limit_wait)
            what = "section"
        else:
            print(f"[{done + 1}] {which}", flush=True)
            prompt = f"Invoke the next-milestone skill with the argument {which}. {UNATTENDED}"
            code = run_claude(prompt, ["--model", args.model, *extra], LOGS / f"{stamp}-{which}.log", args.limit_wait)
            what = "milestone"
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
            if what == "milestone":
                done += 1
            print(f"  committed {after[:8]}: {git('log', '-1', '--format=%s')}", flush=True)
        time.sleep(args.pause)
    print("stopped" if STOP.exists() else f"{done} milestone(s) done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
