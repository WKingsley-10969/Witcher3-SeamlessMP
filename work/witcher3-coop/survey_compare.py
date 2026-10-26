"""monster_survey: what each monster's copy on the second PC lacks. Usage: survey_compare.py <run folder>...

Reads the SURVEY lines of BotA.log (the leader's real monsters) and BotB.log (the second PC's copies) and
prints, per monster, the values the leader saw and the copy did not, and the other way round."""
import collections
import pathlib
import sys

KINDS = ("buff", "app", "stance", "air", "mode", "ent")


def read(log, side):
    seen = collections.defaultdict(lambda: collections.defaultdict(set))
    notes = collections.defaultdict(list)
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split(" ")
        if len(parts) < 6 or parts[1] != "SURVEY" or parts[2] != side:
            continue
        monster, kind, value = parts[3], parts[4], " ".join(parts[5:])
        if kind in KINDS:
            seen[monster][kind].add(value)
        else:
            notes[monster].append(" ".join(parts[4:]))
    return seen, notes


for run in map(pathlib.Path, sys.argv[1:]):
    leader, leader_notes = read(run / "BotA.log", "leader")
    copy, copy_notes = read(run / "BotB.log", "copy")
    print(f"# {run.name}")
    for monster in leader_notes.keys() | leader.keys():
        print(f"\n## {monster}")
        for note in leader_notes[monster] + copy_notes[monster]:
            print(f"  note: {note}")
        if monster not in copy:
            print("  NO COPY on the second PC")
            continue
        for kind in KINDS:
            missing = sorted(leader[monster][kind] - copy[monster][kind])
            extra = sorted(copy[monster][kind] - leader[monster][kind])
            if missing:
                print(f"  {kind:6} copy lacks: {', '.join(missing)}")
            if extra:
                print(f"  {kind:6} copy only: {', '.join(extra)}")
