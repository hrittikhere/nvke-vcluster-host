#!/usr/bin/env python3
"""Create a separate SSH-tunnel kubeconfig without disabling TLS verification."""
import ipaddress
import json
import os
import sys
from urllib.parse import urlsplit


def transform(data, port):
    if not 1024 <= port <= 65535:
        raise ValueError('local port must be in 1024..65535')
    if len(data.get('clusters', [])) != 1 or len(data.get('users', [])) != 1:
        raise ValueError('expected a minified kubeconfig with one cluster and user')
    user = data['users'][0]['user']
    if 'exec' in user or 'auth-provider' in user:
        raise ValueError('credentials require a VM-side plugin; use ./nvke-gcp.sh kubectl instead')
    cluster = data['clusters'][0]['cluster']
    url = urlsplit(cluster['server'])
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise ValueError('expected an HTTPS Kubernetes API endpoint')
    # Mock NICo yields an IP. Restrict it to prevent injecting SSH forward syntax.
    address = ipaddress.IPv4Address(url.hostname)
    target_port = url.port or 443
    if cluster.get('insecure-skip-tls-verify') or not cluster.get('certificate-authority-data'):
        raise ValueError('expected embedded CA data and TLS verification enabled')
    cluster.setdefault('tls-server-name', str(address))
    cluster['server'] = f'https://127.0.0.1:{port}'
    cluster.pop('proxy-url', None)
    return data, str(address), target_port


if __name__ == '__main__':
    try:
        source, dest, target, port = sys.argv[1:]
        with open(source) as f:
            data, host, remote_port = transform(json.load(f), int(port))
        for path, value in [(dest, json.dumps(data, indent=2) + '\n'),
                            (target, f'{host} {remote_port}\n')]:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as f:
                f.write(value)
            os.chmod(path, 0o600)
    except (ValueError, KeyError, OSError) as exc:
        sys.exit(f'Kubeconfig export failed: {exc}')
