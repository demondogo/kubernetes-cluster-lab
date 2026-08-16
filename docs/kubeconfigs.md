# Kubernetes Kubeconfigs

## Overview

Kubernetes components use kubeconfig files to determine:

- Which Kubernetes cluster to connect to
- Which API server endpoint to use
- Which Certificate Authority to trust
- Which client identity to present
- Which cluster and user combination forms the active context

In this lab, kubeconfigs are generated manually on the jumpbox to preserve the learning objectives of Kubernetes The Hard Way.

Distribution is automated with Ansible.

This follows the same pattern used for PKI:

```text
Generate manually
       |
       v
Inspect and understand
       |
       v
Validate
       |
       v
Distribute with Ansible
```

## Workspace

Kubeconfigs are generated on the jumpbox under:

```text
/home/vagrant/kubernetes-kubeconfigs
```

PKI material used during generation resides under:

```text
/home/vagrant/kubernetes-pki
```

Generated kubeconfigs contain embedded certificate material and must not be committed to Git.

The repository `.gitignore` excludes:

```text
*.kubeconfig
```

## Kubeconfig Structure

A kubeconfig combines three primary concepts:

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

### Cluster

The cluster entry defines where Kubernetes is located and which CA should be trusted.

For example:

```yaml
clusters:
  - name: kubernetes-the-hard-way
    cluster:
      server: https://server.kubernetes.local:6443
      certificate-authority-data: ...
```

The CA certificate is embedded directly into the kubeconfig.

### User

The user entry defines the identity presented to Kubernetes.

For example, the `node-0` kubelet authenticates as:

```text
system:node:node-0
```

using the certificate and private key generated for that node.

Conceptually:

```yaml
users:
  - name: system:node:node-0
    user:
      client-certificate-data: ...
      client-key-data: ...
```

### Context

A context associates a cluster with an identity.

```yaml
contexts:
  - name: default
    context:
      cluster: kubernetes-the-hard-way
      user: system:node:node-0
```

The resulting configuration answers three questions:

```text
Where am I connecting?
        +
Who do I trust?
        +
Who am I?
```

## API Server Endpoint

Remote cluster components use:

```text
https://server.kubernetes.local:6443
```

The lab resolves:

```text
server.kubernetes.local
```

to:

```text
192.168.56.20
```

through the lab's host configuration.

The API server certificate includes the hostname in its Subject Alternative Names:

```text
DNS:server.kubernetes.local
```

The hostname was verified against the certificate using:

```bash
openssl verify \
  -CAfile ~/kubernetes-pki/ca.crt \
  -verify_hostname server.kubernetes.local \
  ~/kubernetes-pki/kube-api-server.crt
```

This ensures that:

```text
DNS resolution
       +
TLS certificate identity
       +
kubeconfig endpoint
```

all agree on the same control-plane identity.

## Local Control Plane Endpoint

The controller manager and scheduler execute on the same machine as the API server.

Their kubeconfigs therefore use:

```text
https://127.0.0.1:6443
```

rather than the external control-plane hostname.

This produces two connection patterns:

```text
node-0 --------------------+
node-1 --------------------+
kube-proxy ----------------+--> server.kubernetes.local:6443
admin ---------------------+

server:
  kube-controller-manager -----> 127.0.0.1:6443
  kube-scheduler --------------> 127.0.0.1:6443
```

## Generated Kubeconfigs

The lab generates six kubeconfigs.

| Kubeconfig | Kubernetes Identity | API Endpoint |
|---|---|---|
| `admin.kubeconfig` | `admin` | `server.kubernetes.local:6443` |
| `node-0.kubeconfig` | `system:node:node-0` | `server.kubernetes.local:6443` |
| `node-1.kubeconfig` | `system:node:node-1` | `server.kubernetes.local:6443` |
| `kube-proxy.kubeconfig` | `system:kube-proxy` | `server.kubernetes.local:6443` |
| `kube-controller-manager.kubeconfig` | `system:kube-controller-manager` | `127.0.0.1:6443` |
| `kube-scheduler.kubeconfig` | `system:kube-scheduler` | `127.0.0.1:6443` |

## Embedded Credentials

Kubeconfigs are generated using:

```text
--embed-certs=true
```

This embeds the required credential material directly into each file:

```text
certificate-authority-data
client-certificate-data
client-key-data
```

As a result, a distributed kubeconfig does not depend on paths back to the original PKI workspace.

This also means kubeconfigs containing client private keys must be treated as sensitive credentials.

## Distribution

Kubeconfig generation is performed manually.

Ansible handles distribution.

The workflow is:

```text
jumpbox
   |
   | fetch
   v
temporary controller staging
   |
   +---------------------+
   |                     |
   v                     v
server                 workers
   |
   v
temporary staging removed
```

The Ansible controller does not retain the staged credentials after distribution.

## Control Plane Distribution

The control-plane server receives:

```text
/var/lib/kubernetes/
├── kube-controller-manager.kubeconfig
└── kube-scheduler.kubeconfig
```

Both files are:

```text
owner: root
group: root
mode: 0600
```

## Worker Distribution

`node-0` receives:

```text
/var/lib/kubernetes/
├── kubelet.kubeconfig
└── kube-proxy.kubeconfig
```

The source mapping is:

```text
node-0.kubeconfig -> kubelet.kubeconfig
```

`node-1` receives the same destination filenames:

```text
/var/lib/kubernetes/
├── kubelet.kubeconfig
└── kube-proxy.kubeconfig
```

with:

```text
node-1.kubeconfig -> kubelet.kubeconfig
```

This allows both workers to use the conventional local filename while retaining distinct Kubernetes node identities.

## Administrative Credentials

`admin.kubeconfig` is intentionally not distributed to the control plane or workers.

It remains an administrative credential.

The Ansible distribution workflow explicitly verifies that it is not included in a node's distribution configuration.

The intended boundary is:

```text
jumpbox
└── admin.kubeconfig

server
├── kube-controller-manager.kubeconfig
└── kube-scheduler.kubeconfig

node-0
├── kubelet.kubeconfig
└── kube-proxy.kubeconfig

node-1
├── kubelet.kubeconfig
└── kube-proxy.kubeconfig
```

## Ansible Role Design

Kubeconfig distribution uses a dedicated role:

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

The role implements operations while the playbook controls orchestration.

```text
playbooks/distribute-kubeconfigs.yml
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

This maintains a clear separation:

```text
Playbook
    "Where and when?"

Role
    "How?"
```

## Ephemeral Staging and Idempotency

The distribution workflow uses temporary controller-side staging.

Each execution:

1. Creates the staging directory.
2. Fetches kubeconfigs from the jumpbox.
3. Installs the required files on cluster nodes.
4. Deletes the staging directory.

Because the staging directory is deliberately removed after every execution, the staging and cleanup phases report changes on subsequent runs.

This is intentional.

Persistent cluster configuration remains idempotent:

```text
server   install changed=0
node-0   install changed=0
node-1   install changed=0
```

while temporary credential transport changes during each execution:

```text
create staging   changed
fetch            changed
cleanup          changed
```

The security benefit of removing sensitive staged credentials is preferred over retaining temporary files solely to produce `changed=0` for the entire workflow.

## Verification

Control-plane kubeconfigs can be verified with:

```bash
ansible server -b -m shell -a \
  'ls -l /var/lib/kubernetes/*.kubeconfig'
```

Workers can be verified with:

```bash
ansible workers -b -m shell -a \
  'ls -l /var/lib/kubernetes/*.kubeconfig'
```

The administrative credential should not exist on cluster nodes:

```bash
ansible 'control_plane:workers' -b -m shell -a \
  'test ! -e /var/lib/kubernetes/admin.kubeconfig && echo "admin kubeconfig absent"'
```

## Current State

At completion of this phase:

```text
Infrastructure provisioning       Vagrant       COMPLETE
OS bootstrap                      Ansible       COMPLETE
PKI generation                    Manual        COMPLETE
Certificate distribution          Ansible       COMPLETE
Kubeconfig generation             Manual        COMPLETE
Kubeconfig distribution           Ansible       COMPLETE
Encryption at rest                              NEXT
etcd                                            PENDING
Control plane                                   PENDING
Workers                                         PENDING
Pod networking                                  PENDING
CoreDNS                                         PENDING
```

The next phase is configuring Kubernetes encryption at rest before bootstrapping etcd and the control plane.