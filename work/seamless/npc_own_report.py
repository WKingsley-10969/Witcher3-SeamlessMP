"""Judge an npc_own run: per-NPC ownership of Ciri between the two worlds.

Reads the "CIRI host" (BotA, the leader) and "CIRI member" (BotB, the second PC) lines and reports
- the ownership timeline on both sides,
- running in place: the shown Ciri playing a walk/run (anim > 0.5) while moving under 0.2 m/s,
- sliding: a shown stand-in moving over 0.5 m/s with no walk/run playing (anim < 0.3),
- duplicates: samples where a screen shows Ciri other than exactly once,
- the mirror error: how far apart the two screens show Ciri, while the second PC owns her and
  while the leader does (same wall clock, both bots run on one machine; the second PC's position
  is interpolated to the leader's sample time, the two bots log about 0.5 s apart).

    python -I npc_own_report.py <run dir>
"""
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path

VEC = r"([-\d.]+),([-\d.]+),([-\d.]+)"
LINE = re.compile(r"^(\d\d:\d\d:\d\d\.\d+) CIRI (host|member) (.*)$")
SHOWN = re.compile(r"shownAt=" + VEC + r" anim=([-\d.]+) dist=([-\d.]+) standIn=(\w+)")
MODE = re.compile(r"(?:mode|owner)=(\S*)")
VISIBLE = re.compile(r"visible=(\d+)")


def clock(text):
    return datetime.strptime(text, "%H:%M:%S.%f")


def load(path, side):
    rows = []
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = LINE.match(line)
        if not m or m.group(2) != side:
            continue
        s = SHOWN.search(m.group(3))
        mode = MODE.match(m.group(3))
        visible = VISIBLE.search(m.group(3))
        if not s:
            continue
        rows.append({"t": clock(m.group(1)), "mode": mode.group(1) if mode else "?",
                     "pos": tuple(float(s.group(i)) for i in (1, 2, 3)), "anim": float(s.group(4)),
                     "dist": float(s.group(5)), "standIn": s.group(6) == "true",
                     "visible": int(visible.group(1)) if visible else None})
    return rows


def distance(a, b):
    return sum((p - q) ** 2 for p, q in zip(a, b)) ** 0.5


def timeline(rows, name):
    print(f"{name} ownership timeline:")
    last = None
    for r in rows:
        if r["mode"] != last:
            print(f"  {r['t'].time()} {r['mode']} (stand-in shown={r['standIn']}, player {r['dist']} m from Ciri)")
            last = r["mode"]


def treadmill(rows, name):
    hits, slides, samples = [], [], 0
    for a, b in zip(rows, rows[1:]):
        dt = (b["t"] - a["t"]).total_seconds()
        if dt <= 0 or dt > 3:
            continue
        samples += 1
        moved = distance(a["pos"], b["pos"]) / dt
        if b["anim"] > 0.5 and moved < 0.2:
            hits.append((b["t"].time(), b["mode"], b["anim"], round(moved, 2)))
        if b["standIn"] and 0.5 < moved < 10 and b["anim"] < 0.3:  # faster is a teleport
            slides.append((b["t"].time(), b["mode"], b["anim"], round(moved, 2)))
    print(f"{name}: running in place in {len(hits)} of {samples} one-second steps")
    for h in hits[:10]:
        print(f"    {h[0]} mode={h[1]} anim={h[2]} moved={h[3]} m/s")
    print(f"{name}: stand-in sliding without a walk in {len(slides)} of {samples} one-second steps")
    for h in slides[:10]:
        print(f"    {h[0]} mode={h[1]} anim={h[2]} moved={h[3]} m/s")


def duplicates(rows, name):
    counted = [r for r in rows if r["visible"] is not None]
    wrong = [r for r in counted if r["visible"] != 1]
    print(f"{name}: Ciri visible exactly once in {len(counted) - len(wrong)} of {len(counted)} samples")
    for r in wrong[:10]:
        print(f"    {r['t'].time()} visible={r['visible']} mode={r['mode']}")


def mirror(host, member):
    groups = {}
    for h in host:
        later = next((i for i, m in enumerate(member) if m["t"] >= h["t"]), None)
        if not later:
            continue
        a, b = member[later - 1], member[later]
        span = (b["t"] - a["t"]).total_seconds()
        if span <= 0 or span > 1.5 or a["mode"] != b["mode"]:
            continue
        f = (h["t"] - a["t"]).total_seconds() / span
        pos = tuple(p + f * (q - p) for p, q in zip(a["pos"], b["pos"]))
        key = "second PC owns her" if a["mode"] == "owned" else "leader owns her"
        groups.setdefault(key, []).append(distance(h["pos"], pos))
    for key, values in groups.items():
        values.sort()
        print(f"Mirror error while {key}: {len(values)} samples, median {statistics.median(values):.2f} m, "
              f"90th pct {values[int(0.9 * (len(values) - 1))]:.2f} m, max {values[-1]:.2f} m")


def main(run):
    run = Path(run)
    host, member = load(run / "BotA.log", "host"), load(run / "BotB.log", "member")
    if not host or not member:
        raise SystemExit("no CIRI lines with a shown Ciri in one of the logs")
    timeline(host, "Leader (BotA)")
    timeline(member, "Second PC (BotB)")
    treadmill(host, "Leader's screen")
    treadmill(member, "Second PC's screen")
    duplicates(host, "Leader's screen")
    duplicates(member, "Second PC's screen")
    mirror(host, member)


if __name__ == "__main__":
    main(sys.argv[1])
