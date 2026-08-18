# Bootstrapping etcd

## Overview

Kubernetes control-plane components are largely stateless. Persistent cluster state is stored in **etcd**, a distributed key-value datastore.

etcd stores Kubernetes resources and control-plane state, including information about:

- Nodes
- Pods
- Deployments
- Services
- ConfigMaps
- Secrets
- RBAC resources
- Cluster configuration

In this lab, etcd runs as a **single-member cluster** on the Kubernetes control-plane server.

```text
                     server
┌────────────────────────────────────────┐
│                                        │
│ Kubernetes API Server                  │
│          │                             │
│          │ http://127.0.0.1:2379       │
│          ▼                             │
│       ┌──────┐                         │
│       │ etcd │                         │
│       └──┬───┘                         │
│          │                             │
│          ▼                             │
│    /var/lib/etcd                       │
│                                        │
│ client: 127.0.0.1:2379                 │
│ peer:   127.0.0.1:2380                 │
└────────────────────────────────────────┘

node-0 ─────────X─────────> etcd
node-1 ─────────X─────────> etcd
```

The worker nodes do not communicate directly with etcd.

---

## Role in the Kubernetes Architecture

The Kubernetes API server is the interface between Kubernetes clients/components and persistent cluster state.

Components do not normally interact with etcd directly.

The expected flow is:

```text
kubectl
   |
   v
kube-apiserver
   |
   v
etcd
```

For example, creating a Deployment eventually results in the API server persisting the desired state in etcd.

Similarly, controllers retrieve cluster state through the Kubernetes API rather than querying etcd themselves.

This establishes an important architectural boundary:

```text
Kubernetes components
        |
        v
   kube-apiserver
        |
        v
       etcd
```

---

## Single-Member Cluster

This lab uses one etcd member named:

```text
controller
```

The configuration is intentionally aligned with the Kubernetes The Hard Way topology.

A production Kubernetes environment would typically use multiple etcd members to provide fault tolerance and quorum.

For example:

```text
             etcd-1
            /      \
           /        \
      etcd-2 ------ etcd-3
```

This lab instead uses:

```text
controller
    |
    v
single etcd member
```

The objective is to understand how Kubernetes depends on etcd before introducing the operational complexity of a highly available datastore.

---

## Architecture Support

The etcd binaries are obtained from the architecture-specific Kubernetes The Hard Way download set.

On the ARM64 lab, the binaries were verified before installation.

The installed version is:

```text
etcd 3.6.0-rc.3
```

with:

```text
GOOS:   linux
GOARCH: arm64
```

Both `etcd` and `etcdctl` were confirmed as ARM aarch64 executables before distribution.

The same workflow can use the corresponding AMD64 artifacts when the lab runs on an x86_64 guest.

---

## etcd and etcdctl

Two binaries are used:

```text
etcd
```

and:

```text
etcdctl
```

### etcd

`etcd` is the datastore server.

It runs as a systemd-managed service on the control-plane node.

### etcdctl

`etcdctl` is the command-line client used to inspect and administer etcd.

It provides operations such as:

```bash
etcdctl member list
```

and:

```bash
etcdctl endpoint health
```

Later in the lab, `etcdctl` will also be used to inspect raw Kubernetes data stored in etcd.

---

## Binary Distribution

The architecture-specific binaries are prepared on the jumpbox:

```text
/home/vagrant/kubernetes-the-hard-way/downloads/
├── client/
│   └── etcdctl
└── controller/
    └── etcd
```

Ansible stages the binaries through the controller running Ansible:

```text
jumpbox
   |
   | fetch
   v
temporary Ansible staging
   |
   | copy
   v
server
```

They are installed on the control-plane server as:

```text
/usr/local/bin/
├── etcd
└── etcdctl
```

with executable permissions.

The temporary staging directory is removed after installation.

---

## etcd Data Directory

Persistent etcd state is stored under:

```text
/var/lib/etcd
```

The directory is created with restrictive permissions:

```text
owner: root
group: root
mode: 0700
```

Unlike temporary Ansible staging directories, `/var/lib/etcd` contains persistent cluster state and must survive service restarts.

Conceptually:

```text
etcd process
     |
     v
/var/lib/etcd
     |
     +-- Kubernetes cluster state
```

Deleting this directory would remove the datastore for this single-member cluster.

---

## Client and Peer Interfaces

etcd exposes two different interfaces.

### Client Interface

The client interface listens on:

```text
127.0.0.1:2379
```

This endpoint is used by etcd clients.

For this Kubernetes cluster, the primary client will be:

```text
kube-apiserver
```

The future API server configuration uses:

```text
--etcd-servers=http://127.0.0.1:2379
```

The resulting path is:

```text
kube-apiserver
      |
      | localhost:2379
      v
     etcd
```

### Peer Interface

The etcd peer interface listens on:

```text
127.0.0.1:2380
```

Port `2380` is used for communication between etcd members.

In a multi-member cluster, the architecture could resemble:

```text
etcd-1:2380 <----> etcd-2:2380
     \                 /
      \               /
       ---> etcd-3:2380
```

This lab contains only one etcd member, so no remote peer communication occurs.

The peer configuration is still present because the server is initialized as an etcd cluster containing one member.

---

## Network Isolation

Both etcd interfaces are bound exclusively to localhost:

```text
127.0.0.1:2379
127.0.0.1:2380
```

etcd does not listen on:

```text
0.0.0.0
```

or:

```text
192.168.56.20
```

This prevents worker nodes and other machines on the lab network from directly accessing the datastore.

The intended boundary is:

```text
node-0 ─────X─────> etcd
node-1 ─────X─────> etcd

kube-apiserver
      |
      | localhost
      v
     etcd
```

Only processes running locally on the control-plane server can connect to the etcd endpoints.

---

## TLS Design

This Kubernetes The Hard Way version intentionally configures the single-node etcd instance over localhost without TLS.

The API server will connect using:

```text
http://127.0.0.1:2379
```

rather than an externally exposed TLS endpoint.

This design is appropriate to the topology of this learning lab because etcd traffic never leaves the control-plane machine.

A production or multi-node etcd deployment would normally require a different security architecture, including authenticated and encrypted client and peer communication.

---

## systemd Configuration

etcd is managed by systemd.

The Ansible role generates:

```text
/etc/systemd/system/etcd.service
```

from:

```text
roles/etcd/templates/etcd.service.j2
```

The resulting service is conceptually:

```ini
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify

ExecStart=/usr/local/bin/etcd \
  --name controller \
  --initial-advertise-peer-urls http://127.0.0.1:2380 \
  --listen-peer-urls http://127.0.0.1:2380 \
  --listen-client-urls http://127.0.0.1:2379 \
  --advertise-client-urls http://127.0.0.1:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster controller=http://127.0.0.1:2380 \
  --initial-cluster-state new \
  --data-dir=/var/lib/etcd

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

The template keeps the upstream Kubernetes The Hard Way architecture while allowing important values to be managed through Ansible variables.

---

## Ansible Implementation

etcd installation is implemented using a dedicated role:

```text
roles/etcd/
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
    └── etcd.service.j2
```

The corresponding playbook is:

```text
playbooks/install-etcd.yml
```

The workflow follows three phases:

```text
jumpbox
   |
   +--> stage binaries

control_plane
   |
   +--> install and configure etcd

localhost
   |
   +--> remove staging
```

---

## Configuration Variables

Important etcd configuration values are represented as Ansible variables rather than hardcoded throughout the role.

These include:

```text
etcd_name
etcd_client_url
etcd_peer_url
etcd_initial_cluster_token
etcd_data_directory
etcd_binary_directory
```

The current lab values produce:

```text
name:          controller
client URL:    http://127.0.0.1:2379
peer URL:      http://127.0.0.1:2380
data:          /var/lib/etcd
```

This keeps the role readable while preserving the configuration used by Kubernetes The Hard Way.

---

## Service Handlers

Changes to persistent etcd configuration may require the service to restart.

The role uses Ansible handlers rather than restarting etcd on every execution.

Conceptually:

```text
etcd binary changed?
        |
        +-- yes ----+
                    |
unit changed?       |
        |           |
        +-- yes ----+----> restart etcd
        |
        +-- no
             |
             v
       leave running
```

This is particularly important after etcd begins storing real Kubernetes state.

Unnecessary datastore restarts should be avoided.

---

## Idempotency

The persistent installation is idempotent.

After etcd has been installed and configured, running:

```bash
ansible-playbook playbooks/install-etcd.yml
```

again should leave the persistent server configuration unchanged when no source files or variables have changed.

As with other artifact-distribution workflows in this project, temporary staging and cleanup remain intentionally ephemeral.

The expected pattern is:

```text
Stage binaries       changed
Install binaries     unchanged
Configure service    unchanged
Start service        unchanged
Cleanup staging      changed
```

The cluster's persistent state remains unchanged.

---

## Verification

Several checks are performed after installation.

### Service State

Verify etcd is running:

```bash
ansible server -b -m command -a \
  'systemctl is-active etcd'
```

Expected:

```text
active
```

Verify the service is enabled:

```bash
ansible server -b -m command -a \
  'systemctl is-enabled etcd'
```

Expected:

```text
enabled
```

---

## Member Verification

List the etcd cluster members:

```bash
ansible server -b -m command -a \
  'etcdctl member list'
```

The cluster should contain one member named:

```text
controller
```

This verifies that the single-member cluster initialized successfully.

---

## Endpoint Health

Check datastore health:

```bash
ansible server -b -m command -a \
  'etcdctl endpoint health'
```

The localhost etcd endpoint should report healthy.

This confirms that etcd is able to accept client requests.

---

## Network Verification

Inspect the listening sockets:

```bash
ansible server -b -m shell -a \
  'ss -lntp | grep -E ":(2379|2380)"'
```

The expected listeners are:

```text
127.0.0.1:2379
127.0.0.1:2380
```

There should be no etcd listener exposed on the private lab network.

---

## Relationship to Encryption at Rest

etcd itself does not use the Kubernetes encryption-at-rest key.

Encryption occurs in the API server before data reaches etcd.

The eventual data path will be:

```text
Kubernetes Secret
       |
       v
kube-apiserver
       |
       | encryption-config.yaml
       |
       | AES-CBC encryption
       v
      etcd
```

etcd receives the already-encrypted representation.

After the API server is operational, the lab will verify this behavior by creating a Secret through Kubernetes and reading the raw stored value directly from etcd.

The raw value should not expose the Secret plaintext and should contain the Kubernetes encryption provider prefix.

---

## Current Architecture

At completion of this phase:

```text
                    CONTROL PLANE

                   kube-apiserver
                       NEXT
                    /   |   \
                   /    |    \
                  v     v     v
               etcd    PKI  encryption
                ✓       ✓       ✓
                        |
                  kubeconfigs
                        ✓
```

The datastore and security prerequisites are now available for the Kubernetes API server.

---

## Bootstrap Progress

```text
Infrastructure provisioning        COMPLETE
OS bootstrap                       COMPLETE
Architecture validation            COMPLETE
PKI generation                     COMPLETE
Certificate distribution           COMPLETE
Kubeconfig generation              COMPLETE
Kubeconfig distribution            COMPLETE
Encryption-at-rest configuration   COMPLETE
Encryption config distribution     COMPLETE
etcd bootstrap                     COMPLETE
Control plane                      NEXT
Workers                            PENDING
Pod networking                     PENDING
CoreDNS                            PENDING
```

The next phase bootstraps the Kubernetes control plane:

- `kube-apiserver`
- `kube-controller-manager`
- `kube-scheduler`

This phase connects the datastore, PKI, kubeconfigs, and encryption-at-rest configuration into a functioning Kubernetes control plane.