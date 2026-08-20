# Configuring kubectl for Remote Access

## Overview

The Kubernetes control plane and worker nodes are now operational, but administrative access should not require specifying a kubeconfig path for every `kubectl` command.

This phase configures the jumpbox with a default administrative kubeconfig:

```text
~/.kube/config
```

After configuration, the jumpbox can manage the cluster using standard commands such as:

```bash
kubectl get nodes
```

rather than:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get nodes
```

This phase follows the Kubernetes The Hard Way remote-access workflow while using the PKI workspace created earlier in this lab.

---

## Prerequisites

The jumpbox already contains:

```text
/home/vagrant/kubernetes-pki/
├── ca.crt
├── admin.crt
└── admin.key
```

The `kubectl` client is also installed on the jumpbox.

The Kubernetes API is available at:

```text
https://server.kubernetes.local:6443
```

which resolves through the lab host configuration to:

```text
192.168.56.20
```

---

## Verify API Server Connectivity

Before configuring `kubectl`, verify that the jumpbox can reach the API server and validate its TLS certificate:

```bash
curl \
  --cacert "$HOME/kubernetes-pki/ca.crt" \
  https://server.kubernetes.local:6443/version
```

The running cluster returned:

```json
{
  "major": "1",
  "minor": "32",
  "gitVersion": "v1.32.3",
  "platform": "linux/arm64"
}
```

This validates:

```text
jumpbox
   |
   | DNS
   v
server.kubernetes.local
   |
   | 192.168.56.20:6443
   v
kube-apiserver
   |
   | TLS verification
   v
Kubernetes CA
```

Unlike an insecure connectivity test, this command uses:

```text
--cacert
```

without disabling TLS verification.

---

## Existing kubectl Configuration

Before creating the administrative configuration, verify that an existing default kubeconfig will not be overwritten:

```bash
ls -la ~/.kube
```

Then:

```bash
test -f ~/.kube/config && \
  kubectl config view --kubeconfig="$HOME/.kube/config" || \
  echo "No existing ~/.kube/config"
```

For this lab, no existing default configuration was present:

```text
No existing ~/.kube/config
```

---

## Create the Administrative Cluster Entry

Configure the Kubernetes cluster:

```bash
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority="$HOME/kubernetes-pki/ca.crt" \
  --embed-certs=true \
  --server=https://server.kubernetes.local:6443
```

This creates a cluster entry containing:

```text
Cluster name:
  kubernetes-the-hard-way

API endpoint:
  https://server.kubernetes.local:6443

Certificate Authority:
  Kubernetes CA
```

The CA certificate is embedded directly into the kubeconfig.

---

## Create the Administrative Identity

Configure the `admin` user:

```bash
kubectl config set-credentials admin \
  --client-certificate="$HOME/kubernetes-pki/admin.crt" \
  --client-key="$HOME/kubernetes-pki/admin.key" \
  --embed-certs=true
```

The resulting user entry contains the administrative client certificate and private key.

Conceptually:

```text
admin
  |
  +-- admin.crt
  |
  +-- admin.key
  |
  v
Kubernetes administrative identity
```

Because the credentials are embedded, the resulting kubeconfig does not depend on the original PKI file paths during normal use.

The kubeconfig must therefore be treated as a sensitive credential.

---

## Create the kubectl Context

Associate the cluster with the administrative identity:

```bash
kubectl config set-context kubernetes-the-hard-way \
  --cluster=kubernetes-the-hard-way \
  --user=admin
```

Then activate it:

```bash
kubectl config use-context kubernetes-the-hard-way
```

The resulting configuration is:

```text
~/.kube/config
      |
      +-- cluster
      |      |
      |      +-- kubernetes-the-hard-way
      |      +-- server.kubernetes.local:6443
      |      +-- embedded CA
      |
      +-- user
      |      |
      |      +-- admin
      |      +-- embedded admin certificate
      |      +-- embedded admin private key
      |
      +-- context
             |
             +-- kubernetes-the-hard-way
                     |
                     +-- cluster
                     +-- admin
```

---

## Protect the Configuration

Because the kubeconfig contains embedded private-key material, restrict access to the owner:

```bash
chmod 600 "$HOME/.kube/config"
```

The administrative kubeconfig must not be committed to Git.

The project `.gitignore` excludes:

```text
*.kubeconfig
```

The default configuration is also maintained only inside the jumpbox home directory rather than the repository.

---

## Verify the Active Context

List available contexts:

```bash
kubectl config get-contexts
```

The configured context is:

```text
CURRENT   NAME                      CLUSTER                   AUTHINFO
*         kubernetes-the-hard-way   kubernetes-the-hard-way   admin
```

Verify the current context directly:

```bash
kubectl config current-context
```

Expected:

```text
kubernetes-the-hard-way
```

---

## Verify Client and Server Versions

Run:

```bash
kubectl version
```

The completed lab reported:

```text
Client Version: v1.32.3
Kustomize Version: v5.5.0
Server Version: v1.32.3
```

This confirms that the local `kubectl` client can successfully authenticate to and communicate with the remote API server.

---

## Verify Remote Cluster Access

List the Kubernetes Nodes:

```bash
kubectl get nodes -o wide
```

The cluster reported:

```text
NAME     STATUS   VERSION   INTERNAL-IP
node-0   Ready    v1.32.3   192.168.56.50
node-1   Ready    v1.32.3   192.168.56.60
```

Both nodes use:

```text
containerd://2.1.0-beta.0
```

and run:

```text
Ubuntu 24.04.3 LTS
```

This verifies the complete administrative path:

```text
kubectl
   |
   | default configuration
   v
~/.kube/config
   |
   | admin certificate
   v
server.kubernetes.local:6443
   |
   v
kube-apiserver
   |
   v
Kubernetes cluster
   |
   +-- node-0   Ready
   |
   +-- node-1   Ready
```

---

## Relationship to Earlier Kubeconfig Generation

Earlier in the lab, an administrative kubeconfig was generated manually under:

```text
/home/vagrant/kubernetes-kubeconfigs/admin.kubeconfig
```

It was used explicitly:

```bash
kubectl \
  --kubeconfig="$HOME/kubernetes-kubeconfigs/admin.kubeconfig" \
  get nodes
```

That configuration proved the administrative identity and API endpoint worked.

This phase establishes the conventional default configuration used automatically by `kubectl`:

```text
Earlier

admin.kubeconfig
      |
      | --kubeconfig
      v
kubectl


Remote-access phase

~/.kube/config
      |
      | automatic lookup
      v
kubectl
```

The two phases therefore serve different purposes:

```text
Kubeconfig generation
        |
        +-- understand and validate credentials
        |
        v
Remote kubectl configuration
        |
        +-- establish normal administrative workflow
```

---

## Manual vs Automated Responsibility

This phase remains manual.

The administrative kubeconfig contains privileged credentials and configures the interactive administration environment on the jumpbox.

Keeping this step manual preserves the Kubernetes The Hard Way learning objective:

```text
Administrative PKI
       |
       v
Build kubeconfig manually
       |
       v
Understand cluster/user/context
       |
       v
Verify remote access
```

There is currently no Ansible role responsible for creating `~/.kube/config`.

---

## Verification Summary

At completion of this phase:

```text
API TLS connectivity                  ✓
Administrative cluster entry          ✓
Administrative identity               ✓
Default kubectl context               ✓
~/.kube/config permissions            ✓
Client/server communication           ✓
node-0 Ready                          ✓
node-1 Ready                          ✓
```

The jumpbox can now administer the cluster using standard commands:

```bash
kubectl get nodes
```

without explicitly specifying a kubeconfig.

---

## Next Phase

Remote administrative access is complete.

The next Kubernetes The Hard Way milestone is:

```text
Provisioning Pod Network Routes
```

The workers currently own independent Pod CIDRs:

```text
node-0 -> 10.200.0.0/24
node-1 -> 10.200.1.0/24
```

The next phase establishes routing between those networks so Pods on different workers can communicate across the cluster.