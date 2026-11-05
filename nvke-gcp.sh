#!/usr/bin/env bash
set -euo pipefail
KIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# This is your own trusted shell configuration.
source "${NVKE_CONFIG:-$KIT_DIR/config.env}"
STATE_DIR="$KIT_DIR/.state"
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Install $1 first."; }
quote() { printf '%q' "$1"; }
remote() { gcloud compute ssh "$NVKE_VM" "${GCLOUD_ARGS[@]}" "${SSH_ARGS[@]}" --command "$1"; }
usage() {
  cat <<'HELP'
Usage: ./nvke-gcp.sh COMMAND [arguments]
  plan               Show target and operations without accessing GCP
  up                 Create/reuse VM, install and launch NVKE, wait for readiness
  status             Show setup, services, providers and workload nodes
  logs               Follow setup logs (Ctrl+C leaves setup running)
  tilt-logs          Follow Tilt logs
  wait               Wait for the background setup to complete
  tunnel             Download an isolated kubeconfig and open localhost tunnels
  kubectl ARGS...    Run kubectl against the workload cluster on the VM
  vcluster ARGS...   Run the vCluster CLI against the workload cluster on the VM
  ssh                Open an SSH shell on the VM
  destroy --yes      Delete this VM and its boot disk, including all lab state
HELP
}
CMD=${1:-help}
case "$CMD" in help|-h|--help) usage; exit 0;; esac
[[ "$NVKE_PROJECT" =~ ^[a-z][a-z0-9-]{4,61}[a-z0-9]$ ]] || die "Set a valid NVKE_PROJECT."
[[ "$NVKE_VM" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || die "Invalid VM name."
[[ "$NVKE_ZONE" =~ ^[a-z0-9-]+$ ]] || die "Invalid zone."
[[ "$NVKE_CLUSTER" =~ ^[a-z][a-z0-9-]{0,50}[a-z0-9]$ ]] || die "Invalid cluster name."
[[ "$NVKE_REF" =~ ^[a-f0-9]{40}$ ]] || die "NVKE_REF must be a full immutable Git commit SHA."
[[ "$NVKE_DISK_GB" =~ ^[0-9]+$ ]] && (( NVKE_DISK_GB >= 200 )) || die "Disk must be at least 200 GB."
[[ "$NVKE_READY_TIMEOUT" =~ ^[0-9]+$ ]] || die "Invalid timeout."
[[ "$NVKE_VCLUSTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "NVKE_VCLUSTER_VERSION must be a plain semver like 0.37.6."
k8s_name='^[a-z]([a-z0-9-]{0,50}[a-z0-9])?$'
[[ -z "$NVKE_VCLUSTER_NAME" || "$NVKE_VCLUSTER_NAME" =~ $k8s_name ]] || die "NVKE_VCLUSTER_NAME must be empty or a lowercase DNS label."
[[ "$NVKE_VCLUSTER_NAMESPACE" =~ $k8s_name ]] || die "NVKE_VCLUSTER_NAMESPACE must be a lowercase DNS label."
[[ "$NVKE_LOCAL_PATH_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "NVKE_LOCAL_PATH_VERSION must be a tag like v0.0.30."
[[ "$NVKE_LOCAL_PATH_SHA256" =~ ^[a-f0-9]{64}$ ]] || die "NVKE_LOCAL_PATH_SHA256 must be the manifest's sha256."
for port in "$NVKE_LOCAL_API_PORT" "$NVKE_LOCAL_TILT_PORT" "$NVKE_LOCAL_K8S_PORT"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port > 1023 && port < 65536 )) || die "Invalid local port: $port"
done
[[ "$NVKE_LOCAL_API_PORT" != "$NVKE_LOCAL_TILT_PORT" && "$NVKE_LOCAL_API_PORT" != "$NVKE_LOCAL_K8S_PORT" && "$NVKE_LOCAL_TILT_PORT" != "$NVKE_LOCAL_K8S_PORT" ]] || die "Local ports must be distinct."
GCLOUD_ARGS=(--project="$NVKE_PROJECT" --zone="$NVKE_ZONE")
SSH_ARGS=(--quiet)
[[ "$NVKE_USE_IAP" != 1 ]] || SSH_ARGS+=(--tunnel-through-iap)
if [[ "$CMD" == plan ]]; then
  vcluster_plan='skipped (NVKE_VCLUSTER_NAME is empty)'
  [[ -z "$NVKE_VCLUSTER_NAME" ]] || vcluster_plan="cluster $NVKE_VCLUSTER_NAME in namespace $NVKE_VCLUSTER_NAMESPACE, chart $NVKE_VCLUSTER_VERSION"
  cat <<PLAN
Target: $NVKE_PROJECT / $NVKE_ZONE / $NVKE_VM
New VM: $NVKE_MACHINE, ${NVKE_DISK_GB} GB balanced disk, Ubuntu 24.04 amd64
Existing VM: reuse without resizing or replacing it
NVKE: $NVKE_REF; workload cluster: $NVKE_CLUSTER
VM tools: Tilt $NVKE_TILT_VERSION, kubectl $NVKE_KUBECTL_VERSION, vCluster CLI $NVKE_VCLUSTER_VERSION
Workload cluster add-ons: local-path-provisioner $NVKE_LOCAL_PATH_VERSION as the default storage class
vCluster: $vcluster_plan
Host installation: /opt/nvke-lab, dedicated nvkelab user
Endpoint access: SSH to localhost ports $NVKE_LOCAL_TILT_PORT, $NVKE_LOCAL_API_PORT, $NVKE_LOCAL_K8S_PORT
No public application ingress rules are created.
PLAN
  exit 0
fi
need gcloud
case "$CMD" in
  up)
    need python3
    need tar
    # A failed list is a failed operation, never mistaken for an absent VM.
    existing=$(gcloud compute instances list --project="$NVKE_PROJECT" \
      --filter="name=$NVKE_VM AND zone:($NVKE_ZONE)" --format='value(name)')
    if [[ -z "$existing" ]]; then
      create_args=(--machine-type="$NVKE_MACHINE" --boot-disk-size="${NVKE_DISK_GB}GB"
        --boot-disk-type=pd-balanced --image-project=ubuntu-os-cloud
        --image-family=ubuntu-2404-lts-amd64 --network="$NVKE_NETWORK"
        --provisioning-model=STANDARD --labels=purpose=nvke-blog,managed-by=nvke-gcp-kit
        --no-service-account --no-scopes)
      [[ -z "$NVKE_SUBNET" ]] || create_args+=(--subnet="$NVKE_SUBNET")
      gcloud compute instances create "$NVKE_VM" "${GCLOUD_ARGS[@]}" "${create_args[@]}"
    else
      echo "Reusing $existing. Existing files outside /opt/nvke-lab are preserved."
    fi
    vm_status=$(gcloud compute instances describe "$NVKE_VM" "${GCLOUD_ARGS[@]}" --format='value(status)')
    [[ "$vm_status" == RUNNING ]] || die "VM status is $vm_status. Start it before running up."
    umask 077
    mkdir -p "$STATE_DIR"
    # Only copy non-secret configuration and the remote scripts.
    {
      for key in NVKE_REF NVKE_CLUSTER NVKE_TILT_VERSION NVKE_KUBECTL_VERSION NVKE_VCLUSTER_VERSION \
                 NVKE_VCLUSTER_NAME NVKE_VCLUSTER_NAMESPACE NVKE_LOCAL_PATH_VERSION NVKE_LOCAL_PATH_SHA256 NVKE_READY_TIMEOUT; do
        printf '%s=%q\n' "$key" "${!key}"
      done
    } > "$STATE_DIR/lab.env"
    COPYFILE_DISABLE=1 tar --no-xattrs -czf "$STATE_DIR/payload.tar.gz" -C "$KIT_DIR" remote -C "$STATE_DIR" lab.env
    # Retry SSH during first boot, then fail with its actual diagnostics.
    for attempt in $(seq 1 30); do
      if remote 'true'; then break; fi
      [[ "$attempt" != 30 ]] || die "SSH did not become reachable. Check the VPC SSH rule or enable IAP."
      sleep 5
    done
    # cloud-init exits 2 for "degraded done" (recoverable warnings), which GCE images
    # produce routinely; only exit 1 is a failed boot.
    remote 'sudo cloud-init status --wait >/dev/null; rc=$?; [[ $rc == 0 || $rc == 2 ]] && { test ! -d /opt/nvke-lab || sudo test -f /opt/nvke-lab/.kit-owned; }' \
      || die "Cloud init failed or /opt/nvke-lab belongs to another setup."
    remote 'case "$(sudo systemctl show nvke-lab-setup.service -p ActiveState --value)" in active|activating) exit 10;; esac; mkdir -p "$HOME/nvke-kit-upload" && chmod 700 "$HOME/nvke-kit-upload"' \
      || die "Setup is already active. Use logs or wait."
    gcloud compute scp "$STATE_DIR/payload.tar.gz" "$NVKE_VM:nvke-kit-upload/payload.tar.gz" \
      "${GCLOUD_ARGS[@]}" "${SSH_ARGS[@]}"
    remote 'tar -xzf "$HOME/nvke-kit-upload/payload.tar.gz" -C "$HOME/nvke-kit-upload" && sudo bash "$HOME/nvke-kit-upload/remote/submit.sh" "$HOME/nvke-kit-upload"'
    echo "Setup is running in the background. A dropped SSH session will not stop it."
    # This session can last hours; keepalives stop idle disconnects.
    gcloud compute ssh "$NVKE_VM" "${GCLOUD_ARGS[@]}" "${SSH_ARGS[@]}" \
      --command 'sudo bash /opt/nvke-lab/kit/remote/manage.sh wait' \
      -- -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
      || die "Lost the readiness wait or setup failed. Reattach with ./nvke-gcp.sh wait, or inspect ./nvke-gcp.sh logs."
    echo "Ready. Open endpoints in another terminal: ./nvke-gcp.sh tunnel"
    ;;
  status|wait)
    remote "sudo bash /opt/nvke-lab/kit/remote/manage.sh $CMD" ;;
  logs)
    remote 'sudo journalctl -u nvke-lab-setup.service -n 80 -f --no-pager' ;;
  tilt-logs)
    remote 'sudo journalctl -u nvke-lab-tilt.service -n 80 -f --no-pager' ;;
  ssh)
    exec gcloud compute ssh "$NVKE_VM" "${GCLOUD_ARGS[@]}" "${SSH_ARGS[@]}" ;;
  kubectl)
    shift
    cmd='sudo -iu nvkelab /usr/local/bin/kubectl --kubeconfig=/opt/nvke-lab/state/workload.kubeconfig'
    for arg in "$@"; do cmd="$cmd $(quote "$arg")"; done
    remote "$cmd" ;;
  vcluster)
    shift
    # The lab user's profile points KUBECONFIG at the management cluster; target the workload cluster.
    cmd='sudo -iu nvkelab env KUBECONFIG=/opt/nvke-lab/state/workload.kubeconfig /usr/local/bin/vcluster'
    for arg in "$@"; do cmd="$cmd $(quote "$arg")"; done
    remote "$cmd" ;;
  tunnel)
    need python3
    umask 077
    mkdir -p "$STATE_DIR"
    remote 'sudo test -f /opt/nvke-lab/state/ready && curl -fsS http://127.0.0.1:10350/ >/dev/null' \
      || die "Setup or Tilt is not ready. Use status and logs first."
    remote 'sudo -iu nvkelab /usr/local/bin/kubectl --kubeconfig=/opt/nvke-lab/state/workload.kubeconfig config view --raw --flatten --minify -o json' > "$STATE_DIR/workload.remote.json"
    python3 "$KIT_DIR/kubeconfig.py" "$STATE_DIR/workload.remote.json" \
      "$STATE_DIR/workload.local.json" "$STATE_DIR/tunnel.target" "$NVKE_LOCAL_K8S_PORT"
    read -r target_host target_port < "$STATE_DIR/tunnel.target"
    echo "Tilt: http://localhost:$NVKE_LOCAL_TILT_PORT"
    echo "NVKE API docs: http://localhost:$NVKE_LOCAL_API_PORT/api/docs"
    echo "Workload kubeconfig: $STATE_DIR/workload.local.json"
    echo "Keep this terminal open; Ctrl+C closes only the tunnels."
    exec gcloud compute ssh "$NVKE_VM" "${GCLOUD_ARGS[@]}" "${SSH_ARGS[@]}" -- \
      -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -L "127.0.0.1:$NVKE_LOCAL_TILT_PORT:127.0.0.1:10350" \
      -L "127.0.0.1:$NVKE_LOCAL_API_PORT:127.0.0.1:8080" \
      -L "127.0.0.1:$NVKE_LOCAL_K8S_PORT:$target_host:$target_port"
    ;;
  destroy)
    [[ ${2:-} == --yes ]] || die "Deletes $NVKE_PROJECT/$NVKE_ZONE/$NVKE_VM and its boot disk. Run destroy --yes to confirm."
    gcloud compute instances delete "$NVKE_VM" "${GCLOUD_ARGS[@]}" --delete-disks=boot --quiet
    rm -f "$STATE_DIR/workload.remote.json" "$STATE_DIR/workload.local.json" "$STATE_DIR/tunnel.target"
    ;;
  *) usage; die "Unknown command: $CMD" ;;
esac
