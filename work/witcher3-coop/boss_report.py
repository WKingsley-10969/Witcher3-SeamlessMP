"""boss_fight: what the second PC got wrong in a quest fight. Usage: boss_report.py <run folder>...

Reads the BOSS lines of BotA.log (the leader's real fight) and BotB.log (the second PC's copies of it), pairs each
leader sample with the second PC's nearest one (both games log the same clock) and prints, per enemy kind, how long
each difference lasted: enemies with no copy, copies of nothing, health apart by over 10 points, immortality mode,
gameplay visibility, stance and flight. Then the second PC's own hostiles, the quest objectives and scenes each side
saw, and the hit counters."""
import collections
import datetime
import pathlib
import sys

PAIR_WINDOW = 2.5  # seconds between a leader sample and the second PC's that can be compared
HP_APART = 10
TRANSIENT = 2  # samples (about 4 s): a copy appearing, dying or changing that late is the snapshot delay


def clock(stamp):
    return datetime.datetime.strptime(stamp, "%H:%M:%S.%f")


def read(log, side):
    samples, own, objectives, scenes, counters, notes = [], [], [], [], "", []
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split(" ", 4)
        if len(parts) < 4 or parts[1] != "BOSS" or parts[2] != side:
            continue
        at, kind, rest = clock(parts[0]), parts[3], parts[4] if len(parts) > 4 else ""
        if kind == "enemies":
            enemies = []
            for item in rest.split("|", 1)[1].split(";"):
                f = item.split()
                if len(f) >= 5:
                    enemies.append(dict(name=f[0], hp=int(f[1]), mode=f[2], vis=f[3], stance=f[4],
                                        fly="fly" in f[5:], shared="x" not in f[5:], alive="dead" not in f[5:]))
            samples.append((at, enemies))
        elif kind == "own":
            names = [n.strip() for n in rest.split("|", 1)[1].split(";") if n.strip()]
            own.append((at, names))
        elif kind == "objectives":
            objectives.append((at, rest.split("|", 1)[1].strip(" ;")))
        elif kind == "scene":
            scenes.append((at, rest))
        elif kind == "counters":
            counters = rest
        else:
            notes.append(f"{parts[0]} {kind} {rest}")
    return samples, own, objectives, scenes, counters, notes


def nearest(samples, at):
    best = min(samples, key=lambda s: abs((s[0] - at).total_seconds()), default=None)
    if best and abs((best[0] - at).total_seconds()) <= PAIR_WINDOW:
        return best[1]
    return None


def compare(leader, copy):
    """{(enemy name, issue): [first time, samples]} over the paired samples."""
    issues = collections.OrderedDict()

    def note(at, name, issue):
        entry = issues.setdefault((name, issue), [at, 0])
        entry[1] += 1

    for at, real in leader:
        copies = nearest(copy, at)
        if copies is None:
            continue
        shared = [e for e in real if e["shared"]]
        for e in real:
            if not e["shared"]:
                note(at, e["name"], "not shared with the second PC")
        alive = [c for c in copies if c["alive"]]
        by_name = collections.defaultdict(lambda: ([], []))
        for e in shared:
            by_name[e["name"]][0].append(e)
        for c in alive:
            by_name[c["name"]][1].append(c)
        for name, (es, cs) in by_name.items():
            if len(es) > len(cs):
                note(at, name, f"no copy on the second PC ({len(es) - len(cs)} of {len(es)})")
            elif len(cs) > len(es):
                note(at, name, f"copy of nothing the leader has ({len(cs) - len(es)})")
            # pair by health, highest first: the closest guess without network ids
            for e, c in zip(sorted(es, key=lambda x: -x["hp"]), sorted(cs, key=lambda x: -x["hp"])):
                if abs(e["hp"] - c["hp"]) > HP_APART:
                    note(at, name, "health apart by over 10 points")
                if e["mode"] != c["mode"]:
                    note(at, name, f"immortality mode leader {e['mode']} copy {c['mode']}")
                if e["vis"] != c["vis"]:
                    note(at, name, f"gameplay visibility leader {e['vis']} copy {c['vis']}")
                if e["stance"] != c["stance"]:
                    note(at, name, f"stance leader {e['stance']} copy {c['stance']}")
                if e["fly"] != c["fly"]:
                    note(at, name, "flying on one PC only")
    return issues


for run in map(pathlib.Path, sys.argv[1:]):
    leader, _, leader_obj, leader_scenes, leader_counters, leader_notes = read(run / "BotA.log", "leader")
    copy, own, copy_obj, copy_scenes, copy_counters, copy_notes = read(run / "BotB.log", "copy")
    print(f"# {run.name}")
    for n in leader_notes + copy_notes:
        print(f"  {n}")
    kinds = collections.Counter()
    for _, real in leader:
        for e in real:
            kinds[e["name"]] += 1
    print(f"\n## Enemies ({len(leader)} leader samples, {len(copy)} second-PC samples)")
    for name, count in kinds.most_common():
        print(f"  {name}: seen in {count} samples")
    print("\n## Differences (first seen, samples)")
    issues = compare(leader, copy)
    lasting = {k: v for k, v in issues.items() if v[1] > TRANSIENT}
    for (name, issue), (first, count) in lasting.items():
        print(f"  {first:%H:%M:%S} x{count:<4} {name}: {issue}")
    if not lasting:
        print("  none")
    if len(lasting) < len(issues):
        print(f"  (and {len(issues) - len(lasting)} lasting {TRANSIENT} samples or less: the snapshot delay)")
    shown = collections.Counter()
    for _, names in own:
        for n in set(names):
            shown[n] += 1
    print("\n## The second PC's own hostiles that showed there (not copies)")
    for n, count in shown.most_common():
        print(f"  {n}: {count} samples")
    if not shown:
        print("  none")
    print("\n## Objectives")
    for label, changes in (("leader", leader_obj), ("second PC", copy_obj)):
        for at, text in changes:
            print(f"  {at:%H:%M:%S} {label}: {text or '(none open)'}")
    # what each ends on: a step the leader passed in a second may never show on the second PC
    if leader_obj and copy_obj and leader_obj[-1][1] != copy_obj[-1][1]:
        print(f"  ENDS APART: leader '{leader_obj[-1][1]}', second PC '{copy_obj[-1][1]}'")
    print("\n## Scenes")
    for label, changes in (("leader", leader_scenes), ("second PC", copy_scenes)):
        for at, scene in changes:
            print(f"  {at:%H:%M:%S} {label}: {scene}")
    print("\n## Counters at the end")
    print(f"  leader:    {leader_counters}")
    print(f"  second PC: {copy_counters}")
