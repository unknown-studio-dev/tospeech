"""Maintainer download of the pinned upstream snapshot; never uploads audio."""
import argparse,json,hashlib,subprocess
from pathlib import Path
REV='8d83dee94817a07dc150f87d08f7e0ee01bdb66d'
p=argparse.ArgumentParser();p.add_argument('directory',type=Path);a=p.parse_args();a.directory.mkdir(parents=True,exist_ok=True)
def fetch(url,path):
 subprocess.run(['curl','--fail','-L','--connect-timeout','15','--max-time','1800','--retry','2','-o',str(path),url],check=True)
metadata=a.directory/'upstream-metadata.json'
fetch('https://huggingface.co/api/models/changelinglab/PhoneticXeus/revision/'+REV+'?blobs=true',metadata)
d=json.loads(metadata.read_text());assert d['sha']==REV
for file in d['siblings']:
 name=file['rfilename']
 if name=='phoneticxeus_state_dict.pt':continue
 path=a.directory/name
 if Path(name).is_absolute() or '..' in Path(name).parts:raise ValueError(name)
 path.parent.mkdir(parents=True,exist_ok=True)
 fetch('https://huggingface.co/changelinglab/PhoneticXeus/resolve/'+REV+'/'+name,path)
 if file.get('lfs'):
  with path.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==file['lfs']['sha256'],name
