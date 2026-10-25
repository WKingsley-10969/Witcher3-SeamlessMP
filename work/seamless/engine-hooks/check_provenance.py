"""Read-only: check active FactsSet body and two NON-STAGED research candidate bodies."""
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parent
work = root.parents[1]
game = work / 'test-game'
exe = game / 'bin/x64_dx12/witcher3.exe'
expected_exe = '2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101'
assert hashlib.sha256(exe.read_bytes()).hexdigest() == expected_exe, 'Game changed; re-research helper contracts'
wrapper = (root / 'sceneFactCapture.ws').read_text(encoding='utf-8')
scene_candidates = (root / 'candidates/scene-helper-candidates.txt').read_text(encoding='utf-8')

def body(source, name):
    start = re.search(r'\bfunction\s+' + re.escape(name) + r'\s*\(', source).end()
    first = source.index('{', start)
    depth = 1
    end = first + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[first + 1:end - 1]

def normalized(source):
    source = re.sub(r'//[^\n]*|/\*.*?\*/', '', source, flags=re.S)
    source = re.sub(r'(?:if\s*\(\s*WNB_FactOpsActive\(\)\s*\)\s*)?WNB_FactOpsRecord\([^;]*\);', '', source)
    source = re.sub(r'SC_ProbeFactsSet\([^;]*\);', '', source)  # development probe, observation only
    return re.sub(r'\s+', '', source)

files = {'game/facts.ws': ['FactsSet'], 'game/scenes/scene_functions.ws': ['AddFact_S', 'RemoveFact_S']}
manifest = {'exeSha256': expected_exe, 'activeFunctions': ['FactsSet'], 'unstagedResearchOnly': ['AddFact_S', 'RemoveFact_S'], 'files': {}}
for relative, names in files.items():
    path = game / 'content/content0/scripts' / relative
    original = path.read_text(encoding='utf-8-sig')
    manifest['files'][relative] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'functions': names}
    for name in names:
        source = wrapper if name == 'FactsSet' else scene_candidates
        assert normalized(body(original, name)) == normalized(body(source, name)), f'Original helper body changed: {name}'
        label = 'ACTIVE' if name == 'FactsSet' else 'RESEARCH ONLY, NOT STAGED'
        print(f'PASS unchanged vanilla helper body: {name} [{label}] (observation calls excluded)')
(root / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print('Pinned helper provenance PASS; no game bytes were modified')
