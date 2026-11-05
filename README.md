# NVKE on Google Cloud: one-VM demo kit

This kit provisions or reuses an Ubuntu GCE VM, installs the tools, builds the pinned NVKE source, starts the management environment, and creates a workload Kubernetes cluster through NVKE using mock-NICo. Two workload nodes run as Docker containers. It then installs vCluster on that workload cluster and creates one cluster, so the lab ends with a running vCluster control plane on NVKE infrastructure. The purpose is the Blog 2 evaluation and integration walkthrough.

**This is a GCE demo, not a GKE cluster or a production GPU deployment.** The upstream mock-NICo workflow needs a Linux host with Docker, virtual TPM support and host networking. Running that workflow as ordinary GKE workloads would be a different deployment design. GKE Autopilot also restricts the privileged and host-access features involved. No GPU or NVIDIA account is required for this mock environment.

## Start on your Mac or Cloud Shell

Prerequisites: Bash, Python 3, tar, Google Cloud CLI, and an authenticated Google Cloud account. Your account must be able to create/reuse the VM and SSH with sudo. The project needs billing, the Compute Engine API, VM/disk quota, and a VPC with SSH connectivity and outbound internet. The kit does not change project IAM or open firewall ports.

```bash
unzip nvke-gcp-kit.zip
cd nvke-gcp-kit
gcloud auth login

# Review config.env. Defaults already match your existing VM:
# hrittik-project / us-central1-a / nvke-blog-demo
./nvke-gcp.sh plan
./nvke-gcp.sh up
```

New VMs use 12 vCPUs, 24 GiB RAM, a 400 GB balanced persistent boot disk, and Ubuntu 24.04 amd64. They get an external IP for outbound downloads and SSH, but no attached service account. Existing VMs retain their current machine type, disk and service account. To use a separate VM, change `NVKE_VM` in `config.env` before running `up`.

The installer uses `/opt/nvke-lab` and a dedicated `nvkelab` user. It preserves any manual checkout in your home directory. It refuses to take over an existing `controller-capi` cluster or occupied lab ports. If you have already started the manual walkthrough, use a fresh VM name or clean up that walkthrough first. Docker group membership grants the lab user host-level privileges, as required for this local development setup.

`up` waits for readiness. If your laptop disconnects, setup continues as a systemd job. Reattach to the progress with:

```bash
./nvke-gcp.sh logs         # Ctrl+C only exits the log viewer
./nvke-gcp.sh status
./nvke-gcp.sh wait
./nvke-gcp.sh tilt-logs
```

The first run downloads and compiles substantial software. Readiness polling allows up to 90 minutes per provider/provisioning phase; compilation is not included in that timeout. Modify `NVKE_READY_TIMEOUT` if needed. The kit declares success only after NVKE reports the cluster as Provisioned, at least two nodes have registered and passed Kubernetes Ready checks, and, unless you skipped it, the vCluster API answers a request.

## Open the endpoints

Once setup succeeds, run this in a separate local terminal and keep it open:

```bash
./nvke-gcp.sh tunnel
```

| Endpoint | Local address | Purpose |
| --- | --- | --- |
| Tilt | http://localhost:10350 | Setup resources, builds and service status |
| NVKE API docs | http://localhost:8080/api/docs | Explore the management API; authentication stays enabled |
| Workload Kubernetes API | https://127.0.0.1:8443 | Access the cluster using the exported kubeconfig |

Change the three `NVKE_LOCAL_*_PORT` settings if these laptop ports are busy. The tunnel command first checks that setup and Tilt are ready, avoiding forwarding to an unstarted service. It binds the local listeners to `127.0.0.1` and does not expose the application ports to the internet. If any local bind fails, SSH exits with an error.

The cluster API lives at a private mock-network address inside the VM. `tunnel` reads that address from the workload kubeconfig, exports `.state/workload.local.json`, and sets `tls-server-name` to preserve server certificate checks through the tunnel. It keeps the original CA and client credentials, and never changes your default kubeconfig or enables insecure TLS.

```bash
# From another local terminal while tunnel is running:
kubectl --kubeconfig=.state/workload.local.json get nodes -o wide

# Or run kubectl on the VM without a local tunnel or local kubectl installation:
./nvke-gcp.sh kubectl get nodes -o wide
./nvke-gcp.sh kubectl get pods -A
```

The exported file contains cluster-admin credentials. Keep `.state/` private. The pinned NVKE CLI reads the admin kubeconfig secret. If a future version returns credentials that require a VM-side executable, the exporter refuses to create a misleading local config and directs you to the remote `kubectl` command.

For IAP, set `NVKE_USE_IAP=1`. Your environment must already have the appropriate IAP permissions and a firewall rule allowing TCP 22 from `35.235.240.0/20`. This option changes the SSH transport; the current VM creation command still assigns an external IP. A VM without an external IP additionally requires Cloud NAT or another outbound route for the downloads.

## Run more sites

Each NVKE site is its own VM with its own management cluster and workload cluster. The `sites/` directory holds one config per extra site. Each file loads `config.env`, then overrides the zone, VM name, cluster name, local state directory and laptop ports, so the sites can be built, tunnelled and destroyed independently and at the same time.

| Config | Zone | VM | NVKE cluster | Laptop ports (API, Tilt, Kubernetes) |
| --- | --- | --- | --- | --- |
| `config.env` | us-central1-a | nvke-blog-demo | nvke-demo | 8080, 10350, 8443 |
| `sites/eu-west4.env` | europe-west4-a | nvke-blog-eu-west4 | nvke-eu | 18080, 11350, 18443 |
| `sites/asia-southeast1.env` | asia-southeast1-b | nvke-blog-asia-southeast1 | nvke-asia | 28080, 21350, 28443 |

Prefix any command with the site config:

```bash
NVKE_CONFIG=sites/eu-west4.env ./nvke-gcp.sh up
NVKE_CONFIG=sites/eu-west4.env ./nvke-gcp.sh status
NVKE_CONFIG=sites/asia-southeast1.env ./nvke-gcp.sh tunnel
NVKE_CONFIG=sites/asia-southeast1.env ./nvke-gcp.sh destroy --yes
```

A site's local files live under `.state/sites/<site>/`. Each site costs the same as the first VM.

## What the scripts do

1. Locate the VM in the configured project and zone. Authentication failures stop execution rather than being treated as a missing VM.
2. Create a VM if needed, wait for SSH/cloud-init, and upload a small setup bundle.
3. Run installation as `nvke-lab-setup.service`, independently of your SSH session.
4. Install Docker with BuildKit, basic build dependencies, Go bootstrap tooling, kind, kubectl, Helm 4, Tilt, and the vCluster CLI. Verify downloaded binary checksums.
5. Fetch NVKE at commit `5293831ce0eb1ec3f8864b2fd8b53a6621a83cc8`. Read the Go, kind and Helm versions from that checkout. Use the exact Go toolchain rather than an arbitrary newer version.
6. Prepare `tpm_vtpm_proxy`, raise the inotify limit if needed, build `nvkectl`, and copy the pinned public CAPNICo module into a writable source directory.
7. Generate local credentials once, preserving them on reruns. Keep upstream API authentication enabled.
8. Run the upstream management-cluster/image preparation target, then keep `tilt up` running as `nvke-lab-tilt.service`.
9. Wait for the NICo provider and API, create the configured workload cluster if absent, and wait for both nodes. Save its kubeconfig.
10. Install `local-path-provisioner` (pinned by `NVKE_LOCAL_PATH_VERSION`, manifest verified against `NVKE_LOCAL_PATH_SHA256`) on the workload cluster and mark `local-path` as the default storage class. The mock lab ships no provisioner, and without one every PersistentVolumeClaim, including a vCluster control plane's data volume, stays Pending.
11. Record tool versions. Setup installs the vCluster CLI but creates no vCluster; create clusters later from vCluster Platform once the workload cluster is connected.

## Files

| File | Runs where | Role |
| --- | --- | --- |
| `config.env` | Laptop | Project, VM, source commit, tool versions and local ports |
| `nvke-gcp.sh` | Laptop | Create/reuse, start, status, logs, tunnel, kubectl and destroy |
| `kubeconfig.py` | Laptop | Prepare a TLS-valid kubeconfig for the SSH tunnel |
| `remote/submit.sh` | VM, root | Submit the persistent setup job |
| `remote/install.sh` | VM, root | Install tools, check kernel and prepare the lab user/services |
| `remote/bootstrap.sh` | VM, lab user | Build and bring up NVKE, create and verify the workload cluster, then add the default storage class |
| `remote/manage.sh` | VM | Status and wait operations |
| `tests/test_kit.py` | Laptop | Offline regression checks |

## Use the vCluster CLI

Setup installs the pinned vCluster CLI (`NVKE_VCLUSTER_VERSION` in `config.env`) on the VM but creates no vCluster. The `vcluster` command runs that CLI on the VM against the workload cluster, so you need no local tunnel or local CLI:

```bash
./nvke-gcp.sh vcluster --version
./nvke-gcp.sh vcluster list
```

Connect the workload cluster to vCluster Platform as described below, then create clusters from the Platform.

## Continue into vCluster Platform

The VM has the pinned vCluster CLI (`NVKE_VCLUSTER_VERSION` in `config.env`) and reaches the workload API directly, so the simplest path runs on the VM. The VM has no browser, so log in with an access key created in the Platform UI under Profile > Access Keys. Leave the key's scope empty. A key limited to the `loft-cli` role can list and connect to clusters but cannot create the management `clusters` resource, and `add cluster` fails with `denied by loft access key scope`.

```bash
./nvke-gcp.sh ssh

# On the VM:
sudo install -m 0600 -o "$USER" -g "$USER" /opt/nvke-lab/state/workload.kubeconfig ~/.kube/config
kubectl get nodes
vcluster platform login https://YOUR_PLATFORM_HOST --access-key YOUR_ACCESS_KEY
vcluster platform add cluster nvke-demo --display-name "NVKE nvke-demo" --description "NVKE Cluster"
vcluster platform list clusters
```

`add cluster` fetches the agent values from the Platform itself once you are logged in. The `--helm-values` URL that the Platform UI's connect snippet includes is optional. Keep `login` and `add cluster` as separate commands or join them with `&&`, so a failed login stops the chain.

Connecting the workload cluster does not hand the `demo` cluster over to the Platform automatically; it stays a Helm release that the CLI manages. Clusters you create in the Platform on this control plane cluster use the `local-path` default storage class that bootstrap installed, so the default backing store (embedded etcd with a persistent data volume) works unchanged. If a cluster sits in Pending, check `kubectl get storageclass` on the VM first; if the list is empty, rerun `./nvke-gcp.sh up`, which reinstalls the provisioner.

Alternatively, with `tunnel` running and the vCluster CLI installed on your laptop:

```bash
vcluster platform login https://YOUR_PLATFORM_HOST
KUBECONFIG="$PWD/.state/workload.local.json" \
  vcluster platform add cluster nvke-demo
```

Either way this is an optional follow-on command, not part of automatic provisioning. Connect the workload cluster, not the kind management cluster. The Platform agent must be able to reach your Platform URL from inside the workload cluster. This kit installs vCluster itself but not vCluster Platform, a GPU runtime, or a Certified Stack, and has not validated the Platform integration against this NVKE revision. Avoid copying the localhost kubeconfig into an external server: it works only on the machine running the tunnel.

## Evidence and troubleshooting

The source commit and installed versions are stored in `/opt/nvke-lab/state/versions.txt`. Command output is in the setup journal and service activity is in the Tilt journal. A failed command leaves the VM and logs available for inspection. After resolving the error, rerun `up` with the same commit and cluster name; it keeps the generated passwords, source checkout and cluster identity, and skips the Cluster API bring-up once the CAPD controller is already installed (rerunning it would make `clusterctl init` fail on a duplicate provider). If `up` exits with an SSH error during the long readiness wait, setup is still running; reattach with `./nvke-gcp.sh wait`. Changing the source commit or cluster name on an initialized VM is rejected to avoid silently mixing environments.

```bash
./nvke-gcp.sh ssh

# Inside the VM. nvkectl is on the PATH for any sudo-capable account; the
# wrapper runs it as the lab user so its site config resolves.
nvkectl get providers
nvkectl get clusters
sudo journalctl -u nvke-lab-setup.service --no-pager
sudo journalctl -u nvke-lab-tilt.service --no-pager
sudo cat /opt/nvke-lab/state/versions.txt

# Or work as the lab user, whose login shell already has the tools and the
# management kubeconfig configured:
sudo -iu nvkelab
kubectl --context=kind-controller-capi get pods -A
```

- **Reauthentication / RAPT error:** run `gcloud auth login` locally, then retry. No credentials are included in the kit.
- **SSH timeout:** verify the VM is running and reachable on TCP 22, or configure IAP. The kit does not open SSH to the internet automatically.
- **Kernel module missing:** inspect `uname -r` and `grep CONFIG_TCG_VTPM_PROXY /boot/config-$(uname -r)`. The upstream helper attempts to install the extra-modules package for the running kernel. If that kernel was built without the driver, use a supported Ubuntu kernel and boot into it before retrying. The kit reports the blocker; it does not silently change bootloaders or reboot the VM. GCE Shielded VM vTPM is not a substitute for this Linux proxy module.
- **Source/tool download fails:** the pinned public dependency must be accessible from the VM. Check GitHub, Go proxy and registry egress. The script fails rather than substituting an unverified tool version.
- **Port occupied or manual kind cluster detected:** use another VM name, or stop/clean up the manual environment. Do not run two copies of this lab on one VM.
- **ProvisioningFailed / timeout:** check Tilt logs and the controller/CAPNICo pods before rerunning. A failed existing cluster is not automatically deleted and recreated.
- **After a VM reboot:** run `up` again to reconcile the development setup. The kit keeps services alive across SSH disconnections but does not promise unattended recovery across host reboots or kernel changes.
- **No GPU workloads:** mock-NICo simulates infrastructure with containers. Use a separate GPU-backed setup to validate GPU scheduling or inference performance.
- **Pod or PersistentVolumeClaim Pending with `no storage class is set`:** the default storage class is missing. `./nvke-gcp.sh kubectl get storageclass` should list `local-path (default)`. Rerun `./nvke-gcp.sh up` to reinstall it, then delete the Pending pod and claim so the StatefulSet recreates them. Persistent volumes live on the node's disk and are not replicated.

## Remove the lab

This deletes the configured VM and boot disk, including any pre-existing work on that VM. Review the target first.

```bash
./nvke-gcp.sh plan
./nvke-gcp.sh destroy --yes
```

Other disks are not requested for deletion. Deleting the VM does not delete the GCP project or shared networking.

## Validation and limits

Prepared on November 3, 2026. Shell syntax validation and 15 offline tests passed, covering VM reuse/create arguments, cloud authentication failure handling, failed setup reporting, explicit deletion, immutable commit input, remote argument quoting, and kubeconfig TLS/credential handling.

Revised on November 4, 2026 after a source review against the pinned commit: the rerun guard around `capd-up`, tolerance for cloud-init's "degraded" exit code on GCE images, SSH keepalives on the readiness wait, and a non-fatal workload node listing in `status`. Only shell syntax checks were rerun after these edits; rerun the offline tests before relying on them.

Revised again on November 4, 2026 after the first real GCE run failed in `make capd-up`: the setup service and the install/bootstrap scripts had used a 077 umask, which gave the upstream Helm Debian package a 0700 control directory that `dpkg-deb` rejects. The build now runs with the default umask, the source tree is made world-readable, and the generated `.env.tilt` and both kubeconfigs are set to 0600 explicitly. The payload tarball no longer carries macOS extended attributes. Shell syntax checks and 16 offline tests pass after these edits.

Revised on November 4, 2026 after the first vCluster Platform import on the live VM: `add cluster` failed with an access key scoped to `loft-cli`, and the first cluster created from the Platform stayed Pending because the workload cluster had no storage class. Bootstrap now installs a pinned, checksum-verified `local-path-provisioner` and marks it default; the README documents the unscoped access key. The provisioner was applied to the live VM by hand with the same version; the bootstrap path was syntax-checked and covered by the 20 offline tests, which pass, but not rerun end to end.

Revised on November 5, 2026 to install vCluster as part of setup. Bootstrap now creates a cluster with the Helm driver and the chart version pinned by `NVKE_VCLUSTER_VERSION`, waits for its control plane pod, and checks its API through `vcluster connect`. The launcher gained a `vcluster` passthrough command, and `status` lists the control plane pod. The CLI flags were checked against vCluster CLI 0.37.1 help output. The chart is fetched by the CLI from the vCluster chart repository and is pinned by version, not by checksum. Shell syntax checks and 24 offline tests pass after these edits. The new phase has not run on a VM yet.

Revised on November 5, 2026 to stop creating a vCluster during setup. Setup still installs and records the pinned vCluster CLI, and the `vcluster` passthrough command remains. `NVKE_VCLUSTER_NAME` and `NVKE_VCLUSTER_NAMESPACE` are gone; clusters are created from vCluster Platform after the workload cluster is connected. The same change added `sites/` configs and `NVKE_STATE_DIR` for running several sites side by side.

**A real GCP end-to-end deployment was not executed while authoring this kit.** Kernel support, cloud capacity/permissions, external artifact downloads, complete upstream startup, and vCluster Platform import still need validation on your VM. The kit is a reproducible starting point with checks and logs, not a claim of a tested production integration.

```bash
python3 tests/test_kit.py
```

Sources reviewed:

- [Pinned NVKE quickstart](https://github.com/dsx-ai-factory/nvke/blob/5293831ce0eb1ec3f8864b2fd8b53a6621a83cc8/docs/get-started/quickstart-local.md)
- [Pinned development Makefile](https://github.com/dsx-ai-factory/nvke/blob/5293831ce0eb1ec3f8864b2fd8b53a6621a83cc8/controller/Makefile.dev)
- [Pinned tool versions](https://github.com/dsx-ai-factory/nvke/blob/5293831ce0eb1ec3f8864b2fd8b53a6621a83cc8/make/tool-versions.mk)
- [Virtual TPM preparation](https://github.com/dsx-ai-factory/nvke/blob/5293831ce0eb1ec3f8864b2fd8b53a6621a83cc8/controller/hack/ensure-vtpm-proxy.sh)
- [NVKE kubeconfig implementation](https://github.com/dsx-ai-factory/nvke/blob/5293831ce0eb1ec3f8864b2fd8b53a6621a83cc8/cli/internal/mgmtcluster/command/get_kubeconfig.go)
- [Docker on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Tilt command options](https://docs.tilt.dev/cli/tilt_up.html)
- [Google Cloud custom machine types](https://docs.cloud.google.com/compute/docs/instances/creating-instance-with-custom-machine-type)
- [GKE Autopilot constraints](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-security)
- [Connect a cluster to vCluster Platform](https://www.vcluster.com/docs/platform/administer/clusters/connect-cluster)
- [local-path-provisioner v0.0.30](https://github.com/rancher/local-path-provisioner/tree/v0.0.30)
- [Deploy vCluster](https://www.vcluster.com/docs/vcluster/deploy/control-plane/kubernetes-pod/basics)
