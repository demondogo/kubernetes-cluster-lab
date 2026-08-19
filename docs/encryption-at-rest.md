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

> **Rebuild note:** The encryption key and `encryption-config.yaml` are generated runtime secrets and are intentionally excluded from Git. After recreating the lab VMs, regenerate the encryption configuration on the jumpbox before running `playbooks/distribute-encryption-config.yml`.

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

The encryption configuration uses a 32-byte randomly generated symmetric key.

```text
32 bytes
    |
    v
256 bits
    |
    v
AES-CBC encryption key
```

The key must:

- Be generated from cryptographically random data
- Remain confidential
- Never be committed to Git
- Never be exposed in logs or documentation
- Be available to the API server for decryption of previously encrypted data

---

# Manual Encryption Configuration Generation

## Create the Workspace

The encryption configuration is generated on the jumpbox.

SSH to the jumpbox:

```bash
vagrant ssh jumpbox
```

Create the workspace:

```bash
mkdir -p ~/kubernetes-encryption
cd ~/kubernetes-encryption
```

Verify the working directory:

```bash
pwd
```

Expected:

```text
/home/vagrant/kubernetes-encryption
```

---

## Generate the Encryption Key

Generate 32 random bytes and encode them as base64:

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
```

Do not print the value.

Verify that the variable contains data without displaying it:

```bash
test -n "${ENCRYPTION_KEY}" && echo "Encryption key generated"
```

Expected:

```text
Encryption key generated
```

Verify the decoded key length:

```bash
printf '%s' "${ENCRYPTION_KEY}" | base64 -d | wc -c
```

Expected:

```text
32
```

This confirms the generated key contains 32 bytes of random data.

---

## Generate `encryption-config.yaml`

Create the Kubernetes EncryptionConfiguration:

```bash
cat > encryption-config.yaml <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
```

Immediately remove the encryption key from the current shell environment:

```bash
unset ENCRYPTION_KEY
```

Verify that it is no longer defined:

```bash
test -z "${ENCRYPTION_KEY:-}" && echo "Encryption key shell variable cleared"
```

Expected:

```text
Encryption key shell variable cleared
```

The key still exists inside `encryption-config.yaml`, so that file must now be treated as a sensitive credential.

---

## Protect the Generated File

Set restrictive permissions:

```bash
chmod 600 encryption-config.yaml
```

Verify:

```bash
ls -l encryption-config.yaml
```

Expected permissions:

```text
-rw-------
```

Do not use:

```bash
cat encryption-config.yaml
```

for routine verification because that would display the encryption key.

The generated file should exist at:

```text
/home/vagrant/kubernetes-encryption/encryption-config.yaml
```

---

## Verify the Artifact Without Exposing the Key

Verify the file exists:

```bash
test -f encryption-config.yaml && echo "Encryption configuration exists"
```

Expected:

```text
Encryption configuration exists
```

Verify its permissions:

```bash
stat -c '%a %U %G %n' encryption-config.yaml
```

Expected:

```text
600 vagrant vagrant encryption-config.yaml
```

The file can also be hashed for later integrity verification:

```bash
sha256sum encryption-config.yaml
```

The hash may be displayed safely; it does not reveal the encryption key.

---

## Encryption Configuration

The generated file uses the Kubernetes `EncryptionConfiguration` API.

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

If configured as:

```text
identity
   |
   v
aescbc
```

new resources would be written without encryption because Kubernetes uses the first provider for writes.

---

## Generated Artifact

The encryption configuration exists on the jumpbox at:

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

# Distribution

After manual generation and validation, Ansible handles distribution.

Run from the `ansible/` directory:

```bash
ansible-playbook playbooks/distribute-encryption-config.yml
```

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

The expected source is:

```text
/home/vagrant/kubernetes-encryption/encryption-config.yaml
```

If the generated file does not exist there, the playbook intentionally fails before attempting distribution.

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

This prevents a control-plane play using:

```yaml
become: true
```

from attempting unnecessary `sudo` operations on the Ansible controller.

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

After the initial installation, running:

```bash
ansible-playbook playbooks/distribute-encryption-config.yml
```

again should leave the installed server configuration unchanged:

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

# Verification

## File Installation

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

---

## Worker Isolation

Verify that workers did not receive the encryption configuration:

```bash
ansible workers -b -m shell -a \
  'test ! -e /var/lib/kubernetes/encryption-config.yaml && echo "encryption config absent"'
```

Both workers should report:

```text
encryption config absent
```

---

## Integrity

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

This verifies:

```text
jumpbox source
      |
      | fetch/copy
      v
server destination
      |
      v
identical contents
```

---

## Runtime Verification

Successful distribution proves that the API server will have access to the encryption configuration.

It does **not yet prove that Kubernetes data is being encrypted in etcd**.

That verification requires a running API server and etcd.

After the control plane is operational, the lab will:

1. Create a Kubernetes Secret through the API server.
2. Retrieve the Secret normally through the Kubernetes API.
3. Read the corresponding raw value directly from etcd.
4. Verify that the plaintext Secret value is not present in the stored etcd data.
5. Verify the Kubernetes encryption provider prefix.

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

The raw etcd value is expected to contain a prefix similar to:

```text
k8s:enc:aescbc:v1:key1
```

This runtime test verifies that encryption at rest is functioning rather than merely configured.

---

## Security Properties

At completion of this phase:

- The encryption key is generated from cryptographically random data.
- The key is 32 bytes / 256 bits.
- The key is not stored in Git.
- The generated configuration is excluded by `.gitignore`.
- The generated file is mode `0600`.
- Only the API server host receives the encryption configuration.
- Worker nodes do not receive the encryption key.
- The destination is root-owned and mode `0600`.
- Temporary controller-side copies are removed after distribution.
- Source and destination integrity are verified using SHA-256.
- Runtime encryption is validated after etcd and the API server are operational.

---

## Rebuild Procedure

The encryption configuration is runtime state and is intentionally not stored in Git.

If the virtual machines are destroyed, regenerate it rather than attempting to recover the old key.

For a completely rebuilt cluster with a new/empty etcd datastore, generating a new encryption key is expected.

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
Distribute kubeconfigs
     |
     v
Generate new encryption key
     |
     v
Create encryption-config.yaml
     |
     v
Distribute encryption configuration
```

On the jumpbox:

```bash
mkdir -p ~/kubernetes-encryption
cd ~/kubernetes-encryption

ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

printf '%s' "${ENCRYPTION_KEY}" | base64 -d | wc -c
```

Create the configuration:

```bash
cat > encryption-config.yaml <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
```

Clear the temporary shell variable and protect the file:

```bash
unset ENCRYPTION_KEY
chmod 600 encryption-config.yaml
```

Verify:

```bash
test -f encryption-config.yaml &&
stat -c '%a %U %G %n' encryption-config.yaml
```

Then, from the Ansible controller:

```bash
ansible-playbook playbooks/distribute-encryption-config.yml
```

Do not reuse this procedure to rotate the encryption key of an existing cluster containing encrypted etcd data without first planning key rotation and migration. Existing encrypted resources must remain decryptable.

---

## Next Phase

With the encryption configuration installed on the control-plane server, the Kubernetes API server has the configuration required to encrypt sensitive resources before they are persisted.

The next infrastructure dependency is etcd.

Runtime encryption will be validated after both etcd and the Kubernetes API server are operational.

See [`architecture.md`](architecture.md) for the current overall project status.