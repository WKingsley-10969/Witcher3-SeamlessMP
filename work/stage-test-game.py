"""Deploy only to this workspace's verified independent game copy; keep backups and a root-bound manifest."""
import hashlib
import json
from pathlib import Path
import shutil

work = Path(__file__).resolve().parent
game = work / 'test-game'
testing = work / 'game-testing'
testing.mkdir(exist_ok=True)
marker = json.loads((game / '.w3lan-test-copy.json').read_text(encoding='utf-8-sig'))
assert marker['TestCopy'] is True and Path(marker['OriginalPath']).resolve() != game.resolve()
assert game.resolve().parent == work.resolve()
exe = game / 'bin/x64_dx12/witcher3.exe'
assert hashlib.sha256(exe.read_bytes()).hexdigest() == marker['ExeSha256']
manifest_file = testing / 'deploy-manifest.json'
manifest = json.loads(manifest_file.read_text()) if manifest_file.exists() else {'game_root': str(game.resolve()), 'files': {}}
assert manifest['game_root'] == str(game.resolve())
# Match upstream deploy.py/build_package.py: these old Gwent overrides are
# intentionally absent on 5.01. Source overlays must preserve that exclusion.
excluded = {'gwintManager.ws', 'gwintGameMenu.ws', 'gwentHooks.ws'}
for key in list(manifest['files']):
    relative = Path(key)
    if relative.name in excluded and not (work / 'baseline-package' / relative).exists():
        target = game / relative
        assert target.resolve().is_relative_to(game.resolve())
        if target.exists():
            assert hashlib.sha256(target.read_bytes()).hexdigest() == manifest['files'][key]
            backup = testing / 'deploy-backup' / relative
            if backup.exists(): shutil.copy2(backup, target)
            else: target.unlink()
        del manifest['files'][key]
sources = [(work / 'baseline-package', Path('.')),
           (work / 'WitcherOnline/witcher/mods/modWitcherOnline/content/scripts', Path('mods/modWitcherOnline/content/scripts')),
           (work / 'witcher3-coop/w3test/modW3Test', Path('mods/modW3Test'))]
single = [(work / 'witcher3-coop/w3test/build/w3test.asi', Path('bin/x64_dx12/w3test.asi'))]
bridge = work / 'WitcherNativeBridge/build/Release/WitcherNativeBridge.asi'
if bridge.is_file():
    single.append((bridge, Path('bin/x64_dx12/WitcherNativeBridge.asi')))
single.append((work / 'WitcherOnline/client/build/Release/WitcherOnlineClient.asi', Path('bin/x64_dx12/WitcherOnlineClient.asi')))
assert all(p.is_file() for p, _ in single), 'Build the native test hook first.'
pairs = []
for source, relative in sources:
    assert source.is_dir()
    pairs += [(p, relative / p.relative_to(source)) for p in source.rglob('*') if p.is_file() and p.name not in excluded]
pairs += single  # native builds override the baseline payload, never the other way around
for source, relative in pairs:
    target = game / relative
    assert target.resolve().is_relative_to(game.resolve())
    key = relative.as_posix()
    if key not in manifest['files'] and target.exists():
        backup = testing / 'deploy-backup' / relative
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, backup)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    manifest['files'][key] = hashlib.sha256(target.read_bytes()).hexdigest()
manifest_file.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
(game / '.w3lan-native.json').write_text(json.dumps({'profileApi': 1, 'profileDllSha256': hashlib.sha256((game / 'bin/x64_dx12/w3test.asi').read_bytes()).hexdigest()}, indent=2), encoding='utf-8')
server_jar = work / 'WitcherOnline/server/build/WitcherServer.jar'
assert server_jar.is_file(), 'Build server first; never silently replace it with the baseline.'
shutil.copy2(server_jar, game / 'bin/w3coop/server/WitcherServer.jar')
seamless_files = ['bin/x64_dx12/WitcherOnlineClient.asi', 'bin/x64_dx12/WitcherNativeBridge.asi'] + [
    'mods/modWitcherOnline/content/scripts/local/' + name for name in
    ('seamlessCampaign.ws', 'seamlessEffects.ws', 'sceneFactCapture.ws', 'client.ws', 'anno.ws', 'coopEnemies.ws')]
(game / '.w3lan-seamless.json').write_text(json.dumps({
    'api': 1, 'protocol': 1, 'exeSha256': marker['ExeSha256'],
    'files': {name: hashlib.sha256((game / name).read_bytes()).hexdigest() for name in seamless_files},
    'serverJarSha256': hashlib.sha256(server_jar.read_bytes()).hexdigest()
}, indent=2), encoding='utf-8')
print(f'DEPLOYED {len(pairs)} files to verified isolated test copy')
