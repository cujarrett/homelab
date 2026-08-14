# OSI, for real

Don't memorise seven layers. Trace one packet through all of them.

**L2, L3, L4**

- Ethernet frames, ARP, MAC learning - `ip neigh`, `tcpdump -e -n arp` on a Pi
- IP, subnets, routing tables - `ip route get 192.168.1.1` from `work-1`, explain every hop
- TCP handshake, window, retransmit, `RST` vs `FIN` - capture with `tcpdump -i any port 443 -n`
- VLANs - VLAN 10 is already in use; find the 802.1Q tag on the UDR7 side

**L5, L6, L7, plus the cluster overlay**

- TLS handshake - SNI, ALPN, cert chain. Run `openssl s_client -connect ... -servername` against `mattjarrett.com` and against a `.local.lab` host, then diff what comes back.
- DNS as a protocol - `dig +trace`, SOA and negative caching. The UDR7 negative-caching behaviour is already documented in [CLAUDE.md](../../CLAUDE.md); go prove it with `dig`.
- HTTP/1.1 vs HTTP/2 framing - where Traefik terminates and what it re-originates

**Artifact** - a doc tracing a request to `myvinyl.mattjarrett.dev` from a phone on cellular → Cloudflare edge → tunnel → cloudflared pod → Traefik → Cilium → Istio sidecar → app, naming the layer at each hop. Worth more than a book.
