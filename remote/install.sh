#!/usr/bin/env bash
set -euo pipefail
# Upstream builds Debian packages and container images; dpkg-deb rejects
# control directories narrower than 0755, so keep the default umask and
# protect secrets explicitly instead.
umask 022
BASE=/opt/nvke-lab
source "$BASE/kit/lab.env"
trap 'echo "Install failed at line $LINENO; inspect the setup journal." >&2' ERR
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 && $(uname -m) == x86_64 ]] || {
  echo 'This kit targets Ubuntu 24.04 amd64.' >&2; exit 1;
}
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y \
  git build-essential golang-go jq curl netcat-openbsd dpkg-dev \
  ca-certificates unzip python3 python3-yaml openssl kmod util-linux
id nvkelab >/dev/null 2>&1 || useradd -m -d "$BASE/home" -s /bin/bash nvkelab
for dir in home src state capnico; do
  install -d -m 0700 -o nvkelab -g nvkelab "$BASE/$dir"
done
# Do not change identities or source revisions underneath an existing lab.
if [[ -f "$BASE/state/identity" ]]; then
  [[ $(cat "$BASE/state/identity") == "$NVKE_REF $NVKE_CLUSTER" ]] || {
    echo 'Existing lab uses another commit or cluster name. Use a new VM for a different lab.' >&2; exit 1;
  }
fi
printf '%s %s\n' "$NVKE_REF" "$NVKE_CLUSTER" > "$BASE/state/identity"
chown nvkelab:nvkelab "$BASE/state/identity"
echo 'Installing Docker Engine and BuildKit...'
if ! command -v docker >/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --retry 4 -sSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/nvke-docker.list
  chmod 0644 /etc/apt/sources.list.d/nvke-docker.list
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
docker buildx version || { echo 'Docker exists but lacks Buildx. Install the matching Buildx package and rerun.' >&2; exit 1; }
systemctl enable --now docker
usermod -aG docker nvkelab
current=$(sysctl -n fs.inotify.max_user_instances)
if (( current < 1024 )); then
  echo 'fs.inotify.max_user_instances=1024' > /etc/sysctl.d/99-nvke-lab.conf
  chmod 0644 /etc/sysctl.d/99-nvke-lab.conf
  sysctl -p /etc/sysctl.d/99-nvke-lab.conf
fi
# Fetch only the pinned revision. A separate checkout preserves manual work.
if [[ ! -d "$BASE/src/.git" ]]; then
  [[ -z $(ls -A "$BASE/src") ]] || { echo 'Lab source directory is not empty.' >&2; exit 1; }
  runuser -u nvkelab -- git -C "$BASE/src" init
  runuser -u nvkelab -- git -C "$BASE/src" remote add origin https://github.com/dsx-ai-factory/nvke.git
  runuser -u nvkelab -- git -C "$BASE/src" fetch --depth=1 origin "$NVKE_REF"
  runuser -u nvkelab -- git -C "$BASE/src" checkout --detach FETCH_HEAD
fi
[[ $(runuser -u nvkelab -- git -C "$BASE/src" rev-parse HEAD) == "$NVKE_REF" ]] || {
  echo 'Source checkout does not match NVKE_REF; refusing to reset your work.' >&2; exit 1;
}
# Public source and build outputs must be world-readable for image builds and
# dpkg-deb. Generated credentials stay private.
chmod -R go+rX "$BASE/src" "$BASE/capnico"
[[ ! -f "$BASE/src/controller/.env.tilt" ]] || chmod 0600 "$BASE/src/controller/.env.tilt"
echo 'Checking virtual TPM support in the running GCE kernel...'
bash "$BASE/src/controller/hack/ensure-vtpm-proxy.sh" || {
  echo "Kernel $(uname -r) lacks working tpm_vtpm_proxy. See README kernel troubleshooting; setup cannot proceed." >&2
  exit 1
}
GO_PIN=$(awk '$1 == "go" {print $2; exit}' "$BASE/src/go.work")
[[ "$GO_PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Unexpected go.work version.' >&2; exit 1; }
export GOTOOLCHAIN="go$GO_PIN"
echo "Downloading the exact upstream Go toolchain: $GOTOOLCHAIN"
runuser -u nvkelab -- env HOME="$BASE/home" GOTOOLCHAIN="$GOTOOLCHAIN" go version
pin() { awk -v key="$1" '$1 == key && $2 == "?=" {print $3; exit}' "$BASE/src/make/tool-versions.mk"; }
KIND_VERSION=$(pin KIND_VERSION)
KIND_SHA=$(pin KIND_SHA256_AMD64)
HELM_VERSION=$(pin HELM_VERSION)
install -d -m 0700 "$BASE/downloads"
cd "$BASE/downloads"
fetch() { curl --fail --retry 4 --connect-timeout 30 -sSL "$1" -o "$2"; }
verify() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
fetch "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-amd64" kind
verify "$KIND_SHA" kind
install -m 0755 kind /usr/local/bin/kind
fetch "https://dl.k8s.io/release/$NVKE_KUBECTL_VERSION/bin/linux/amd64/kubectl" kubectl
fetch "https://dl.k8s.io/release/$NVKE_KUBECTL_VERSION/bin/linux/amd64/kubectl.sha256" kubectl.sha256
verify "$(cat kubectl.sha256)" kubectl
install -m 0755 kubectl /usr/local/bin/kubectl
helm_archive="helm-$HELM_VERSION-linux-amd64.tar.gz"
fetch "https://get.helm.sh/$helm_archive" "$helm_archive"
fetch "https://get.helm.sh/$helm_archive.sha256sum" helm.sha256
verify "$(awk 'NR==1 {print $1}' helm.sha256)" "$helm_archive"
tar -xzf "$helm_archive" linux-amd64/helm
install -m 0755 linux-amd64/helm /usr/local/bin/helm
tilt_archive="tilt.$NVKE_TILT_VERSION.linux.x86_64.tar.gz"
fetch "https://github.com/tilt-dev/tilt/releases/download/v$NVKE_TILT_VERSION/$tilt_archive" "$tilt_archive"
fetch "https://github.com/tilt-dev/tilt/releases/download/v$NVKE_TILT_VERSION/checksums.txt" tilt.sha256
tilt_sha=$(awk -v file="$tilt_archive" '$2 == file {print $1}' tilt.sha256)
[[ "$tilt_sha" =~ ^[a-f0-9]{64}$ ]] || { echo 'Tilt checksum missing.' >&2; exit 1; }
verify "$tilt_sha" "$tilt_archive"
tar -xzf "$tilt_archive" tilt
install -m 0755 tilt /usr/local/bin/tilt
vcluster_base="https://github.com/loft-sh/vcluster/releases/download/v$NVKE_VCLUSTER_VERSION"
fetch "$vcluster_base/vcluster-linux-amd64" vcluster
fetch "$vcluster_base/checksums.txt" vcluster.sha256
vcluster_sha=$(awk '$2 == "vcluster-linux-amd64" {print $1}' vcluster.sha256)
[[ "$vcluster_sha" =~ ^[a-f0-9]{64}$ ]] || { echo 'vCluster CLI checksum missing.' >&2; exit 1; }
verify "$vcluster_sha" vcluster
install -m 0755 vcluster /usr/local/bin/vcluster
cat > /etc/systemd/system/nvke-lab-tilt.service <<UNIT
[Unit]
Description=NVKE lab Tilt development environment
Requires=docker.service
After=docker.service network-online.target
[Service]
Type=simple
User=nvkelab
Group=nvkelab
SupplementaryGroups=docker
WorkingDirectory=$BASE/src/controller
Environment=HOME=$BASE/home
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$BASE/src/cli/bin
Environment=GOTOOLCHAIN=$GOTOOLCHAIN
Environment=DOCKER_BUILDKIT=1
Environment=KUBECONFIG=$BASE/home/.kube/config
ExecStart=/usr/local/bin/tilt up --host=127.0.0.1 --port=10350 --stream
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
UMask=0022
[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 /etc/systemd/system/nvke-lab-tilt.service
systemctl daemon-reload
# Grant the lab user only the service operations bootstrap needs.
cat > /etc/sudoers.d/nvke-lab <<'SUDO'
nvkelab ALL=(root) NOPASSWD: /usr/bin/systemctl start nvke-lab-tilt.service
SUDO
chmod 0440 /etc/sudoers.d/nvke-lab
visudo -cf /etc/sudoers.d/nvke-lab
# Put the lab tools on the lab user's PATH, and give admins a wrapper that
# runs nvkectl as the lab user so its site config and kubeconfig resolve.
cat > "$BASE/kit/lab-profile.sh" <<PROFILE
export PATH="$BASE/src/cli/bin:/usr/local/bin:\$PATH"
export GOTOOLCHAIN="$GOTOOLCHAIN"
export KUBECONFIG="$BASE/home/.kube/config"
PROFILE
chmod 0644 "$BASE/kit/lab-profile.sh"
for rc in .bashrc .profile; do
  touch "$BASE/home/$rc"; chown nvkelab:nvkelab "$BASE/home/$rc"
  grep -qF 'kit/lab-profile.sh' "$BASE/home/$rc" \
    || echo '[ -r /opt/nvke-lab/kit/lab-profile.sh ] && . /opt/nvke-lab/kit/lab-profile.sh' >> "$BASE/home/$rc"
done
cat > /usr/local/bin/nvkectl <<'WRAP'
#!/usr/bin/env bash
# Runs the lab's nvkectl as the nvkelab user. Needs sudo for other accounts.
BIN=/opt/nvke-lab/src/cli/bin/nvkectl
[[ $(id -un) != nvkelab ]] || exec "$BIN" "$@"
exec sudo -u nvkelab env HOME=/opt/nvke-lab/home \
  PATH=/opt/nvke-lab/src/cli/bin:/usr/local/bin:/usr/bin:/bin "$BIN" "$@"
WRAP
chmod 0755 /usr/local/bin/nvkectl
runuser -u nvkelab -- env HOME="$BASE/home" \
  PATH="/usr/local/bin:/usr/bin:/bin:$BASE/src/cli/bin" GOTOOLCHAIN="$GOTOOLCHAIN" \
  bash "$BASE/kit/remote/bootstrap.sh"
# Give root the workload cluster as its default kubeconfig, so `sudo kubectl`
# works on the VM. Copy rather than move: the kit reads the original. Keep a
# backup of any different config already there instead of overwriting it.
install -d -m 0700 -o root -g root /root/.kube
if [[ -f /root/.kube/config ]] && ! cmp -s "$BASE/state/workload.kubeconfig" /root/.kube/config; then
  cp -p /root/.kube/config "/root/.kube/config.bak-$(date -u +%Y%m%dT%H%M%SZ)"
fi
install -m 0600 -o root -g root "$BASE/state/workload.kubeconfig" /root/.kube/config
echo 'Workload kubeconfig installed at /root/.kube/config.'
