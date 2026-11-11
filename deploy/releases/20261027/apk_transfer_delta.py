"""Transport-only delta: reconstruct the exact already-signed APK, then verify SHA256."""
import base64,gzip,hashlib,json,struct,sys,zipfile
from pathlib import Path

def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()

def spans(p):
 with zipfile.ZipFile(p) as z,open(p,'rb') as f:
  for i in sorted(z.infolist(),key=lambda i:i.header_offset):
   f.seek(i.header_offset+26);nl,el=struct.unpack('<HH',f.read(4));off=i.header_offset+30+nl+el
   f.seek(off);b=f.read(i.compress_size)
   if len(b)>128:yield off,b

if sys.argv[1]=='create':
 old,new,out=map(Path,sys.argv[2:5]);index={hashlib.sha256(b).hexdigest():(o,len(b)) for o,b in spans(old)}
 ops=[];cursor=0
 with new.open('rb') as f:
  for o,b in spans(new):
   hit=index.get(hashlib.sha256(b).hexdigest())
   if hit:
    if o>cursor:
     f.seek(cursor);ops.append(['data',base64.b64encode(f.read(o-cursor)).decode()])
    ops.append(['copy',*hit]);cursor=o+len(b)
  f.seek(cursor);tail=f.read()
  if tail:ops.append(['data',base64.b64encode(tail).decode()])
 doc={'old_sha256':sha(old),'new_sha256':sha(new),'size':new.stat().st_size,'ops':ops}
 with gzip.open(out,'wt') as f:json.dump(doc,f,separators=(',',':'))
 print('DELTA',out.stat().st_size,'TARGET',doc['size'])
elif sys.argv[1]=='apply':
 delta,old,out=map(Path,sys.argv[2:5]);doc=json.load(gzip.open(delta,'rt'));assert sha(old)==doc['old_sha256'],'Wrong source APK'
 assert not out.exists(),'Output exists'
 with old.open('rb') as src,out.open('xb') as dst:
  for op in doc['ops']:
   if op[0]=='copy':src.seek(op[1]);dst.write(src.read(op[2]))
   else:dst.write(base64.b64decode(op[1]))
 assert out.stat().st_size==doc['size'] and sha(out)==doc['new_sha256'],'Reconstruction mismatch'
 print('EXACT_SIGNED_APK',doc['size'],doc['new_sha256'],flush=True)
