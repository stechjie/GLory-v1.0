import unittest
import numpy as np
from repair_crimson_normals import smooth_normals


class NormalFanTests(unittest.TestCase):
    def fixture(self):
        # Two triangles share a UV seam; normals are intentionally split.
        v = np.array([[0,0,0],[1,0,0],[0,1,0], [1,0,0],[0,0,0],[0,0.5,0.866]], dtype=float)
        f = np.array([[0,1,2],[3,4,5]])
        n = np.repeat([[0,0,1],[0,0.866,-0.5]],3,axis=0).astype(np.float32)
        # Bend the second face by only 60 degrees (not 120).
        v[5] = [0,-0.5,0.866]; n[3:] = [0,0.866,0.5]
        n /= np.linalg.norm(n,axis=1)[:,None]
        j = np.zeros((6,4),dtype=int); w=np.zeros((6,4)); w[:,0]=1
        return v,n,f,j,w

    def test_uv_seam_is_smooth(self):
        v,n,f,j,w=self.fixture(); out,_=smooth_normals(v,n,f,j,w)
        np.testing.assert_allclose(out[0],out[4],atol=1e-6)
        np.testing.assert_allclose(out[1],out[3],atol=1e-6)
        self.assertGreater(out[0,1],0.1)

    def test_separate_skin_weights_do_not_join(self):
        v,n,f,j,w=self.fixture();j[3:,0]=1
        out,_=smooth_normals(v,n,f,j,w)
        np.testing.assert_allclose(out,n,atol=1e-6)

    def test_back_to_back_cards_do_not_cancel(self):
        v,n,f,j,w=self.fixture();v[3:]=v[[1,0,2]];n[3:]=[0,0,-1]
        out,_=smooth_normals(v,n,f,j,w)
        np.testing.assert_allclose(out,n,atol=1e-6)

    def test_hard_fold_is_retained(self):
        v,n,f,j,w=self.fixture();v[5]=[0,0.5,0.866];n[3:]=[0,0.866,-0.5]
        n[3:]/=np.linalg.norm(n[3:],axis=1)[:,None]
        out,_=smooth_normals(v,n,f,j,w)
        np.testing.assert_allclose(out,n,atol=1e-6)

if __name__ == '__main__':unittest.main()
