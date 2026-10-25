"""Assemble mod-only deliverable; exclude the game, owner profiles and local logs."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

work=Path(__file__).resolve().parent
root=work.parent
starter=root/'outputs/witcher3-lan-starter'
package=root/'outputs/Witcher3-LAN-0.2.0-dev'
package.mkdir(exist_ok=True)
for name in ('W3Lan.psm1','W3LanProfile.psm1','Play-LAN.ps1','Launch-Game.ps1','Install-LAN.ps1','Play Host LAN.cmd','Play Join LAN.cmd','Setup LAN.cmd','Host LAN.cmd','Join LAN.cmd','Lan.ps1','Build-Server.ps1','README.md','LICENSE.txt','PROVENANCE.json','BUILD-NATIVE.md'):
    shutil.copy2(starter/name,package/name)
shutil.copy2(starter/'GAME-TEST-RESULTS.md',package/'TEST-RESULTS.md')
for name in ('server','licenses','tests'):
    shutil.copytree(starter/name,package/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('profile-fixture-*','w3lan-profile-fixture-*'))
# Play-LAN.ps1 hosts with server/WitcherServer.jar: the current build, with its source.
shutil.copy2(work/'WitcherOnline/server/build/WitcherServer.jar',package/'server/WitcherServer.jar')
shutil.copytree(work/'WitcherOnline/server/src',package/'server/src',dirs_exist_ok=True)
# The payload is rebuilt from scratch so no file from an older build survives into the manifest.
if (package/'mod').exists():
    assert (package/'mod').resolve().parent == package.resolve()
    shutil.rmtree(package/'mod')
shutil.copytree(work/'baseline-package',package/'mod')
# Same overlays as stage-test-game.py, which the real-game tests ran: current Witcher Online
# scripts (party NPC sync, campaign adapters) over the baseline, and the current native builds.
# The old Gwent overrides stay out, as upstream ships them for 5.01.
excluded={'gwintManager.ws','gwintGameMenu.ws','gwentHooks.ws'}
scripts=work/'WitcherOnline/witcher/mods/modWitcherOnline/content/scripts'
for src in scripts.rglob('*'):
    if src.is_file() and src.name not in excluded:
        out=package/'mod/mods/modWitcherOnline/content/scripts'/src.relative_to(scripts)
        out.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,out)
shutil.copy2(work/'witcher3-coop/w3test/build/w3test.asi',package/'mod/bin/x64_dx12/w3test.asi')
shutil.copy2(work/'WitcherNativeBridge/build/Release/WitcherNativeBridge.asi',package/'mod/bin/x64_dx12/WitcherNativeBridge.asi')
shutil.copy2(work/'WitcherOnline/client/build/Release/WitcherOnlineClient.asi',package/'mod/bin/x64_dx12/WitcherOnlineClient.asi')
server_jar=work/'WitcherOnline/server/build/WitcherServer.jar'
assert server_jar.is_file(), 'Build the server first; never ship the baseline jar with the current scripts.'
shutil.copy2(server_jar,package/'mod/bin/w3coop/server/WitcherServer.jar')
source=package/'source'
helper=source/'witcher3-coop/w3test'
helper.mkdir(parents=True,exist_ok=True)
shutil.copy2(work/'witcher3-coop/w3test/w3test.cpp',helper/'w3test.cpp')
shutil.copy2(work/'witcher3-coop/w3test/build.cmd',helper/'build.cmd')
shutil.copy2(work/'witcher3-coop/LICENSE',helper.parent/'LICENSE')
repo='WitcherNativeBridge'
paths=subprocess.run(['git','-C',str(work/repo),'ls-files'],capture_output=True,text=True,check=True).stdout.splitlines()
for relative in paths:
    src=work/repo/relative
    if src.is_file():
        out=source/repo/relative
        out.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,out)
# Source of the modified native client (GPL-3.0): tracked and new files, not build output.
online='WitcherOnline'
listing=subprocess.run(['git','-C',str(work/online),'ls-files','--cached','--others','--exclude-standard','client'],capture_output=True,text=True,check=True).stdout.splitlines()
for relative in listing:
    src=work/online/relative
    if src.is_file() and 'build' not in Path(relative).parts:
        out=source/online/relative
        out.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,out)
for relative in ('src/ScriptStringResult.h', 'src/FactOperationJournal.h'):
    new_header = work/repo/relative
    if new_header.is_file():
        shutil.copy2(new_header,source/repo/relative)
shutil.copytree(work/'native-tests',source/'native-tests',dirs_exist_ok=True,ignore=shutil.ignore_patterns('*.exe','*.obj','*.lib','*.exp','*.log','documents'))
shutil.copytree(work/'witcher3-coop/w3test/modW3Test',helper/'modW3Test',dirs_exist_ok=True)
manifest={'version':'0.2.0-dev','files':[]}
for file in sorted((package/'mod').rglob('*')):
    if file.is_file():
        manifest['files'].append({'path':file.relative_to(package/'mod').as_posix(),'sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
(package/'mod-manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
archive=Path(str(package)+'.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    for file in sorted(package.rglob('*')):
        if file.is_file():
            assert not any(p in file.parts for p in ('.git','.w3lan-profiles','game-copy','game-testing'))
            assert file.name not in ('launcher.settings.json','install-copy.log')
            z.write(file, str(Path(package.name)/file.relative_to(package)))
checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.zip.sha256').write_text(checksum+'  '+archive.name+'\n',encoding='ascii')
print(f'PACKAGE_READY {archive.name} size={archive.stat().st_size} SHA256={checksum}')
