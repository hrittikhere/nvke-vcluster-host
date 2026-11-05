#!/usr/bin/env bash
set -euo pipefail
BASE=/opt/nvke-lab
lab() { runuser -u nvkelab -- env HOME="$BASE/home" PATH="/usr/local/bin:/usr/bin:/bin:$BASE/src/cli/bin" "$@"; }
case ${1:-status} in
  wait)
    previous=''
    while :; do
      phase=$(cat "$BASE/state/phase" 2>/dev/null || echo 'Installing prerequisites')
      if [[ "$phase" != "$previous" ]]; then echo "$phase"; previous="$phase"; fi
      state=$(systemctl show nvke-lab-setup.service -p ActiveState --value)
      if [[ "$state" == failed ]]; then
        journalctl -u nvke-lab-setup.service -n 60 --no-pager
        exit 1
      fi
      if [[ -f "$BASE/state/ready" && "$state" != activating ]]; then
        cat "$BASE/state/ready"; exit 0
      fi
      case "$state" in
        activating|active) sleep 10 ;;
        *) echo "Setup ended ($state) without a ready marker. Use logs." >&2; exit 1 ;;
      esac
    done
    ;;
  status)
    systemctl --no-pager --full status nvke-lab-setup.service nvke-lab-tilt.service || true
    cat "$BASE/state/phase" 2>/dev/null || true
    if [[ -x "$BASE/src/cli/bin/nvkectl" ]]; then
      lab timeout 30 nvkectl get providers || true
      lab timeout 30 nvkectl get clusters || true
    fi
    if [[ -f "$BASE/state/workload.kubeconfig" ]]; then
      lab kubectl --request-timeout=20s --kubeconfig="$BASE/state/workload.kubeconfig" get nodes -o wide \
        || echo 'Workload API is not reachable right now; see Tilt logs.' >&2
      lab kubectl --request-timeout=20s --kubeconfig="$BASE/state/workload.kubeconfig" top nodes 2>/dev/null \
        || echo 'Metrics API is not available yet.' >&2
    fi
    ;;
  *) echo 'Expected status or wait.' >&2; exit 2 ;;
esac
