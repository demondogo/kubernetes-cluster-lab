# Kubernetes PKI

## Purpose

Kubernetes components use TLS certificates for encryption, authentication, and establishing trust between cluster components.

For this lab, certificate generation is performed manually on the jumpbox to preserve the learning objectives of Kubernetes The Hard Way.

Certificate distribution is automated with Ansible.

## Certificate Authority

The cluster Certificate Authority consists of:

```text
ca.crt
ca.key
```

The CA private key signs Kubernetes certificates.

```text
                  ca.key
                    |
                    | signs
                    v
              Kubernetes CA
                    |
       +------------+------------+
       |            |            |
       v            v            v
   API server    workers      clients
```

`ca.key` is sensitive and must remain on the jumpbox.

It is **never distributed to Kubernetes nodes**.

`ca.crt` contains the public CA certificate and is distributed to components that need to validate certificates issued by the cluster CA.

## Kubernetes Identities

The lab generates certificates for:

* `admin`
* `service-accounts`
* `node-0`
* `node-1`
* `kube-proxy`
* `kube-controller-manager`
* `kube-scheduler`
* `kube-api-server`

Supporting OpenSSL configuration sections define distinguished names, request extensions, and API server Subject Alternative Names.

## Certificate Verification

Every generated leaf certificate is verified against the cluster CA:

```bash
openssl verify -CAfile ca.crt <certificate>
```

A valid certificate reports:

```text
<certificate>: OK
```

## Distribution

Ansible handles certificate distribution after generation.

### Control Plane

The control-plane server receives:

```text
ca.crt
kube-api-server.crt
kube-api-server.key
service-accounts.crt
service-accounts.key
```

### Worker Node 0

`node-0` receives:

```text
ca.crt
node-0.crt -> kubelet.crt
node-0.key -> kubelet.key
```

### Worker Node 1

`node-1` receives:

```text
ca.crt
node-1.crt -> kubelet.crt
node-1.key -> kubelet.key
```

## CA Private Key Protection

The distribution playbook explicitly prevents `ca.key` from being included in a node's certificate distribution list.

The desired trust boundary is:

```text
jumpbox
├── ca.crt
├── ca.key              <- stays here
└── generated certificates
       |
       | Ansible
       |
       +----> server
       |       └── required server certificates only
       |
       +----> node-0
       |       └── node-0 identity only
       |
       └----> node-1
               └── node-1 identity only
```

## File Permissions

Public certificates may use:

```text
0644
```

Private keys use:

```text
0600
```

Files installed on Kubernetes nodes are owned by `root`.

## Verification After Distribution

The API server certificate can be verified directly on the control-plane node:

```bash
openssl verify \
  -CAfile /var/lib/kubernetes/ca.crt \
  /var/lib/kubernetes/kube-api-server.crt
```

Worker kubelet certificates are similarly verified against their installed CA certificate.

The CA private key should not exist on any Kubernetes node.
