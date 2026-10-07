import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import glory_nightly as n
import glory_aab_build as a


class NightlyTests(unittest.TestCase):
    def test_failed_play_version_query_still_runs_ios(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); runs=root/'build/nightly'; seen=[]
            def step(state,path,name,command):
                seen.append(name); state['steps'][name]={'ok':True}; return True
            with mock.patch.object(n,'RUNS',runs), mock.patch.object(n.b,'ROOT',root), \
                 mock.patch.object(n.b,'capture',return_value='sha'), mock.patch.object(n,'local_code',return_value=29), \
                 mock.patch.object(n,'step',side_effect=step), \
                 mock.patch.object(n.subprocess,'run',return_value=subprocess.CompletedProcess([],1,'','unavailable')), \
                 mock.patch('sys.argv',['nightly','--local']):
                self.assertEqual(n.main(),1)
            self.assertIn('testflight',seen)
            state=json.loads(next(runs.glob('*/state.json')).read_text())
            self.assertFalse(state['steps']['android_pipeline']['ok'])
            self.assertEqual(state['status'],'failed')
    def test_env_signing_secret_does_not_call_keychain(self):
        with mock.patch.dict(a.os.environ,{'GLORY_KEYSTORE_PASSWORD':'test-only'}),mock.patch.object(a.subprocess,'run') as run:
            self.assertEqual(a.signing_password(),'test-only');run.assert_not_called()
    def test_unfinished_previous_release_prevents_duplicate_run(self):
        with tempfile.TemporaryDirectory() as folder:
            runs=Path(folder);old=runs/'old';old.mkdir();state=old/'state.json'
            state.write_text(json.dumps({'build_only':False,'status':'failed'}))
            (runs/'latest.json').write_text(json.dumps({'state':str(state)}))
            with mock.patch.object(n,'RUNS',runs),mock.patch('sys.argv',['nightly']):
                with self.assertRaisesRegex(RuntimeError,'unfinished'):n.main()

if __name__=='__main__':unittest.main()
