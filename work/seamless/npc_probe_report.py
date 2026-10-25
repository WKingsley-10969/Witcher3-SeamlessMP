"""Compare the two games' NPC lists from an npc_probe run.

Pairs each BotA sample with the BotB sample nearest in wall-clock time, then matches NPCs:
first by voicetag when it is unique on both sides, otherwise by template + appearance with the
nearest unclaimed candidate. Reports how many NPCs exist in both worlds, how many could be
matched and by what, how far apart matched NPCs stand and how often their activity differs.

    python -I npc_probe_report.py <run dir>
"""
import re
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

LINE = re.compile(r"^(\d\d:\d\d:\d\d\.\d+) NPC sample=(\d+) voice=(.*?) tpl=(\S*) app=(\S*) tags=(\S*) pos=([-\d.]+),([-\d.]+),([-\d.]+) "
                  r"yaw=([-\d.]+) action=(\d+) work=(\w+) sit=(\w+) combat=(\w+) horse=(\w+)")
SAMPLE = re.compile(r"^(\d\d:\d\d:\d\d\.\d+) NPCSAMPLE sample=(\d+) count=(\d+)")
UNNAMED = {"", "None", "NONE"}


def clock(text):
    return datetime.strptime(text, "%H:%M:%S.%f")


def load(path):
    samples, times = defaultdict(list), {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = LINE.match(line)
        if m:
            t, s, voice, tpl, app, tags, x, y, z, yaw, action, work, sit, combat, horse = m.groups()
            samples[int(s)].append({"voice": voice, "tpl": tpl, "app": app, "tags": tags, "pos": (float(x), float(y), float(z)),
                                    "yaw": float(yaw), "action": int(action), "work": work == "true", "sit": sit == "true",
                                    "combat": combat == "true", "horse": horse == "true"})
            continue
        m = SAMPLE.match(line)
        if m:
            times[int(m.group(2))] = clock(m.group(1))
    return samples, times


def distance(a, b):
    return sum((p - q) ** 2 for p, q in zip(a, b)) ** 0.5


def match(left, right):
    pairs, used, how = [], set(), Counter()
    voices_l = Counter(n["voice"] for n in left if n["voice"] not in UNNAMED)
    voices_r = Counter(n["voice"] for n in right if n["voice"] not in UNNAMED)
    pending = []
    for a in left:
        if a["voice"] not in UNNAMED and voices_l[a["voice"]] == 1 and voices_r[a["voice"]] == 1:
            j = next(i for i, b in enumerate(right) if b["voice"] == a["voice"])
            pairs.append((a, right[j])); used.add(j); how["unique voicetag"] += 1
        else:
            pending.append(a)
    for a in pending:
        best, best_d = None, None
        for j, b in enumerate(right):
            if j in used or b["tpl"] != a["tpl"] or b["app"] != a["app"]:
                continue
            d = distance(a["pos"], b["pos"])
            if best_d is None or d < best_d:
                best, best_d = j, d
        if best is None:
            how["no counterpart"] += 1
            continue
        used.add(best)
        pairs.append((a, right[best]))
        same = sum(1 for b in right if b["tpl"] == a["tpl"] and b["app"] == a["app"])
        how["template+appearance (unique)" if same == 1 else "template+appearance (ambiguous, nearest)"] += 1
    return pairs, how, len(right) - len(used)


def main(run):
    a_samples, a_times = load(Path(run) / "BotA.log")
    b_samples, b_times = load(Path(run) / "BotB.log")
    if not a_samples or not b_samples:
        raise SystemExit("no NPC samples in one of the logs")
    gaps, totals = [], Counter()
    all_dist, moving_dist, action_diff, work_diff = [], [], 0, 0
    for s, when in sorted(a_times.items()):
        other = min(b_times, key=lambda k: abs((b_times[k] - when).total_seconds()))
        gap = abs((b_times[other] - when).total_seconds())
        gaps.append(gap)
        left, right = a_samples[s], b_samples[other]
        pairs, how, only_b = match(left, right)
        totals.update(how)
        totals["only in BotB"] += only_b
        totals["BotA NPCs"] += len(left)
        totals["BotB NPCs"] += len(right)
        for x, y in pairs:
            d = distance(x["pos"], y["pos"])
            all_dist.append(d)
            if x["action"] != y["action"]:
                action_diff += 1
            if x["work"] != y["work"] or x["sit"] != y["sit"]:
                work_diff += 1
        print(f"A sample {s} vs B sample {other} ({gap:.1f} s apart): A={len(left)} B={len(right)} matched={len(pairs)} "
              + ", ".join(f"{k}={v}" for k, v in sorted(how.items())) + f", only in B={only_b}")
    matched = len(all_dist)
    print()
    print(f"Samples paired: {len(gaps)}, wall-clock gap median {statistics.median(gaps):.1f} s")
    for key in ("BotA NPCs", "BotB NPCs", "unique voicetag", "template+appearance (unique)",
                "template+appearance (ambiguous, nearest)", "no counterpart", "only in BotB"):
        print(f"  {key}: {totals[key]}")
    if matched:
        all_dist.sort()
        print(f"Matched pairs: {matched}; distance between the two copies: median {statistics.median(all_dist):.1f} m, "
              f"90th pct {all_dist[int(0.9 * (matched - 1))]:.1f} m, max {all_dist[-1]:.1f} m; "
              f"over 2 m apart: {sum(d > 2 for d in all_dist)} ({100 * sum(d > 2 for d in all_dist) / matched:.0f}%)")
        print(f"  different current action: {action_diff} ({100 * action_diff / matched:.0f}%), "
              f"different work/sitting state: {work_diff} ({100 * work_diff / matched:.0f}%)")
    voices = Counter(n["voice"] for ns in a_samples.values() for n in ns)
    named = sorted(v for v in voices if v not in UNNAMED)
    print(f"Distinct voicetags seen by BotA: {len(named)} (e.g. {', '.join(named[:12])})")


if __name__ == "__main__":
    main(sys.argv[1])
