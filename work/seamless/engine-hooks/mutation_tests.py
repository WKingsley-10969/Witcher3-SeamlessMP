"""Compile real journal tests against deliberately broken guards; no game is launched."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
header = (root / '../../WitcherNativeBridge/src/FactOperationJournal.h').read_text(encoding='utf-8')
test = (root / 'fact_operations_test.cpp').read_text(encoding='utf-8').replace(
    '#include "../../WitcherNativeBridge/src/FactOperationJournal.h"', '#include "FactOperationJournal.h"')
vcvars = r'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
mutations = {
    'allow_real_targets': ('if (value.size() <= 8 || value.size() > 96 || value.compare(0, 8, "sc_test_") != 0)', 'if (value.empty())'),
    'ignore_watch': ('|| !watches_.count(target)', ''),
    'lose_expiry': ('target, value, validFor, telemetry, observedAt}', 'target, value, 0, telemetry, observedAt}'),
    'ignore_ack_generation': ('pending_.front().generation != generation', 'false /* stale ACK accepted */'),
    'ignore_ack_order': ('pending_.front().revision != revision', 'false /* future ACK accepted */'),
    'echo_remote': ('if (remote_) return true;', 'if (false && remote_) return true;'),
    'swallow_prior_local': ('remote_ = true;', 'pending_.clear(); remote_ = true;'),
    'drop_on_overflow': ('error_ = "OVERFLOW_RECONCILE_REQUIRED";', 'pending_.clear(); /* no sticky gap */'),
    'ack_overflow_away': ('if (!error_.empty() || pending_.empty() ||', 'if (pending_.empty() ||'),
    'reuse_load_generation': ('generation_ = generation_ == INT32_MAX ? 1 : generation_ + 1;', '/* generation never changes */'),
}
for name, (old, replacement) in mutations.items():
    assert header.count(old) == 1, f'mutation target changed: {name}'
    folder = root / 'build' / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'FactOperationJournal.h').write_text(header.replace(old, replacement), encoding='utf-8')
    (folder / 'fact_operations_test.cpp').write_text(test, encoding='utf-8')
    script = folder / 'build.cmd'
    script.write_text(f'@echo off\ncall "{vcvars}" >nul\ncl /nologo /std:c++17 /EHsc /W4 /WX /wd4100 /wd4127 /Fe:"{folder / "test.exe"}" /Fo:"{folder / "test.obj"}" "{folder / "fact_operations_test.cpp"}"\n', encoding='utf-8')
    compiled = subprocess.run(['cmd', '/d', '/c', str(script)], capture_output=True, text=True)
    assert compiled.returncode == 0, f'{name} did not compile:\n{compiled.stdout}\n{compiled.stderr}'
    result = subprocess.run([str(folder / 'test.exe')], capture_output=True, text=True)
    assert result.returncode != 0, f'mutation survived: {name}'
    print(f'CAUGHT {name}: {(result.stderr or result.stdout).strip()}')
print(f'Fact operation journal mutation PASS: {len(mutations)} broken guards caught')
