#!/usr/bin/env python3
"""Build local installables from exact allowlists; never upload or install."""
import argparse, gzip, hashlib, io, json, os, shutil, subprocess, tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def archive(folder,target,prefix):
    with target.open('xb') as raw, gzip.GzipFile(fileobj=raw,mode='wb',mtime=0,filename='') as gz, tarfile.open(fileobj=gz,mode='w') as tar:
        for p in sorted(folder.rglob('*')):
            if not p.is_file():continue
            data=p.read_bytes();info=tarfile.TarInfo(prefix+'/'+p.relative_to(folder).as_posix())
            info.size=len(data);info.mode=p.stat().st_mode&0o777;info.mtime=0
            tar.addfile(info,io.BytesIO(data))
def build(output):
    plan=json.loads((ROOT/'packaging/allowlists.json').read_text())
    output.mkdir(parents=True,exist_ok=False)
    rev=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()
    dirty=bool(subprocess.check_output(['git','-C',str(ROOT),'status','--porcelain'],text=True).strip())
    summary={'sourceDirty':dirty,'candidate':plan['candidate'],'sourceRevision':rev,'baseRevision':plan['base_revision'],'compatibility':plan['compatibility'],'artifacts':{}}
    for kind,files in plan['artifacts'].items():
        if len(files)!=len(set(files)):raise ValueError('duplicate allowlist path')
        folder=output/kind;folder.mkdir();entries=[]
        for name in files:
            rel=Path(name);src=ROOT/rel
            if rel.is_absolute() or '..' in rel.parts or src.is_symlink() or not src.is_file() or src.resolve()!=src:raise ValueError('unsafe/missing source '+name)
            destination=rel.relative_to('plugin') if kind=='native' and name.startswith('plugin/') else rel
            target=folder/destination
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,target)
            target.chmod(0o755 if src.read_bytes().startswith(b'#!') else 0o644)
            entries.append({'path':target.relative_to(folder).as_posix(),'source':name,'sha256':digest(target),'mode':oct(target.stat().st_mode&0o777),'ownerTicket':'OC168-SEC-001'})
        manifest={'sourceDirty':dirty,'schema':1,'kind':kind,'candidate':plan['candidate'],'sourceRevision':rev,'compatibility':plan['compatibility'],'files':entries}
        (output/(kind+'-manifest.json')).write_text(json.dumps(manifest,indent=2)+'\n')
        name=f"antenna-{kind}-{plan['candidate']}.tgz";tarpath=output/name
        archive(folder,tarpath,'package' if kind=='native' else 'antenna-'+kind)
        summary['artifacts'][kind]={'archive':name,'sha256':digest(tarpath),'files':len(entries)}
    if not dirty:
        source=output/('antenna-source-'+plan['candidate']+'.tgz')
        data=subprocess.check_output(['git','-C',str(ROOT),'archive','--format=tar','--prefix=antenna-source/','HEAD'])
        with source.open('xb') as raw, gzip.GzipFile(fileobj=raw,mode='wb',mtime=0,filename='') as gz:gz.write(data)
        summary['sourceArchive']={'archive':source.name,'sha256':digest(source),'sourceRevision':rev}
    (output/'build.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();build(a.output.resolve())
