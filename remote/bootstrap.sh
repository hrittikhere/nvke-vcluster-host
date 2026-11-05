#!/usr/bin/env bash
set -euo pipefail
umask 022
BASE=/opt/nvke-lab
source "$BASE/kit/lab.env"
export KUBECONFIG="$BASE/home/.kube/config"
export DOCKER_BUILDKIT=1
cd "$BASE/src"
trap 'echo "Bootstrap failed at line $LINENO. Check setup and Tilt journals." >&2' ERR
exec 9>"$BASE/state/bootstrap.lock"
flock -n 9 || { echo 'Bootstrap is already running.' >&2; exit 1; }
phase() { echo "$*" | tee "$BASE/state/phase"; }
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }
if [[ ! -f "$BASE/state/initialized" ]]; then
  phase 'Checking resources and conflicting services'
  (( $(nproc) >= 6 )) || { echo 'Need at least 6 vCPUs.' >&2; exit 1; }
  awk '/MemAvailable:/ {exit ($2 < 12*1024*1024)}' /proc/meminfo || { echo 'Need 12 GiB available RAM.' >&2; exit 1; }
  free_kb=$(df -Pk "$BASE" | awk 'NR==2 {print $4}')
  (( free_kb >= 100*1024*1024 )) || { echo 'Need 100 GiB free disk.' >&2; exit 1; }
  docker info >/dev/null
  if kind get clusters 2>/dev/null | grep -qx controller-capi; then
    echo 'An existing controller-capi kind cluster was found. Use a fresh VM to avoid taking over a manual lab.' >&2; exit 1
  fi
  for port in 179 5432 7233 8080 8081 10350 18080 30440 30443; do
    if [[ -n $(ss -H -ltn "sport = :$port") ]]; then
      echo "Port $port is already occupied. Stop that service or use a fresh VM." >&2; exit 1
    fi
  done
  touch "$BASE/state/initialized"
fi
phase 'Building nvkectl'
run make -C cli build
export PATH="$BASE/src/cli/bin:$PATH"
phase 'Preparing the pinned public CAPNICo source'
if [[ ! -f "$BASE/capnico/chart/Chart.yaml" ]]; then
  module_dir=$(go mod download -json github.com/dsx-ai-factory/cluster-api-provider-nico | jq -er '.Dir')
  cp -R "$module_dir/." "$BASE/capnico/"
  chmod -R u+w "$BASE/capnico"
fi
test -f "$BASE/capnico/chart/Chart.yaml"
if [[ ! -f controller/tilt_config.json ]]; then
  python3 - <<'PY'
import json
with open('controller/tilt_config.json', 'w') as f:
    json.dump({'providers': ['capi_core', 'bgp-containers', 'nico'],
               'nico_sim_backends': ['container'],
               'capnico_source_dir': '/opt/nvke-lab/capnico'}, f, indent=2)
PY
fi
if [[ ! -f controller/.env.tilt ]]; then
  python3 - <<'PY'
import pathlib, secrets
p = pathlib.Path('controller/.env.tilt.example')
values = {key: secrets.token_hex(24) for key in
          ['DGXC_TENANT_PASSWORD', 'CNPG_SUPERUSER_PASSWORD',
           'CNPG_CLOUD_PASSWORD', 'CNPG_TEMPORAL_PASSWORD']}
values['DGXC_TENANT_USER'] = 'nvke-lab'
lines = []
for line in p.read_text().splitlines():
    key = line.split('=', 1)[0]
    lines.append(f'{key}={values[key]}' if key in values else line)
pathlib.Path('controller/.env.tilt').write_text('\n'.join(lines) + '\n')
PY
fi
chmod 0600 controller/.env.tilt
phase 'Preparing management cluster and node images (first run can take a while)'
# capd-up runs clusterctl init unconditionally, and clusterctl refuses to
# install a provider twice. Skip it once CAPD is installed so reruns recover.
if kubectl --context=kind-controller-capi --request-timeout=20s \
     get deployment -n capd-system capd-controller-manager >/dev/null 2>&1; then
  echo 'Management cluster already initialized; skipping capd-up.'
else
  run make -C controller capd-up
fi
run kubectl config use-context kind-controller-capi
kubectl config view --raw --minify --context kind-controller-capi > "$BASE/state/management.kubeconfig"
chmod 0600 "$BASE/state/management.kubeconfig"
phase 'Starting Tilt and waiting for the NVKE API and NICo provider'
sudo /usr/bin/systemctl start nvke-lab-tilt.service
run nvkectl config set-site --name local --url http://localhost:8080 \
  --kubeconfig "$BASE/state/management.kubeconfig"
deadline=$((SECONDS + NVKE_READY_TIMEOUT))
until providers=$(timeout 30 nvkectl get providers 2>&1) && \
      echo "$providers" | awk '$1 == "nico" && $2 == "CONFIGURED" {ok=1} END {exit !ok}' && \
      timeout 30 nvkectl get clusters >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { echo "$providers"; echo 'Timed out waiting for provider/API.' >&2; exit 1; }
  sleep 10
done
echo "$providers"
phase 'Creating or resuming the NVKE workload cluster'
export NVKE_CLUSTER
python3 - <<'PY'
import os, pathlib, yaml
name = os.environ['NVKE_CLUSTER']
source = pathlib.Path('cli/examples/nico-mock-cluster.yaml')
obj = yaml.safe_load(source.read_text())
old = obj['name']
def rename(value):
    if isinstance(value, dict):
        return {k: rename(v) for k, v in value.items()}
    if isinstance(value, list):
        return [rename(v) for v in value]
    if isinstance(value, str) and (value == old or value.startswith(old + '-')):
        return name + value[len(old):]
    return value
obj = rename(obj)
pathlib.Path('/opt/nvke-lab/state/cluster.yaml').write_text(yaml.safe_dump(obj, sort_keys=False))
PY
# List first: a connection/auth failure must not become a duplicate create.
clusters=$(timeout 30 nvkectl get clusters -o json)
if ! echo "$clusters" | jq -e --arg name "$NVKE_CLUSTER" 'any(.[]; .name == $name)' >/dev/null; then
  run nvkectl create cluster -f "$BASE/state/cluster.yaml"
fi
deadline=$((SECONDS + NVKE_READY_TIMEOUT))
while :; do
  if result=$(timeout 30 nvkectl get clusters "$NVKE_CLUSTER" 2>&1); then
    echo "$result"
    status=$(echo "$result" | awk -v name="$NVKE_CLUSTER" '$1 == name {print $4}')
    case "$status" in
      Provisioned) break ;;
      *Failed*|Deleting|Deleted) echo "Cluster entered $status. Inspect Tilt logs." >&2; exit 1 ;;
    esac
  fi
  (( SECONDS < deadline )) || { echo 'Timed out waiting for workload provisioning.' >&2; exit 1; }
  sleep 15
done
phase 'Waiting for admin kubeconfig and both workload nodes'
deadline=$((SECONDS + 900))
until timeout 30 nvkectl get kubeconfig "$NVKE_CLUSTER" --output-file "$BASE/state/workload.kubeconfig"; do
  (( SECONDS < deadline )) || exit 1
  sleep 10
done
chmod 0600 "$BASE/state/workload.kubeconfig"
# Require both expected nodes, not just whichever nodes happen to exist first.
until nodes=$(kubectl --request-timeout=20s --kubeconfig="$BASE/state/workload.kubeconfig" get nodes -o json) && \
      echo "$nodes" | jq -e '.items | length >= 2' >/dev/null; do
  (( SECONDS < deadline )) || { echo 'Both workload nodes did not register.' >&2; exit 1; }
  sleep 10
done
run kubectl --kubeconfig="$BASE/state/workload.kubeconfig" wait --for=condition=Ready nodes --all --timeout=900s
run kubectl --kubeconfig="$BASE/state/workload.kubeconfig" get nodes -o wide
phase 'Installing the default storage class on the workload cluster'
# The mock lab has no CSI driver or provisioner, so every PersistentVolumeClaim
# (including a vCluster control plane's data volume) stays Pending without one.
# local-path-provisioner keeps data on the node's disk, which is enough for a demo.
wk() { kubectl --request-timeout=30s --kubeconfig="$BASE/state/workload.kubeconfig" "$@"; }
manifest="$BASE/state/local-path-storage.$NVKE_LOCAL_PATH_VERSION.yaml"
if [[ ! -f "$manifest" ]]; then
  curl --fail --retry 4 --connect-timeout 30 -sSL \
    "https://raw.githubusercontent.com/rancher/local-path-provisioner/$NVKE_LOCAL_PATH_VERSION/deploy/local-path-storage.yaml" \
    -o "$manifest.tmp"
  printf '%s  %s\n' "$NVKE_LOCAL_PATH_SHA256" "$manifest.tmp" | sha256sum -c - \
    || { rm -f "$manifest.tmp"; echo 'local-path-provisioner manifest checksum mismatch.' >&2; exit 1; }
  mv "$manifest.tmp" "$manifest"
fi
run wk apply -f "$manifest"
# Only one class may be the default; clear any other before marking local-path.
for sc in $(wk get storageclass -o json | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name'); do
  [[ "$sc" == local-path ]] || run wk annotate storageclass "$sc" storageclass.kubernetes.io/is-default-class- --overwrite
done
run wk annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
run wk -n local-path-storage rollout status deployment/local-path-provisioner --timeout=300s
run wk get storageclass
{
  git rev-parse HEAD
  go version
  docker version --format '{{.Server.Version}}'
  kind version
  kubectl version --client -o yaml
  helm version --short
  tilt version
  vcluster --version
  echo "local-path-provisioner $NVKE_LOCAL_PATH_VERSION"
} > "$BASE/state/versions.txt"
phase 'Ready: workload cluster has two Ready nodes'
date -u +%FT%TZ > "$BASE/state/ready"
