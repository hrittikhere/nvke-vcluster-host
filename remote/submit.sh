#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run submit.sh with sudo.' >&2; exit 1; }
UPLOAD=${1:?upload directory required}
BASE=/opt/nvke-lab
if [[ -d "$BASE" && ! -f "$BASE/.kit-owned" ]]; then
  echo "$BASE already exists and is not owned by this kit." >&2; exit 1
fi
case "$(systemctl show nvke-lab-setup.service -p ActiveState --value)" in
  active|activating) echo 'Setup already running; use logs or wait.' >&2; exit 1 ;;
esac
install -d -m 0755 "$BASE/kit/remote"
touch "$BASE/.kit-owned"
install -m 0644 "$UPLOAD/lab.env" "$BASE/kit/lab.env"
install -m 0755 "$UPLOAD"/remote/*.sh "$BASE/kit/remote/"
rm -f "$BASE/state/ready"
cat > /etc/systemd/system/nvke-lab-setup.service <<'UNIT'
[Unit]
Description=Prepare NVKE mock-NICo lab
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash /opt/nvke-lab/kit/remote/install.sh
TimeoutStartSec=infinity
StandardOutput=journal
StandardError=journal
UNIT
systemctl daemon-reload
systemctl reset-failed nvke-lab-setup.service 2>/dev/null || true
systemctl start --no-block nvke-lab-setup.service
echo 'Started nvke-lab-setup.service. Follow progress with ./nvke-gcp.sh logs'
