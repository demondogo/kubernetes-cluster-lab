# Ansible Bootstrap

## Purpose

Vagrant creates the virtual infrastructure for the Kubernetes lab. Ansible is responsible for configuring those machines.

This separation keeps the responsibilities clear:

```text
Vagrant -> infrastructure
Ansible -> configuration
Kubernetes -> cluster
```

## Python Environment

Ansible is installed inside a project-local Python virtual environment.

Create the environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Install project dependencies:

```bash
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

The project currently pins:

```text
ansible==14.3.0
```

## Inventory Structure

The Ansible layout is:

```text
ansible/
├── ansible.cfg
├── inventory/
│   ├── lab.yml
│   ├── group_vars/
│   │   ├── all.yml
│   │   ├── control_plane.yml
│   │   └── workers.yml
│   └── host_vars/
│       ├── server.yml
│       ├── node-0.yml
│       └── node-1.yml
├── playbooks/
└── roles/
```

The inventory defines machine membership.

`group_vars` defines configuration shared by groups of machines.

`host_vars` defines machine-specific configuration such as node IP addresses and worker pod CIDRs.

## Vagrant SSH Integration

The host may not have direct connectivity to the VirtualBox private cluster network.

Vagrant already provides reliable SSH connectivity through NAT and forwarded ports.

Generate an SSH configuration:

```bash
vagrant ssh-config > .vagrant/ssh-config
```

The generated file contains entries similar to:

```text
Host jumpbox
  HostName 127.0.0.1
  User vagrant
  Port 2222
  IdentityFile ...
```

Ansible uses this file rather than duplicating Vagrant's SSH ports or private-key locations in inventory.

The Ansible SSH configuration points to:

```ini
[ssh_connection]
ssh_args = -F ../.vagrant/ssh-config
```

## Connectivity Verification

From the `ansible/` directory:

```bash
ansible-inventory --graph
```

Verify connectivity:

```bash
ansible all -m ping
```

Verify privilege escalation:

```bash
ansible all -b -m command -a 'id'
```

The command should execute as:

```text
uid=0(root)
```

## Common Role

The `common` role establishes the operating-system baseline required by all Kubernetes lab machines.

Responsibilities include:

* Base operating-system packages
* Cluster entries in `/etc/hosts`
* Required kernel modules
* Kubernetes networking sysctl parameters

The bootstrap playbook applies the role to every machine.

```bash
ansible-playbook playbooks/bootstrap.yml
```

## Idempotency

Configuration should be idempotent.

After the initial successful run:

```bash
ansible-playbook playbooks/bootstrap.yml
```

running the same playbook again should result in:

```text
changed=0
failed=0
```

for all machines.

This is an important distinction between configuration management and imperative provisioning scripts: the playbook describes the desired state rather than a sequence of commands that must only be executed once.
