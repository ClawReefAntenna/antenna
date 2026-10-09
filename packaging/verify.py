#!/usr/bin/env python3
"""Verify extracted allowlist artifacts, dependency closure and offline fixtures."""
import argparse, ast, hashlib, json, os, re, shutil, subprocess, tarfile, tempfile
from pathlib import Path
SOURCE=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('build',type=Path);a=p.parse_args();build=a.build.resolve()
meta=json.loads((build/'build.json').read_text());checks=[]
def check(name,ok):
    if not ok: raise AssertionError(name)
    checks.append(name)
def anchor_ids(file):
    text=file.read_text()
    return set(re.findall(r'<a id="([^"]+)"',text))|{re.sub(r'[^\w\- ]','',heading.lower()).replace(' ','-') for heading in re.findall(r'^#{1,6} (.+)$',text,re.M)}
def run(name,args,cwd=None,env=None):
    r=subprocess.run(args,cwd=cwd,env=env,capture_output=True,text=True,timeout=180)
    check(name+'\n'+r.stdout[-500:]+'\n'+r.stderr[-1000:],r.returncode==0)
    print('PASS',name,flush=True)
    return r
with tempfile.TemporaryDirectory(prefix='antenna-artifacts-') as temp:
    roots={}
    for kind,item in meta['artifacts'].items():
        folder=Path(temp)/kind;folder.mkdir()
        check(kind+' archive hash',hashlib.sha256((build/item['archive']).read_bytes()).hexdigest()==item['sha256'])
        with tarfile.open(build/item['archive']) as tar:tar.extractall(folder,filter='data')
        root=next(folder.iterdir());roots[kind]=root
        manifest=json.loads((build/(kind+'-manifest.json')).read_text())
        actual={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
        check(kind+' exact extracted inventory',actual=={x['path']:x['sha256'] for x in manifest['files']})
        for file in root.rglob('*'):
            if not file.is_file():continue
            if file.suffix=='.mjs':
                s=file.read_text()
                for target in re.findall(r'''(?:from\s*|import\s*\(|new URL\s*\()\s*['"](\.[^'"]+)['"]''',s):
                    check(kind+' import/resource '+str(file.relative_to(root))+' -> '+target,(file.parent/target).is_file())
                run(kind+' JS syntax '+file.name,['node','--check',str(file)])
            elif file.suffix=='.sh':
                run(kind+' shell syntax '+file.name,['bash','-n',str(file)])
                for target in re.findall(r'''source ["']?\$SKILL_DIR/([^"'\s]+)''',file.read_text()):check(kind+' shell source '+target,(root/target).is_file())
            elif file.suffix=='.py':ast.parse(file.read_text())
            elif file.suffix=='.md':
                for target in re.findall(r'\]\(([^)]+)\)',file.read_text()):
                    if re.match(r'[a-zA-Z]+:|#',target):continue
                    dest=file.parent/target.split('#')[0]
                    check(kind+' local link '+str(file.relative_to(root))+' -> '+target,dest.exists())
                    if '#' in target and dest.suffix=='.md':check(kind+' local anchor '+target,target.split('#',1)[1] in anchor_ids(dest))
        if kind in ('native','companion','clawhub'):
            check(kind+' no optional/history/legacy activation',not any(re.search(r'(evaluation\.mjs|corpus/|MIGRATION\.md|legacy-migration|migration-check|legacy-guides/|/agent/|antenna-(setup|upgrade|uninstall|relay|model-test|test-suite|inbox)\.sh)',n) for n in actual))
            cli=root/'cli.mjs' if kind=='native' else root/'plugin/cli.mjs'
            for command in ['mcs','migrate']:
                r=subprocess.run(['node',str(cli),'/nonexistent-host',command],capture_output=True,text=True)
                check(kind+' missing '+command+' actionable without host',r.returncode!=0 and 'OPTIONAL-KITS.md' in r.stderr)
    check('companion and ClawHub file identity',json.loads((build/'companion-manifest.json').read_text())['files']==json.loads((build/'clawhub-manifest.json').read_text())['files'])
    for kind in ['native','companion']:
        root=roots[kind];plugin=root if kind=='native' else root/'plugin';tests=plugin/'tests';tests.mkdir()
        suite=['cli-writes.mjs','config-write.mjs','operator-auth.mjs','package.mjs','flow.mjs','native-doctor.mjs']
        if kind=='companion':suite+=['native-companion.mjs']
        for test in suite:
            shutil.copyfile(SOURCE/'plugin/tests'/test,tests/test)
            run(kind+' '+test,['node',str(tests/test)])
    root=roots['companion']
    run('companion help',['bash',str(root/'bin/antenna.sh'),'help'])
    run('companion Registry dispatch',['bash',str(root/'bin/antenna.sh'),'clawreef','--help'])
    run('companion backup dispatch',['bash',str(root/'bin/antenna.sh'),'backup','--help'])
    # Execute recovery fixtures against the extracted runtime, not the source checkout.
    tests=root/'tests';tests.mkdir()
    for test in ['ant-167-recovery.py','ant-168-recovery.py','ant-168-plugin-group-pins.py','ant-168-imports.py']:
        shutil.copyfile(SOURCE/'tests'/test,tests/test)
    env={**os.environ,'ANT167_TEST_ROOT':str(root),'PYTHONDONTWRITEBYTECODE':'1'}
    run('extracted native recovery',['python3',str(tests/'ant-168-recovery.py')],env=env)
    for test in ['ant-168-plugin-group-pins.py','ant-168-imports.py']:
        run('extracted '+test,['python3',str(tests/test)],env=env)
    for test in ['diagnostics.mjs','corpus.mjs','resources.mjs','report-bounds.mjs']:
        run('standalone diagnostics '+test,['node',str(roots['diagnostics']/'plugin/tests'/test)])
    for test in ['plugin/tests/config-write.mjs','plugin/tests/migration-doctor.mjs','migration/schema-test.mjs','migration/cutover-test.mjs']:
        run('standalone migration '+test,['node',str(roots['migration']/test)])
(build/'verification.json').write_text(json.dumps({'passed':len(checks),'checks':checks},indent=2)+'\n')
print('PASS',len(checks),'checks')
