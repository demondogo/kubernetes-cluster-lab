# Provisioning Pod Network Routes

## Overview

Kubernetes Pods receive addresses from the Pod CIDR assigned to the worker on which they run.

This lab uses:

| Worker | Node Address | Pod CIDR |
|---|---|---|
| `node-0` | `192.168.56.50` | `10.200.0.0/24` |
| `node-1` | `192.168.56.60` | `10.200.1.0/24` |

The CNI configuration created during worker bootstrap establishes the local Pod network on each worker.

At that stage, however, the machines do not know how to reach Pod networks attached to other workers.

Section 11 of Kubernetes The Hard Way addresses this by creating explicit Linux routes between the worker Pod CIDRs.

```text
                  192.168.56.0/24

          node-0                  node-1
      192.168.56.50           192.168.56.60
            |                       |
            |                       |
      10.200.0.0/24           10.200.1.0/24
            |                       |
            +------- routes --------+
```

The routing model is implemented manually first and then persisted with Ansible.

---

## Kubernetes Networking Model

The Kubernetes networking model expects Pods to be able to communicate across nodes.

In this lab, each worker owns an independent Pod network:

```text
node-0
    |
    +-- 192.168.56.50
    |
    +-- cni0
           |
           +-- 10.200.0.0/24


node-1
    |
    +-- 192.168.56.60
    |
    +-- cni0
           |
           +-- 10.200.1.0/24
```

The local CNI bridge tells a worker how to reach its own Pods.

It does not automatically provide a route to the Pod CIDR belonging to another worker.

For example, `node-0` initially knows about:

```text
192.168.56.0/24
```

and its local Pod network, but it has no route describing how traffic destined for:

```text
10.200.1.0/24
```

should reach `node-1`.

---

## Pre-Routing State

Before Section 11, the control plane and workers had no explicit `10.200.x.0/24` routes.

The private cluster network was directly connected through:

```text
eth1
```

with:

```text
server -> 192.168.56.20
node-0 -> 192.168.56.50
node-1 -> 192.168.56.60
```

All three machines therefore share:

```text
192.168.56.0/24
```

This allows the worker node addresses themselves to be used as route next hops.

---

## Required Routes

The required routing table can be derived directly from the worker addresses and Pod CIDRs.

### Control Plane

The control-plane server requires routes to both worker Pod networks:

```text
10.200.0.0/24 via 192.168.56.50
10.200.1.0/24 via 192.168.56.60
```

Conceptually:

```text
                    server
                192.168.56.20
                  /          \
                 /            \
        via .50 /              \ via .60
               v                v
       10.200.0.0/24      10.200.1.0/24
           node-0             node-1
```

### node-0

`node-0` already owns:

```text
10.200.0.0/24
```

and therefore requires only the route to the remote Pod network:

```text
10.200.1.0/24 via 192.168.56.60
```

### node-1

`node-1` already owns:

```text
10.200.1.0/24
```

and requires:

```text
10.200.0.0/24 via 192.168.56.50
```

The complete routing model is:

```text
server
├── 10.200.0.0/24 -> 192.168.56.50
└── 10.200.1.0/24 -> 192.168.56.60

node-0
└── 10.200.1.0/24 -> 192.168.56.60

node-1
└── 10.200.0.0/24 -> 192.168.56.50
```

---

## Manual Route Configuration

Following the Kubernetes The Hard Way learning model, the routes were first created manually.

On the control plane:

```bash
ip route add 10.200.0.0/24 via 192.168.56.50
ip route add 10.200.1.0/24 via 192.168.56.60
```

On `node-0`:

```bash
ip route add 10.200.1.0/24 via 192.168.56.60
```

On `node-1`:

```bash
ip route add 10.200.0.0/24 via 192.168.56.50
```

In the lab these operations were executed through Ansible ad-hoc commands for privileged remote access while preserving the manual nature of the routing operation.

For example:

```bash
ansible node-0 -b -m command -a \
  'ip route add 10.200.1.0/24 via 192.168.56.60'
```

---

## Manual Verification

The resulting routes were inspected with:

```bash
ansible 'control_plane:workers' -b -m shell -a \
  'ip route | grep "^10\.200" || true'
```

The control plane reported:

```text
10.200.0.0/24 via 192.168.56.50 dev eth1
10.200.1.0/24 via 192.168.56.60 dev eth1
```

`node-0` reported:

```text
10.200.1.0/24 via 192.168.56.60 dev eth1
```

`node-1` reported:

```text
10.200.0.0/24 via 192.168.56.50 dev eth1
```

This confirmed that the expected routes had been added to the kernel routing tables.

---

## Kernel Route Selection

The routing configuration was also validated using:

```text
ip route get
```

This verifies the route the Linux kernel would actually select for a destination rather than only confirming that a route exists in the table.

From `server`:

```bash
ip route get 10.200.0.10
```

resolved through:

```text
192.168.56.50
```

and:

```bash
ip route get 10.200.1.10
```

resolved through:

```text
192.168.56.60
```

From `node-0`:

```bash
ip route get 10.200.1.10
```

resolved through:

```text
192.168.56.60
```

From `node-1`:

```bash
ip route get 10.200.0.10
```

resolved through:

```text
192.168.56.50
```

The resulting path selection is:

```text
server -> 10.200.0.x -> node-0
server -> 10.200.1.x -> node-1

node-0 -> 10.200.1.x -> node-1
node-1 -> 10.200.0.x -> node-0
```

---

## Runtime Routes vs Persistent Routes

The manual command:

```bash
ip route add
```

modifies the current kernel routing table.

Those routes are runtime state and are not sufficient as the final lab implementation.

Conceptually:

```text
ip route add
      |
      v
kernel routing table
      |
      v
works now
      |
      X
      |
    reboot
```

The project therefore automates persistent route configuration after the manual routing model has been understood and validated.

This follows the project workflow:

```text
Configure manually
       |
       v
Understand routing
       |
       v
Validate kernel selection
       |
       v
Automate persistence
```

---

## Netplan Ownership

Ubuntu 24.04 uses Netplan for network configuration.

Vagrant already creates:

```text
/etc/netplan/50-vagrant.yaml
```

to configure the private cluster interface.

For example:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth1:
      addresses:
        - 192.168.56.50/24
```

This file belongs to the infrastructure layer and may be regenerated by Vagrant.

Ansible therefore does not modify it.

Instead, Kubernetes Pod routes are managed separately in:

```text
/etc/netplan/60-kubernetes-routes.yaml
```

This establishes a clear ownership boundary:

```text
Vagrant
   |
   +-- 50-vagrant.yaml
          |
          +-- eth1 address


Ansible
   |
   +-- 60-kubernetes-routes.yaml
          |
          +-- Kubernetes Pod routes
```

Netplan merges the configuration when generating the effective network configuration.

---

## Persistent Route Configuration

The control-plane server receives:

```yaml
---
network:
  version: 2
  ethernets:
    eth1:
      routes:
        - to: "10.200.0.0/24"
          via: "192.168.56.50"
        - to: "10.200.1.0/24"
          via: "192.168.56.60"
```

`node-0` receives:

```yaml
---
network:
  version: 2
  ethernets:
    eth1:
      routes:
        - to: "10.200.1.0/24"
          via: "192.168.56.60"
```

`node-1` receives:

```yaml
---
network:
  version: 2
  ethernets:
    eth1:
      routes:
        - to: "10.200.0.0/24"
          via: "192.168.56.50"
```

---

## Inventory-Driven Routing

The route definitions are not hardcoded independently inside the role.

Worker routing information already exists in Ansible inventory.

For `node-0`:

```yaml
node_ip: "192.168.56.50"
pod_cidr: "10.200.0.0/24"
```

For `node-1`:

```yaml
node_ip: "192.168.56.60"
pod_cidr: "10.200.1.0/24"
```

The routing role derives the required routes from these values.

Conceptually:

```text
inventory
   |
   +-- node-0
   |     node_ip
   |     pod_cidr
   |
   +-- node-1
         node_ip
         pod_cidr
            |
            v
   pod_network_routes role
            |
      +-----+-----+
      |           |
      v           v
 destination    next hop
```

The routing rule is:

```text
For every worker:
    Pod CIDR -> worker node IP

Except:
    a worker does not require
    a static route to its own Pod CIDR
```

As a result:

```text
server
  receives routes for both workers

node-0
  excludes node-0
  receives route for node-1

node-1
  excludes node-1
  receives route for node-0
```

This prevents route information from being duplicated across the role and inventory.

---

## Ansible Implementation

Persistent Pod routing uses a dedicated role:

```text
roles/pod_network_routes/
├── defaults/
│   └── main.yml
├── tasks/
│   └── main.yml
└── templates/
    └── 60-kubernetes-routes.yaml.j2
```

The corresponding playbook is:

```text
playbooks/configure-pod-network-routes.yml
```

The role is intentionally separate from the worker role because the control-plane server also requires Pod network routes.

The responsibility boundary is:

```text
worker role
    |
    +-- worker runtime
    +-- kubelet
    +-- kube-proxy
    +-- local CNI


pod_network_routes role
    |
    +-- cluster-wide Pod CIDR routing
```

---

## Netplan Validation

Network configuration changes are validated before they are applied.

The workflow is:

```text
render route configuration
        |
        v
netplan generate
        |
        | validation succeeds
        v
netplan apply
```

This prevents an invalid generated Netplan configuration from being intentionally applied by the role.

The configuration is applied only when the managed route file changes.

---

## Persistent Route Verification

After applying the role, inspect the managed configuration:

```bash
ansible 'control_plane:workers' -b -m shell -a \
  'echo "=== $(hostname) ==="; cat /etc/netplan/60-kubernetes-routes.yaml'
```

Then inspect active routes:

```bash
ansible 'control_plane:workers' -b -m shell -a \
  'ip route | grep "^10\.200" || true'
```

The active routes report:

```text
proto static
```

confirming that they are installed through the persistent network configuration.

The resulting active state is:

```text
server
├── 10.200.0.0/24 via 192.168.56.50 dev eth1
└── 10.200.1.0/24 via 192.168.56.60 dev eth1

node-0
└── 10.200.1.0/24 via 192.168.56.60 dev eth1

node-1
└── 10.200.0.0/24 via 192.168.56.50 dev eth1
```

---

## Idempotency

After the persistent route configuration was established, the playbook was executed again.

No persistent configuration changes were required.

The route template remained unchanged and Netplan did not need to be reapplied.

This confirms that the routing role converges to the intended state rather than repeatedly modifying network configuration.

---

## Verification Summary

At completion of this phase:

```text
Worker Pod CIDRs identified             ✓
Manual routes configured                ✓
Control-plane route selection verified  ✓
Cross-worker route selection verified   ✓
Persistent Netplan routes configured    ✓
Vagrant network ownership preserved     ✓
Ansible route ownership established     ✓
Kernel routes report proto static       ✓
Ansible idempotency verified            ✓
```

The cluster now has routing information for:

```text
10.200.0.0/24 <----> 10.200.1.0/24
```

through the workers' private cluster addresses.

---

## Next Phase

Section 11 of Kubernetes The Hard Way is complete.

The remaining milestone is Section 12:

```text
Smoke Test
```

The smoke test validates the cluster from the workload perspective, including Kubernetes Secrets, Deployments, Pods, logs, command execution, port forwarding, and Services.

That phase provides end-to-end validation that the control plane, workers, container runtime, networking, encryption, and Kubernetes API operate together as a functioning cluster.