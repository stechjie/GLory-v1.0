from pathlib import Path as P
import subprocess,json,hashlib,re,time,shutil,os,datetime
stage=P('/var/backups/glory/server-20261028-66dd488');p=json.loads((stage/'prepared.json').read_text());conf=P('/etc/systemd/system/glory-server.service.d/99-glory-current.conf')
def run(a,**kw):
 try:return subprocess.check_output(a,text=True,stderr=subprocess.STDOUT,**kw)
 except subprocess.CalledProcessError as exc:
  print(exc.output,flush=True);raise
def pid(s):return run(['systemctl','show',s,'-p','MainPID','--value']).strip()
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
boot=P('/proc/sys/kernel/random/boot_id').read_text().strip().replace('-','')
def logs(s,n):return run(['journalctl','-u',s,'_PID='+n,'_BOOT_ID='+boot,'--no-pager','-o','cat'])
assert os.geteuid()==0 and pid('glory-server')==p['old_pid'] and conf.read_text()==(stage/'previous.conf').read_text()
release=P(p['release']);manifest=json.loads((release/'server_bundle_manifest.json').read_text())
for row in manifest['files']:assert sha(release/row['path'])==row['sha256']
# Source archive is fixed at the merged release commit. Back up changed backend files.
src=stage/'source';backend=P('/opt/glory/repo/backend')
backend_changes={}
for f in (src/'backend').rglob('*'):
 if not f.is_file() or '__pycache__' in f.parts or f.suffix=='.pyc':continue
 rel=f.relative_to(src/'backend');target=backend/rel
 if not target.is_file() or sha(target)!=sha(f):backend_changes[str(rel)]={'new_sha256':sha(f),'old_sha256':sha(target) if target.is_file() else None}
# Verify the live DB against the candidate's actual SQL. No credentials are printed.
probe=stage/'schema-probe.py'
probe.write_text('import os,sys,asyncio,json\nfrom pathlib import Path\nfor l in Path(\'/opt/glory/backend.env\').read_text().splitlines():\n if l.strip() and not l.lstrip().startswith(\'#\') and \'=\' in l:\n  k,v=l.split(\'=\',1);os.environ.setdefault(k.strip(),v.strip().strip(chr(34)).strip(chr(39)))\nsys.path.insert(0,\'/var/backups/glory/server-20261028-66dd488/source/backend\')\nfrom app import db,schema_check\nfrom app.config import get_settings\nasync def main():\n await db.connect(get_settings().database_url)\n try:\n  errors=await schema_check.verify();print(\'SCHEMA_ERRORS\',json.dumps(errors,ensure_ascii=False));assert all(e.startswith(\'041 \') for e in errors), errors\n  if errors and \'--repair-041\' in sys.argv:\n   async with db.pool().acquire() as conn:\n    async with conn.transaction():\n     await conn.execute("SET LOCAL lock_timeout=\'5s\'")\n     defs=await conn.fetch("select conname,pg_get_constraintdef(oid) as definition from pg_constraint where conrelid=\'ranked_reward_receipts\'::regclass and contype=\'c\'")\n     Path(\'/var/backups/glory/server-20261028-66dd488/ranked-constraints.before.json\').write_text(json.dumps([dict(r) for r in defs]))\n     sql=next(Path(\'/var/backups/glory/server-20261028-66dd488/source/database\').glob(\'041*.sql\')).read_text()\n     sql=\'\\n\'.join(l for l in sql.splitlines() if l.strip().lower() not in [\'begin;\',\'commit;\'])\n     await conn.execute(sql)\n   errors=await schema_check.verify();print(\'SCHEMA_AFTER\',json.dumps(errors));assert not errors\n finally:await db.disconnect()\nasyncio.run(main())\n')
print(run(['/opt/glory/venv/bin/python',str(probe)]),flush=True)
backend_pid=pid('glory-backend')
site=P('/opt/glory/public/beta');site_hash={n:sha(site/n) for n in ['index.html','app.js','i18n.mjs','routing.mjs','config.json','invite-qr.png']}
audit=stage/'roomaudit';audit.mkdir(exist_ok=True);(audit/'project.godot').write_text('config_version=5\n');(audit/'.godot').mkdir(exist_ok=True);(audit/'.godot/global_script_class_cache.cfg').write_text('list=[]\n')
env=dict(x.split('=',1) for x in P('/proc/'+p['old_pid']+'/environ').read_text().split('\0') if '=' in x)
root=P(env.get('XDG_DATA_HOME',env.get('HOME','/home/nins17121')+'/.local/share'))/'godot/app_userdata/Glory Beta 0.04'
snap=root/'server_rooms.bin';assert snap.is_file()
(audit/'audit.gd').write_text('extends SceneTree\nfunc _initialize():\n\tvar d = bytes_to_var(FileAccess.get_file_as_bytes('+json.dumps(str(snap))+'))\n\tprint("ROOM_AUDIT " + JSON.stringify({"protocol":d.get("protocol",-1),"room_count":d.get("rooms",[]).size()}))\n\tquit()\n')
def idle():
 assert pid('glory-server')==p['old_pid']
 log=logs('glory-server',p['old_pid']);assert 'server started protocol=44 ' in log
 peers=set()
 for line in log.splitlines():
  m=re.match(r'\[NET\] client (connected|disconnected) peer=(\d+)',line)
  if m:(peers.add if m[1]=='connected' else peers.discard)(m[2])
 assert not peers,'WAIT active battle connections='+str(len(peers))
 online=re.findall(r'在线\s+(\d+)\s*[（(]\s*连着\s+(\d+)',logs('glory-backend',backend_pid))
 assert online and online[-1]==('0','0'),'WAIT backend online='+str(online[-1:])
 out=run([p['binary'],'--headless','--path',str(audit),'--script',str(audit/'audit.gd')],timeout=20)
 rows=[json.loads(l.removeprefix('ROOM_AUDIT ')) for l in out.splitlines() if l.startswith('ROOM_AUDIT ')]
 assert len(rows)==1 and rows[0]=={'protocol':44,'room_count':0} and 'ERROR:' not in out,'WAIT active or unknown rooms: '+out
 result={'battle_connections':0,'account_online':0,'room_count':0,'protocol':44,'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 print('IDLE '+json.dumps(result),flush=True);return result
checks=[idle()];time.sleep(3);checks.append(idle())
assert not (stage/'deployment.json').exists()
shutil.copy2(snap,stage/'server_rooms.before.bin');(stage/'site-before.json').write_text(json.dumps(site_hash,indent=2))
switched=False
backend_switched=False
backup_backend=stage/'backend-before'
backup_backend.mkdir(exist_ok=True)
try:
 assert conf.read_text()==(stage/'previous.conf').read_text()
 for rel in backend_changes:
  target=backend/rel;backup=backup_backend/rel
  if target.exists():backup.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(target,backup)
 backend_switched=True
 print(run(['/opt/glory/venv/bin/python',str(probe),'--repair-041']),flush=True)
 for rel in backend_changes:
  target=backend/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src/'backend'/rel,target);target.chmod(0o644)
 for rel in ['avatars.json','blocked_words.txt','shop.json','seven_day_login.json','pets/pets.json','balance/final_status.json','iap_products.json']:
  source=src/'data'/rel;target=P('/opt/glory/repo/data')/rel
  assert target.is_file() and sha(source)==sha(target),'Unexpected data difference: '+rel
 run(['systemctl','restart','glory-backend'],timeout=45)
 for _ in range(20):
  time.sleep(.5)
  try:
   h=json.loads(run(['curl','-fsS','--max-time','3','http://127.0.0.1:8099/health']))
   if h.get('status')=='ok' and h.get('configured'):break
  except subprocess.CalledProcessError:pass
 else:raise RuntimeError('backend startup failed')
 print(run(['/opt/glory/venv/bin/python',str(probe)]),flush=True)
 conf.write_text((stage/'candidate.conf').read_text());switched=True
 run(['systemctl','daemon-reload']);run(['systemctl','restart','glory-server'],timeout=45)
 ready=False
 for _ in range(30):
  time.sleep(.5);newpid=pid('glory-server')
  if newpid in ['0',p['old_pid']]:continue
  output=logs('glory-server',newpid)
  assert not re.search(r'SCRIPT ERROR|Parse Error|^ERROR:|setup failed',output,re.M),output
  if '[SERVER] ServerMain ready' in output and '[NET] server started protocol=45 port=8080' in output:ready=True;break
 assert ready,'startup timeout'
 time.sleep(3);assert pid('glory-server')==newpid
 statuses={s:run(['systemctl','is-active',s]).strip() for s in ['glory-server','glory-backend','livekit','caddy']}
 assert all(x=='active' for x in statuses.values())
 health=json.loads(run(['curl','-fsS','--max-time','10','http://127.0.0.1:8099/health']))
 assert health['status']=='ok' and health['configured']
 assert all(sha(site/n)==h for n,h in site_hash.items())
 assert ':8080' in run(['ss','-lunp','sport = :8080'])
 assert str(release) in run(['systemctl','show','glory-server','-p','ExecStart','--value'])
 report={'status':'deployed','commit':p['commit'],'release':str(release),'protocol':45,'source_tree_sha256':p['source_tree_sha256'],'old_pid':p['old_pid'],'new_pid':newpid,'idle_checks':checks,'cold_start_passed':p['smoke']['passed'],'services':statuses,'health':health,'backend_unchanged':False,'old_backend_pid':backend_pid,'backend_pid':pid('glory-backend'),'backend_changes':backend_changes,'schema_verified':True,'site_unchanged':True,'rollback_directory':str(stage),'verified_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'device_gameplay_tested':False}
 (stage/'deployment.json').write_text(json.dumps(report,indent=2));(stage/'startup.log').write_text(output);print('DEPLOYED '+json.dumps(report),flush=True)
except BaseException:
 if backend_switched:
  for rel in backend_changes:
   backup=backup_backend/rel;target=backend/rel
   if backup.exists():shutil.copy2(backup,target)
   elif target.exists():target.unlink()
  run(['systemctl','restart','glory-backend'],timeout=45)
 if switched:
  conf.write_text((stage/'previous.conf').read_text());run(['systemctl','daemon-reload']);run(['systemctl','restart','glory-server'],timeout=45);print('ROLLED_BACK battle runtime',flush=True)
 raise
