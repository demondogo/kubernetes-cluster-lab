#!/usr/bin/env bash

#
# Jumpbox Provisioning Script
#
# Purpose:
#   Prepares the dedicated jumpbox/bastion host for cluster management.
#
# Responsibilities:
#   - Install management utilities
#   - Configure SSH agent forwarding
#   - Configure SSH access for cluster administration
#   - Create the cluster machine inventory
#   - Clone Kubernetes The Hard Way
#   - Download architecture-compatible Kubernetes tooling
#
# Supported guest architectures:
#   - amd64  (x86_64)
#   - arm64  (aarch64)
#

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [JUMPBOX] $1"
}

# ---------------------------------------------------------------------------
# Architecture Detection
# ---------------------------------------------------------------------------

MACHINE_ARCH="$(uname -m)"

case "${MACHINE_ARCH}" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        log "ERROR: Unsupported guest architecture: ${MACHINE_ARCH}"
        exit 1
        ;;
esac

log "Detected guest architecture: ${MACHINE_ARCH}"
log "Using binary architecture: ${ARCH}"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

log "Installing jumpbox-specific utility packages..."

apt-get update -y
apt-get install -y \
    jq \
    sshpass \
    tree

# ---------------------------------------------------------------------------
# SSH Server
# ---------------------------------------------------------------------------

log "Configuring SSH server for agent forwarding..."

if systemctl list-unit-files ssh.service --no-legend | grep -q '^ssh.service'; then
    SSH_SERVICE="ssh"
elif systemctl list-unit-files sshd.service --no-legend | grep -q '^sshd.service'; then
    SSH_SERVICE="sshd"
else
    log "ERROR: Unable to determine SSH service name."
    exit 1
fi

install -d -m 0755 /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-kubernetes-lab.conf <<'EOF'
AllowAgentForwarding yes
EOF

log "Validating SSH server configuration..."
sshd -t

log "Restarting ${SSH_SERVICE}..."
systemctl restart "${SSH_SERVICE}"

# ---------------------------------------------------------------------------
# SSH Client
# ---------------------------------------------------------------------------

log "Configuring root SSH client..."

install -d -m 0700 /root/.ssh

cat > /root/.ssh/config <<'EOF'
Host server node-0 node-1
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

chmod 600 /root/.ssh/config

#
# IMPORTANT:
#
# Do not embed a private SSH key in this script or commit one to Git.
#
# Cluster SSH credentials should be generated or injected separately by
# Vagrant/Ansible.
#

# ---------------------------------------------------------------------------
# Cluster Inventory
# ---------------------------------------------------------------------------

log "Configuring cluster inventory..."

cat > /root/machines.txt <<'EOF'
192.168.56.20 server.kubernetes.local server
192.168.56.50 node-0.kubernetes.local node-0 10.200.0.0/24
192.168.56.60 node-1.kubernetes.local node-1 10.200.1.0/24
EOF

# ---------------------------------------------------------------------------
# Kubernetes The Hard Way
# ---------------------------------------------------------------------------

KTHW_DIR="/root/kubernetes-the-hard-way"

log "Cloning Kubernetes The Hard Way tutorial repository..."

if [ ! -d "${KTHW_DIR}/.git" ]; then
    rm -rf "${KTHW_DIR}"

    git clone \
        --depth 1 \
        https://github.com/kelseyhightower/kubernetes-the-hard-way.git \
        "${KTHW_DIR}"
else
    log "Kubernetes The Hard Way repository already exists."
fi

log "Kubernetes The Hard Way repository available at ${KTHW_DIR}."

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

log "Jumpbox information:"
log "  Hostname:     $(hostname)"
log "  Architecture: $(uname -m)"
log "  OS:           $(. /etc/os-release && echo "${PRETTY_NAME}")"

log "Jumpbox setup complete."