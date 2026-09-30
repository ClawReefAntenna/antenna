import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
ROOT=Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'lib'))
import clawreef_http as http
VECTORS=json.loads((ROOT/'tests/fixtures/clawreef-http-v1.json').read_text())['vectors']

class SigningTests(unittest.TestCase):
    def test_rfc8032_vectors_match_node_and_openssl(self):
        # Public RFC test seed; not an installed or production credential.
        der=bytes.fromhex('302e020100300506032b6570042204209d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
        with tempfile.TemporaryDirectory() as directory:
            key=Path(directory)/'key.der';key.write_bytes(der);key.chmod(0o600)
            for v in VECTORS:
                self.assertEqual(base64.b64encode(http.canonical(v['fields'])).decode(),v['canonical_base64'])
                self.assertEqual(http.sign(v['fields'],key,v['fields']['key_id']),v['signature_base64'])
            self.assertEqual(key.read_bytes(),der)
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()),['key.der'])
    def test_unsafe_symlink_wrong_algorithm_mismatched_key_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            key=Path(directory)/'key.pem'
            subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(key)],check=True,capture_output=True)
            key.chmod(0o644)
            v=VECTORS[0]
            with self.assertRaises(http.SigningError):http.sign(v['fields'],key,v['fields']['key_id'])
            key.chmod(0o600)
            with self.assertRaises(http.SigningError):http.sign(v['fields'],key,v['fields']['key_id'])
            link=Path(directory)/'link';link.symlink_to(key)
            with self.assertRaises(http.SigningError):http.sign(v['fields'],link,v['fields']['key_id'])
            fifo=Path(directory)/'fifo';os.mkfifo(fifo,0o600)
            with self.assertRaises(http.SigningError):http.sign(v['fields'],fifo,v['fields']['key_id'])
            subprocess.run(['openssl','genpkey','-algorithm','EC','-pkeyopt','ec_paramgen_curve:P-256','-out',str(key)],check=True,capture_output=True)
            with self.assertRaises(http.SigningError):http.sign(v['fields'],key,v['fields']['key_id'])
    def test_nonce_operation_grammar_and_no_reusable_credentials(self):
        nonces={http.nonce() for _ in range(100)};self.assertEqual(len(nonces),100)
        for n in nonces:self.assertRegex(n,r'^[A-Za-z0-9_-]{22}$');self.assertEqual(len(base64.urlsafe_b64decode(n+'==')),16)
        self.assertRegex(http.operation_id(),r'^\d{8}T\d{6}Z\.[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
        headers=http.headers(VECTORS[0]['fields'],VECTORS[0]['signature_base64'])
        self.assertFalse({'Cookie','Authorization','Idempotency-Key'} & headers.keys())
if __name__=='__main__':unittest.main()
