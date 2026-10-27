import hashlib,json,os,shutil,time,urllib.request
from pathlib import Path
root=Path('/opt/glory/public/beta')
expected='e3e01b4263c47dc39d32a0e7486951cf343553f5aa5ada2ebc95ae286bc88122'
size=606029185
assert shutil.disk_usage(root).free > size*2, 'Not enough staging space'
downloads=root/'downloads'; downloads.mkdir(exist_ok=True)
tmp=downloads/('Glory-1.0.2-46-android.apk.part-'+str(os.getpid()))
url='https://drive.usercontent.google.com/download?id=19qnP6WQXTYhl43G5BFHFY7gpRPaPbJAk&export=download&confirm=t'
h=hashlib.sha256(); n=0
with urllib.request.urlopen(url,timeout=60) as r:
 assert 'attachment' in r.headers.get('Content-Disposition','').lower(), 'Drive did not return an attachment'
 with tmp.open('wb') as f:
  while True:
   block=r.read(1024*1024)
   if not block:break
   f.write(block);h.update(block);n+=len(block)
  f.flush();os.fsync(f.fileno())
assert n==size, ('Wrong size',n)
assert h.hexdigest()==expected, ('Wrong SHA256',h.hexdigest())
target=downloads/'Glory-1.0.2-46-android.apk'
os.chmod(tmp,0o644);os.replace(tmp,target)
print('APK_READY',str(target),n,h.hexdigest(),flush=True)

import sys,sqlite3,json
from pathlib import Path
sys.path.insert(0,'/opt/glory/repo/backend')
from app.patch_store import PatchStore
p=Path('/var/lib/glory-patches/catalogue.sqlite3')
d=Path('/var/backups/glory/clients-20261027-protocol44');d.mkdir(parents=True,exist_ok=True)
assert not (d/'registered.json').exists(), 'Already registered; inspect evidence rather than repeat'
with sqlite3.connect(p) as src,sqlite3.connect(d/'catalogue.before.sqlite3') as dst:src.backup(dst)
s=PatchStore(p,firebase_host='glory-patches.web.app')
c=s.catalogue();active=c['active'].get('internal');seq=next((r['seq'] for r in c['releases'] if r['release_id']==active),0);assert seq==4, ('Active patch changed; review baseline content first',seq)
old={v:s.snapshot('internal',v,'glory-20261021-audio43-slim',0) for v in ['android','ios']}
for platform in ['android']:
 s.register_client_base('internal',platform,'glory-20261027-protocol44-slim',4,'release-1.0.2-46-protocol44')
 snap=s.snapshot('internal',platform,'glory-20261027-protocol44-slim',0)
 assert snap['action']=='none' and snap['required_patch_seq']==0,snap
 after=s.snapshot('internal',platform,'glory-20261021-audio43-slim',0)
 for key in ['action','artifact','required_patch_seq','hotfixes']:assert old[platform][key]==after[key]
 print('REGISTERED',platform,snap['action'],snap['required_patch_seq'])
(d/'registered.json').write_text(json.dumps({'base_id':'glory-20261027-protocol44-slim','includes_seq':4,'platforms':['android']}))

from pathlib import Path
import hashlib,json,os,shutil
root=Path('/opt/glory/public/beta')
h=hashlib.sha256()
with (root/'downloads/Glory-1.0.2-46-android.apk').open('rb') as f:
 for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
assert h.hexdigest()=='e3e01b4263c47dc39d32a0e7486951cf343553f5aa5ada2ebc95ae286bc88122'
backup=Path('/var/backups/glory/beta-site/20261027-release1');backup.mkdir(parents=True,exist_ok=False)
shutil.copy2(root/'config.json',backup/'config.json')
config=json.loads((root/'config.json').read_text());candidate=json.loads('{\n  "ios": {\n    "ready": true,\n    "url": "https://testflight.apple.com/join/W2p1ukJp",\n    "version": "1.0.1 (68)",\n    "pending_version": "1.0.2 (70)"\n  },\n  "android": {\n    "ready": true,\n    "mode": "apk",\n    "url": "https://glorytd-api.duckdns.org/beta/downloads/Glory-1.0.2-46-android.apk",\n    "version": "1.0.2 (46)",\n    "size_bytes": 606029185,\n    "size_label": "578.0 MiB"\n  }\n}\n')
for platform in ['ios','android']:config[platform].update(candidate[platform])
tmp=root/'config.json.release20261027.tmp';tmp.write_text(json.dumps(config,indent=2)+'\n');tmp.chmod(0o644);os.replace(tmp,root/'config.json')
report={'config_source_commit':'3767387d','config':config,'config_sha256':hashlib.sha256((root/'config.json').read_bytes()).hexdigest(),'qr_sha256':hashlib.sha256((root/'invite-qr.png').read_bytes()).hexdigest(),'apk_sha256':h.hexdigest()}
(backup/'published.json').write_text(json.dumps(report,indent=2)+'\n');print('SITE_PUBLISHED',json.dumps(report),flush=True)
