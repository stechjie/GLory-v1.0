import json
from pathlib import Path
import tempfile
import unittest
import glory_play as p


class FakePlay:
    def __init__(self):
        self.calls = []; self.bundles = []; self.committed = False; self.uploads = 0
    def edit(self):
        self.calls.append(('edit',)); return '1'
    def inventory(self, edit):
        return self.bundles
    def track(self, edit):
        return {'releases': [{'versionCodes': ['29'], 'status': 'completed'}]} if self.committed else {}
    def upload(self, edit, path):
        self.uploads += 1
        self.bundles = [{'versionCode': 29, 'sha256': 'abc'}]
        return self.bundles[0]
    def call(self, method, path, **kw):
        self.calls.append((method, path, kw))
        if path.endswith(':commit'): self.committed = True
        return {}


class PlayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name)/'state.json'
        self.meta = {'version_code':29, 'sha256':'abc', 'version_name':'0.0.21'}
        self.api = FakePlay()
    def publish(self):
        p.publish(self.api,self.meta,Path('unused.aab'),self.state,'notes')
    def test_publish_then_retry_never_uploads_twice(self):
        self.publish(); self.publish()
        self.assertEqual(self.api.uploads,1)
        self.assertEqual(json.loads(self.state.read_text())['phase'],'complete')
        writes = [x for x in self.api.calls if x[0]=='PUT']
        self.assertEqual(writes[0][1],'/edits/1/tracks/internal')
        self.assertEqual(writes[0][2]['json']['track'],'internal')
        commit = next(x for x in self.api.calls if len(x)>1 and x[1].endswith(':commit'))
        self.assertEqual(commit[2]['params']['changesInReviewBehavior'],'ERROR_IF_IN_REVIEW')
    def test_same_code_different_hash_rejected_before_write(self):
        self.api.bundles = [{'versionCode':29,'sha256':'different'}]
        with self.assertRaisesRegex(RuntimeError,'different bytes'):self.publish()
        self.assertEqual(self.api.uploads,0)
        self.assertFalse(any(x[0]=='PUT' for x in self.api.calls))
    def test_uncertain_upload_is_not_repeated(self):
        p.save(self.state,{},package=p.PACKAGE,sha256='abc',version_code=29,notes='notes',edit='existing',phase='uploading',upload_attempted=True)
        with self.assertRaisesRegex(RuntimeError,'unknown'): self.publish()
        self.assertEqual(self.api.uploads,0)
        self.assertNotIn(('edit',),self.api.calls)
    def test_uploaded_edit_resumes_without_new_edit_until_commit(self):
        p.save(self.state,{},package=p.PACKAGE,sha256='abc',version_code=29,notes='notes',edit='existing',phase='uploaded',upload_attempted=True)
        self.api.bundles=[{'versionCode':29,'sha256':'abc'}]
        self.publish()
        self.assertEqual(self.api.uploads,0)
        self.assertEqual(self.api.calls[0][0:2],('PUT','/edits/existing/tracks/internal'))
    def test_completed_release_never_downgrades_track(self):
        self.publish(); self.api.committed=False
        with self.assertRaisesRegex(RuntimeError,'downgrade'):self.publish()
        self.assertEqual(self.api.uploads,1)

if __name__=='__main__':unittest.main()
