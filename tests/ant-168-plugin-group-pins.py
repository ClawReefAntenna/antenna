#!/usr/bin/env python3
"""Public-group pin roots after real plugin contact import, plus fail-closed paths."""
from pathlib import Path
import json,subprocess,tempfile,shutil,datetime,os
ROOT=Path(__file__).resolve().parents[1]
checks=[]
with tempfile.TemporaryDirectory(prefix='antenna-group-pins-') as directory:
 base=Path(directory)
 subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(base/'private.pem')],check=True,capture_output=True)
 pub=subprocess.check_output(['openssl','pkey','-in',str(base/'private.pem'),'-pubout'],text=True)
 for name in ['imported-plugin','legacy-keys','legacy-secrets','outside','symlink-key','symlink-root','writable-key','writable-root','invalid-key']:
  root=base/name;root.mkdir();(root/'scripts').mkdir();(root/'lib').mkdir();(root/'keys').mkdir(mode=0o700);(root/'secrets').mkdir(mode=0o700)
  shutil.copyfile(ROOT/'scripts/antenna-public-group.sh',root/'scripts/antenna-public-group.sh');shutil.copyfile(ROOT/'lib/antenna-signature.sh',root/'lib/antenna-signature.sh')
  shutil.copytree(ROOT/'plugin',root/'plugin')
  (root/'antenna-peers.json').write_text('{}');(root/'antenna-peers.json').chmod(0o600)
  contact={'schema_version':3,'bundle_type':'antenna-plugin-contact','transport_profile':'antenna-plugin-v2','peer':'clawreef','origin':'https://example.invalid/api','allow_http':False,'public_key':pub,'antenna_bearer':'synthetic-only-'+'x'*40,'destinations':['groups'],'expires_at':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=10)).isoformat()}
  f=root/'contact';f.write_text(json.dumps(contact));f.chmod(0o600)
  subprocess.run(['node',str(root/'plugin/pairing.mjs'),'import',str(root),str(f),'clawreef','groups'],check=True,capture_output=True)
  peers=json.loads((root/'antenna-peers.json').read_text());pin=Path(peers['clawreef']['signing_public_key_file'])
  if name=='legacy-keys':
   peers['clawreef'].pop('transport_profile');shutil.copyfile(pin,root/'keys/pin.pem');(root/'keys/pin.pem').chmod(0o600);peers['clawreef']['signing_public_key_file']='keys/pin.pem'
  elif name=='legacy-secrets':peers['clawreef'].pop('transport_profile')
  elif name=='outside':
   f=base/'outside.pem';f.write_text(pub);f.chmod(0o600);peers['clawreef']['signing_public_key_file']=str(f)
  elif name=='symlink-key':
   link=root/'secrets/link.pem';link.symlink_to(pin);peers['clawreef']['signing_public_key_file']=str(link)
  elif name=='symlink-root':
   old=root/'secrets';old.rename(root/'actual-secrets');old.symlink_to(root/'actual-secrets',target_is_directory=True)
  elif name=='writable-key':pin.chmod(0o666)
  elif name=='writable-root':(root/'secrets').chmod(0o777)
  elif name=='invalid-key':pin.write_text('not an Ed25519 public key')
  (root/'antenna-peers.json').write_text(json.dumps(peers))
  route=root/'route.json';route.write_text(json.dumps({'proof':{'group_id':'12345678-1234-4234-8234-123456789abc','name':'Proof','relay_peer':'clawreef'}}))
  r=subprocess.run(['bash',str(root/'scripts/antenna-public-group.sh'),'install',str(route)],capture_output=True,text=True)
  expected=name in ['imported-plugin','legacy-keys'];assert (r.returncode==0)==expected,(name,r.stdout,r.stderr)
  if not expected:assert not (root/'antenna-public-groups.json').exists(),name
  checks.append({'case':name,'accepted':expected})
print(json.dumps({'passed':len(checks),'checks':checks},indent=2))
