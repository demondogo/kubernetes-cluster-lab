# Kubernetes Cluster Lab Architecture

## Overview

This project builds a multi-node Kubernetes lab inspired by Kelsey Hightower's *Kubernetes The Hard Way*.

The project deliberately separates infrastructure provisioning from configuration management:

* **Vagrant** creates virtual machines and networking.
* **VirtualBox** provides virtualization.
* **Ansible** configures the guest operating systems and distributes cluster configuration.
* **Kubernetes The Hard Way** provides the underlying Kubernetes bootstrap process and learning path.

The goal is to understand each Kubernetes component and its dependencies before progressively automating repeatable operations.

## Cluster Topology

| Host      | Address         | Role                          |
| --------- | --------------- | ----------------------------- |
| `jumpbox` | `192.168.56.10` | Management and administration |
| `server`  | `192.168.56.20` | Kubernetes control plane      |
| `node-0`  | `192.168.56.50` | Kubernetes worker             |
| `node-1`  | `192.168.56.60` | Kubernetes worker             |

Worker pod networks:

| Worker   | Pod CIDR        |
| -------- | --------------- |
| `node-0` | `10.200.0.0/24` |
| `node-1` | `10.200.1.0/24` |

## Infrastructure Boundary

Vagrant is responsible for creating infrastructure only:

* Virtual machines
* Hostnames
* CPU and memory allocation
* Private networking
* Initial SSH access

Vagrant does **not** install or configure Kubernetes.

Guest configuration is delegated to Ansible.

## Configuration Management

Ansible connects to the Vagrant-managed SSH endpoints and configures the virtual machines.

Vagrant's generated SSH configuration is exported to:

```text
.vagrant/ssh-config
```

Ansible uses this configuration for management connectivity.

This separates management connectivity from Kubernetes cluster networking.

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

### Kubernetes Network

```text
jumpbox  192.168.56.10
              |
              |
server   192.168.56.20
          /        \
         /          \
node-0 .50          node-1 .60
```

The `192.168.56.0/24` network is used for communication between Kubernetes cluster machines.

## Architecture Support

The lab is designed to avoid coupling Kubernetes configuration to the host operating system or CPU architecture.

The Vagrant box:

```text
bento/ubuntu-24.04
```

provides the guest environment.

The guest architecture is discovered independently.

For example:

```text
Apple Silicon host
       |
       v
Ubuntu ARM64 guest
       |
       v
aarch64
       |
       v
arm64 Kubernetes artifacts
```

and:

```text
Intel/AMD host
       |
       v
Ubuntu AMD64 guest
       |
       v
x86_64
       |
       v
amd64 Kubernetes artifacts
```

Architecture-specific Kubernetes binaries are selected according to the architecture detected inside the guest rather than assumptions about the host platform.

## Automation Philosophy

Automation is introduced after the underlying operation is understood.

The general workflow is:

```text
Perform manually
      |
      v
Understand behavior
      |
      v
Identify repetitive operation
      |
      v
Automate with Ansible
```

For example, Kubernetes PKI certificates are generated manually so their identities and trust relationships remain visible.

Ansible then handles the repetitive and error-prone task of distributing the correct certificates to the correct machines.
