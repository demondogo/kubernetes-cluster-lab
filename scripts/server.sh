#!/usr/bin/env bash

#
# Control Plane (Server) Provisioning Script
#
# Purpose:
#   Prepares the Kubernetes control plane node.
#
# Responsibilities:
#   - Configure SSH for cluster administration
#   - Allow SSH agent forwarding
#   - Allow root authentication using SSH keys
#   - Create baseline Kubernetes and etcd directories
#
# Kubernetes components are intentionally not installed here. They will be
# configured separately as part of the Kubernetes The Hard Way workflow.
#

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SERVER] $1"
}

log "Starting control plane server setup..."

# ---------------------------------------------------------------------------
# SSH Server
# ---------------------------------------------------------------------------

log "Configuring SSH server..."

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
PermitRootLogin prohibit-password
EOF

log "Validating SSH server configuration..."
sshd -t

log "Restarting ${SSH_SERVICE}..."
systemctl restart "${SSH_SERVICE}"

# ---------------------------------------------------------------------------
# Kubernetes Directories
# ---------------------------------------------------------------------------

log "Creating control plane directories..."

install -d -m 0755 \
    /etc/kubernetes \
    /etc/kubernetes/manifests \
    /var/lib/kubernetes \
    /var/lib/etcd

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

log "Control plane information:"
log "  Hostname:     $(hostname)"
log "  Architecture: $(uname -m)"
log "  OS:           $(. /etc/os-release && echo "${PRETTY_NAME}")"

log "Control plane server provisioning completed."
