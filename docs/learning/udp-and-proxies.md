# UDP, proxies, and reverse proxies

Don't memorise definitions. Trace one UDP packet and one TCP request through this cluster and compare what each proxy in the path can do with them.

**UDP vs TCP**

- No handshake, no ordering, no retransmit - a UDP datagram either arrives or it doesn't, and nothing in the protocol notices. Capture both: `tcpdump -i any udp port 53 -n` against AdGuard, then `tcpdump -i any tcp port 443 -n` against Traefik. Count the packets a single DNS query takes versus a single HTTPS request.
- No concept of a "request" - TCP's stream gives HTTP something to frame a request/response inside. UDP has no equivalent, so nothing above it gets that framing for free; the application protocol (DNS, RakNet/Bedrock, RTP) has to invent its own.
- Where it already lives here - AdGuard on 53/UDP, the Bedrock server from [the shelved Minecraft doc](../../local-only/wip/minecraft-bedrock-server.md) on 19132/UDP. Everything else in the Namespaces & Applications table is TCP.

**Forward proxy vs reverse proxy**

- A forward proxy sits in front of the *client* - the client is configured to use it, and the server on the other end has no idea it exists. Corporate egress proxies are the usual example; nothing in this cluster runs one.
- A reverse proxy sits in front of the *server* - the client thinks it's talking to the real thing, and the operator chose to put it there. Traefik and cloudflared are both reverse proxies: `mattjarrett.dev` never touches a client directly, cloudflared and Traefik terminate on its behalf and re-originate the request.
- The direction matters for who's protected: a forward proxy hides the client's identity from the server; a reverse proxy hides the server's identity (and IP) from the client.

**Why a reverse proxy is shaped around TCP/HTTP**

- Terminating means ending one connection and starting another, copying the semantics across - method, path, headers, body. That only works because HTTP defines those semantics on top of TCP's reliable stream.
- UDP has no request to copy. A reverse proxy fronting a UDP service can pass bytes through at best (NAT-style forwarding) but can't do what Traefik does for HTTP - route by path, rewrite a header, terminate TLS and re-issue it, apply a `Host`-based rule. There's no `Host` header in a datagram.
- This is why Cloudflare Tunnel and Traefik can front `blog.mattjarrett.dev` but not a Bedrock server - see [Platform Connections → Complications outside HTTP](../platform-connections.md#complications-outside-http) for what that costs a UDP workload on this platform specifically.

**Wrinkle worth knowing** - cloudflared's own uplink to the Cloudflare edge runs over QUIC, which is UDP underneath. So the tunnel is a reverse proxy for UDP transport but only for HTTP *payloads* - it never becomes a generic UDP relay for whatever's inside.

**Artifact** - `tcpdump` a request to `blog.mattjarrett.dev` and a query to AdGuard side by side, then write one paragraph naming, for each, where a reverse proxy touches it and where it doesn't.
