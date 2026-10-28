import os,sys,asyncio,json
from pathlib import Path
for l in Path('/opt/glory/backend.env').read_text().splitlines():
 if l.strip() and not l.lstrip().startswith('#') and '=' in l:
  k,v=l.split('=',1);os.environ.setdefault(k.strip(),v.strip().strip(chr(34)).strip(chr(39)))
sys.path.insert(0,'/var/backups/glory/server-20261028-66dd488/source/backend')
from app import db,schema_check
from app.config import get_settings
async def main():
 await db.connect(get_settings().database_url)
 try:
  errors=await schema_check.verify();print('SCHEMA_ERRORS',json.dumps(errors,ensure_ascii=False));assert all(e.startswith('041 ') for e in errors), errors
  if errors and '--repair-041' in sys.argv:
   async with db.pool().acquire() as conn:
    async with conn.transaction():
     await conn.execute("SET LOCAL lock_timeout='5s'")
     defs=await conn.fetch("select conname,pg_get_constraintdef(oid) as definition from pg_constraint where conrelid='ranked_reward_receipts'::regclass and contype='c'")
     Path('/var/backups/glory/server-20261028-66dd488/ranked-constraints.before.json').write_text(json.dumps([dict(r) for r in defs]))
     sql=next(Path('/var/backups/glory/server-20261028-66dd488/source/database').glob('041*.sql')).read_text()
     sql='\n'.join(l for l in sql.splitlines() if l.strip().lower() not in ['begin;','commit;'])
     await conn.execute(sql)
   errors=await schema_check.verify();print('SCHEMA_AFTER',json.dumps(errors));assert not errors
 finally:await db.disconnect()
asyncio.run(main())
