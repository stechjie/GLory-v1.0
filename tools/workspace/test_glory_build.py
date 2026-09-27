"""Offline tests for narrow FBX import diagnostic exceptions; all writes use temporary directories."""
import contextlib,copy,importlib.util,io,json,re,tempfile,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('glory_build_review',Path(__file__).with_name('glory_build.py'));b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
class Tests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name);self.stage=self.root/'stage';self.logs=self.root/'logs';self.logs.mkdir();self.model=self.stage/'assets/models/unit';self.model.mkdir(parents=True);(self.stage/'.godot/imported').mkdir(parents=True)
  (self.model/'idle.fbx').write_bytes(b'FBX source fixture');self.meta=self.model/'idle.fbx.import';self.meta.write_text('[remap]\npath="res://.godot/imported/idle.scn"\n');self.compiled=self.stage/'.godot/imported/idle.scn';self.compiled.write_bytes(b'imported-scene-test')
  self.path='res://assets/models/unit/old.fbm/Material_001_Diffuse.png';self.report={'models':[{'scene_path':'res://assets/models/unit/unit.tscn','status':'PASS'}]}
 def log(self,path=None):
  p=path or self.path
  return "ERROR: Resource file not found: res:// (expected type: Texture2D)\n   at: _load (resource_loader.cpp:325)\nERROR: Can't open file from path '"+p+"'.\n   at: get_file_as_bytes (file_access.cpp:907)\nWARNING: FBX: Image index '0' couldn't be loaded from path: "+p+" because there was no data to load. Skipping it.\n"
 def run_check(self,log=None,report=None):
  with contextlib.redirect_stdout(io.StringIO()):return b.verify_import_diagnostics(log if log is not None else self.log(),self.stage,self.logs,report if report is not None else self.report)
 def test_pair_accepted_with_report_and_compiled_scene(self):self.assertEqual(self.run_check()['compiled_fbx_scenes'],1)
 def test_unknown_error_is_fatal(self):
  with self.assertRaises(RuntimeError):self.run_check(self.log()+'ERROR: Shader parse error\n')
 def test_script_error_is_fatal(self):
  with self.assertRaises(RuntimeError):self.run_check(self.log()+'SCRIPT ERROR: Invalid access\n')
 def test_unpaired_error_is_fatal(self):
  with self.assertRaises(RuntimeError):self.run_check("ERROR: Resource file not found: res:// (expected type: Texture2D)\n")
 def test_same_path_warning_required(self):
  with self.assertRaises(RuntimeError):self.run_check(self.log().replace('path: '+self.path,'path: res://different.png'))
 def test_failed_wrapper_is_fatal(self):
  report=copy.deepcopy(self.report);report['models'][0]['status']='FAIL'
  with self.assertRaises(RuntimeError):self.run_check(report=report)
 def test_uncovered_sibling_wrapper_is_fatal(self):
  with self.assertRaises(RuntimeError):self.run_check(self.log('res://assets/models/unit_other/old.fbm/Material_001_Diffuse.png'))
 def test_missing_compiled_scene_is_fatal(self):
  self.compiled.unlink()
  with self.assertRaises(RuntimeError):self.run_check()
 def test_zero_imported_fbx_must_not_vacuously_pass(self):
  self.meta.unlink()
  with self.assertRaises(RuntimeError):self.run_check()
 def test_directory_without_its_own_fbx_must_not_use_other_directory_compiled(self):
  self.meta.unlink();other=self.stage/'assets/models/other';other.mkdir();(other/'idle.fbx').write_bytes(b'other FBX fixture');(other/'idle.fbx.import').write_text('[remap]\npath="res://.godot/imported/idle.scn"\n')
  with self.assertRaises(RuntimeError):self.run_check()
 def test_parent_traversal_is_not_covered(self):
  with self.assertRaises(RuntimeError):self.run_check(self.log('res://assets/models/unit/../../../unrelated.png'))
 def test_empty_compiled_scene_is_fatal(self):
  self.compiled.write_bytes(b'')
  with self.assertRaises(RuntimeError):self.run_check()
 def test_compiled_scene_cannot_escape_stage(self):
  outside=self.root/'outside.scn';outside.write_bytes(b'outside imported fixture')
  self.meta.write_text('[remap]\npath="res://../outside.scn"\n')
  with self.assertRaises(RuntimeError):self.run_check()
 def test_missing_source_fbx_is_fatal(self):
  (self.model/'idle.fbx').unlink()
  with self.assertRaises(RuntimeError):self.run_check()
if __name__=='__main__':unittest.main()
