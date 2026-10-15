"""Pure safety/behavior checks; never installs anything on the test machine."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'server'))
spec = importlib.util.spec_from_file_location('deploy', Path(__file__).parents[1] / 'server/deploy.py')
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

class ServerTests(unittest.TestCase):
    def config(self):
        return dict(vpsIp='89.208.96.163', exitIp='185.203.4.24', vpsDomain='vpn.example.net',
                    email='admin@example.net', vpnUser='lethe', vpnPassword='A-long-unique-password-123!')

    def test_invalid_ip_never_reaches_installer(self):
        for value in ['127.0.0.1', 'not-an-ip', '::1', '8.8.8.8;touch /tmp/x']:
            with self.subTest(value=value), self.assertRaises(d.DeployError):
                d.validate({**self.config(), 'vpsIp': value})

    def test_domain_and_email_cannot_inject_caddyfile(self):
        for key, value in [('vpsDomain','x.example\n}'),('email','user@example.net\nadmin off'),('vpsDomain','example..net'),('vpsDomain','-x.example.net')]:
            with self.subTest(key=key), self.assertRaises(d.DeployError): d.validate({**self.config(),key:value})

    def test_password_length_and_username(self):
        for update in [dict(vpnPassword='short'),dict(vpnUser='x:y'),dict(vpnPassword='x'*20+'\n')]:
            with self.assertRaises(d.DeployError):d.validate({**self.config(),**update})

    def test_credentials_are_data_not_caddyfile_code(self):
        c = self.config();c['vpnPassword']='"{$INJECT}\n' # render helper itself never inserts the credential
        text=d.caddyfile(c)
        self.assertNotIn(c['vpnPassword'],text)
        j={'route':[{'handler':'forward_proxy','auth_credentials':[]}]}
        self.assertEqual(d.inject_auth(j,'x',c['vpnPassword']),1)
        self.assertEqual(base64.b64decode(base64.b64decode(j['route'][0]['auth_credentials'][0])).decode(),'x:'+c['vpnPassword'])

    def test_snat_is_scoped_and_does_not_flush_firewall(self):
        text=d.nft_config(987,'185.203.4.24')
        self.assertIn('meta skuid 987 ct direction original',text)
        self.assertNotIn('flush',text);self.assertNotIn('hook input',text)
        with self.assertRaises(ValueError):d.nft_config(987,'1.2.3.4; flush ruleset')

    def test_existing_server_blocks_mutations(self):
        with patch.object(d,'os_check'),patch.object(d,'status',return_value={'status':'installed','installed':True}),patch.object(d,'run') as run:
            self.assertTrue(d.install(self.config())['installed']);run.assert_not_called()

    def test_conflict_blocks_mutations(self):
        with patch.object(d,'os_check'),patch.object(d,'status',return_value={'status':'conflict','installed':False}),patch.object(d,'run') as run:
            self.assertEqual(d.install(self.config())['status'],'conflict');run.assert_not_called()

    def test_bad_dns_prevents_network_changes(self):
        import socket
        entries=[(socket.AF_INET,socket.SOCK_STREAM,6,'',('8.8.8.8',443))]
        with patch.object(d.socket,'getaddrinfo',return_value=entries),patch.object(d,'run') as run:
            with self.assertRaises(d.DeployError):d.network_check(self.config())
            run.assert_not_called()

    def test_aaaa_is_rejected_for_this_ipv4_installer(self):
        import socket
        entries=[(socket.AF_INET,socket.SOCK_STREAM,6,'',('89.208.96.163',443)),(socket.AF_INET6,socket.SOCK_STREAM,6,'',('2001:4860:4860::8888',443))]
        with patch.object(d.socket,'getaddrinfo',return_value=entries):
            with self.assertRaises(d.DeployError):d.network_check(self.config())

    def test_private_file_permissions_and_no_overwrite(self):
        import os
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'config';d.private_write(p,'secret')
            self.assertEqual(p.stat().st_mode & 0o777,0o600)
            with self.assertRaises(FileExistsError):d.private_write(p,'replacement')
            self.assertEqual(p.read_text(),'secret')

    def test_service_can_read_config_with_restrictive_umask(self):
        import os
        previous=os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                p=Path(tmp)/'config';d.private_write(p,'data',0o640)
                self.assertEqual(p.stat().st_mode & 0o777,0o640)
        finally:os.umask(previous)

    def test_curl_credential_escaping(self):
        self.assertEqual(d.curl_quote('a"b\\c'),'"a\\"b\\\\c"')
        c=self.config(); c['vpnPassword']='test"quoted\\password'
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            def fake(args,**kwargs):
                text=(folder/'probe-auth.cfg').read_text()
                self.assertNotIn(c['vpnPassword'], ' '.join(args))
                self.assertIn('noproxy = ""',text)
                self.assertIn('write-out = "\\nLETHE_CONNECT=%{http_connect}"',text)
                return Mock(returncode=0,stdout=b'185.203.4.24\nLETHE_CONNECT=200')
            with patch.object(d,'run',side_effect=fake):
                self.assertEqual(d.proxy_check(c,folder,True),(0,'185.203.4.24','200'))
            self.assertFalse((folder/'probe-auth.cfg').exists())

    def test_wrong_download_hash_never_executes(self):
        import io
        response=io.BytesIO(b'not a valid package')
        with tempfile.TemporaryDirectory() as tmp,patch.object(d.urllib.request,'urlopen',return_value=response),patch.object(d,'run') as run:
            with self.assertRaises(d.DeployError):d.download_binary(Path(tmp))
            run.assert_not_called()

    def test_installed_stopped_is_still_installed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);etc=root/'etc';etc.mkdir();opt=root/'opt';opt.mkdir();unit=root/'unit';unit.touch()
            (etc/'manifest.json').write_text(json.dumps({'product':'LETHE','domain':'vpn.example.net'}))
            (etc/'config.json').write_text('{}');(opt/'caddy').touch()
            with patch.multiple(d,ETC=etc,OPT=opt,UNIT=unit),patch.object(d,'active',return_value=False):
                result=d.status();self.assertTrue(result['installed']);self.assertFalse(result['running'])

if __name__=='__main__':unittest.main(verbosity=2)
