#!/bin/bash

#
# Common Provisioning Script (Applied to ALL nodes)
#
# Purpose: Prepares base OS requirements across jumpbox, control plane,
#          and worker nodes.
#

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [COMMON] $1"
}

log "Updating system package repositories..."
apt-get update -y

log "Installing base OS packages..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    net-tools \
    vim \
    wget

log "Configuring /etc/hosts for internal cluster name resolution..."

cat <<'EOF' >> /etc/hosts
192.168.56.10 jumpbox
192.168.56.20 server
192.168.56.50 node-0
192.168.56.60 node-1
EOF

log "Loading necessary kernel modules for container networking..."

cat <<'EOF' > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

log "Setting sysctl parameters for Kubernetes networking..."

cat <<'EOF' > /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

log "Applying Kubernetes networking sysctl settings..."
sysctl -p /etc/sysctl.d/99-kubernetes.conf

log "Base common setup complete."
