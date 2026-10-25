"""Guarded entry point for upstream verification/scenarios; never use default game/work paths."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

work = Path(__file__).resolve().parent
game = work / 'test-game'
testing = work / 'game-testing'
marker = json.loads((game / '.w3lan-test-copy.json').read_text(encoding='utf-8-sig'))
assert marker['TestCopy'] and Path(marker['OriginalPath']).resolve() != game.resolve()
assert game.resolve().parent == work.resolve()
assert hashlib.sha256((game / 'bin/x64_dx12/witcher3.exe').read_bytes()).hexdigest() == marker['ExeSha256']
assert (game / 'bin/x64_dx12/w3test.asi').is_file(), 'Save-isolation hook must exist before game launch.'
assert (testing / 'deploy-manifest.json').is_file()
assert json.loads((testing / 'deploy-manifest.json').read_text())['game_root'] == str(game.resolve())
assert len(str(testing / 'runs/20261024-120000-example/documents-BotA')) < 240
ap = argparse.ArgumentParser()
ap.add_argument('scenario')
ap.add_argument('--save', default='ManualSave_4e4da')
ap.add_argument('--duration', type=int)
a = ap.parse_args()
env = dict(os.environ, W3_GAME_DIR=str(game), W3C_ROOT=str(work), W3C_WORK=str(testing),
           WO_SERVER_IP='127.0.0.1', WO_SERVER_PORT='41000', WO_USERNAME='CompileCheck')
jdk = next((work / 'tooling').glob('jdk-*'))
env['PATH'] = str(jdk / 'bin') + os.pathsep + env.get('PATH', '')
tools = work / 'witcher3-coop'
if a.scenario == 'verify':
    tag = 'verify-' + time.strftime('%Y%m%d-%H%M%S')
    docs = testing / (tag + '-documents')
    assert docs.resolve().is_relative_to(testing.resolve())
    command = [sys.executable, str(tools / 'w3run.py'), '--tag', 'isolated-verify', '--sandbox', str(docs),
               '--errors', str(testing / (tag + '-errors.txt')), '--timeout', '240', '--', '-verifyscriptsandexit']
else:
    command = [sys.executable, str(tools / 'run_test.py'), a.scenario, '--save', a.save,
               '--duration', str(a.duration or (60 if a.scenario in ('see_each_other', 'movement') else 300)), '--timeout', '480', '--size', '960x540']
    if a.scenario.startswith('seamless_'):
        command.append('--campaign')
slot_source = work / 'coop-playbook/tools/gameslot/gameslot.py'
assert hashlib.sha256(slot_source.read_bytes()).hexdigest() == '7a939829c6a782c774226a5c72f4137c1b94af60730d02c75b6251bfd2ceaf3d'
os.environ['GAMESLOT_DIR'] = str(work.parent / 'local/gameslot')
spec = importlib.util.spec_from_file_location('gameslot', slot_source)
slots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slots)
owner = 'w3-' + uuid.uuid4().hex
ok, indices, reason = slots.try_acquire(owner, 900, 1 if a.scenario == 'verify' else 2, time.time())
if not ok:
    raise SystemExit('Game slot unavailable: ' + reason)
env.update(GAMESLOT_DIR=os.environ['GAMESLOT_DIR'], GAMESLOT_OWNER=owner, GAMESLOT_SOURCE=str(slot_source))
try:
    result = subprocess.run(command, env=env, cwd=tools)
finally:
    # Include interrupted harness runs: kill only exact registered process identities.
    for state in slots.status()['slots']:
        lease = state['lease']
        if lease and lease.get('owner') == owner:
            slots.kill_registered(lease.get('procs', []))
    slots.release(owner)
raise SystemExit(result.returncode)
