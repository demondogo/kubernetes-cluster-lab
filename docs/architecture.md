# Kubernetes Cluster Lab Architecture

## Overview

This project builds a multi-node Kubernetes lab inspired by Kelsey Hightower's **Kubernetes The Hard Way**.

The lab is designed around a clear separation of responsibilities:

- ****Vagrant**** provisions virtual machine infrastructure.

- ****VirtualBox**** provides the virtualization layer.

- ****Ansible**** configures the guest operating systems and automates repeatable cluster operations.

- ****Kubernetes The Hard Way**** provides the Kubernetes bootstrap process and learning path.

The goal is not simply to produce a working Kubernetes cluster. The project is structured to expose how Kubernetes components communicate, authenticate, establish trust, and depend on one another before those operations are automated.

The general approach is:

```text

Build manually

      |

      v

Understand the operation

      |

      v

Validate the result

      |

      v

Automate repeatable work

```

---

## Cluster Topology

| Host | Address | Role |

|---|---|---|

| \`jumpbox\` | \`192.168.56.10\` | Management and administration |

| \`server\` | \`192.168.56.20\` | Kubernetes control plane |

| \`node-0\` | \`192.168.56.50\` | Kubernetes worker |

| \`node-1\` | \`192.168.56.60\` | Kubernetes worker |

Worker pod networks:

| Worker | Pod CIDR |

|---|---|

| \`node-0\` | \`10.200.0.0/24\` |

| \`node-1\` | \`10.200.1.0/24\` |

The control-plane node is also addressable within the lab as:

```text

server.kubernetes.local

```

which resolves to:

```text

192.168.56.20

```

The Kubernetes API server certificate contains \`server.kubernetes.local\` as a Subject Alternative Name, allowing cluster components to securely use the hostname as the API endpoint.

---

## Infrastructure Boundary

Vagrant is responsible only for creating the infrastructure required by the lab.

Its responsibilities include:

- Virtual machine creation

- Hostname assignment

- CPU allocation

- Memory allocation

- Private networking

- Initial SSH access

Vagrant does ****not**** install Kubernetes components or configure the guest operating systems for Kubernetes.

This keeps the infrastructure layer intentionally small:

```text

Vagrant

   |

   +-- VM lifecycle

   +-- CPU / memory

   +-- hostnames

   +-- networking

   +-- bootstrap SSH

          |

          v

       Ansible

```

Guest configuration is delegated to Ansible.

---

## Configuration Management

Ansible manages the desired configuration of the guest operating systems.

Current Ansible responsibilities include:

- Base operating-system packages

- Cluster host resolution

- Kernel modules

- Kubernetes networking sysctl parameters

- Jumpbox configuration

- Certificate distribution

- Kubeconfig distribution

- Encryption configuration distribution

- etcd installation and configuration

- Kubernetes control-plane installation

- Kubernetes worker installation

- Container runtime configuration

- CNI plugin installation and configuration

The roles are designed to be idempotent wherever they manage persistent cluster state.

---

## Management Connectivity

The host does not rely on direct access to the VirtualBox private network for Ansible management.

Instead, Vagrant's generated SSH configuration is exported to:

```text

.vagrant/ssh-config

```

The configuration contains Vagrant's NAT-forwarded SSH endpoints and SSH credentials.

Ansible consumes this configuration rather than duplicating Vagrant's SSH implementation details in inventory.

### Management Path

```text

Ansible

   |

   v

Vagrant SSH configuration

   |

   v

127.0.0.1:<forwarded-port>

   |

   v

VirtualBox NAT

   |

   v

Guest VM

```

This creates an intentional distinction between the ****management path**** and the ****Kubernetes cluster network****.

---

## Kubernetes Network

Kubernetes components communicate between machines using the private lab network:

```text

192.168.56.0/24

```

The topology is:

```text

                  jumpbox

              192.168.56.10

                     |

                     |

                  server

              192.168.56.20

             /             \\

            /               \\

       node-0               node-1

   192.168.56.50        192.168.56.60

    10.200.0.0/24        10.200.1.0/24

```

The two worker nodes receive independent pod CIDRs:

```text

node-0 -> 10.200.0.0/24

node-1 -> 10.200.1.0/24

```

These networks provide the address space for Pods running on each worker.

Cluster-wide routing between the worker Pod CIDRs is established in the Pod networking phase.

---

## Ansible Inventory Model

Ansible inventory separates machine membership from machine-specific configuration.

Conceptually:

```text

inventory

   |

   +-- jumpboxes

   |      |

   |      +-- jumpbox

   |

   +-- control_plane

   |      |

   |      +-- server

   |

   +-- workers

          |

          +-- node-0

          +-- node-1

```

Inventory-specific variables are organized using \`group_vars\` and \`host_vars\`.

```text

inventory/

├── lab.yml

├── group_vars/

│   ├── all.yml

│   ├── control_plane.yml

│   └── workers.yml

└── host_vars/

    ├── server.yml

    ├── node-0.yml

    └── node-1.yml

```

This keeps different kinds of information separate:

```text

inventory

    "Which machines exist?"

group_vars

    "What does this group have in common?"

host_vars

    "What is unique about this machine?"

roles

    "How should the machine be configured?"

playbooks

    "Which operations run where and in what order?"

```

Host-specific variables include values such as:

```text

node_ip

pod_cidr

certificate_files

kubeconfig_files

```

For example:

```text

server

node_ip -> 192.168.56.20

node-0

node_ip  -> 192.168.56.50

pod_cidr -> 10.200.0.0/24

node-1

node_ip  -> 192.168.56.60

pod_cidr -> 10.200.1.0/24

```

---

## Architecture Support

The lab avoids coupling Kubernetes configuration to the operating system or CPU architecture of the machine running Vagrant.

The default Vagrant box is:

```text

bento/ubuntu-24.04

```

The appropriate guest artifact is selected for the host/provider combination when available.

Architecture-specific decisions are based on the architecture detected ****inside the guest****, rather than assumptions about the host.

### ARM64

The Apple Silicon configuration has been validated as:

```text

Apple Silicon host

       |

       v

VirtualBox

       |

       v

Ubuntu 24.04 ARM64

       |

       v

aarch64

       |

       v

arm64 Kubernetes artifacts

```

Downloaded Kubernetes components were verified as ARM64/aarch64 binaries before use.

### AMD64

The equivalent Intel/AMD path is:

```text

Intel/AMD host

       |

       v

VirtualBox

       |

       v

Ubuntu 24.04 AMD64

       |

       v

x86_64

       |

       v

amd64 Kubernetes artifacts

```

This allows the same lab design and Ansible configuration to be used across multiple host architectures.

Architecture support is considered tested only after the complete path has been validated on that platform.

---

## PKI and Trust Model

Kubernetes uses TLS certificates for both encrypted communication and component authentication.

Certificate generation is performed manually on the jumpbox so that the identities and trust relationships remain visible.

The cluster Certificate Authority establishes the root of trust:

```text

                     ca.key

                       |

                       | signs

                       v

                 Kubernetes CA

                       |

          +------------+------------+

          |            |            |

          v            v            v

      API server    workers      clients

```

The CA private key originates on the jumpbox.

The control-plane server also requires the CA private key because \`kube-controller-manager\` performs certificate-signing operations using:

```text

--cluster-signing-cert-file=/var/lib/kubernetes/ca.crt

--cluster-signing-key-file=/var/lib/kubernetes/ca.key

```

The resulting security boundary is:

```text

jumpbox

   |

   +-- ca.key

   |

   +-------> server

   |          |

   |          +-- kube-controller-manager

   |

   +-------> server credentials

   |

   +-------> node-0 credentials

   |

   +-------> node-1 credentials

node-0    X ca.key

node-1    X ca.key

```

The CA private key is therefore permitted only on the jumpbox and control-plane hosts.

It is never distributed to worker nodes.

Ansible enforces this boundary during certificate distribution.

This separates certificate ****creation and trust decisions**** from certificate ****transport and installation****.

---

## Kubeconfig Architecture

Kubeconfigs combine three pieces of information:

```text

                   kubeconfig

                       |

          +------------+------------+

          |            |            |

          v            v            v

       cluster        user        context

          |            |            |

          |            |            |

 API endpoint      certificate      |

 trusted CA        private key      |

          |            |            |

          +------------+------------+

                       |

                       v

              active connection

```

Remote Kubernetes components use:

```text

https://server.kubernetes.local:6443

```

The controller manager and scheduler execute on the control-plane machine and use:

```text

https://127.0.0.1:6443

```

The resulting communication pattern is:

```text

node-0 --------------------+

node-1 --------------------+

kube-proxy ----------------+--> server.kubernetes.local:6443

admin ---------------------+

server:

  kube-controller-manager -----> 127.0.0.1:6443

  kube-scheduler --------------> 127.0.0.1:6443

```

Kubeconfigs are generated manually and inspected before distribution.

Ansible then installs only the credentials required by each machine.

```text

jumpbox

├── admin.kubeconfig

│

├──────> server

│        ├── kube-controller-manager.kubeconfig

│        └── kube-scheduler.kubeconfig

│

├──────> node-0

│        ├── kubelet.kubeconfig

│        └── kube-proxy.kubeconfig

│

└──────> node-1

         ├── kubelet.kubeconfig

         └── kube-proxy.kubeconfig

```

The administrative kubeconfig is intentionally not distributed to cluster nodes.

---

## Encryption at Rest

The Kubernetes API server encrypts configured resources before they are persisted to etcd.

The encryption boundary is:

```text

Kubernetes client

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

The encryption configuration is generated manually on the jumpbox and distributed only to the control-plane server.

Worker nodes do not receive the encryption key.

Runtime encryption has been validated by creating a Kubernetes Secret through the API server and inspecting the raw value stored in etcd.

The plaintext Secret value was absent and the stored value contained:

```text

k8s:enc:aescbc:v1:key1

```

This verifies that encryption at rest is functioning rather than merely configured.

---

## Kubernetes Runtime Architecture

The completed control plane runs on \`server\`:

```text

server

├── etcd

├── kube-apiserver

├── kube-controller-manager

└── kube-scheduler

```

The workers run:

```text

node-0

├── containerd

├── runc

├── kubelet

├── kube-proxy

└── CNI plugins

node-1

├── containerd

├── runc

├── kubelet

├── kube-proxy

└── CNI plugins

```

The resulting component relationship is:

```text

                          server

                     192.168.56.20

                           |

                  Kubernetes API

                       TCP 6443

                           |

               +-----------+-----------+

               |                       |

               v                       v

            node-0                  node-1

        192.168.56.50           192.168.56.60

        10.200.0.0/24           10.200.1.0/24

               |                       |

        +------+------+         +------+------+

        |      |      |         |      |      |

        v      v      v         v      v      v

   containerd kubelet proxy containerd kubelet proxy

        |                         |

        v                         v

       runc                      runc

```

Both kubelets authenticate to the API server using their node-specific PKI identities and register themselves as Kubernetes Nodes.

Both workers currently report:

```text

Ready

```

---

## Worker Runtime Installation

Worker runtime artifacts are installed explicitly rather than extracted directly into the root filesystem.

Ubuntu 24.04 uses a merged-usr filesystem layout:

```text

/bin -> usr/bin

```

The upstream containerd archive contains a top-level:

```text

bin/

```

directory.

Extracting that archive directly into \`/\` can replace the \`/bin\` symbolic link with a real directory.

This can break critical operating-system paths such as:

```text

/bin/bash

```

and prevent new SSH sessions from starting.

The worker role therefore uses:

```text

containerd archive

        |

        v

temporary extraction

        |

        v

/tmp/containerd-extract/bin/

        |

        | explicit installation

        v

/usr/local/bin/

```

The containerd systemd service consequently starts:

```text

/usr/local/bin/containerd

```

rather than relying on the archive's original \`bin/\` layout.

This separates external archive layout from operating-system filesystem layout and preserves the Ubuntu merged-usr structure.

See [\`workers.md\`](workers.md) for implementation and troubleshooting details.

---

## Pod Network Architecture

The controller manager is configured with the cluster-wide Pod CIDR:

```text
10.200.0.0/16
```

Each worker receives a dedicated subnet:

```text
                     10.200.0.0/16
                           |
               +-----------+-----------+
               |                       |
               v                       v
        10.200.0.0/24           10.200.1.0/24
             node-0                  node-1
```

The worker CNI bridge configuration uses the host-specific `pod_cidr` variable to establish the local Pod network on each worker.

Local CNI configuration alone does not provide routing between Pod CIDRs on different workers.

The cluster therefore uses explicit Linux routes:

```text
server
├── 10.200.0.0/24 via 192.168.56.50
└── 10.200.1.0/24 via 192.168.56.60

node-0
└── 10.200.1.0/24 via 192.168.56.60

node-1
└── 10.200.0.0/24 via 192.168.56.50
```

The routes were first configured manually to validate the Kubernetes The Hard Way routing model.

Persistent routing is managed by Ansible through:

```text
/etc/netplan/60-kubernetes-routes.yaml
```

while Vagrant retains ownership of the private interface configuration in:

```text
/etc/netplan/50-vagrant.yaml
```

Route definitions are derived from each worker's `node_ip` and `pod_cidr` inventory variables. Kernel route selection has been validated with `ip route get`, and a subsequent Ansible execution confirmed that the persistent route configuration is idempotent.

See [`pod-network-routes.md`](pod-network-routes.md) for the complete implementation and verification workflow.

---

## Sensitive Artifact Transport

Certificates, kubeconfigs, and other generated cluster artifacts originate on the jumpbox, while Ansible runs from the host.

Sensitive files therefore follow this transport path:

```text

jumpbox

   |

   | fetch

   v

temporary controller staging

   |

   | copy

   v

destination node

   |

   v

temporary staging removed

```

The host-side staging directory exists only for the duration of the distribution operation.

This means staging and cleanup may report changes every time a distribution playbook runs.

That behavior is intentional.

Persistent cluster state remains idempotent:

```text

server   changed=0

node-0   changed=0

node-1   changed=0

```

while temporary credential transport is ephemeral:

```text

create staging   changed

fetch            changed

cleanup          changed

```

Removing sensitive temporary files is preferred over retaining them solely to make the entire orchestration report \`changed=0\`.

---

## Playbooks and Roles

Playbooks and roles have deliberately different responsibilities.

```text

Playbook

    "Where and when?"

Role

    "How?"

```

For example, worker installation is orchestrated by:

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

The implementation resides in:

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

The same orchestration pattern is used for other multi-stage operations such as kubeconfig and encryption configuration distribution.

This keeps orchestration separate from reusable configuration logic.

---

## Automation Philosophy

Automation is introduced only after the underlying operation has been understood and validated.

The general workflow is:

```text

Perform manually

      |

      v

Understand behavior

      |

      v

Validate result

      |

      v

Identify repetitive operation

      |

      v

Automate with Ansible

```

For example:

```text

Generate PKI manually

        |

        v

Understand certificate identities

        |

        v

Verify trust chains

        |

        v

Distribute certificates with Ansible

```

and:

```text

Generate kubeconfigs manually

        |

        v

Understand clusters/users/contexts

        |

        v

Verify endpoints and identities

        |

        v

Distribute kubeconfigs with Ansible

```

The worker runtime also demonstrates why the validation step matters:

```text

Understand upstream installation

        |

        v

Test against target operating system

        |

        v

Identify filesystem assumption

        |

        v

Adapt installation safely

        |

        v

Automate corrected behavior

```

This approach avoids turning Kubernetes bootstrap into an opaque automation exercise.

The objective is to understand the system first and automate the repetitive parts second.

---

## Kubernetes Bootstrap Workflow

The cluster is built progressively, with infrastructure provisioning, security configuration, Kubernetes component bootstrap, and network configuration handled as separate phases.

```text
Vagrant infrastructure
        |
        v
Ansible OS bootstrap
        |
        v
Architecture validation
        |
        v
Kubernetes binary acquisition
        |
        v
Manual PKI generation
        |
        v
Ansible certificate distribution
        |
        v
Manual kubeconfig generation
        |
        v
Ansible kubeconfig distribution
        |
        v
Manual encryption-at-rest configuration
        |
        v
Ansible encryption config distribution
        |
        v
Ansible etcd bootstrap
        |
        v
Ansible control-plane bootstrap
        |
        v
Ansible worker bootstrap
        |
        v
Manual kubectl remote access
        |
        v
Manual Pod network route validation
        |
        v
Ansible persistent Pod network routes
        |
        v
Smoke test
```

The workflow intentionally separates operations performed manually for learning and validation from repetitive configuration that is automated with Ansible.

At this stage, all cluster bootstrap and network-routing phases are complete. The remaining Kubernetes The Hard Way milestone is the end-to-end smoke test.

---

## Project Progress

This section is the canonical source for the current implementation status of the lab. Individual phase documents describe how each component is designed, implemented, rebuilt, and verified.

| Phase | Implementation | Status |
|---|---|---|
| Infrastructure provisioning | Vagrant | Complete |
| OS bootstrap | Ansible | Complete |
| Architecture validation | Manual | Complete |
| Kubernetes binary preparation | Manual | Complete |
| PKI generation | Manual | Complete |
| Certificate distribution | Ansible | Complete |
| Kubeconfig generation | Manual | Complete |
| Kubeconfig distribution | Ansible | Complete |
| Encryption-at-rest configuration | Manual | Complete |
| Encryption config distribution | Ansible | Complete |
| etcd bootstrap | Ansible | Complete |
| Control-plane bootstrap | Ansible | Complete |
| Worker bootstrap | Ansible | Complete |
| kubectl remote access | Manual | Complete |
| Pod network route validation | Manual | Complete |
| Persistent Pod network routes | Ansible | Complete |
| Smoke test | Manual | In Progress |

### Current Phase

The Kubernetes control plane, worker nodes, administrative access, and Pod network routing are operational.

```text
                         Kubernetes Cluster

                              server
                         192.168.56.20
                              |
                   Kubernetes API :6443
                              |
                  +-----------+-----------+
                  |                       |
                  v                       v
               node-0                  node-1
           192.168.56.50           192.168.56.60
           10.200.0.0/24           10.200.1.0/24
                  |                       |
                Ready                   Ready
                  |                       |
                  +------ routing --------+
```

The control-plane services are operational:

```text
server
├── etcd                       ✓
├── kube-apiserver             ✓
├── kube-controller-manager    ✓
└── kube-scheduler             ✓
```

The worker services are operational:

```text
node-0 / node-1
├── containerd                 ✓
├── runc                       ✓
├── kubelet                    ✓
├── kube-proxy                 ✓
└── CNI plugins                ✓
```

Both kubelets successfully authenticate to the Kubernetes API server, register their machines as Kubernetes Nodes, and report `Ready`.

Remote administrative access from the jumpbox is configured through:

```text
/home/vagrant/.kube/config
```

with the active context:

```text
kubernetes-the-hard-way
```

Remote access has been validated without specifying an explicit kubeconfig:

```bash
kubectl version
kubectl get nodes -o wide
```

The client and server are both running Kubernetes v1.32.3.

Pod network routing is also complete. The control-plane server has routes to both worker Pod CIDRs:

```text
10.200.0.0/24 via 192.168.56.50
10.200.1.0/24 via 192.168.56.60
```

Each worker has a route to the remote worker's Pod network:

```text
node-0
└── 10.200.1.0/24 via 192.168.56.60

node-1
└── 10.200.0.0/24 via 192.168.56.50
```

Persistent routes are managed by Ansible through:

```text
/etc/netplan/60-kubernetes-routes.yaml
```

while Vagrant retains ownership of the private interface configuration:

```text
/etc/netplan/50-vagrant.yaml
```

Kernel route selection has been validated in every required direction:

```text
server -> 10.200.0.x -> node-0    ✓
server -> 10.200.1.x -> node-1    ✓
node-0 -> 10.200.1.x -> node-1    ✓
node-1 -> 10.200.0.x -> node-0    ✓
```

A subsequent execution of the Pod network route playbook required no persistent configuration changes, confirming idempotency.

At this stage, the lab has completed:

```text
Infrastructure provisioning          ✓
Operating-system bootstrap            ✓
Architecture validation               ✓
PKI generation                        ✓
Certificate distribution              ✓
Kubeconfig generation                 ✓
Kubeconfig distribution               ✓
Encryption at rest                    ✓
etcd                                  ✓
Control plane                         ✓
Worker bootstrap                      ✓
kubectl remote access                 ✓
Pod network route validation          ✓
Persistent Pod network routes         ✓
```

All Kubernetes bootstrap and network-routing phases are therefore complete.

The next and final Kubernetes The Hard Way milestone is Section 12:

```text
Smoke Test
```

The smoke test validates the completed cluster from the workload perspective, including Secrets, Deployments, Pods, logs, command execution, port forwarding, and Services.

This provides end-to-end validation that the API server, etcd, encryption, worker runtime, kubelet, kube-proxy, CNI configuration, and Pod network routing operate together as a functioning Kubernetes cluster.
