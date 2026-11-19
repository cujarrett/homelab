# Postmortem: Router Restart

On 2026-11-18 I restarted the UniFi router, then acted surprised when the internet left. The cluster stayed up but was offline for about 5 minutes.

## Impact

- 03:31 to 03:36 UTC: every public hostname failed.
- No reboots, no restarts, no data lost. Only my pride.

## Cause

I pressed restart. The router is every node's only gateway and DNS server. I built it that way, so there is nobody else to blame.

## Recovery

The cluster fixed itself before I finished panicking.
