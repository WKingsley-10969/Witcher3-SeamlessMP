"""Real-process regression checks of save-isolation startup; no game or owner files written."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
fixture = root / 'sandbox_fixture.exe'
docs = root / 'documents'
docs.mkdir(exist_ok=True)
cases = [
    ('all document APIs redirect', 'valid', str(docs), 0),
    ('human LAN profile redirects without test mode', 'interactive', str(docs), 0),
    ('missing path terminates', 'missing', '', 9),
    ('relative path terminates', 'relative', 'relative', 9),
    ('nonexistent path terminates', 'nonexistent', str(root / 'does-not-exist'), 9),
    ('owner documents rejected', 'owner', str(docs), 9),
    ('owner trailing slash rejected', 'owner-slash', str(docs), 9),
    ('owner dot alias rejected', 'owner-dot', str(docs), 9),
    ('missing required import terminates', 'missing-import', str(docs), 9),
    ('long wide path never falls back', 'long-wide', 'C:\\' + 'a' * 260, 0),
]
failures = []
for label, mode, path, expected in cases:
    env = dict(os.environ, W3T_SCENARIO='fixture', W3T_DOCUMENTS=path,
               W3T_LOG=str(root / (mode + '.log')))
    result = subprocess.run([str(fixture), mode], env=env, timeout=10, capture_output=True)
    passed = result.returncode == expected
    print(f'{"PASS" if passed else "FAIL"} {label}: code={result.returncode} expected={expected}', flush=True)
    if not passed:
        failures.append(label)
print(f'RESULT: {len(cases)-len(failures)}/{len(cases)} passed')
raise SystemExit(bool(failures))
