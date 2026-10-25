"""Deploy only to this workspace's verified independent game copy; keep backups and a root-bound manifest."""
import hashlib
import json
import os
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
# Custom Player Characters (nikich340) in the test copy only when a run asks for it (W3T_CPC=1),
# from the player's own downloads extracted to local/cpc (never committed or shipped); its stand-in
# mod then stays out, as the installer leaves it out next to the real mod.
cpc = os.environ.get('W3T_CPC') == '1'
cpc_root = work.parent / 'local/cpc'
cpc_sources = [(cpc_root / 'cpc-3.1.2/Mods/modCustomPlayerCharacters', Path('mods/modCustomPlayerCharacters')),
               (cpc_root / 'cpc-3.1.2/Mods/mod_sharedutils_oneliners', Path('mods/mod_sharedutils_oneliners')),
               (cpc_root / 'cpc-3.1.2/dlc/dlcCustomPlayerCharacters', Path('dlc/dlcCustomPlayerCharacters')),
               (cpc_root / 'remaster-fix/mods/mod0000_CPC_RemasterFix', Path('mods/mod0000_CPC_RemasterFix')),
               (cpc_root / 'remaster-fix/dlc/dlc_cpc_remaster_fix', Path('dlc/dlc_cpc_remaster_fix'))]
sources = [(work / 'baseline-package', Path('.')),
           (work / 'WitcherOnline/witcher/mods/modWitcherOnlineCompat', Path('mods/modWitcherOnlineCompat')),
           (work / 'WitcherOnline/witcher/mods/modWitcherOnline/content/scripts', Path('mods/modWitcherOnline/content/scripts')),
           (work / 'WitcherOnline/witcher/bin/config', Path('bin/config')),  # the mod's settings menu
           (work / 'witcher3-coop/w3test/modW3Test', Path('mods/modW3Test'))]
sources += cpc_sources if cpc else [(work / 'WitcherOnline/witcher/mods/modWitcherOnlineCompatCPC', Path('mods/modWitcherOnlineCompatCPC'))]
cpc_targets = {relative.as_posix() + '/' for _, relative in cpc_sources}
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
# Files an earlier deploy placed that the current sources no longer have (another branch's
# scripts) would still be compiled: restore the original or remove them, if unchanged since.
current = {relative.as_posix() for _, relative in pairs}
for key in [k for k in manifest['files'] if k not in current]:
    target = game / key
    assert target.resolve().is_relative_to(game.resolve())
    if target.exists():
        assert hashlib.sha256(target.read_bytes()).hexdigest() == manifest['files'][key], f'{key} changed since it was deployed'
        backup = testing / 'deploy-backup' / key
        if backup.exists(): shutil.copy2(backup, target)
        else: target.unlink()
        print(f'REMOVED stale {key}')
    del manifest['files'][key]
for source, relative in pairs:
    target = game / relative
    assert target.resolve().is_relative_to(game.resolve())
    key = relative.as_posix()
    # the CPC files (over a gigabyte) are copied again only when they changed
    if key in manifest['files'] and any(key.startswith(t) for t in cpc_targets) and target.exists()             and target.stat().st_size == source.stat().st_size and int(target.stat().st_mtime) == int(source.stat().st_mtime):
        continue
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
