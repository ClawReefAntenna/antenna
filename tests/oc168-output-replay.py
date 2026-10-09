#!/usr/bin/env python3
import os,pathlib,subprocess,tempfile,concurrent.futures,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
checks=0
def check(value,name):
 global checks
 assert value,name
 checks+=1
 print('PASS',name)
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d);body=p/'body';body.write_text('hello');out=p/'out'
 def prefix(target):return subprocess.run(['python3',str(ROOT/'lib/antenna-list-meta.py'),'prefix','staff','alpha',str(body),str(target)],capture_output=True,timeout=5)
 check(prefix(out).returncode==0 and out.stat().st_mode&0o777==0o600,'new metadata output is private')
 old=out.read_bytes();check(prefix(out).returncode!=0 and out.read_bytes()==old,'nonempty output preserved')
 link=p/'symlink';link.symlink_to(out);check(prefix(link).returncode!=0 and out.read_bytes()==old,'symlink output refused without mutation')
 empty=p/'empty';empty.touch(mode=0o600);hard=p/'hard';os.link(empty,hard)
 check(prefix(hard).returncode!=0 and empty.stat().st_size==0,'hardlink output refused')
 public=p/'public';public.touch(mode=0o644);check(prefix(public).returncode!=0 and public.stat().st_size==0,'public output refused')
 fifo=p/'fifo';os.mkfifo(fifo,0o600);check(prefix(fifo).returncode!=0,'FIFO output refuses without blocking')
 stage=p/'stage';stage.touch(mode=0o600);check(prefix(stage).returncode==0,'existing private mktemp output works')
 for helper in ['plugin/antenna-replay.sh','lib/antenna-replay.sh']:
  if not (ROOT/helper).exists():
   assert helper=='lib/antenna-replay.sh', 'native replay helper missing'
   print('SOURCE-ONLY helper excluded from artifact:',helper)
   continue
  directory=p/helper.split('/')[0];directory.mkdir(mode=0o700);cache=directory/'replay.json'
  message=str(uuid.uuid4())
  def reserve(mid=message,capacity='240'):
   return subprocess.run(['bash','-c','source "$1"; replay_reserve "$2" 360 "$3" "$4" "$5"','test',str(ROOT/helper),str(cache),capacity,'peer;$(touch SHOULD_NOT_EXIST)',mid],capture_output=True,timeout=8).returncode
  with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:codes=list(pool.map(lambda _:reserve(),range(8)))
  check(codes.count(0)==1 and codes.count(2)==7,helper+' concurrent duplicate admits exactly once')
  check(cache.stat().st_mode&0o777==0o600 and directory.stat().st_mode&0o777==0o700,helper+' private state')
  old=cache.read_bytes();check(reserve(str(uuid.uuid4()),'1')==3 and cache.read_bytes()==old,helper+' full cache refuses and preserves state')
  cache.write_text('damaged');check(reserve(str(uuid.uuid4()))==3,helper+' damaged cache fails closed')
  check(not list(directory.glob('.replay*')),helper+' failure cleans both staging files')
  cache.unlink();cache.symlink_to(out);saved=out.read_bytes();check(reserve()==3 and out.read_bytes()==saved,helper+' symlink cache refuses without target mutation')
print('PASS',checks,'output/replay checks')
