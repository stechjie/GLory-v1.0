"""Repair unpainted atlas islands sampled by the priest mesh (Pillow + NumPy).
This is deterministic UV padding: no generated artwork, no global brightening.
Keep the original atlas and all small dark components (eyes/ink) unchanged.
"""
import argparse,json,hashlib
from collections import deque
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter

def repair(source,output,report):
    original=np.array(Image.open(source).convert('RGBA'));h,w=original.shape[:2]
    rgb=original[:,:,:3];dark=(rgb.max(2)<=12).ravel();labels=np.zeros(h*w,np.int32);sizes=[0]
    def neighbors(k):
        x=k%w
        if x:yield k-1
        if x<w-1:yield k+1
        if k>=w:yield k-w
        if k<w*(h-1):yield k+w
    for seed in np.flatnonzero(dark):
        if labels[seed]:continue
        label=len(sizes);queue=deque([int(seed)]);labels[seed]=label;count=0
        while queue:
            k=queue.popleft();count+=1
            for n in neighbors(k):
                if dark[n] and not labels[n]:labels[n]=label;queue.append(n)
        sizes.append(count)
    # Large nearly pure black regions are atlas voids; small ink marks are not.
    chosen=[i for i,n in enumerate(sizes) if i and n>=256]
    mask=np.isin(labels,chosen).reshape(h,w)
    core=mask.copy();maximum=rgb.max(2)
    for _ in range(3):
        adjacent=np.zeros_like(mask);adjacent[1:]|=mask[:-1];adjacent[:-1]|=mask[1:];adjacent[:,1:]|=mask[:,:-1];adjacent[:,:-1]|=mask[:,1:]
        mask|=adjacent & (maximum<80)
    flat=mask.ravel();filled=rgb.reshape(-1,3).copy();visited=~flat.copy();queue=deque()
    # Seed only with painted surface colours, not the black antialiased fringe.
    for k in np.flatnonzero(flat):
        for n in neighbors(int(k)):
            if not flat[n] and int(filled[n].max())>=100:
                filled[k]=filled[n];visited[k]=True;queue.append(int(k));break
    while queue:
        k=queue.popleft()
        for n in neighbors(k):
            if flat[n] and not visited[n]:filled[n]=filled[k];visited[n]=True;queue.append(n)
    if not visited.all():raise RuntimeError('Unreachable void pixels: source atlas needs manual review')
    # Smooth only the newly supplied data; valid painted texels stay bit exact.
    smooth=np.array(Image.fromarray(filled.reshape(h,w,3)).filter(ImageFilter.GaussianBlur(1.5)))
    result=original.copy();result[:,:,:3][mask]=smooth[mask]
    Image.fromarray(result).save(output)
    record={'source_sha256':hashlib.sha256(Path(source).read_bytes()).hexdigest(),'output_sha256':hashlib.sha256(Path(output).read_bytes()).hexdigest(),'size':[w,h],'selected_void_components':chosen,'component_sizes':{str(i):sizes[i] for i in chosen},'core_void_pixels':int(core.sum()),'repaired_pixels_including_fringe':int(mask.sum()),'painted_pixels_unchanged':bool(np.array_equal(original[~mask],result[~mask])),'alpha_unchanged':bool(np.array_equal(original[:,:,3],result[:,:,3])),'remaining_nearly_black_pixels_in_repaired_regions':int((result[:,:,:3][core].max(1)<=12).sum()),'method':'nearest painted boundary flood fill, soften new fill only; preserve small dark ink components'}
    Path(report).write_text(json.dumps(record,indent=2));print(json.dumps(record,ensure_ascii=False))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--out',required=True);p.add_argument('--report',required=True);a=p.parse_args();repair(a.source,a.out,a.report)
