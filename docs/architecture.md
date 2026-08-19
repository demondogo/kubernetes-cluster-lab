# Kubernetes Cluster Lab Architecture

## Overview

This project builds a multi-node Kubernetes lab inspired by Kelsey Hightower's *Kubernetes The Hard Way*.

The lab is designed around a clear separation of responsibilities:

- **Vagrant** provisions virtual machine infrastructure.
- **VirtualBox** provides the virtualization layer.
- **Ansible** configures the guest operating systems and automates repeatable cluster operations.
- **Kubernetes The Hard Way** provides the Kubernetes bootstrap process and learning path.

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
| `jumpbox` | `192.168.56.10` | Management and administration |
| `server` | `192.168.56.20` | Kubernetes control plane |
| `node-0` | `192.168.56.50` | Kubernetes worker |
| `node-1` | `192.168.56.60` | Kubernetes worker |

Worker pod networks:

| Worker | Pod CIDR |
|---|---|
| `node-0` | `10.200.0.0/24` |
| `node-1` | `10.200.1.0/24` |

The control-plane node is also addressable within the lab as:

```text
server.kubernetes.local
```

which resolves to:

```text
192.168.56.20
```

The Kubernetes API server certificate contains `server.kubernetes.local` as a Subject Alternative Name, allowing cluster components to securely use the hostname as the API endpoint.

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

Vagrant does **not** install Kubernetes components or configure the guest operating systems for Kubernetes.

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

The roles are designed to be idempotent wherever they manage persistent cluster state.

---

## Management Connectivity

The host does not rely on direct access to the VirtualBox private network for Ansible management.

Instead, Vagrant's generated SSH configuration is exported to:

```text
.vagrant/ssh-config
```

The configuration contains Vagrant's NAT-forwarded SSH endpoints and generated SSH credentials.

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

This creates an intentional distinction between the **management path** and the **Kubernetes cluster network**.

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
             /             \
            /               \
       node-0               node-1
   192.168.56.50        192.168.56.60
    10.200.0.0/24        10.200.1.0/24
```

The two worker nodes receive independent pod CIDRs:

```text
node-0 -> 10.200.0.0/24
node-1 -> 10.200.1.0/24
```

This network will later provide the foundation for pod routing between workers.

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

Inventory-specific variables are organized using `group_vars` and `host_vars`.

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

---

## Architecture Support

The lab avoids coupling Kubernetes configuration to the operating system or CPU architecture of the machine running Vagrant.

The default Vagrant box is:

```text
bento/ubuntu-24.04
```

The appropriate guest artifact is selected for the host/provider combination when available.

Architecture-specific decisions are based on the architecture detected **inside the guest**, rather than assumptions about the host.

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

The CA private key remains on the jumpbox.

It is never distributed to the control plane or worker nodes.

Ansible handles only the repetitive distribution of the certificates required by each machine.

```text
jumpbox
   |
   +-- ca.key                 NEVER DISTRIBUTED
   |
   +-- server credentials -------> server
   |
   +-- node-0 credentials -------> node-0
   |
   +-- node-1 credentials -------> node-1
```

This separates certificate **creation and trust decisions** from certificate **transport and installation**.

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

## Sensitive Artifact Transport

Certificates and kubeconfigs originate on the jumpbox, while Ansible runs from the host.

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

Removing sensitive temporary files is preferred over retaining them solely to make the entire orchestration report `changed=0`.

---

## Playbooks and Roles

Playbooks and roles have deliberately different responsibilities.

```text
Playbook
    "Where and when?"

Role
    "How?"
```

For example, credential distribution is orchestrated by a playbook:

```text
distribute-kubeconfigs.yml
        |
        +--> jumpbox
        |      |
        |      +--> stage
        |
        +--> control_plane + workers
        |      |
        |      +--> install
        |
        +--> localhost
               |
               +--> cleanup
```

The corresponding role contains the implementation:

```text
roles/kubeconfigs/
├── defaults/
│   └── main.yml
└── tasks/
    ├── main.yml
    ├── stage.yml
    ├── install.yml
    └── cleanup.yml
```

This pattern keeps orchestration separate from reusable configuration logic.

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

This approach avoids turning Kubernetes bootstrap into an opaque automation exercise.

The objective is to understand the system first and automate the repetitive parts second.

---


## Kubernetes Bootstrap Workflow

The cluster is built progressively, with infrastructure provisioning, security configuration, and Kubernetes component bootstrap handled as separate phases.

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
Worker bootstrap
        |
        v
Pod networking
        |
        v
CoreDNS
```

The workflow intentionally separates operations that are performed manually for learning from repetitive configuration and distribution tasks that are automated with Ansible.

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
| Worker bootstrap | Ansible | In Progress |
| Pod networking | TBD | Pending |
| CoreDNS | TBD | Pending |

### Current Phase

The Kubernetes control plane is operational.

The following control-plane components are running on `server`:

```text
server
├── etcd
├── kube-apiserver
├── kube-controller-manager
└── kube-scheduler
```

The control-plane stack has been validated beyond basic service availability:

```text
Control Plane
     |
     +-- etcd healthy                         ✓
     |
     +-- kube-apiserver active                ✓
     |
     +-- kube-controller-manager active       ✓
     |
     +-- kube-scheduler active                ✓
     |
     +-- API readiness checks                 ✓
     |
     +-- API reachable over 192.168.56.20     ✓
     |
     +-- advertised endpoint correct          ✓
     |
     +-- admin authentication                 ✓
     |
     +-- encryption at rest                   ✓
```

The API server advertises the cluster-facing address:

```text
192.168.56.20:6443
```

rather than the VirtualBox NAT interface.

Encryption at rest has also been validated end-to-end by creating a Kubernetes Secret through the API server and inspecting its raw representation in etcd.

The plaintext Secret value was absent, while the stored value contained the expected encryption-provider marker:

```text
k8s:enc:aescbc:v1:key1
```

The next implementation phase is bootstrapping the worker nodes:

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

Once the workers are registered and operational, the remaining phases will establish pod networking and cluster DNS.