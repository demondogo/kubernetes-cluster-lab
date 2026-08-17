# Kubernetes Encryption at Rest

## Overview

Kubernetes stores cluster state in etcd. This includes potentially sensitive resources such as Kubernetes Secrets.

TLS protects communication between Kubernetes components while data is moving across the network, but TLS does not protect data after it has been written to etcd.

Encryption at rest addresses this separate security boundary.

```text
TLS / PKI
Protects data in transit

client
   |
   | encrypted connection
   v
API server


Encryption at Rest
Protects stored data

API server
   |
   | encrypt
   v
etcd
```

This lab configures the Kubernetes API server to encrypt Secret resources before they are persisted to etcd.

---

## Encryption Boundary

Encryption and decryption are performed by the Kubernetes API server.

etcd does not receive or manage the encryption key.

```text
Client
   |
   v
Kubernetes API Server
   |
   | encryption-config.yaml
   |
   | AES encryption
   v
etcd
```

This means the encryption configuration is required only by the control-plane API server.

Worker nodes do not receive it.

---

## Encryption Key

A 32-byte random key is generated on the jumpbox:

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
```

The decoded key length can be verified without displaying the key:

```bash
printf '%s' "${ENCRYPTION_KEY}" | base64 -d | wc -c
```

Expected result:

```text
32
```

The resulting 256-bit key is used by the API server's encryption provider.

The key itself must not be committed to Git or exposed in logs.

---

## Encryption Configuration

The generated configuration uses the Kubernetes `EncryptionConfiguration` API.

Conceptually:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration

resources:
  - resources:
      - secrets

    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <symmetric-key>

      - identity: {}
```

The actual configuration containing key material is generated outside the Git repository.

---

## Provider Ordering

Provider order is significant.

The configured order is:

```text
1. aescbc
2. identity
```

For new writes, Kubernetes uses the first provider.

```text
Secret
   |
   v
API server
   |
   v
AES-CBC
   |
   v
ciphertext
   |
   v
etcd
```

This ensures newly written Secret resources are encrypted before being persisted.

### Identity Provider

The `identity` provider performs no encryption.

It is placed after the encryption provider so the API server can continue reading data that may have previously been stored without encryption.

Conceptually:

```text
READ FROM ETCD
      |
      v
Try AES-CBC
   |
   +-- decryptable --> plaintext resource
   |
   +-- not encrypted
            |
            v
        identity
            |
            v
     plaintext resource
```

The identity provider must not be placed first.

If it were first:

```text
identity
   |
   v
aescbc
```

new resources would be written without encryption because Kubernetes uses the first provider for writes.

---

## Generated Artifact

The encryption configuration is generated on the jumpbox at:

```text
/home/vagrant/kubernetes-encryption/encryption-config.yaml
```

The file contains symmetric encryption key material and is protected with:

```text
0600
```

It is explicitly excluded from Git by `.gitignore`.

The repository stores only the automation required to distribute the configuration.

---

## Distribution Architecture

The encryption configuration follows the same temporary transport model used for other sensitive cluster credentials.

```text
jumpbox
   |
   | fetch
   v
temporary Ansible controller staging
   |
   | copy
   v
server
   |
   v
temporary staging removed
```

Unlike certificates and kubeconfigs, the encryption configuration is distributed only to the control-plane server.

```text
                         jumpbox
                            |
                            |
                            v
                          Ansible
                            |
                            v
                          server
                            |
                            v
             /var/lib/kubernetes/
                encryption-config.yaml


node-0    X
node-1    X
```

Workers have no reason to possess the encryption key.

---

## Ansible Implementation

Encryption configuration distribution is implemented with a dedicated Ansible role:

```text
roles/encryption/
├── defaults/
│   └── main.yml
└── tasks/
    ├── main.yml
    ├── stage.yml
    ├── install.yml
    └── cleanup.yml
```

The corresponding playbook orchestrates the workflow:

```text
playbooks/distribute-encryption-config.yml
```

The playbook performs three operations:

```text
jumpbox
   |
   +--> stage

control_plane
   |
   +--> install

localhost
   |
   +--> cleanup
```

The role handles implementation while the playbook determines where each operation runs.

---

## Stage

The staging phase:

1. Creates a temporary directory on the Ansible controller.
2. Verifies that `encryption-config.yaml` exists on the jumpbox.
3. Fetches the file from the jumpbox to the controller.

The temporary directory uses restrictive permissions.

The encryption configuration contents are suppressed from normal Ansible output.

---

## Install

The installation phase runs only against the `control_plane` inventory group.

The destination is:

```text
/var/lib/kubernetes/encryption-config.yaml
```

The installed file is configured as:

```text
owner: root
group: root
mode: 0600
```

Privilege escalation is required on the server because `/var/lib/kubernetes` is root-owned.

Controller-side validation explicitly disables privilege escalation when delegated to localhost.

This prevents a control-plane play using `become: true` from attempting unnecessary `sudo` operations on the Ansible controller.

---

## Cleanup

After installation, the temporary controller-side staging directory is removed.

This intentionally leaves no persistent copy of the encryption key on the Ansible controller.

```text
Before execution:

controller
└── no staged encryption config


During execution:

controller
└── temporary staging
    └── encryption-config.yaml


After execution:

controller
└── no staged encryption config
```

---

## Idempotency

Persistent cluster state is idempotent.

After the initial installation, running the distribution playbook again should leave the server configuration unchanged:

```text
Install encryption configuration
changed=0
```

The staging workflow is intentionally ephemeral and therefore reports changes on each execution.

```text
Create staging     changed
Fetch config       changed
Install config     unchanged
Cleanup staging    changed
```

This is expected.

Removing sensitive temporary material is preferred over retaining it solely to make the complete playbook report `changed=0`.

---

## Verification

### File Installation

Verify the destination without displaying its contents:

```bash
ansible server -b -m stat -a \
  'path=/var/lib/kubernetes/encryption-config.yaml'
```

The expected state is:

```text
exists: true
owner: root
group: root
mode: 0600
```

### Worker Isolation

Verify that workers did not receive the encryption configuration:

```bash
ansible workers -b -m shell -a \
  'test ! -e /var/lib/kubernetes/encryption-config.yaml && echo "encryption config absent"'
```

Both workers should report:

```text
encryption config absent
```

### Integrity

The source and destination can be compared without exposing the encryption key.

Jumpbox:

```bash
ansible jumpbox -m command -a \
  'sha256sum /home/vagrant/kubernetes-encryption/encryption-config.yaml'
```

Control plane:

```bash
ansible server -b -m command -a \
  'sha256sum /var/lib/kubernetes/encryption-config.yaml'
```

The SHA-256 hashes must match.

---

## Runtime Verification

Successful distribution proves that the API server will have access to the encryption configuration.

It does **not yet prove that Kubernetes data is being encrypted in etcd**.

That verification requires a running API server and etcd.

After the control plane is operational, the lab will:

1. Create a Kubernetes Secret through the API server.
2. Retrieve the Secret normally through the Kubernetes API.
3. Read the corresponding raw value directly from etcd.
4. Verify that the plaintext secret value is not present in the stored etcd data.

The expected flow is:

```text
kubectl
   |
   | create Secret
   v
API server
   |
   | AES-CBC encryption
   v
etcd
   |
   | direct etcd read
   v
encrypted stored value
```

This runtime test will validate that encryption at rest is functioning rather than merely configured.

---

## Security Properties

At completion of this phase:

- The encryption key is generated from cryptographically random data.
- The key is not stored in Git.
- The generated configuration is excluded by `.gitignore`.
- Only the API server host receives the encryption configuration.
- Worker nodes do not receive the encryption key.
- The destination is root-owned and mode `0600`.
- Temporary controller-side copies are removed after distribution.
- Source and destination integrity are verified using SHA-256.
- Runtime encryption will be validated after etcd and the API server are operational.

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
etcd                               NEXT
Control plane                      PENDING
Workers                            PENDING
Pod networking                     PENDING
CoreDNS                            PENDING
```

The next phase bootstraps etcd, the persistent datastore used by the Kubernetes control plane.