# Post-Quantum

Someone can record encrypted traffic today and decrypt it once a quantum computer exists. ML-KEM is a key exchange built to resist that. Most links here pair it with a classical one, as `X25519MLKEM768` in TLS and `mlkem768x25519-sha256` in SSH.

# Protected links

These links negotiate a post-quantum key exchange. Most get it from Go 1.24+ and OpenSSH 10 defaults. Only Traefik and the mesh need a setting here.

| Link | What provides it |
|---|---|
| Browser to the public sites | Cloudflare's edge |
| Cloudflare to the cluster | `cloudflared` lists `X25519MLKEM768` first by default |
| Any client to Traefik | Traefik's default, plus a TLS 1.3 minimum in [cluster/traefik/helmchartconfig.yaml](../cluster/traefik/helmchartconfig.yaml) |
| Pod to pod inside the Istio mesh | `COMPLIANCE_POLICY: pqc` on istiod in [cluster/argocd/istio.yaml](../cluster/argocd/istio.yaml) |
| `kubectl` to the k3s API | k3s's default |
| SSH to all four nodes | OpenSSH's default |
| `git` to GitHub over SSH | OpenSSH's default, so local clones use `git@github.com` remotes |
| Cluster to AWS (STS, S3, DynamoDB, SSM, RDS) | The Go clients and AWS's endpoints |
| Cluster to the Cloudflare API, Discord and Tailscale's control plane | The Go clients and those endpoints |
| The Go services in [AGENTS.md](../AGENTS.md#go-app-conventions) | Go's default. None of them sets `CurvePreferences` |

TLS 1.2 has no post-quantum key exchange, so Traefik and the mesh require TLS 1.3.

# Classical links

These links still use a classical key exchange. Each waits on the service at the other end.

| Link | Key exchange | What travels on it |
|---|---|---|
| ArgoCD, CI and the Go services to `github.com`, `api.github.com` and `ghcr.io` | `X25519` | Manifests, images and short-lived tokens |
| Crossplane and sign-in to `login.microsoftonline.com` and `graph.microsoft.com` | `P-256` | Short-lived tokens |
| Image pulls from `quay.io` and Docker Hub | `X25519` | Public images |
| cert-manager to Let's Encrypt | `X25519` | Public certificate requests |
| Tailscale between devices | WireGuard's `Curve25519` | SSH, `kubectl` and HTTPS. Each carries its own post-quantum key exchange inside the tunnel |

# Plain-text links

These links carry no encryption at all. They stay inside VLAN 10.

| Link | Why it is plain text |
|---|---|
| Traefik to app pods | Traefik runs outside the mesh and calls apps on their plain-text ports |
| Pods outside the mesh | flannel carries their traffic between nodes as sent |
| NATS | Clients and the three servers talk without TLS |

# Certificates

Every certificate and host key here has a classical signature. A recording can't exploit a signature. It matters only once a quantum computer can forge one during a live connection. Each moves to ML-DSA, the post-quantum signature, when its issuer offers it.

| Where | Certificate or key |
|---|---|
| Public sites | ECDSA certificates from Let's Encrypt at Cloudflare's edge, and an RSA-2048 Let's Encrypt certificate on Traefik |
| `*.local.lab` | An ECDSA P-256 CA from cert-manager, valid 10 years |
| SPIRE | An RSA-2048 CA, valid 1 year, signing 4-hour workload certificates |
| Nodes | Ed25519 SSH host keys |

# Stored data

Symmetric ciphers such as AES-256 and ChaCha20 keep their strength against a quantum computer.

- Cluster backups: `age` encrypts them from a passphrase, with no public key. See [Cluster Backup](./cluster-backup/README.md).
- Kubernetes Secrets: k3s stores them unencrypted in its SQLite datastore on `ctrl-1`. k3s secrets encryption would keep its key on that same disk.

# Checking a link

Each check prints the key exchange a link negotiated. The TLS checks need OpenSSL 3.5 or newer. For an outside service, run the first check with its hostname, such as `github.com:443`.

```bash
# Traefik. Prints "Negotiated TLS1.3 group: X25519MLKEM768".
echo | openssl s_client -connect argocd.local.lab:443 -groups X25519MLKEM768:X25519 2>/dev/null | grep 'Negotiated TLS1.3 group'

# Traefik refuses TLS 1.2. Prints "alert protocol version".
echo | openssl s_client -tls1_2 -connect argocd.local.lab:443 2>&1 | grep 'alert'

# SSH. Prints "kex: algorithm: mlkem768x25519-sha256".
ssh -v pi@192.168.10.100 true 2>&1 | grep 'kex: algorithm'

# cloudflared. Each connection logs its curve list.
kubectl logs -n cloudflare deploy/cloudflared | grep 'curve preferences'

# Mesh. Run on ctrl-1 against a mesh pod's IP and app port.
# Offering only X25519 ends in "alert handshake failure".
echo | openssl s_client -connect <pod-ip>:<port> -alpn istio -groups X25519MLKEM768 2>&1 | grep 'Negotiated TLS1.3 group'
```
