# Kubernetes Control Plane

## Overview

The Kubernetes control plane manages cluster state and exposes the Kubernetes API.

This lab runs the control-plane components on the `server` VM:

```text
server
├── kube-apiserver
├── kube-controller-manager
└── kube-scheduler
```

The control-plane phase brings together the infrastructure and security components configured during earlier phases:

```text
                         kube-apiserver
                        /      |       \
                       /       |        \
                      v        v         v
                   etcd       PKI    encryption
                    |          |          |
                    ✓          ✓          ✓
                     \
                      \
                       +-------------------+
                                           |
                              Kubernetes API :6443
                                  /        \
                                 /          \
                                v            v
                   controller-manager    scheduler
                          |                   |
                          v                   v
                     kubeconfig          kubeconfig
                          ✓                   ✓
```

The control plane is installed and managed with Ansible while preserving the configuration used by Kubernetes The Hard Way.

---

## Control Plane Components

### kube-apiserver

`kube-apiserver` is the central interface to the Kubernetes cluster.

All Kubernetes clients and components communicate with cluster state through the API server.

```text
kubectl
   |
   v
kube-apiserver
   |
   v
etcd
```

Its responsibilities include:

- Exposing the Kubernetes API
- Authenticating clients
- Authorizing API requests
- Running admission controllers
- Reading and writing cluster state in etcd
- Encrypting configured resources before storing them
- Providing the API used by controllers, schedulers, and kubelets

In this lab the API server listens on:

```text
TCP 6443
```

and is reachable through:

```text
https://server.kubernetes.local:6443
```

---

### kube-controller-manager

`kube-controller-manager` runs Kubernetes controllers that continuously reconcile actual cluster state with desired state.

Conceptually:

```text
Desired State
     |
     v
controller-manager
     |
     | observe / reconcile
     v
Actual State
```

The controller manager also performs certificate-signing functions in this lab.

It therefore requires access to:

```text
/var/lib/kubernetes/ca.crt
/var/lib/kubernetes/ca.key
```

This is why the CA private key is distributed to the control-plane server but never to worker nodes.

---

### kube-scheduler

`kube-scheduler` determines which worker node should run a newly created Pod.

Conceptually:

```text
Unscheduled Pod
      |
      v
kube-scheduler
      |
      | evaluate nodes
      v
Selected Worker
```

At the current stage no worker nodes have been bootstrapped yet, but the scheduler is operational and ready to schedule workloads once nodes register with the API server.

---

## Prerequisites

Before the control plane is installed, the server requires several previously configured dependencies.

### etcd

etcd must be running and healthy:

```text
http://127.0.0.1:2379
```

Verify:

```bash
ansible server -b -m command -a \
  'etcdctl endpoint health'
```

The API server uses:

```text
--etcd-servers=http://127.0.0.1:2379
```

Because etcd and the API server run on the same machine, etcd remains bound exclusively to localhost.

---

## PKI Requirements

The server requires:

```text
/var/lib/kubernetes/
├── ca.crt
├── ca.key
├── kube-api-server.crt
├── kube-api-server.key
├── service-accounts.crt
└── service-accounts.key
```

The API server uses the CA certificate to authenticate certificate-based clients:

```text
--client-ca-file=/var/lib/kubernetes/ca.crt
```

Its HTTPS identity is provided by:

```text
--tls-cert-file=/var/lib/kubernetes/kube-api-server.crt
--tls-private-key-file=/var/lib/kubernetes/kube-api-server.key
```

---

## CA Private Key

The controller manager requires the CA private key:

```text
--cluster-signing-cert-file=/var/lib/kubernetes/ca.crt
--cluster-signing-key-file=/var/lib/kubernetes/ca.key
```

This allows Kubernetes to sign certificate requests.

The security boundary is:

```text
                         ca.key
                           |
               +-----------+-----------+
               |                       |
               v                       v
            jumpbox                  server
                                  control plane
                                       |
                                       v
                             controller-manager

node-0    X
node-1    X
```

The Ansible certificate distribution workflow enforces that `ca.key` may only be distributed to hosts in the `control_plane` inventory group.

The installed key is:

```text
owner: root
group: root
mode: 0600
```

---

## Kubeconfig Requirements

The control plane requires:

```text
/var/lib/kubernetes/
├── kube-controller-manager.kubeconfig
└── kube-scheduler.kubeconfig
```

Both use:

```text
https://127.0.0.1:6443
```

because the controller manager and scheduler run on the same machine as the API server.

Their identities are:

```text
system:kube-controller-manager
system:kube-scheduler
```

---

## Encryption-at-Rest Configuration

The API server requires:

```text
/var/lib/kubernetes/encryption-config.yaml
```

and starts with:

```text
--encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml
```

This allows the API server to encrypt configured Kubernetes resources before persisting them to etcd.

The encryption boundary is:

```text
Kubernetes resource
        |
        v
   kube-apiserver
        |
        | encryption-config.yaml
        v
     AES-CBC
        |
        v
       etcd
```

etcd itself does not possess the encryption key.

---

# API Server Configuration

The API server is installed as:

```text
/usr/local/bin/kube-apiserver
```

and managed by:

```text
/etc/systemd/system/kube-apiserver.service
```

The Ansible source template is:

```text
roles/control_plane/templates/kube-apiserver.service.j2
```

---

## API Server Network Configuration

The API server listens on all server interfaces:

```text
--bind-address=0.0.0.0
```

This allows components on the Kubernetes lab network to reach:

```text
192.168.56.20:6443
```

The server contains two network interfaces:

```text
eth0 -> 10.0.2.15       VirtualBox NAT
eth1 -> 192.168.56.20   Kubernetes lab network
```

Without an explicit advertise address, Kubernetes selected the NAT interface:

```text
10.0.2.15
```

This was visible in the API server logs when the Kubernetes service endpoint was initially created.

The API server configuration therefore explicitly sets:

```text
--advertise-address={{ node_ip }}
```

`node_ip` is a project-defined Ansible inventory variable, not an Ansible built-in.

For `server`, it is defined in:

```text
inventory/host_vars/server.yml
```

as:

```yaml
node_ip: "192.168.56.20"
```

Ansible renders:

```text
--advertise-address=192.168.56.20
```

into the final systemd unit.

This ensures Kubernetes advertises the cluster-facing address rather than the VirtualBox NAT address.

---

## API Server Endpoint

The API server certificate includes:

```text
DNS:server.kubernetes.local
```

and the lab resolves:

```text
server.kubernetes.local
```

to:

```text
192.168.56.20
```

Remote Kubernetes clients therefore use:

```text
https://server.kubernetes.local:6443
```

The resulting relationship is:

```text
server.kubernetes.local
        |
        | DNS
        v
192.168.56.20
        |
        | TCP 6443
        v
kube-apiserver
        |
        | TLS certificate
        v
DNS:server.kubernetes.local
```

---

## API Server Security Configuration

The API server uses:

```text
--authorization-mode=Node,RBAC
```

which enables:

- Node authorization
- Role-Based Access Control

The configured admission plugins are:

```text
NamespaceLifecycle
NodeRestriction
LimitRanger
ServiceAccount
DefaultStorageClass
ResourceQuota
```

The `NodeRestriction` admission plugin is particularly important for restricting what authenticated kubelets may modify.

---

## Service Accounts

Service account signing uses:

```text
--service-account-key-file=/var/lib/kubernetes/service-accounts.crt
--service-account-signing-key-file=/var/lib/kubernetes/service-accounts.key
```

The issuer is:

```text
https://server.kubernetes.local:6443
```

This matches the externally addressable Kubernetes API endpoint.

---

## Cluster Networking Configuration

The controller manager defines the cluster-wide Pod CIDR:

```text
10.200.0.0/16
```

through:

```text
--cluster-cidr=10.200.0.0/16
```

Individual workers use subnets from this range:

```text
10.200.0.0/16
       |
       +-- node-0 -> 10.200.0.0/24
       |
       +-- node-1 -> 10.200.1.0/24
```

The Kubernetes Service network is:

```text
10.32.0.0/24
```

configured through:

```text
--service-cluster-ip-range=10.32.0.0/24
```

The API server also permits NodePort Services in:

```text
30000-32767
```

---

# Scheduler Configuration

The scheduler configuration is installed at:

```text
/etc/kubernetes/config/kube-scheduler.yaml
```

The source is maintained as:

```text
roles/control_plane/templates/kube-scheduler.yaml.j2
```

The configuration is:

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration

clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"

leaderElection:
  leaderElect: true
```

The scheduler therefore authenticates to the API server using:

```text
/var/lib/kubernetes/kube-scheduler.kubeconfig
```

Leader election is enabled even though the lab currently contains only one scheduler instance.

This keeps the configuration compatible with the behavior expected from a Kubernetes control plane that could later contain multiple scheduler instances.

---

# Ansible Implementation

Control-plane installation is implemented using:

```text
roles/control_plane/
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
    ├── kube-apiserver.service.j2
    ├── kube-controller-manager.service.j2
    ├── kube-scheduler.service.j2
    └── kube-scheduler.yaml.j2
```

The corresponding playbook is:

```text
playbooks/install-control-plane.yml
```

---

## Installation Workflow

The workflow follows the same artifact-staging model used by other binary installation phases:

```text
jumpbox
   |
   | fetch binaries
   v
temporary Ansible controller staging
   |
   | copy
   v
server
   |
   +-- install binaries
   +-- render configuration
   +-- install systemd units
   +-- enable services
   +-- start services
   |
   v
temporary staging removed
```

The jumpbox provides:

```text
downloads/controller/
├── kube-apiserver
├── kube-controller-manager
└── kube-scheduler
```

The binaries are installed as:

```text
/usr/local/bin/
├── kube-apiserver
├── kube-controller-manager
└── kube-scheduler
```

with:

```text
owner: root
group: root
mode: 0755
```

---

## systemd Management

The services are managed through:

```text
/etc/systemd/system/
├── kube-apiserver.service
├── kube-controller-manager.service
└── kube-scheduler.service
```

All three are:

```text
enabled: true
state: started
```

and restart automatically on failure.

---

## Handlers

The control-plane role uses separate handlers:

```text
Restart kube-apiserver
Restart kube-controller-manager
Restart kube-scheduler
```

This prevents unrelated components from restarting when only one component's configuration changes.

For example:

```text
scheduler config changed
        |
        v
restart kube-scheduler

kube-apiserver              unchanged
kube-controller-manager     unchanged
```

Avoiding unnecessary restarts becomes increasingly important as the cluster begins running workloads.

---

## Idempotency

Persistent control-plane configuration is idempotent.

Running:

```bash
ansible-playbook playbooks/install-control-plane.yml
```

again should leave installed binaries, rendered configuration, and running services unchanged when their source configuration has not changed.

Temporary binary staging remains ephemeral:

```text
stage binaries       changed
install binaries     unchanged
render config        unchanged
services             unchanged
cleanup staging      changed
```

---

# Verification

## Service State

Verify all three services:

```bash
ansible server -b -m shell -a '
systemctl is-active kube-apiserver
systemctl is-active kube-controller-manager
systemctl is-active kube-scheduler
'
```

Expected:

```text
active
active
active
```

---

## API Server Listener

Verify port `6443`:

```bash
ansible server -b -m shell -a \
  'ss -lntp | grep 6443'
```

The API server should listen on:

```text
*:6443
```

---

## API Server Process

Verify the advertised address:

```bash
ansible server -b -m shell -a \
  'pgrep -a kube-apiserver | grep -- "--advertise-address=192.168.56.20"'
```

This confirms that the API server is advertising the Kubernetes lab network rather than the VirtualBox NAT interface.

---

## Kubernetes API Readiness

From the jumpbox:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get --raw='/readyz?verbose'
```

The readiness output should report successful checks including:

```text
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
...
readyz check passed
```

This verifies substantially more than the systemd service state.

It confirms that the API server has successfully initialized its internal controllers and can communicate with etcd.

---

## Kubernetes Service Endpoint

Verify the API endpoint Kubernetes advertises internally:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get endpoints kubernetes -o wide
```

The endpoint should reference:

```text
192.168.56.20:6443
```

and not:

```text
10.0.2.15:6443
```

This confirms that:

```text
--advertise-address={{ node_ip }}
```

is functioning correctly.

---

## Node State

Before worker bootstrap:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get nodes
```

No Kubernetes Nodes are expected yet.

The worker VMs exist, but they do not become Kubernetes Nodes until their kubelets are installed, configured, started, and registered with the API server.

```text
VirtualBox VM
      !=
Kubernetes Node
```

---

# Encryption-at-Rest Runtime Verification

The running API server and etcd allow the encryption-at-rest configuration to be tested end-to-end.

This test proves that the encryption configuration is not merely installed, but is actually being used when Kubernetes persists sensitive data.

---

## Create a Test Secret

From the jumpbox:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  create secret generic kubernetes-the-hard-way \
  --from-literal=mykey=mydata
```

Verify that Kubernetes can retrieve the resource:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get secret kubernetes-the-hard-way
```

---

## Verify Plaintext Is Not Stored

Read the raw etcd record directly, bypassing the Kubernetes API:

```bash
ansible server -b -m shell -a \
  'etcdctl get /registry/secrets/default/kubernetes-the-hard-way | grep -q mydata && echo "PLAINTEXT FOUND" || echo "plaintext absent"'
```

Expected:

```text
plaintext absent
```

This proves the literal Secret value is not stored directly in etcd.

---

## Verify the Encryption Provider

Verify that the stored value contains the Kubernetes AES-CBC encryption marker:

```bash
ansible server -b -m shell -a \
  'etcdctl get /registry/secrets/default/kubernetes-the-hard-way | grep -a -o "k8s:enc:aescbc:v1:key1"'
```

Expected:

```text
k8s:enc:aescbc:v1:key1
```

Together these checks prove:

```text
Secret submitted
       |
       v
kube-apiserver
       |
       | EncryptionConfiguration
       v
    AES-CBC
       |
       v
      etcd
       |
       +-- plaintext absent              ✓
       |
       +-- k8s:enc:aescbc:v1:key1        ✓
```

This completes the runtime validation deferred during the encryption-at-rest phase.

---

## Remove the Test Secret

After verification:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  delete secret kubernetes-the-hard-way
```

---

## Troubleshooting

### API Server Reports Connection Refused

Verify the service:

```bash
ansible server -b -m command -a \
  'systemctl status kube-apiserver --no-pager'
```

Verify the listener:

```bash
ansible server -b -m shell -a \
  'ss -lntp | grep 6443'
```

Test from the jumpbox:

```bash
curl -k https://server.kubernetes.local:6443/version
```

A newly started API server may briefly refuse connections while initializing. Use `/readyz` to determine when the API server is actually ready.

---

### API Server Advertises `10.0.2.15`

The VirtualBox NAT interface may be automatically selected if no explicit advertise address is configured.

Verify:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get endpoints kubernetes -o wide
```

The control-plane role explicitly sets:

```text
--advertise-address={{ node_ip }}
```

where:

```yaml
node_ip: "192.168.56.20"
```

is defined for `server`.

Reapply:

```bash
ansible-playbook playbooks/install-control-plane.yml
```

---

### `~` Does Not Resolve in `--kubeconfig=...`

Avoid:

```bash
kubectl --kubeconfig=~/kubernetes-kubeconfigs/admin.kubeconfig ...
```

With this argument form, the shell may pass the tilde literally.

Use:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  ...
```

or:

```bash
kubectl \
  --kubeconfig ~/kubernetes-kubeconfigs/admin.kubeconfig \
  ...
```

---

## Rebuild Procedure

The control-plane installation itself is automated, but it depends on generated runtime security artifacts.

After a complete VM rebuild, restore the prerequisites first:

```text
Recreate VMs
     |
     v
Ansible bootstrap
     |
     v
Prepare Kubernetes binaries
     |
     v
Regenerate PKI
     |
     v
Distribute certificates
     |
     v
Regenerate kubeconfigs
     |
     v
Distribute kubeconfigs
     |
     v
Regenerate encryption config
     |
     v
Distribute encryption config
     |
     v
Install etcd
     |
     v
Install control plane
```

Once the prerequisites exist, the control plane itself is restored with:

```bash
ansible-playbook playbooks/install-control-plane.yml
```

Then verify:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get --raw='/readyz?verbose'
```

---

## Next Phase

The Kubernetes control plane is now operational.

The API server:

- Is reachable over the Kubernetes lab network
- Authenticates clients using the cluster PKI
- Uses Node and RBAC authorization
- Communicates successfully with etcd
- Encrypts Kubernetes Secrets before persistence
- Advertises the correct cluster-facing address

The controller manager and scheduler are also running and authenticated to the API server.

The next phase bootstraps the worker nodes:

```text
node-0
├── containerd
├── runc
├── CNI plugins
├── kubelet
└── kube-proxy

node-1
├── containerd
├── runc
├── CNI plugins
├── kubelet
└── kube-proxy
```

See [`architecture.md`](architecture.md) for the current overall project status.