"""Execute removal against real temporary files; system commands are simulated."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'server'))
import deploy as d
import removal as r

class RemovalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.users = {}; self.groups = {}; self.active = set(); self.commands = []; self.nft = False; self.fail_stop = False
        self.stack = []
        for p in [patch.object(r, 'HOST_ROOT', self.root), patch.object(r.pwd, 'getpwnam', side_effect=self.user),
                  patch.object(r.pwd, 'getpwall', side_effect=lambda: list(self.users.values())),
                  patch.object(r.grp, 'getgrnam', side_effect=self.group),
                  patch.object(r.shutil, 'which', return_value='/usr/sbin/nft'),
                  patch.object(d, 'run', side_effect=self.run_command), patch.object(d, 'step')]:
            p.start(); self.stack.append(p)
    def tearDown(self):
        for p in reversed(self.stack): p.stop()
        self.tmp.cleanup()
    def user(self, name):
        if name not in self.users: raise KeyError(name)
        return self.users[name]
    def group(self, name):
        if name not in self.groups: raise KeyError(name)
        return self.groups[name]
    def put(self, name, text='project data'):
        p=r.path(name);p.parent.mkdir(parents=True, exist_ok=True);p.write_text(text);return p
    def run_command(self, args, **kwargs):
        self.commands.append(args); out=b''; code=0
        if args[0]=='systemctl':
            unit=args[-1]; unit_file=r.path('/etc/systemd/system/'+unit)
            if args[1]=='disable' and not self.fail_stop:self.active.discard(unit)
            if args[1]=='show':
                prop=args[args.index('-p')+1]
                if prop=='FragmentPath':out=('/etc/systemd/system/'+unit).encode() if unit_file.exists() else b''
                elif prop=='ActiveState':out=b'active' if unit in self.active else b'inactive'
                elif prop=='LoadState':out=b'loaded' if unit_file.exists() else b'not-found'
        elif args[0]=='nft':
            if args[1]=='delete':self.nft=False
            elif args[1]=='list':code=0 if self.nft else 1
        elif args[0]=='userdel':self.users.pop(args[1],None)
        elif args[0]=='groupdel':self.groups.pop(args[1],None)
        return subprocess.CompletedProcess(args,code,out,b'')
    def setup_project(self, kind='lethe'):
        layout=r.LAYOUTS[kind]
        for name in layout['paths']:
            if name in layout['links']:
                p=r.path(name);p.parent.mkdir(parents=True,exist_ok=True);p.symlink_to(r.path('/etc/systemd/system/'+p.name))
            elif name.endswith('.service'):
                prefix='/opt/lethe/caddy' if kind=='lethe' else '/opt/https-tunnel-lab/current/bin/caddy'
                text='[Service]\nExecStart='+prefix+' run\n'
                if name.endswith('egress.service'):text='[Service]\nExecStop=/usr/sbin/nft delete table ip lethe_v060\n'
                self.put(name,text)
            elif name=='/usr/local/bin/tunnelctl':
                target=self.put('/opt/https-tunnel-lab/devices/0.2.0/server/tunnelctl.py')
                r.path(name).parent.mkdir(parents=True,exist_ok=True);r.path(name).symlink_to(target)
            else:self.put(name+'/owned-data.txt')
        self.active=set(layout['services'])
        for i,name in enumerate(layout['accounts']):
            self.users[name]=SimpleNamespace(pw_name=name,pw_uid=900+i,pw_gid=900+i,pw_dir='/var/lib/'+name,pw_shell='/usr/sbin/nologin')
            self.groups[name]=SimpleNamespace(gr_mem=[],gr_gid=900+i)
        if kind=='lethe':
            self.put('/etc/lethe/manifest.json',json.dumps(dict(product='LETHE',domain='vpn.example.net',vpsIp='89.208.96.163')))
            self.put('/etc/lethe/config.json','{"secret":"must-never-appear"}')
            self.put('/etc/lethe/egress.nft','table ip lethe_v060 { }'); self.nft=True
        else:
            self.put('/opt/https-tunnel-lab/PROJECT','HTTPS Tunnel Lab\n')
            self.put('/etc/https-tunnel-lab/lab.json',json.dumps(dict(domain='vpn.example.net',experiment_ip='89.208.96.163')))
        self.put('/etc/ssh/sshd_config','keep SSH');self.put('/opt/unrelated/data','keep other software')
    def plan(self):return r.prepare(d.removal_api())[1]
    def execute(self, plan=None):
        p=plan or self.plan()
        return r.remove(d.removal_api(),dict(planToken=p['planToken'],confirmDomain=p['domain']))
    def assert_preserved(self):
        self.assertEqual(r.path('/etc/ssh/sshd_config').read_text(),'keep SSH')
        self.assertEqual(r.path('/opt/unrelated/data').read_text(),'keep other software')
    def test_native_complete_removal_and_verified_absence(self):
        self.setup_project();plan=self.plan();self.assertNotIn('must-never-appear',json.dumps(plan))
        self.assertEqual(self.execute(plan)['status'],'removed')
        for p in r.LAYOUTS['lethe']['paths']:self.assertFalse(r.exists(r.path(p)),p)
        self.assertFalse(self.users);self.assertFalse(self.groups);self.assertFalse(self.nft);self.assertFalse(r.path(r.JOURNAL).exists());self.assert_preserved()
    def test_legacy_removes_agent_history_devices_and_backups(self):
        self.setup_project('legacy');plan=self.plan();self.assertTrue(plan['includesMonitoring'])
        self.assertEqual(self.execute(plan)['status'],'removed')
        for p in r.LAYOUTS['legacy']['paths']:self.assertFalse(r.exists(r.path(p)),p)
        self.assert_preserved()
    def test_foreign_caddy_without_ownership_marker_is_never_removed(self):
        file=self.put('/opt/caddy/config','foreign')
        with self.assertRaises(d.DeployError):self.plan()
        self.assertEqual(file.read_text(),'foreign');self.assertFalse(self.commands)
    def test_stale_plan_stops_before_any_deletion(self):
        self.setup_project();plan=self.plan();self.commands.clear()
        self.put('/etc/lethe/config.json','changed after review')
        with self.assertRaises(d.DeployError):self.execute(plan)
        self.assertFalse(any(x[:2]==['systemctl','disable'] for x in self.commands));self.assertFalse(r.path(r.JOURNAL).exists())
    def test_wrong_typed_domain_stops_before_mutations(self):
        self.setup_project();plan=self.plan()
        with self.assertRaises(d.DeployError):r.remove(d.removal_api(),dict(planToken=plan['planToken'],confirmDomain='wrong.example.net'))
        self.assertFalse(r.path(r.JOURNAL).exists())
    def test_symlink_root_cannot_delete_another_directory(self):
        self.setup_project();shutil.rmtree(r.path('/opt/lethe'));r.path('/opt/lethe').symlink_to(r.path('/opt/unrelated'))
        with self.assertRaises(d.DeployError):self.plan()
        self.assert_preserved()
    def test_changed_unit_binary_blocks_removal(self):
        self.setup_project();self.put('/etc/systemd/system/lethe-caddy.service','[Service]\nExecStart=/opt/foreign/caddy run\n')
        with self.assertRaises(d.DeployError):self.plan()
        self.assert_preserved()
    def test_active_service_prevents_file_deletion_then_can_retry(self):
        self.setup_project();self.fail_stop=True
        with self.assertRaises(d.DeployError):self.execute()
        self.assertTrue(r.path('/etc/lethe/config.json').exists());self.assertTrue(r.path(r.JOURNAL+'/state.json').exists())
        self.fail_stop=False;self.assertTrue(self.plan()['resuming']);self.assertEqual(self.execute()['status'],'removed')
    def test_partial_filesystem_failure_can_resume(self):
        self.setup_project();original=shutil.rmtree
        def fail_web(p,*a,**kw):
            if Path(p)==r.path('/var/www/lethe'):raise PermissionError('simulated')
            return original(p,*a,**kw)
        with patch.object(r.shutil,'rmtree',side_effect=fail_web):
            with self.assertRaises(PermissionError):self.execute()
        self.assertFalse(r.path('/etc/systemd/system/lethe-caddy.service').exists())
        self.assertTrue(self.plan()['resuming']);self.assertEqual(self.execute()['status'],'removed');self.assert_preserved()
    def test_foreign_new_file_after_partial_removal_is_not_deleted(self):
        self.setup_project();self.fail_stop=True
        with self.assertRaises(d.DeployError):self.execute()
        p=r.path('/etc/systemd/system/lethe-caddy.service');p.unlink();p.write_text('replacement foreign service')
        with self.assertRaises(d.DeployError):self.plan()
        self.assertEqual(p.read_text(),'replacement foreign service')
    def test_changed_account_or_shared_group_is_not_removed(self):
        self.setup_project();self.users['lethe-caddy'].pw_dir='/home/human'
        with self.assertRaises(d.DeployError):self.plan()
        self.users['lethe-caddy'].pw_dir='/var/lib/lethe-caddy';self.groups['lethe-caddy'].gr_mem=['other-user']
        with self.assertRaises(d.DeployError):self.plan()
    def test_other_service_using_account_blocks_removal(self):
        self.setup_project();self.put('/etc/systemd/system/other.service','[Service]\nUser=lethe-caddy\nExecStart=/opt/other\n')
        with self.assertRaises(d.DeployError):self.plan()
    def test_nested_mount_is_not_traversed(self):
        self.setup_project();mount=r.path('/var/lib/lethe-caddy/mounted');mount.mkdir()
        with patch.object(r.os.path,'ismount',side_effect=lambda x:Path(x)==mount):
            with self.assertRaises(d.DeployError):self.plan()
    def test_foreign_tunnelctl_is_not_removed(self):
        self.setup_project('legacy');r.path('/usr/local/bin/tunnelctl').unlink();self.put('/usr/local/bin/tunnelctl','foreign script')
        with self.assertRaises(d.DeployError):self.plan()
    def test_unexpected_second_installation_blocks_removal(self):
        self.setup_project();self.put('/opt/https-tunnel-lab/PROJECT','HTTPS Tunnel Lab\n');self.put('/etc/https-tunnel-lab/lab.json','{"domain":"other.example.net"}')
        with self.assertRaises(d.DeployError):self.plan()

if __name__=='__main__':unittest.main(verbosity=2)
