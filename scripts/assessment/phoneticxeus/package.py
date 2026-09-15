"""Freeze/sign a local helper; checkpoint remains a separately downloaded asset."""
import argparse,subprocess,json,hashlib,shutil
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--snapshot',type=Path,required=True);p.add_argument('--python',type=Path,required=True);a=p.parse_args()
script=Path(__file__).resolve().parent;root=script.parents[2];work=root/'.build/phoneticxeus-package'
subprocess.run([str(a.python),'-m','PyInstaller','--noconfirm','--clean','--onedir','--name','xeus-helper',
 '--paths',str(a.snapshot),'--add-data',str(a.snapshot/'src/model/xeusphoneme/resources')+':src/model/xeusphoneme/resources',
 '--add-data',str(script/'uk-contrast-head.json')+':.',
 '--distpath',str(work/'dist'),'--workpath',str(work/'build'),'--specpath',str(work),str(script/'runtime.py')],check=True)
source=work/'dist/xeus-helper';dest=root/'vendor/phoneticxeus'
if dest.exists():shutil.rmtree(dest)
shutil.copytree(source,dest,symlinks=True)
subprocess.run(['codesign','--force','--sign','-','--entitlements',str(script.parent/'UKHelper.entitlements'),str(dest/'xeus-helper')],check=True)
manifest={}
for f in sorted(dest.rglob('*')):
 if f.is_file() and not f.is_symlink():
  with f.open('rb') as stream:manifest[str(f.relative_to(dest))]=hashlib.file_digest(stream,'sha256').hexdigest()
(dest/'checksums.json').write_text(json.dumps(manifest,sort_keys=True,indent=2))
print('Runtime manifest SHA256',hashlib.sha256((dest/'checksums.json').read_bytes()).hexdigest())
