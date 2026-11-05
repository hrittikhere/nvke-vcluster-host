#!/usr/bin/env python3
"""Offline tests. No Google Cloud calls or infrastructure are created."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('kubeconfig', ROOT / 'kubeconfig.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture():
    return {'clusters': [{'name': 'demo', 'cluster': {
        'server': 'https://172.31.2.1:6443', 'certificate-authority-data': 'TEST_CA'}}],
        'users': [{'name': 'admin', 'user': {'client-certificate-data': 'TEST_CERT',
                                          'client-key-data': 'TEST_KEY'}}],
        'contexts': [{'name': 'demo', 'context': {'cluster': 'demo', 'user': 'admin'}}],
        'current-context': 'demo'}


class KubeconfigTests(unittest.TestCase):
    def test_preserves_tls_and_credentials(self):
        source = fixture()
        result, host, port = module.transform(copy.deepcopy(source), 8443)
        c = result['clusters'][0]['cluster']
        self.assertEqual(c['server'], 'https://127.0.0.1:8443')
        self.assertEqual(c['tls-server-name'], '172.31.2.1')
        self.assertEqual((host, port), ('172.31.2.1', 6443))
        self.assertEqual(result['users'], source['users'])
        self.assertEqual(c['certificate-authority-data'], 'TEST_CA')
        self.assertNotIn('insecure-skip-tls-verify', c)

    def test_preserves_explicit_tls_name(self):
        data = fixture()
        data['clusters'][0]['cluster']['tls-server-name'] = 'api.example.test'
        result, _, _ = module.transform(data, 8443)
        self.assertEqual(result['clusters'][0]['cluster']['tls-server-name'], 'api.example.test')

    def test_rejects_exec_plugin(self):
        data = fixture()
        data['users'][0]['user']['exec'] = {'command': '/opt/remote-only'}
        with self.assertRaisesRegex(ValueError, 'VM-side plugin'):
            module.transform(data, 8443)

    def test_rejects_unsafe_or_unexpected_endpoint(self):
        for endpoint in ['http://172.31.2.1:6443', 'https://badhost:6443',
                         'https://user:password@172.31.2.1:6443']:
            with self.subTest(endpoint=endpoint):
                data = fixture()
                data['clusters'][0]['cluster']['server'] = endpoint
                with self.assertRaises(ValueError):
                    module.transform(data, 8443)

    def test_rejects_disabled_tls(self):
        data = fixture()
        data['clusters'][0]['cluster']['insecure-skip-tls-verify'] = True
        with self.assertRaises(ValueError):
            module.transform(data, 8443)

    def test_private_output_permissions(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'source').write_text(json.dumps(fixture()))
            subprocess.run(['python3', str(ROOT / 'kubeconfig.py'), str(p / 'source'),
                            str(p / 'local'), str(p / 'target'), '8443'], check=True)
            self.assertEqual((p / 'local').stat().st_mode & 0o777, 0o600)
            self.assertEqual((p / 'target').read_text(), '172.31.2.1 6443\n')


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.kit = self.base / 'kit'
        shutil.copytree(ROOT, self.kit, ignore=shutil.ignore_patterns('.state', '__pycache__'))
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'calls.jsonl'
        stub = self.bin / 'gcloud'
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a') as f: f.write(json.dumps(a) + '\\n')
if a[:3] == ['compute', 'instances', 'list']:
    if os.environ.get('MOCK_LIST_ERROR') == '1':
        print('Authentication failure', file=sys.stderr); sys.exit(1)
    print(os.environ.get('MOCK_EXISTING', 'nvke-blog-demo'))
elif a[:3] == ['compute', 'instances', 'describe']:
    print(os.environ.get('MOCK_STATUS', 'RUNNING'))
elif a[:2] == ['compute', 'ssh'] and os.environ.get('MOCK_WAIT_ERROR') == '1':
    if '--command' in a and a[a.index('--command')+1].endswith('manage.sh wait'):
        print('Setup failed', file=sys.stderr); sys.exit(1)
''')
        stub.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        MOCK_LOG=str(self.log))
        self.env.pop('NVKE_CONFIG', None)

    def tearDown(self):
        self.temp.cleanup()

    def run_kit(self, *args):
        return subprocess.run(['bash', str(self.kit / 'nvke-gcp.sh'), *args],
                              env=self.env, capture_output=True, text=True)

    def calls(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_plan_has_no_cloud_calls(self):
        r = self.run_kit('plan')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('400 GB', r.stdout)
        self.assertEqual(self.calls(), [])

    def test_reuses_existing_vm(self):
        r = self.run_kit('up')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(any(c[:3] == ['compute', 'instances', 'create'] for c in self.calls()))
        self.assertTrue(any(c[:2] == ['compute', 'scp'] for c in self.calls()))

    def test_new_vm_shape_and_network(self):
        self.env['MOCK_EXISTING'] = ''
        r = self.run_kit('up')
        self.assertEqual(r.returncode, 0, r.stderr)
        create = next(c for c in self.calls() if c[:3] == ['compute', 'instances', 'create'])
        for arg in ['--boot-disk-size=400GB', '--machine-type=e2-custom-12-24576', '--no-service-account']:
            self.assertIn(arg, create)
        self.assertFalse(any('firewall-rules' in c for c in self.calls()))

    def test_auth_failure_does_not_create(self):
        self.env['MOCK_LIST_ERROR'] = '1'
        r = self.run_kit('up')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_stopped_vm_does_not_install(self):
        self.env['MOCK_STATUS'] = 'TERMINATED'
        r = self.run_kit('up')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(any(c[:2] == ['compute', 'scp'] for c in self.calls()))

    def test_setup_failure_not_reported_as_ready(self):
        self.env['MOCK_WAIT_ERROR'] = '1'
        r = self.run_kit('up')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('Ready. Open endpoints', r.stdout)

    def test_delete_requires_explicit_flag(self):
        r = self.run_kit('destroy')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_ref_rejected(self):
        p = self.kit / 'config.env'
        p.write_text(p.read_text().replace('5293831ce0eb1ec3f8864b2fd8b53a6621a83cc8', 'main'))
        r = self.run_kit('up')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_vcluster_version_validated_and_forwarded(self):
        p = self.kit / 'config.env'
        p.write_text(p.read_text().replace('NVKE_VCLUSTER_VERSION=0.37.6', 'NVKE_VCLUSTER_VERSION=latest'))
        r = self.run_kit('up')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), [])
        p.write_text(p.read_text().replace('NVKE_VCLUSTER_VERSION=latest', 'NVKE_VCLUSTER_VERSION=0.37.6'))
        r = self.run_kit('up')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('NVKE_VCLUSTER_VERSION=0.37.6', (self.kit / '.state' / 'lab.env').read_text())

    def test_storage_class_pin_validated_and_forwarded(self):
        p = self.kit / 'config.env'
        original = p.read_text()
        p.write_text(original.replace('NVKE_LOCAL_PATH_VERSION=v0.0.30', 'NVKE_LOCAL_PATH_VERSION=master'))
        r = self.run_kit('up')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), [])
        p.write_text(original.replace('NVKE_LOCAL_PATH_SHA256=', 'NVKE_LOCAL_PATH_SHA256=deadbeef'))
        r = self.run_kit('up')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), [])
        p.write_text(original)
        r = self.run_kit('up')
        self.assertEqual(r.returncode, 0, r.stderr)
        env = (self.kit / '.state' / 'lab.env').read_text()
        self.assertIn('NVKE_LOCAL_PATH_VERSION=v0.0.30', env)
        self.assertRegex(env, r'NVKE_LOCAL_PATH_SHA256=[a-f0-9]{64}\n')

    def test_metrics_server_pin_validated_and_forwarded(self):
        p = self.kit / 'config.env'
        original = p.read_text()
        for bad in [original.replace('NVKE_METRICS_SERVER_VERSION=v0.9.0', 'NVKE_METRICS_SERVER_VERSION=latest'),
                    original.replace('NVKE_METRICS_SERVER_SHA256=', 'NVKE_METRICS_SERVER_SHA256=deadbeef')]:
            p.write_text(bad)
            r = self.run_kit('up')
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(self.calls(), [])
        p.write_text(original)
        r = self.run_kit('plan')
        self.assertIn('metrics-server v0.9.0', r.stdout)
        r = self.run_kit('up')
        self.assertEqual(r.returncode, 0, r.stderr)
        env = (self.kit / '.state' / 'lab.env').read_text()
        self.assertIn('NVKE_METRICS_SERVER_VERSION=v0.9.0\n', env)
        self.assertRegex(env, r'NVKE_METRICS_SERVER_SHA256=[a-f0-9]{64}\n')

    def test_remote_vcluster_targets_workload_and_quotes(self):
        dangerous = 'x; touch /tmp/nvke-should-not-exist'
        r = self.run_kit('vcluster', 'list', '--namespace', dangerous)
        self.assertEqual(r.returncode, 0, r.stderr)
        call = self.calls()[0]
        import shlex
        words = shlex.split(call[call.index('--command') + 1])
        self.assertIn('KUBECONFIG=/opt/nvke-lab/state/workload.kubeconfig', words)
        self.assertEqual(words[-3:], ['list', '--namespace', dangerous])

    def test_site_configs_isolate_state(self):
        seen = {}
        for site in sorted((self.kit / 'sites').glob('*.env')):
            self.env['NVKE_CONFIG'] = str(site)
            self.env['MOCK_EXISTING'] = ''
            r = self.run_kit('up')
            self.assertEqual(r.returncode, 0, r.stderr)
            create = [c for c in self.calls() if c[:3] == ['compute', 'instances', 'create']][-1]
            lab = (self.kit / '.state' / 'sites' / site.stem / 'lab.env').read_text()
            seen[site.stem] = (create[3], next(a for a in create if a.startswith('--zone=')), lab)
        self.assertGreaterEqual(len(seen), 2)
        vms = {v[0] for v in seen.values()}
        zones = {v[1] for v in seen.values()}
        self.assertEqual(len(vms), len(seen))
        self.assertEqual(len(zones), len(seen))
        self.assertNotIn('nvke-blog-demo', vms)
        for stem, (_, _, lab) in seen.items():
            self.assertNotIn('NVKE_CLUSTER=nvke-demo\n', lab, stem)
        self.assertFalse((self.kit / '.state' / 'lab.env').exists())

    def test_site_ports_never_collide(self):
        import re
        ports = []
        for cfg in [self.kit / 'config.env', *sorted((self.kit / 'sites').glob('*.env'))]:
            ports += re.findall(r'^NVKE_LOCAL_\w+_PORT=(\d+)$', cfg.read_text(), re.M)
        self.assertEqual(len(ports), len(set(ports)), ports)

    def test_remote_kubectl_shell_quoting(self):
        dangerous = 'x; touch /tmp/nvke-should-not-exist'
        r = self.run_kit('kubectl', 'get', 'pods', '-l', dangerous)
        self.assertEqual(r.returncode, 0, r.stderr)
        call = self.calls()[0]
        import shlex
        cmd = call[call.index('--command') + 1]
        self.assertEqual(shlex.split(cmd)[-1], dangerous)



class RemoteScriptTests(unittest.TestCase):
    def test_build_path_keeps_default_umask(self):
        """dpkg-deb rejects control directories narrower than 0755, so the
        setup service, install.sh and bootstrap.sh must not build under 077."""
        for name in ['remote/submit.sh', 'remote/install.sh', 'remote/bootstrap.sh']:
            text = (ROOT / name).read_text()
            self.assertNotIn('UMask=0077', text, name)
            self.assertNotIn('umask 077', text, name)
        bootstrap = (ROOT / 'remote/bootstrap.sh').read_text()
        for secret in ['controller/.env.tilt', 'management.kubeconfig', 'workload.kubeconfig']:
            self.assertRegex(bootstrap, r'chmod 0600 "?[^\n]*' + secret.replace('.', r'\.'))

    def test_bootstrap_installs_default_storage_class(self):
        """The mock lab has no provisioner; vCluster control planes need one."""
        bootstrap = (ROOT / 'remote/bootstrap.sh').read_text()
        self.assertIn('local-path-provisioner/$NVKE_LOCAL_PATH_VERSION/deploy/local-path-storage.yaml', bootstrap)
        self.assertIn('"$NVKE_LOCAL_PATH_SHA256"', bootstrap)
        self.assertIn('sha256sum -c', bootstrap)
        self.assertIn('storageclass local-path storageclass.kubernetes.io/is-default-class=true', bootstrap)
        self.assertIn('rollout status deployment/local-path-provisioner', bootstrap)
        # The phase must run against the workload cluster, after its nodes are Ready.
        self.assertLess(bootstrap.index('condition=Ready nodes'), bootstrap.index('local-path-storage.yaml'))
        self.assertLess(bootstrap.index('local-path-storage.yaml'), bootstrap.index('versions.txt'))

    def test_bootstrap_installs_metrics_server(self):
        """kubectl top needs the Metrics API; install it after the storage class, verified."""
        bootstrap = (ROOT / 'remote/bootstrap.sh').read_text()
        url = 'metrics-server/releases/download/$NVKE_METRICS_SERVER_VERSION/components.yaml'
        self.assertIn(url, bootstrap)
        self.assertIn('"$NVKE_METRICS_SERVER_SHA256"', bootstrap)
        self.assertNotIn('kubelet-insecure-tls', bootstrap.replace('without --kubelet-insecure-tls', ''))
        self.assertIn('rollout status deployment/metrics-server', bootstrap)
        self.assertIn('condition=Available apiservice/v1beta1.metrics.k8s.io', bootstrap)
        self.assertLess(bootstrap.index('rollout status deployment/local-path-provisioner'), bootstrap.index(url))
        self.assertLess(bootstrap.index('apiservice/v1beta1.metrics.k8s.io'), bootstrap.index('versions.txt'))

    def test_setup_installs_cli_but_creates_no_vcluster(self):
        """Setup installs only the pinned vCluster CLI; clusters are created later from the Platform."""
        install = (ROOT / 'remote/install.sh').read_text()
        self.assertIn('install -m 0755 vcluster /usr/local/bin/vcluster', install)
        for name in ['remote/bootstrap.sh', 'remote/manage.sh', 'nvke-gcp.sh', 'config.env']:
            text = (ROOT / name).read_text()
            self.assertNotIn('NVKE_VCLUSTER_NAME', text, name)
            self.assertNotIn('vc create', text, name)
        env = {k: v for k, v in os.environ.items() if k != 'NVKE_CONFIG'}
        r = subprocess.run(['bash', str(ROOT / 'nvke-gcp.sh'), 'plan'], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('vCluster CLI 0.37.6', r.stdout)
        self.assertNotIn('vCluster:', r.stdout)

    def test_install_exposes_nvkectl(self):
        install = (ROOT / 'remote/install.sh').read_text()
        self.assertIn('/usr/local/bin/nvkectl', install)
        self.assertIn('lab-profile.sh', install)
        self.assertIn('vcluster-linux-amd64', install)
        self.assertIn('checksums.txt', install)

if __name__ == '__main__':
    unittest.main(verbosity=2)
