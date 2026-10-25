"""Build real native unit tests against guard-breaking mutations; no game launched."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
header = (root / "../../WitcherOnline/client/seamless/FactDeltaTracker.h").read_text()
fixture = (root / "fact_tracker_test.cpp").read_text().replace('#include "../../WitcherOnline/client/seamless/FactDeltaTracker.h"', '#include "FactDeltaTracker.h"')
vcvars = r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
mutations = {
    "allow_any_fact": ("if (target.size() <= 8", "if (false && target.size() <= 8"),
    "widen_vetted_quest_facts": ('return target == "mh306_job_taken";', 'return target.size() > 2 && target.compare(0, 2, "mh") == 0;'),
    "collapse_absent_zero": ("return exists == other.exists && (!exists || value == other.value);", "return value == other.value;"),
    "ack_any_revision": ("pending_.front().revision != revision", "false /* any revision */"),
    "swallow_prior_local": ("remoteTarget_ = target;", "pending_.clear(); remoteTarget_ = target;"),
    "echo_remote_apply": ("watched_[remoteTarget_] = StateOf(afterApply, remoteTarget_);", "/* don't suppress remote effect */"),
    "stale_load_ack": ("pending_.front().generation != generation", "false /* ignore epoch */"),
    "lose_overflow": ("if (changes.size() > maxPending_ - pending_.size() ||", "if (false && changes.size() > maxPending_ - pending_.size() ||"),
}
build = root / "build"
build.mkdir(exist_ok=True)
for name, (old, new) in mutations.items():
    if header.count(old) != 1:
        raise AssertionError(f"mutation target changed: {name}")
    folder = build / name
    folder.mkdir(exist_ok=True)
    (folder / "FactDeltaTracker.h").write_text(header.replace(old, new))
    # Suppress unused formal parameters in intentionally guard-breaking mutants.
    (folder / "fact_tracker_test.cpp").write_text(fixture)
    cmd = folder / "build.cmd"
    cmd.write_text(f'@echo off\ncall "{vcvars}" >nul\ncl /nologo /std:c++17 /EHsc /W4 /wd4100 /Fe:"{folder / "test.exe"}" /Fo:"{folder / "test.obj"}" "{folder / "fact_tracker_test.cpp"}"\n')
    compile_result = subprocess.run(["cmd", "/d", "/c", str(cmd)], capture_output=True, text=True)
    if compile_result.returncode:
        raise AssertionError(f"mutant failed to build: {name}\n{compile_result.stdout}\n{compile_result.stderr}")
    result = subprocess.run([str(folder / "test.exe")], capture_output=True, text=True)
    if result.returncode == 0:
        raise AssertionError(f"mutation survived: {name}")
    print(f"CAUGHT {name}: {(result.stderr or result.stdout).strip()}")
print(f"PASS {len(mutations)} guard-breaking native mutations caught")
