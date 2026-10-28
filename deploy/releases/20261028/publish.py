"""Publish verified 1.0.2 (47), preserve prior downloads and client bases."""
import hashlib,json,os,shutil,sqlite3,sys
from pathlib import Path
root=Path('/opt/glory/public/beta');target=root/'downloads/Glory-1.0.2-47-android.apk'
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1048576),b''):h.update(block)
 return h.hexdigest()
assert target.stat().st_size==579375881 and sha(target)=='68650ca8883258fa9d3f0d6d9ea5c1a1d0e74a685ec0b7c44b2e9cff897f76f2'
target.chmod(0o644)
backup=Path('/var/backups/glory/beta-site/20261028-release1');backup.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,'/opt/glory/repo/backend')
from app.patch_store import PatchStore
p=Path('/var/lib/glory-patches/catalogue.sqlite3')
if not (backup/'catalogue.before.sqlite3').exists():
 with sqlite3.connect(p) as src,sqlite3.connect(backup/'catalogue.before.sqlite3') as dst:src.backup(dst)
s=PatchStore(p,firebase_host='glory-patches.web.app');c=s.catalogue();active=c['active'].get('internal');seq=next((r['seq'] for r in c['releases'] if r['release_id']==active),0);assert seq==4,('Active patch changed',seq)
old=s.snapshot('internal','android','glory-20261027-protocol44-slim',0)
s.register_client_base('internal','android','glory-20261028-protocol45-slim',4,'release-1.0.2-47-protocol45')
snap=s.snapshot('internal','android','glory-20261028-protocol45-slim',0);assert snap['action']=='none' and snap['required_patch_seq']==0
assert s.snapshot('internal','android','glory-20261027-protocol44-slim',0)==old
config=json.loads((root/'config.json').read_text());config['android'].update(ready=True,mode='apk',url='https://glorytd-api.duckdns.org/beta/downloads/Glory-1.0.2-47-android.apk',version='1.0.2 (47)',size_bytes=579375881,size_label='552.5 MiB')
# Only open public enrollment after the operator verifies build 71 external testing.
config['ios'].update(ready='--ios-ready' in sys.argv,url='https://testflight.apple.com/join/W2p1ukJp',version='1.0.2 (71)',pending_version='' if '--ios-ready' in sys.argv else '1.0.2 (71)')
repo=Path(__file__).resolve().parents[3]
for name in ['config.json','i18n.mjs']:
 if not (backup/name).exists():shutil.copy2(root/name,backup/name)
 data=(json.dumps(config,indent=2)+'\n').encode() if name=='config.json' else (repo/'deploy/beta-site'/name).read_bytes()
 tmp=root/(name+'.20261028.tmp');tmp.write_bytes(data);tmp.chmod(0o644);os.replace(tmp,root/name)
report={'status':'published','config':config,'apk_sha256':sha(target),'qr_sha256':sha(root/'invite-qr.png'),'config_sha256':sha(root/'config.json'),'i18n_sha256':sha(root/'i18n.mjs'),'base_id':'glory-20261028-protocol45-slim','includes_seq':4,'patch_action':snap['action']}
(backup/'published.json').write_text(json.dumps(report,indent=2)+'\n');print('PUBLISHED',json.dumps(report),flush=True)
