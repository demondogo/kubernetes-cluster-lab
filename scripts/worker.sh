#!/bin/bash
#
# Worker Node Provisioning Script
#
# Purpose: Prepares worker nodes (node-0, node-1) for container execution.
# - Configures SSH server to accept root login via SSH keys
# - Installs required dependencies (socat, conntrack, ipset)
# - Configures OS requirements (disabling swap, setting up directory structures)

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WORKER] $1"
}

log "Starting worker node setup..."

log "Installing worker-specific network and runtime dependencies..."
apt-get update -y
apt-get install -y socat conntrack ipset

log "Disabling swap space permanently..."
swapoff -a
sed -i '/swap/d' /etc/fstab

log "Configuring SSH server settings..."
# Enable agent forwarding
if ! grep -q "^AllowAgentForwarding yes" /etc/ssh/sshd_config; then
    echo "AllowAgentForwarding yes" >> /etc/ssh/sshd_config
fi

# Ensure root login via SSH key is enabled
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

systemctl restart sshd

log "Preparing Kubernetes directory structure..."
mkdir -p /etc/cni/net.d
mkdir -p /opt/cni/bin
mkdir -p /var/lib/kubelet
mkdir -p /var/lib/kube-proxy
mkdir -p /var/lib/kubernetes
mkdir -p /var/run/kubernetes

log "Worker node provisioning completed."