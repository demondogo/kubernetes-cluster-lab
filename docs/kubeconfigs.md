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

> **Rebuild note:** Kubeconfigs are generated runtime credentials and are intentionally excluded from Git. After recreating the lab VMs, regenerate the PKI first, then follow the manual generation procedure below before running `playbooks/distribute-kubeconfigs.yml`.

---

## Workspace

Kubeconfigs are generated on the jumpbox under:

```text
/home/vagrant/kubernetes-kubeconfigs
```

PKI material used during generation resides under:

```text
/home/vagrant/kubernetes-pki
```

Generated kubeconfigs contain embedded certificate and private-key material and must not be committed to Git.

The repository `.gitignore` excludes:

```text
*.kubeconfig
```

---

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

A context associates a cluster with an identity:

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

---

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

Verify the hostname against the certificate:

```bash
openssl verify \
  -CAfile ~/kubernetes-pki/ca.crt \
  -verify_hostname server.kubernetes.local \
  ~/kubernetes-pki/kube-api-server.crt
```

Expected:

```text
/home/vagrant/kubernetes-pki/kube-api-server.crt: OK
```

This ensures:

```text
DNS resolution
       +
TLS certificate identity
       +
kubeconfig endpoint
```

all agree on the same control-plane identity.

---

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

---

# Manual Kubeconfig Generation

## Prerequisites

The Kubernetes PKI must already exist.

Required files include:

```text
/home/vagrant/kubernetes-pki/
├── ca.crt
├── admin.crt
├── admin.key
├── node-0.crt
├── node-0.key
├── node-1.crt
├── node-1.key
├── kube-proxy.crt
├── kube-proxy.key
├── kube-controller-manager.crt
├── kube-controller-manager.key
├── kube-scheduler.crt
└── kube-scheduler.key
```

`kubectl` must also be available on the jumpbox.

If it has already been organized under the Kubernetes The Hard Way downloads directory:

```bash
sudo install -m 0755 \
  ~/kubernetes-the-hard-way/downloads/client/kubectl \
  /usr/local/bin/kubectl
```

Verify:

```bash
kubectl version --client
```

---

## Create the Workspace

```bash
mkdir -p ~/kubernetes-kubeconfigs
cd ~/kubernetes-kubeconfigs
```

Define shared configuration:

```bash
SERVER=server.kubernetes.local
CLUSTER=kubernetes-the-hard-way
PKI=../kubernetes-pki
```

Verify name resolution:

```bash
getent hosts "${SERVER}"
```

Expected:

```text
192.168.56.20 server.kubernetes.local server
```

Verify the API server certificate:

```bash
openssl verify \
  -CAfile "${PKI}/ca.crt" \
  -verify_hostname "${SERVER}" \
  "${PKI}/kube-api-server.crt"
```

Expected:

```text
../kubernetes-pki/kube-api-server.crt: OK
```

---

## Generate `node-0.kubeconfig` Manually

`node-0` is generated step-by-step to demonstrate how a kubeconfig is assembled.

### Configure the Cluster

```bash
kubectl config set-cluster "${CLUSTER}" \
  --certificate-authority="${PKI}/ca.crt" \
  --embed-certs=true \
  --server="https://${SERVER}:6443" \
  --kubeconfig=node-0.kubeconfig
```

This establishes:

```text
cluster name
     +
API server endpoint
     +
trusted Certificate Authority
```

### Configure the Node Identity

```bash
kubectl config set-credentials system:node:node-0 \
  --client-certificate="${PKI}/node-0.crt" \
  --client-key="${PKI}/node-0.key" \
  --embed-certs=true \
  --kubeconfig=node-0.kubeconfig
```

The kubelet authenticates as:

```text
system:node:node-0
```

### Configure the Context

```bash
kubectl config set-context default \
  --cluster="${CLUSTER}" \
  --user=system:node:node-0 \
  --kubeconfig=node-0.kubeconfig
```

Activate it:

```bash
kubectl config use-context default \
  --kubeconfig=node-0.kubeconfig
```

The relationship is:

```text
kubernetes-the-hard-way
          +
system:node:node-0
          |
          v
        default
          |
          v
 node-0.kubeconfig
```

---

## Generate the Remaining Remote Kubeconfigs

After constructing `node-0.kubeconfig` manually, a temporary Bash helper eliminates repetitive commands for the remaining remote clients.

The function exists only in the current shell session and is not permanent project automation.

```bash
generate_kubeconfig() {
    if [[ $# -ne 4 ]]; then
        echo "Usage: generate_kubeconfig <name> <user> <cert> <key>" >&2
        return 1
    fi

    local name="$1"
    local user="$2"
    local cert="$3"
    local key="$4"

    kubectl config set-cluster "${CLUSTER}" \
      --certificate-authority="${PKI}/ca.crt" \
      --embed-certs=true \
      --server="https://${SERVER}:6443" \
      --kubeconfig="${name}.kubeconfig"

    kubectl config set-credentials "${user}" \
      --client-certificate="${PKI}/${cert}" \
      --client-key="${PKI}/${key}" \
      --embed-certs=true \
      --kubeconfig="${name}.kubeconfig"

    kubectl config set-context default \
      --cluster="${CLUSTER}" \
      --user="${user}" \
      --kubeconfig="${name}.kubeconfig"

    kubectl config use-context default \
      --kubeconfig="${name}.kubeconfig"
}
```

The positional arguments are:

```text
$1 -> kubeconfig name
$2 -> Kubernetes identity
$3 -> client certificate
$4 -> client private key
```

Generate `node-1`:

```bash
generate_kubeconfig \
  node-1 \
  system:node:node-1 \
  node-1.crt \
  node-1.key
```

Generate `kube-proxy`:

```bash
generate_kubeconfig \
  kube-proxy \
  system:kube-proxy \
  kube-proxy.crt \
  kube-proxy.key
```

Generate the administrative kubeconfig:

```bash
generate_kubeconfig \
  admin \
  admin \
  admin.crt \
  admin.key
```

---

## Generate the Controller Manager Kubeconfig

The controller manager runs locally on the control-plane server and connects to:

```text
https://127.0.0.1:6443
```

Configure the cluster:

```bash
kubectl config set-cluster "${CLUSTER}" \
  --certificate-authority="${PKI}/ca.crt" \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=kube-controller-manager.kubeconfig
```

Configure its identity:

```bash
kubectl config set-credentials system:kube-controller-manager \
  --client-certificate="${PKI}/kube-controller-manager.crt" \
  --client-key="${PKI}/kube-controller-manager.key" \
  --embed-certs=true \
  --kubeconfig=kube-controller-manager.kubeconfig
```

Create the context:

```bash
kubectl config set-context default \
  --cluster="${CLUSTER}" \
  --user=system:kube-controller-manager \
  --kubeconfig=kube-controller-manager.kubeconfig
```

Activate it:

```bash
kubectl config use-context default \
  --kubeconfig=kube-controller-manager.kubeconfig
```

---

## Generate the Scheduler Kubeconfig

The scheduler also runs locally on the control-plane server.

Configure the cluster:

```bash
kubectl config set-cluster "${CLUSTER}" \
  --certificate-authority="${PKI}/ca.crt" \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=kube-scheduler.kubeconfig
```

Configure its identity:

```bash
kubectl config set-credentials system:kube-scheduler \
  --client-certificate="${PKI}/kube-scheduler.crt" \
  --client-key="${PKI}/kube-scheduler.key" \
  --embed-certs=true \
  --kubeconfig=kube-scheduler.kubeconfig
```

Create the context:

```bash
kubectl config set-context default \
  --cluster="${CLUSTER}" \
  --user=system:kube-scheduler \
  --kubeconfig=kube-scheduler.kubeconfig
```

Activate it:

```bash
kubectl config use-context default \
  --kubeconfig=kube-scheduler.kubeconfig
```

---

## Generated Kubeconfigs

Six kubeconfigs should now exist:

```bash
ls -lh *.kubeconfig
```

Expected:

```text
admin.kubeconfig
kube-controller-manager.kubeconfig
kube-proxy.kubeconfig
kube-scheduler.kubeconfig
node-0.kubeconfig
node-1.kubeconfig
```

| Kubeconfig | Kubernetes Identity | API Endpoint |
|---|---|---|
| `admin.kubeconfig` | `admin` | `server.kubernetes.local:6443` |
| `node-0.kubeconfig` | `system:node:node-0` | `server.kubernetes.local:6443` |
| `node-1.kubeconfig` | `system:node:node-1` | `server.kubernetes.local:6443` |
| `kube-proxy.kubeconfig` | `system:kube-proxy` | `server.kubernetes.local:6443` |
| `kube-controller-manager.kubeconfig` | `system:kube-controller-manager` | `127.0.0.1:6443` |
| `kube-scheduler.kubeconfig` | `system:kube-scheduler` | `127.0.0.1:6443` |

---

## Verify Generated Kubeconfigs

Audit the endpoint and identity without displaying private-key material:

```bash
for config in *.kubeconfig; do
  echo "=== ${config} ==="

  kubectl config view \
    --kubeconfig="${config}" \
    --minify \
    -o jsonpath='server={.clusters[0].cluster.server} user={.contexts[0].context.user}{"\n"}'
done
```

Expected:

```text
admin.kubeconfig
  server=https://server.kubernetes.local:6443
  user=admin

node-0.kubeconfig
  server=https://server.kubernetes.local:6443
  user=system:node:node-0

node-1.kubeconfig
  server=https://server.kubernetes.local:6443
  user=system:node:node-1

kube-proxy.kubeconfig
  server=https://server.kubernetes.local:6443
  user=system:kube-proxy

kube-controller-manager.kubeconfig
  server=https://127.0.0.1:6443
  user=system:kube-controller-manager

kube-scheduler.kubeconfig
  server=https://127.0.0.1:6443
  user=system:kube-scheduler
```

---

## Verify Embedded Credentials

Kubeconfigs are generated with:

```text
--embed-certs=true
```

This embeds:

```text
certificate-authority-data
client-certificate-data
client-key-data
```

Verify the fields exist without printing their values:

```bash
for config in *.kubeconfig; do
  echo "=== ${config} ==="

  for field in \
    certificate-authority-data \
    client-certificate-data \
    client-key-data
  do
    if grep -q "${field}:" "${config}"; then
      echo "  ${field}: OK"
    else
      echo "  ${field}: MISSING"
    fi
  done
done
```

Each kubeconfig should report:

```text
certificate-authority-data: OK
client-certificate-data: OK
client-key-data: OK
```

Because client private keys are embedded, kubeconfigs must be treated as sensitive credentials.

---

# Distribution

After generation and validation, Ansible handles distribution.

Run from the `ansible/` directory:

```bash
ansible-playbook playbooks/distribute-kubeconfigs.yml
```

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

---

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

---

## Worker Distribution

`node-0` receives:

```text
/var/lib/kubernetes/
├── kubelet.kubeconfig
└── kube-proxy.kubeconfig
```

with:

```text
node-0.kubeconfig -> kubelet.kubeconfig
```

`node-1` receives:

```text
/var/lib/kubernetes/
├── kubelet.kubeconfig
└── kube-proxy.kubeconfig
```

with:

```text
node-1.kubeconfig -> kubelet.kubeconfig
```

This allows both workers to use conventional local filenames while retaining distinct Kubernetes node identities.

---

## Administrative Credentials

`admin.kubeconfig` is intentionally not distributed to the control plane or workers.

It remains an administrative credential on the jumpbox.

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

The Ansible distribution workflow explicitly prevents the administrative kubeconfig from being installed on cluster nodes.

---

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

The role implements operations while the playbook controls orchestration:

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

---

## Ephemeral Staging and Idempotency

Each distribution execution:

1. Creates a temporary controller-side staging directory.
2. Fetches kubeconfigs from the jumpbox.
3. Installs the required files on cluster nodes.
4. Deletes the staging directory.

The staging and cleanup phases intentionally report changes on subsequent runs.

Persistent cluster configuration remains idempotent:

```text
server   install changed=0
node-0   install changed=0
node-1   install changed=0
```

while temporary transport changes:

```text
create staging   changed
fetch            changed
cleanup          changed
```

Removing sensitive staged credentials is preferred over retaining them solely to make the complete playbook report `changed=0`.

---

## Verification After Distribution

Verify the control-plane kubeconfigs:

```bash
ansible server -b -m shell -a \
  'ls -l /var/lib/kubernetes/*.kubeconfig'
```

Verify worker kubeconfigs:

```bash
ansible workers -b -m shell -a \
  'ls -l /var/lib/kubernetes/*.kubeconfig'
```

Verify the administrative credential was not distributed:

```bash
ansible 'control_plane:workers' -b -m shell -a \
  'test ! -e /var/lib/kubernetes/admin.kubeconfig && echo "admin kubeconfig absent"'
```

All cluster nodes should report:

```text
admin kubeconfig absent
```

---

## Rebuild Procedure

If the virtual machines are destroyed, kubeconfigs must be regenerated because they are runtime credentials and are intentionally excluded from Git.

The recovery sequence is:

```text
Recreate VMs
     |
     v
Run Ansible bootstrap
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
Validate kubeconfigs
     |
     v
Distribute kubeconfigs
```

After rebuilding PKI according to `pki.md`, follow the manual generation procedure in this document.

Then, from the Ansible controller:

```bash
ansible-playbook playbooks/distribute-certificates.yml
ansible-playbook playbooks/distribute-kubeconfigs.yml
```

The rebuild intentionally generates new credentials rather than depending on credentials stored only inside previous virtual machines.

---

## Next Phase

With kubeconfigs generated, validated, and distributed, Kubernetes components have the client identities and API endpoints required for authenticated communication.

The next security prerequisite is encryption at rest.

See [`architecture.md`](architecture.md) for the current overall project status.