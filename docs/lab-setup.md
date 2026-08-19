# Kubernetes Cluster Lab Setup

## Overview

This document describes how to create the Kubernetes lab environment from a fresh clone of the repository.

The lab is designed so that virtual machines and local development environments are disposable. Persistent configuration is stored in Git, while generated runtime state such as virtual machines, Python virtual environments, certificates, kubeconfigs, and encryption keys is intentionally excluded.

The initial bootstrap path is:

```text
Git repository
      |
      v
Python virtual environment
      |
      v
Vagrant infrastructure
      |
      v
Vagrant SSH configuration
      |
      v
Ansible connectivity
      |
      v
Ansible bootstrap
      |
      v
Kubernetes lab baseline
```

---

## Requirements

The host system requires:

- Git
- Python 3
- Vagrant 2.3+
- VirtualBox
- Approximately 8 GB of available RAM

The default Vagrant box is:

```text
bento/ubuntu-24.04
```

The lab has been designed to support both AMD64 and ARM64 guest environments when compatible Vagrant/VirtualBox artifacts are available.

### Tested Platforms

| Host | Provider | Guest Architecture | Status |
|---|---|---|---|
| macOS Apple Silicon | VirtualBox | ARM64 / `aarch64` | Tested |
| macOS Intel | VirtualBox | AMD64 / `x86_64` | Planned validation |

Support should only be considered tested after the complete lab workflow has been validated on that platform.

---

## Clone the Repository

Clone the project:

```bash
git clone https://github.com/omaraouk/kubernetes-cluster-lab
cd kubernetes-cluster-lab
```

Verify the repository:

```bash
git status
```

---

## Python Virtual Environment

Ansible is installed in a project-local Python virtual environment rather than globally on the host.

Create the environment:

```bash
python3 -m venv .venv
```

Activate it:

```bash
source .venv/bin/activate
```

The shell prompt should indicate that the virtual environment is active.

Verify the Python interpreter:

```bash
which python
```

The path should resolve inside:

```text
kubernetes-cluster-lab/.venv/
```

Upgrade pip:

```bash
python -m pip install --upgrade pip
```

Install the project dependencies:

```bash
python -m pip install -r requirements.txt
```

Verify Ansible:

```bash
which ansible
ansible --version
```

The Ansible executable should also resolve inside:

```text
kubernetes-cluster-lab/.venv/
```

The `.venv/` directory is intentionally excluded from Git.

The virtual environment is disposable; `requirements.txt` is the source-controlled definition required to recreate it.

---

## Create the Virtual Machines

Vagrant is responsible only for infrastructure:

- Virtual machine creation
- CPU allocation
- Memory allocation
- Hostnames
- Private networking
- Bootstrap SSH connectivity

Create all four machines:

```bash
vagrant up
```

The lab contains:

| Machine | Address | Role |
|---|---|---|
| `jumpbox` | `192.168.56.10` | Management node |
| `server` | `192.168.56.20` | Kubernetes control plane |
| `node-0` | `192.168.56.50` | Worker |
| `node-1` | `192.168.56.60` | Worker |

Check their state:

```bash
vagrant status
```

All four should report:

```text
running (virtualbox)
```

---

## Verify Guest Architecture

Verify each machine after creation:

```bash
for vm in jumpbox server node-0 node-1; do
  echo "=== ${vm} ==="

  vagrant ssh "${vm}" -c \
    'printf "hostname=%s arch=%s\n" "$(hostname)" "$(uname -m)"'
done
```

On an ARM64 lab, the expected architecture is:

```text
aarch64
```

On an AMD64 lab, the expected architecture is:

```text
x86_64
```

Kubernetes binary architecture is selected according to the architecture detected inside the guest rather than assumptions about the host machine.

---

## Vagrant SSH Configuration

Ansible does not connect directly to the `192.168.56.0/24` network from the host.

Instead, it uses Vagrant's existing SSH connectivity through VirtualBox NAT.

Generate an SSH configuration:

```bash
vagrant ssh-config > .vagrant/ssh-config
```

The resulting file contains entries similar to:

```text
Host jumpbox
  HostName 127.0.0.1
  User vagrant
  Port 2222
  IdentityFile ...
```

The forwarded ports and generated private keys are implementation details managed by Vagrant.

They are not duplicated in the Ansible inventory.

### Important

Regenerate `.vagrant/ssh-config` whenever the virtual machines are recreated:

```bash
vagrant ssh-config > .vagrant/ssh-config
```

New VMs may receive different SSH keys or forwarded ports.

The entire `.vagrant/` directory is excluded from Git.

---

## Verify SSH Connectivity

Before involving Ansible, verify that the generated SSH configuration works:

```bash
ssh -F .vagrant/ssh-config jumpbox hostname
ssh -F .vagrant/ssh-config server hostname
ssh -F .vagrant/ssh-config node-0 hostname
ssh -F .vagrant/ssh-config node-1 hostname
```

Expected output:

```text
jumpbox
server
node-0
node-1
```

This confirms that the management path is functional:

```text
Host
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

---

## Ansible Working Directory

The project's `ansible.cfg` resides inside:

```text
ansible/
```

Run Ansible commands from this directory:

```bash
cd ansible
```

Verify that Ansible discovers the project configuration:

```bash
ansible --version
```

The reported configuration file should point to:

```text
kubernetes-cluster-lab/ansible/ansible.cfg
```

---

## Verify the Inventory

Display the inventory:

```bash
ansible-inventory --graph
```

The logical topology should contain:

```text
jumpboxes
└── jumpbox

control_plane
└── server

workers
├── node-0
└── node-1
```

Inventory-specific variables are stored alongside the inventory:

```text
inventory/
├── lab.yml
├── group_vars/
└── host_vars/
```

---

## Verify Ansible Connectivity

Run:

```bash
ansible all -m ping
```

All four machines should report:

```text
SUCCESS
```

This verifies:

```text
Ansible
   |
   v
Vagrant SSH configuration
   |
   +--> jumpbox
   +--> server
   +--> node-0
   └--> node-1
```

---

## Verify Privilege Escalation

Ansible connects using Vagrant's normal SSH user and uses privilege escalation when root access is required.

Verify:

```bash
ansible all -b -m command -a 'id'
```

Each machine should report:

```text
uid=0(root)
```

Direct root SSH access is not required.

---

## Bootstrap the Operating Systems

Apply the common configuration and jumpbox setup:

```bash
ansible-playbook playbooks/bootstrap.yml
```

The bootstrap process establishes the operating-system baseline required by the lab.

Current responsibilities include:

- Base operating-system packages
- `/etc/hosts` cluster resolution
- Required kernel modules
- Kubernetes networking sysctl parameters
- Jumpbox management packages
- Kubernetes The Hard Way reference repository
- Cluster machine inventory

---

## Verify Idempotency

Run the bootstrap playbook again:

```bash
ansible-playbook playbooks/bootstrap.yml
```

Persistent configuration should report:

```text
changed=0
failed=0
unreachable=0
```

for all machines when no configuration has changed.

This verifies that Ansible describes the desired state rather than depending on one-time provisioning behavior.

---

## Verify Cluster Name Resolution

The common role configures the Kubernetes lab hostnames.

Verify:

```bash
ansible all -m command -a \
  'getent hosts server.kubernetes.local'
```

The expected control-plane mapping is:

```text
192.168.56.20 server.kubernetes.local server
```

The Kubernetes API server certificate and kubeconfigs use:

```text
server.kubernetes.local
```

as the canonical remote control-plane endpoint.

---

## Fresh Rebuild Workflow

The virtual machines are intentionally disposable.

A complete infrastructure/bootstrap rebuild begins with:

```bash
source .venv/bin/activate

vagrant up

vagrant ssh-config > .vagrant/ssh-config

cd ansible

ansible all -m ping

ansible-playbook playbooks/bootstrap.yml
```

If `.venv/` does not exist, recreate it first:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

---

## What a VM Rebuild Does Not Preserve

The following items are runtime state and are intentionally not stored in Git:

- VirtualBox virtual machines
- Vagrant-generated SSH credentials
- Python virtual environment
- Generated Kubernetes PKI
- Generated kubeconfigs
- Encryption-at-rest key/configuration
- etcd datastore contents

The repository stores the configuration and automation required to recreate the environment, not the generated credentials or runtime state themselves.

At the current stage of the project, some Kubernetes security artifacts are still generated manually as part of the Kubernetes The Hard Way learning process.

As the project evolves, previously understood manual operations may be converted into reproducible automation.

---

## Repository Responsibility Model

The project follows this separation:

```text
Git
 |
 | source of truth
 v
Vagrant
 |
 | infrastructure
 v
Virtual machines
 |
 v
Ansible
 |
 | desired configuration
 v
Kubernetes prerequisites
 |
 v
Kubernetes The Hard Way
```

More specifically:

```text
Vagrant
    "Give me machines."

Ansible
    "Configure those machines."

Kubernetes
    "Run the cluster."

Git
    "Preserve how to reproduce it."
```

---

## Troubleshooting

### Ansible reports `No inventory was parsed`

Ensure commands are being executed from:

```text
kubernetes-cluster-lab/ansible/
```

Verify:

```bash
ansible --version
```

and confirm the correct `ansible.cfg` is loaded.

### Ansible attempts to connect to `192.168.56.x`

The inventory should not use the Kubernetes private IP addresses as `ansible_host`.

Ansible management connectivity is provided by Vagrant's SSH configuration.

Regenerate it:

```bash
vagrant ssh-config > .vagrant/ssh-config
```

Then verify the Ansible SSH configuration references that file.

### SSH configuration contains invalid Vagrant text

Do not print informational banners to standard output from the `Vagrantfile`.

Commands such as:

```bash
vagrant ssh-config
```

produce machine-readable output that may be redirected into other tools.

Any diagnostic output from the `Vagrantfile` can corrupt that output.

### Virtual machines were deleted after a VirtualBox update

The machines are disposable.

Recreate them:

```bash
vagrant up
```

Regenerate SSH configuration:

```bash
vagrant ssh-config > .vagrant/ssh-config
```

Then reapply Ansible:

```bash
cd ansible
ansible all -m ping
ansible-playbook playbooks/bootstrap.yml
```

Do not attempt to recover a deleted VM when the environment can be reproduced from source-controlled infrastructure and configuration.

---

## Next Steps

Once the base lab is operational, continue through the Kubernetes bootstrap phases documented under `docs/`.

The project currently progresses through:

```text
Lab infrastructure
      |
      v
Ansible bootstrap
      |
      v
Architecture-specific binaries
      |
      v
PKI
      |
      v
Kubeconfigs
      |
      v
Encryption at rest
      |
      v
etcd
      |
      v
Kubernetes control plane
      |
      v
Workers
      |
      v
Pod networking
      |
      v
CoreDNS
```

The lab should be considered reproducible when a fresh host can follow this setup process and reach the same Kubernetes cluster state without depending on configuration stored only inside previous virtual machines.