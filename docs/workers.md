# Kubernetes Worker Nodes

## Overview

Kubernetes worker nodes run application workloads and provide the container runtime, kubelet, networking plugins, and Service networking required by Pods.

This lab contains two workers:

| Host | Node Address | Pod CIDR |
|---|---|---|
| `node-0` | `192.168.56.50` | `10.200.0.0/24` |
| `node-1` | `192.168.56.60` | `10.200.1.0/24` |

Each worker runs:

```text
worker
├── containerd
├── runc
├── CNI plugins
├── kubelet
└── kube-proxy
```

Worker bootstrap is automated with Ansible after the required PKI and kubeconfigs have been generated and distributed.

The resulting relationship is:

```text
                       Control Plane
                            |
                            |
                     Kubernetes API
                            |
                  server.kubernetes.local
                      192.168.56.20
                            |
                +-----------+-----------+
                |                       |
                v                       v
             node-0                  node-1
         192.168.56.50           192.168.56.60
                |                       |
        +-------+-------+       +-------+-------+
        |       |       |       |       |       |
        v       v       v       v       v       v
   containerd kubelet proxy containerd kubelet proxy
```

---

## Worker Responsibilities

### containerd

`containerd` provides the container runtime used by the kubelet.

```text
kubelet
   |
   | CRI
   v
containerd
   |
   v
runc
   |
   v
container
```

The kubelet communicates with containerd through:

```text
unix:///var/run/containerd/containerd.sock
```

---

### runc

`runc` is the low-level OCI container runtime used by containerd to create and run containers.

It is installed as:

```text
/usr/local/sbin/runc
```

The separation is:

```text
Kubernetes
    |
    v
kubelet
    |
    v
containerd
    |
    v
runc
    |
    v
Linux container
```

---

### kubelet

The kubelet is the primary Kubernetes node agent.

Its responsibilities include:

- Registering the machine as a Kubernetes Node
- Watching the API server for assigned Pods
- Starting and stopping containers through the container runtime
- Reporting node and Pod status
- Exposing the kubelet API
- Managing Pod lifecycle on the local machine

The kubelet is installed as:

```text
/usr/local/bin/kubelet
```

and managed by:

```text
/etc/systemd/system/kubelet.service
```

---

### kube-proxy

`kube-proxy` implements Kubernetes Service networking on each worker.

This lab configures kube-proxy in:

```text
iptables
```

mode.

Its configuration is stored at:

```text
/var/lib/kube-proxy/kube-proxy-config.yaml
```

---

### CNI Plugins

Container Network Interface plugins provide the networking primitives used when creating Pod network interfaces.

The CNI binaries are installed under:

```text
/opt/cni/bin
```

The CNI configuration is stored under:

```text
/etc/cni/net.d
```

The lab configures:

```text
10-bridge.conf
99-loopback.conf
```

---

## Worker Prerequisites

Before worker bootstrap begins, each worker must already have its Kubernetes credentials.

The certificate and kubeconfig distribution phases place the initial credentials under:

```text
/var/lib/kubernetes/
```

Each worker receives:

```text
/var/lib/kubernetes/
├── ca.crt
├── kubelet.crt
├── kubelet.key
├── kubelet.kubeconfig
└── kube-proxy.kubeconfig
```

The credentials are later installed into the component-specific directories expected by the kubelet and kube-proxy.

---

## Kubelet Identity

Each worker has a unique Kubernetes identity.

`node-0` authenticates as:

```text
system:node:node-0
```

`node-1` authenticates as:

```text
system:node:node-1
```

The relationship is:

```text
node-0
  |
  +-- kubelet.crt
  +-- kubelet.key
  |
  v
system:node:node-0


node-1
  |
  +-- kubelet.crt
  +-- kubelet.key
  |
  v
system:node:node-1
```

The kubelet kubeconfigs connect to:

```text
https://server.kubernetes.local:6443
```

---

## Worker Credential Layout

During worker installation, the previously distributed credentials are copied into the locations expected by each component.

### kubelet

```text
/var/lib/kubelet/
├── ca.crt
├── kubelet.crt
├── kubelet.key
├── kubeconfig
└── kubelet-config.yaml
```

The private key and kubeconfig use restrictive permissions:

```text
kubelet.key     0600
kubeconfig      0600
```

### kube-proxy

```text
/var/lib/kube-proxy/
├── kubeconfig
└── kube-proxy-config.yaml
```

The kube-proxy kubeconfig is:

```text
0600
```

---

# Pod CIDR Assignment

The controller manager is configured with the cluster-wide Pod network:

```text
10.200.0.0/16
```

Each worker receives a dedicated subnet from that range:

```text
                     10.200.0.0/16
                           |
               +-----------+-----------+
               |                       |
               v                       v
        10.200.0.0/24           10.200.1.0/24
             node-0                  node-1
```

The values are maintained as host-specific Ansible variables.

For `node-0`:

```yaml
node_ip: "192.168.56.50"
pod_cidr: "10.200.0.0/24"
```

For `node-1`:

```yaml
node_ip: "192.168.56.60"
pod_cidr: "10.200.1.0/24"
```

The worker role renders each node's CNI bridge configuration using its own:

```text
pod_cidr
```

---

# CNI Configuration

## Bridge Network

The primary CNI network uses the Linux bridge plugin.

Conceptually:

```text
Pod
 |
 | veth
 v
cni0
 |
 | worker Pod CIDR
 v
worker network
```

The configuration is rendered from:

```text
roles/worker/templates/10-bridge.conf.j2
```

Each worker receives its own subnet:

```json
{
  "cniVersion": "1.0.0",
  "name": "bridge",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "ranges": [
      [{"subnet": "<worker-pod-cidr>"}]
    ],
    "routes": [{"dst": "0.0.0.0/0"}]
  }
}
```

Ansible replaces:

```text
<worker-pod-cidr>
```

with the host-specific `pod_cidr`.

---

## Loopback Network

The loopback CNI configuration provides the loopback interface inside Pod network namespaces.

It is installed as:

```text
/etc/cni/net.d/99-loopback.conf
```

---

# containerd Configuration

The container runtime configuration is stored at:

```text
/etc/containerd/config.toml
```

The runtime uses:

```text
snapshotter = "overlayfs"
default_runtime_name = "runc"
```

The runc runtime uses systemd cgroups:

```text
SystemdCgroup = true
```

This matches the kubelet configuration:

```text
cgroupDriver: systemd
```

The relationship is therefore:

```text
kubelet
   |
   | cgroupDriver: systemd
   v
containerd
   |
   | SystemdCgroup = true
   v
runc
```

Using the same cgroup management model avoids conflicting ownership of container cgroups.

---

# kubelet Configuration

The kubelet configuration is installed at:

```text
/var/lib/kubelet/kubelet-config.yaml
```

The kubelet:

- Listens on port `10250`
- Disables anonymous authentication
- Enables webhook authentication
- Uses webhook authorization
- Uses the cluster CA for client authentication
- Uses systemd cgroups
- Communicates with containerd through CRI
- Registers itself with the Kubernetes API server
- Uses its node certificate for TLS
- Allows a maximum of 16 Pods in this lab

The container runtime endpoint is:

```text
unix:///var/run/containerd/containerd.sock
```

The kubelet API listens on:

```text
0.0.0.0:10250
```

---

# kube-proxy Configuration

The kube-proxy configuration is installed at:

```text
/var/lib/kube-proxy/kube-proxy-config.yaml
```

It authenticates using:

```text
/var/lib/kube-proxy/kubeconfig
```

and operates in:

```text
iptables
```

mode.

---

# Worker Binary Artifacts

The jumpbox stores the worker artifacts under the Kubernetes The Hard Way downloads directory.

The worker bootstrap uses:

```text
downloads/
├── worker/
│   ├── kubelet
│   └── kube-proxy
├── cni-plugins-linux-arm64-v1.6.2.tgz
├── containerd-2.1.0-beta.0-linux-arm64.tar.gz
├── crictl-v1.32.0-linux-arm64.tar.gz
└── runc.arm64
```

The Kubernetes binaries used in this phase are:

```text
kubelet      Kubernetes v1.32.3
kube-proxy   Kubernetes v1.32.3
```

The artifacts used in the current ARM64 lab are selected for:

```text
linux/arm64
```

---

# Safe containerd Installation

## Ubuntu merged-usr Layout

Ubuntu 24.04 uses a merged `/usr` filesystem layout.

Under the normal guest configuration:

```text
/bin -> usr/bin
```

This means `/bin` is a symbolic link rather than an independent directory.

The upstream containerd archive contains:

```text
bin/
├── containerd
├── containerd-shim-runc-v2
├── containerd-stress
└── ctr
```

A naive extraction directly into `/` can therefore be unsafe.

---

## Unsafe Extraction

The initial worker implementation extracted the containerd archive directly into:

```text
/
```

Conceptually:

```text
containerd archive
└── bin/
      |
      v
extract into /
      |
      v
/bin
```

On the Ubuntu 24.04 guest, this replaced the merged-usr `/bin` symlink with a real directory containing only the containerd binaries.

The resulting state was:

```text
/bin/
├── containerd
├── containerd-shim-runc-v2
├── containerd-stress
└── ctr
```

while the system shell remained at:

```text
/usr/bin/bash
```

The expected path:

```text
/bin/bash
```

therefore disappeared.

---

## SSH Failure

The `vagrant` account uses:

```text
/bin/bash
```

as its login shell.

Existing SSH sessions remained operational because the shell process had already started.

New SSH sessions failed.

The SSH server reported:

```text
User vagrant not allowed because shell /bin/bash does not exist
```

This initially appeared as a public-key authentication failure from the client:

```text
Permission denied (publickey,password)
```

The actual problem was not:

- The Vagrant SSH key
- `authorized_keys`
- Cloud-init
- Ansible SSH multiplexing
- VirtualBox NAT
- Kubernetes
- containerd itself

The failure was caused by altering the system's merged-usr `/bin` layout.

---

## Safe Extraction Strategy

The worker role therefore does not extract the containerd archive directly into `/`.

Instead:

```text
containerd archive
        |
        v
/tmp/containerd-extract
        |
        | extract
        v
/tmp/containerd-extract/bin/
        |
        | explicit installation
        v
/usr/local/bin/
```

The archive is first copied to:

```text
/tmp/containerd.tar.gz
```

and extracted under:

```text
/tmp/containerd-extract
```

The required binaries are then explicitly installed into:

```text
/usr/local/bin/
```

This preserves:

```text
/bin -> usr/bin
```

and prevents package archive layout from modifying critical operating-system filesystem structure.

The containerd systemd unit therefore starts:

```text
/usr/local/bin/containerd
```

rather than:

```text
/bin/containerd
```

---

## Why Explicit Installation Is Preferred

The safe installation method creates a clearer boundary between:

```text
archive layout
```

and:

```text
host filesystem layout
```

The archive controls only which files are supplied.

Ansible controls where those files are installed.

```text
External archive
      |
      | untrusted filesystem assumptions
      v
temporary extraction
      |
      | explicit Ansible mapping
      v
managed destination
```

This makes the role safer across Linux distributions whose filesystem layouts may differ from assumptions made by an upstream archive.

---

# Ansible Implementation

Worker installation uses:

```text
roles/worker/
├── defaults/
│   └── main.yml
├── handlers/
│   └── main.yml
├── tasks/
│   ├── main.yml
│   ├── stage.yml
│   ├── install.yml
│   └── cleanup.yml
└── templates/
    ├── 10-bridge.conf.j2
    ├── 99-loopback.conf.j2
    ├── containerd-config.toml.j2
    ├── containerd.service.j2
    ├── kubelet-config.yaml.j2
    ├── kubelet.service.j2
    ├── kube-proxy-config.yaml.j2
    └── kube-proxy.service.j2
```

The corresponding playbook is:

```text
playbooks/install-workers.yml
```

---

## Role Dispatcher

The worker role supports three operations:

```text
stage
install
cleanup
```

The playbook determines where each operation runs:

```text
install-workers.yml
        |
        +--> jumpbox
        |      |
        |      +--> stage
        |
        +--> workers
        |      |
        |      +--> install
        |
        +--> localhost
               |
               +--> cleanup
```

This maintains the same separation used by other roles:

```text
Playbook
    "Where and when?"

Role
    "How?"
```

---

## Artifact Staging

Worker artifacts are fetched from the jumpbox into temporary controller-side staging:

```text
jumpbox
   |
   | fetch
   v
/tmp/kubernetes-lab-worker/
├── kubelet
├── kube-proxy
├── runc
├── containerd.tar.gz
├── crictl.tar.gz
└── cni-plugins.tgz
```

The worker role verifies each required artifact exists before attempting installation.

---

## Installation

The installation phase creates:

```text
/opt/cni/bin
/etc/cni/net.d
/etc/containerd
/var/lib/kubelet
/var/lib/kube-proxy
```

It then installs:

```text
/usr/local/bin/kubelet
/usr/local/bin/kube-proxy
/usr/local/sbin/runc
/usr/local/bin/containerd
/usr/local/bin/containerd-shim-runc-v2
/usr/local/bin/containerd-stress
/usr/local/bin/ctr
/usr/local/bin/crictl
```

along with the CNI plugins.

Configuration and credentials are then installed before the systemd services are enabled.

---

## systemd Services

The worker role manages:

```text
containerd.service
kubelet.service
kube-proxy.service
```

The kubelet explicitly depends on containerd:

```text
After=containerd.service
Requires=containerd.service
```

This produces the startup relationship:

```text
containerd
     |
     v
  kubelet

kube-proxy
```

---

## Handlers

Separate handlers manage:

```text
Reload systemd
Restart containerd
Restart kubelet
Restart kube-proxy
```

Configuration changes therefore restart only the affected component.

---

# Idempotency

The worker role is designed so persistent worker state converges after the initial installation.

A subsequent execution leaves the major persistent configuration unchanged:

```text
Create worker directories              ok
Install kubelet                         ok
Install kube-proxy                      ok
Install runc                            ok
Install containerd binaries             ok
Install CNI configuration               ok
Install containerd configuration        ok
Install kubelet credentials             ok
Install kube-proxy credentials          ok
Install kubelet configuration           ok
Install kube-proxy configuration        ok
Install systemd units                   ok
Enable/start services                   ok
```

The temporary transport workflow intentionally continues to report changes:

```text
controller staging                     changed
artifact fetch                         changed
temporary archive copy                 changed
temporary extraction                   changed
temporary archive cleanup              changed
controller cleanup                     changed
```

This is expected.

Temporary artifact handling is intentionally ephemeral rather than retained solely to produce `changed=0` across the entire playbook. The second worker installation run confirmed that the persistent worker configuration had converged while the temporary staging workflow remained ephemeral. :contentReference[oaicite:0]{index=0}

---

# Verification

## Worker Services

Verify all worker services:

```bash
ansible workers -b -m shell -a '
echo "containerd: $(systemctl is-active containerd)"
echo "kubelet:    $(systemctl is-active kubelet)"
echo "kube-proxy: $(systemctl is-active kube-proxy)"
'
```

Each worker should report:

```text
containerd: active
kubelet:    active
kube-proxy: active
```

---

## merged-usr Integrity

Verify that worker installation did not modify the operating-system `/bin` layout:

```bash
ansible workers -b -m shell -a '
ls -ld /bin
test -x /bin/bash && echo "/bin/bash OK"
'
```

The `/bin` path should remain linked to:

```text
usr/bin
```

and:

```text
/bin/bash OK
```

should be reported.

---

## Container Runtime

Verify containerd:

```bash
ansible workers -b -m command -a \
  '/usr/local/bin/containerd --version'
```

Verify runc:

```bash
ansible workers -b -m command -a \
  '/usr/local/sbin/runc --version'
```

Verify `crictl`:

```bash
ansible workers -b -m command -a \
  '/usr/local/bin/crictl --version'
```

---

## CNI Installation

Verify CNI binaries:

```bash
ansible workers -b -m shell -a \
  'ls -l /opt/cni/bin'
```

Verify CNI configuration:

```bash
ansible workers -b -m shell -a \
  'ls -l /etc/cni/net.d'
```

Each worker should contain:

```text
10-bridge.conf
99-loopback.conf
```

---

## Node Registration

From the jumpbox:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get nodes -o wide
```

Both workers should appear:

```text
node-0
node-1
```

with status:

```text
Ready
```

This proves that the kubelets:

1. Successfully authenticated to the API server.
2. Registered their nodes.
3. Communicated successfully with the container runtime.
4. Reported sufficient node health for Kubernetes to mark them Ready.

---

## Node Conditions

Inspect worker conditions:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  describe node node-0
```

and:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  describe node node-1
```

The `Ready` condition should report:

```text
True
```

---

# Troubleshooting

## SSH Reports `Permission denied` After containerd Extraction

A client-side error such as:

```text
Permission denied (publickey,password)
```

does not necessarily indicate a bad SSH key.

Check the server-side SSH logs whenever possible:

```bash
sudo journalctl -u ssh --no-pager
```

During development of this lab, the decisive message was:

```text
User vagrant not allowed because shell /bin/bash does not exist
```

The Vagrant key and `authorized_keys` were unchanged.

The underlying problem was the `/bin` filesystem layout.

---

## Verify Login Shell

Check:

```bash
getent passwd vagrant
```

The login shell should resolve to an executable path.

Verify:

```bash
test -x /bin/bash && echo "/bin/bash OK"
```

---

## Verify `/bin`

On Ubuntu 24.04:

```bash
ls -ld /bin
```

should preserve the merged-usr relationship.

Do not extract archives containing a top-level `bin/` directory directly into `/` without first understanding how the archive interacts with the target distribution's filesystem layout.

---

## Worker Is NotReady

Inspect the node:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  describe node node-0
```

Then inspect kubelet:

```bash
ansible node-0 -b -m shell -a \
  'journalctl -u kubelet -n 100 --no-pager'
```

Check containerd:

```bash
ansible node-0 -b -m shell -a \
  'systemctl status containerd --no-pager'
```

and kube-proxy:

```bash
ansible node-0 -b -m shell -a \
  'journalctl -u kube-proxy -n 100 --no-pager'
```

---

# Rebuild Procedure

Worker machines are disposable infrastructure.

After recreating a worker VM, restore its state through the normal dependency sequence:

```text
Vagrant worker VM
       |
       v
Ansible OS bootstrap
       |
       v
Certificate distribution
       |
       v
Kubeconfig distribution
       |
       v
Worker bootstrap
       |
       v
Node registration
       |
       v
Ready
```

From the Ansible controller:

```bash
ansible-playbook playbooks/bootstrap.yml
ansible-playbook playbooks/distribute-certificates.yml
ansible-playbook playbooks/distribute-kubeconfigs.yml
ansible-playbook playbooks/install-workers.yml
```

Then verify from the jumpbox:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get nodes -o wide
```

---

## Next Phase

Both Kubernetes workers are now registered with the control plane and report `Ready`.

The cluster currently contains:

```text
server
├── etcd
├── kube-apiserver
├── kube-controller-manager
└── kube-scheduler

node-0
├── containerd
├── kubelet
├── kube-proxy
└── CNI plugins

node-1
├── containerd
├── kubelet
├── kube-proxy
└── CNI plugins
```

The next phase establishes the remaining cluster-wide Pod networking required for workloads on different workers to communicate.

See [`architecture.md`](architecture.md) for the current overall project status.