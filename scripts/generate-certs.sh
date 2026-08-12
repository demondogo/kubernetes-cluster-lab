#!/bin/bash
#
# scripts/generate-certs.sh
# Purpose: Generate all required TLS certificates and keys on the Jumpbox.

set -euo pipefail

CERT_DIR="/home/vagrant/certs"
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

echo "==> Downloading cfssl binaries if missing..."
if ! command -v cfssl &> /dev/null; then
  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    CFSSL_ARCH="arm64"
  else
    CFSSL_ARCH="amd64"
  fi

  sudo curl -sSL "https://github.com/cloudflare/cfssl/releases/download/v1.6.4/cfssl_1.6.4_linux_${CFSSL_ARCH}" -o /usr/local/bin/cfssl
  sudo curl -sSL "https://github.com/cloudflare/cfssl/releases/download/v1.6.4/cfssljson_1.6.4_linux_${CFSSL_ARCH}" -o /usr/local/bin/cfssljson
  sudo chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson
fi

echo "==> Creating CA Configuration & CSR..."
cat << 'EOF' > ca-config.json
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat << 'EOF' > ca-csr.json
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

echo "==> Generating Admin Client Cert..."
cat << 'EOF' > admin-csr.json
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

echo "==> Generating Worker Node Certificates (node-0, node-1)..."
for node in node-0 node-1; do
  case $node in
    node-0) ip="192.168.56.50" ;;
    node-1) ip="192.168.56.60" ;;
  esac

cat << EOF > ${node}-csr.json
{
  "CN": "system:node:${node}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname="${node},${ip}" \
  -profile=kubernetes \
  ${node}-csr.json | cfssljson -bare ${node}
done

echo "==> Generating Kube-Controller-Manager Cert..."
cat << 'EOF' > kube-controller-manager-csr.json
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

echo "==> Generating Kube-Proxy Cert..."
cat << 'EOF' > kube-proxy-csr.json
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy

echo "==> Generating Kube-Scheduler Cert..."
cat << 'EOF' > kube-scheduler-csr.json
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler

echo "==> Generating Kubernetes API Server Cert..."
KUBERNETES_HOSTNAMES="kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local"
KUBERNETES_IPS="10.32.0.1,192.168.56.20,127.0.0.1"

cat << 'EOF' > kubernetes-csr.json
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname="${KUBERNETES_IPS},${KUBERNETES_HOSTNAMES},server" \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

echo "==> Generating Service Account Key Pair..."
cat << 'EOF' > service-account-csr.json
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  service-account-csr.json | cfssljson -bare service-account

echo "==> Certificate generation complete! All files saved in ${CERT_DIR}"