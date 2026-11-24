# Firewall Troubleshooting Guide

This guide helps diagnose and resolve common issues with the firewall sidecar implementation.

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Common Issues](#common-issues)
3. [Diagnostic Commands](#diagnostic-commands)
4. [Troubleshooting Flowcharts](#troubleshooting-flowcharts)
5. [Log Analysis](#log-analysis)
6. [Advanced Debugging](#advanced-debugging)

## Quick Diagnostics

Run these commands first to get a quick health check:

```bash
# Check container status
cd /workspaces/XPai/.devcontainer
podman-compose ps

# Check firewall logs
podman logs cui-firewall-manager | tail -50

# Check iptables rules
podman exec cui-firewall-manager iptables -L OUTPUT -n

# Run test suite
/workspaces/XPai/tests/test-firewall.sh
```

## Common Issues

### 1. Containers Won't Start

**Symptoms**:
- `podman-compose up` fails
- Firewall container exits immediately
- AI assistant container won't start

**Diagnosis**:

```bash
# Check container logs
podman logs cui-firewall-manager
podman logs cui-ai-assistant

# Check compose configuration
podman-compose config

# Verify files exist
ls -la /workspaces/XPai/firewall/
```

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **Whitelist file not found** | Verify `whitelist.txt` exists and is mounted at `/firewall/whitelist.txt` |
| **Volume mount path incorrect** | Check docker-compose.yml volume paths match actual file locations |
| **NET_ADMIN capability missing** | Verify `cap_add` includes `NET_ADMIN` in the docker-compose.firewall.yml firewall service |
| **`Can't open socket to ipset`** | `NET_RAW` is missing from the firewall service's `cap_add` (required by the ipset match) |
| **`no IPv4 upstream resolver found in /etc/resolv.conf`** | The runtime gave the container no IPv4 nameserver. Check the container network's DNS settings |
| **`dnsmasq did not start answering on 127.0.0.1:53`** | Check the dnsmasq lines in the firewall logs; another process may hold port 53 in the namespace |
| **Port conflict** | Another container using same ports - stop conflicting containers |

### 2. Firewall Container Unhealthy

**Symptoms**:
- `podman-compose ps` shows firewall as "unhealthy"
- AI assistant won't start (waiting for firewall health)
- Health check keeps failing

**Diagnosis**:

```bash
# Run the health check manually (DROP policy, dnsmasq and ulogd running, resolver wired up)
podman exec cui-firewall-manager /usr/local/bin/firewall-healthcheck.sh && echo OK || echo FAIL

# Check that the DNS resolver and blocked-packet logger are running
podman exec cui-firewall-manager sh -c 'pidof dnsmasq && pidof ulogd'

# Check for iptables errors
podman logs cui-firewall-manager | grep -i error

# Verify kernel modules loaded
podman exec cui-firewall-manager lsmod | grep ip_tables
```

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **iptables not working** | Prebuilt image includes iptables - check container logs |
| **Kernel module not loaded** | Host kernel must support iptables - check `lsmod | grep ip_tables` |
| **Rules not applied** | Check container logs for errors during rule application |
| **dnsmasq or ulogd stopped** | The entrypoint restarts them within `CLOCK_SYNC_INTERVAL_SECONDS` (default 60); check the logs for `not running; restarting` |
| **Old healthcheck in compose file** | Projects created before the dnsmasq change may still use the `policy DROP` + `dpt:53` check; replace it with `/usr/local/bin/firewall-healthcheck.sh` from the starter |
| **Health check too early** | Wait for `start_period: 15s` - firewall needs time to initialize |

### 3. Whitelisted Endpoints Blocked

**Symptoms**:
- Cannot connect to whitelisted endpoint
- curl times out to known-good endpoint
- Previously working endpoint now fails

**Diagnosis**:

```bash
# Check whitelist file content
cat /workspaces/XPai/firewall/whitelist.txt

# Verify endpoint is whitelisted
grep "your-endpoint.com" /workspaces/XPai/firewall/whitelist.txt

# Check if firewall resolved the domain
podman logs cui-firewall-manager | grep "your-endpoint.com"

# Check the IPs currently allowed for the port (filled by dnsmasq at lookup time)
podman exec cui-firewall-manager ipset list fw_allow_tcp_443

# Test resolution through dnsmasq ("REFUSED" = name is not whitelisted)
podman exec cui-firewall-manager dig @127.0.0.1 your-endpoint.com A

# Refused lookups (DNS queries are logged by default; FW_DNS_LOG=0 on the firewall-manager service disables this)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/dns.log*' | grep -E -B1 "config .* is (REFUSED|NXDOMAIN)"

# Test connection from AI container
podman exec cui-ai-assistant curl -v https://your-endpoint.com
```

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **Domain not in whitelist** | Add to `firewall/whitelist.txt` and restart containers |
| **Whitelist format error** | Fix format to `domain:port` (no spaces) |
| **"Could not resolve host" / REFUSED** | Name is not in the whitelist. Entries are exact: `example.com` does not allow `api.example.com`, so list each hostname |
| **DNS resolution failed at startup** | Warning only; the entry is allowed on the next successful lookup |
| **IP address changed** | Handled automatically; clients' lookups add the new IP |
| **Name resolved outside dnsmasq** | Whitelisted names in `/etc/hosts` (e.g. `host.containers.internal`) are allowed from a copy taken on the firewall's first start; recreate the containers (`podman-compose up -d`) after changing `extra_hosts`, since a restart keeps the copy. Hard-coded IPs are never allowed |
| **Short name needs a search domain** | `resolv.conf` has no `search` line, so whitelist the full name (bare container names work as is) |
| **Port mismatch** | Verify whitelist port matches actual port (e.g., 443 for HTTPS) |
| **Containers not restarted after whitelist change** | `podman-compose restart` |

### 4. All Traffic Blocked

**Symptoms**:
- Cannot connect to any endpoint (including whitelisted)
- No network connectivity at all
- DNS queries fail

**Diagnosis**:

```bash
# Check if DROP policy applied too early
podman logs cui-firewall-manager | grep -A 10 "[RULES]"

# Verify rule order
podman exec cui-firewall-manager iptables -L OUTPUT -n -v --line-numbers

# Check for rule application errors
podman logs cui-firewall-manager | grep -i error

# Test DNS from AI container with a whitelisted name (non-whitelisted names are always refused)
podman exec cui-ai-assistant getent hosts bedrock-runtime.us-gov-east-1.amazonaws.com

# Check the shared resolver points at dnsmasq
podman exec cui-ai-assistant cat /etc/resolv.conf   # Expected: nameserver 127.0.0.1
```

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **dnsmasq not running** | Every lookup fails until the entrypoint restarts it; check `pidof dnsmasq` and the firewall logs |
| **Upstream resolver unreachable** | Check `/etc/resolv.conf.upstream` in the firewall container and the dnsmasq lines in its logs |
| **DNS rate limit hit** | Look for `FW-DNS-FLOOD` in `/var/log/firewall/blocked.log`; raise `FW_DNS_RATE` / `FW_DNS_BURST` if the load is legitimate |
| **DNS rules not applied** | Check firewall logs - fix init script |
| **Stateful rules missing** | Check for `ESTABLISHED,RELATED` rules in `iptables -L` |
| **Firewall script error** | Review full firewall logs for script errors |

### 5. Firewall Logs Missing

**Symptoms**:
- No [INIT], [WHITELIST], or [RULES] log entries
- Cannot see blocked connection attempts
- Logs are empty, or audit logs disappear after a rebuild

**Diagnosis**:

```bash
# Check container is running
podman ps | grep cui-firewall-manager

# Check logs with timestamps
podman logs --timestamps cui-firewall-manager

# Check container entrypoint
podman inspect cui-firewall-manager --format='{{.Config.Entrypoint}}'

# Check the audit logs and that they are on the log volume
podman exec cui-firewall-manager ls -l /var/log/firewall
podman inspect cui-firewall-manager --format='{{range .Mounts}}{{.Name}} -> {{.Destination}}{{"\n"}}{{end}}'
```

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **Entrypoint not executed** | Check container image and entrypoint configuration |
| **Container exits immediately** | Check for early exit errors in container logs |
| **Whitelist not mounted** | Verify whitelist.txt volume mount in docker-compose.yml |
| **Looking for blocked attempts in `podman logs` only** | The container log is capped at 10 MB; the full history is in `/var/log/firewall/*.log*` |
| **No `FW-BLOCKED-OUT` for a blocked name** | Expected: names that are not whitelisted are refused at DNS and appear in `dns.log`, not `blocked.log` |
| **Log volume not mounted** | Add `YOURPROJECT-firewall-logs:/var/log/firewall` to the firewall service (see the starter compose file); without it the logs are lost on every rebuild |
| **ulogd not running** | Blocked packets are not logged until it restarts; check `pidof ulogd` and the firewall logs |

### 6. DNS Resolution Slow or Failing

**Symptoms**:
- Firewall takes >30 seconds to start
- "Warm-up lookup failed" warnings in logs
- Lookups of whitelisted names are slow or fail

**Diagnosis**:

```bash
# Check DNS resolution time through dnsmasq
time podman exec cui-firewall-manager dig @127.0.0.1 +short bedrock-runtime.us-gov-east-1.amazonaws.com A

# Check the resolver setup: resolv.conf points at dnsmasq, the upstream list is saved separately
podman exec cui-firewall-manager cat /etc/resolv.conf /etc/resolv.conf.upstream

# Test each whitelist entry through dnsmasq
while read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  domain=$(echo "$line" | cut -d: -f1)
  echo "Testing $domain..."
  podman exec cui-firewall-manager dig @127.0.0.1 +short "$domain" A
done < /workspaces/XPai/firewall/whitelist.txt
```

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **Upstream DNS server unreachable** | Check network connectivity and the runtime's DNS configuration (`/etc/resolv.conf.upstream`) |
| **Domain does not exist** | Verify domain spelling, check if service is up |
| **Slow upstream DNS server** | Fix the container network's DNS settings. Only the runtime-provided upstream is allowed, so a public resolver such as 8.8.8.8 cannot be used directly |
| **Warm-up lookup failed** | Non-fatal. The entry is allowed as soon as a client lookup succeeds |

### 7. Network Namespace Issues

**Symptoms**:
- AI container and firewall have different IPs
- AI container can bypass firewall
- Network isolation not working

**Diagnosis**:

```bash
# Get firewall IP
firewall_ip=$(podman exec cui-firewall-manager ip addr show eth0 | grep "inet " | awk '{print $2}')

# Get AI container IP (should be same)
ai_ip=$(podman exec cui-ai-assistant ip addr show eth0 | grep "inet " | awk '{print $2}' || echo "no eth0")

echo "Firewall IP: $firewall_ip"
echo "AI IP: $ai_ip"

# Check network mode
podman inspect cui-ai-assistant --format='{{.HostConfig.NetworkMode}}'

# Check if AI container has independent network
podman exec cui-ai-assistant ip link show
```

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **network_mode not set** | Add `network_mode: "service:firewall-manager"` to ai-assistant in docker-compose.yml |
| **Wrong network mode** | Ensure exact string: `service:firewall-manager` |
| **Containers started out of order** | Restart: `podman-compose down && podman-compose up -d` |
| **Podman version incompatibility** | Update Podman to latest version, check compatibility |

### 8. Excessive Blocked Attempts

**Symptoms**:
- Hundreds of FW-BLOCKED-OUT log entries, or `FW-BLOCKED-SUMMARY` / `FW-DNS-FLOOD` lines
- Many `REFUSED` lines in `dns.log`
- Performance degradation
- Log file growing rapidly

**Diagnosis**:

```bash
# Count blocked attempts by destination IP (full history on the log volume), top 20
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | \
  grep "FW-BLOCKED-OUT" | \
  awk '{for(i=1;i<=NF;i++) if($i~/^DST=/) print $i}' | \
  sort | uniq -c | sort -rn | head -20

# Count by destination port
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | \
  grep "FW-BLOCKED-OUT" | \
  awk '{for(i=1;i<=NF;i++) if($i~/^DPT=/) print $i}' | \
  sort | uniq -c | sort -rn | head -20

# Blocked packets over the log rate, and DNS floods
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | \
  grep -E "FW-BLOCKED-SUMMARY|FW-DNS-FLOOD" | tail -50

# Most-refused names (the name is on the query line before each REFUSED line)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/dns.log*' | \
  grep -B1 "is REFUSED" | awk '/query\[/ {print $(NF-2)}' | grep -v '^healthcheck.invalid$' | \
  sort | uniq -c | sort -rn | head -20
```

Blocked packets are logged at up to `FW_BLOCK_LOG_RATE` per second per chain, so a burst shows as a few `FW-BLOCKED-OUT` lines plus a `FW-BLOCKED-SUMMARY` count of the rest. Log growth is capped by `FW_LOG_MAX_MB` (see the firewall-manager README).

**Common Causes & Solutions**:

| Cause | Solution |
|-------|----------|
| **Application trying non-whitelisted service** | Add service to whitelist if legitimate |
| **Background process scanning** | Identify and stop the process |
| **Malware/compromised container** | Investigate the AI container for compromise |
| **Application misconfiguration** | Fix application to use correct endpoints |

## Diagnostic Commands

### Container Status

```bash
# List all containers
podman ps -a

# Check specific container
podman inspect cui-firewall-manager

# Container resource usage
podman stats cui-firewall-manager cui-ai-assistant

# Container processes
podman top cui-firewall-manager
```

### Network Configuration

```bash
# List networks
podman network ls

# Inspect network
podman network inspect <network-name>

# Check container network settings
podman inspect cui-firewall-manager --format='{{json .NetworkSettings}}' | jq

# Show all network interfaces in firewall container
podman exec cui-firewall-manager ip link show

# Show routing table
podman exec cui-firewall-manager ip route show
```

### iptables Rules

```bash
# List all rules
podman exec cui-firewall-manager iptables -L -n -v

# List OUTPUT chain specifically
podman exec cui-firewall-manager iptables -L OUTPUT -n -v --line-numbers

# Show rule packet counters
podman exec cui-firewall-manager iptables -L OUTPUT -n -v -x

# Show raw iptables-save format
podman exec cui-firewall-manager iptables-save

# Show allowlist ipsets (IPs added by dnsmasq, with remaining timeout)
podman exec cui-firewall-manager ipset list

# Show the generated dnsmasq config
podman exec cui-firewall-manager cat /etc/dnsmasq-firewall.conf
```

### Logs

The container log (`podman logs`) shows startup output plus a live copy of the audit logs, capped at 10 MB. The full audit history is in `/var/log/firewall` on the firewall log volume. Treat both as potentially containing CUI (DNS query names are logged verbatim).

```bash
# Audit logs on the log volume (.1 is the newest rotation)
podman exec cui-firewall-manager ls -l /var/log/firewall
podman exec cui-firewall-manager tail -f /var/log/firewall/blocked.log /var/log/firewall/dns.log

# Tail firewall logs in real-time
podman logs -f cui-firewall-manager

# Show logs with timestamps
podman logs --timestamps cui-firewall-manager

# Show last 100 lines
podman logs --tail 100 cui-firewall-manager

# Show logs from specific time
podman logs --since 10m cui-firewall-manager

# Search logs for errors
podman logs cui-firewall-manager 2>&1 | grep -i error

# Export the audit logs (handle the copy as CUI)
podman cp cui-firewall-manager:/var/log/firewall ./firewall-logs-$(date +%Y%m%d-%H%M%S)
```

### DNS and Connectivity

```bash
# Test DNS through dnsmasq from the firewall ("status: REFUSED" = not whitelisted)
podman exec cui-firewall-manager dig @127.0.0.1 bedrock-runtime.us-gov-east-1.amazonaws.com A

# Test DNS from AI container
podman exec cui-ai-assistant getent hosts bedrock-runtime.us-gov-east-1.amazonaws.com

# Test HTTPS connectivity
podman exec cui-ai-assistant curl -v https://bedrock-runtime.us-gov-east-1.amazonaws.com

# Test with timeout
podman exec cui-ai-assistant curl --max-time 5 https://example.com

# Test specific port
podman exec cui-ai-assistant nc -zv bedrock-runtime.us-gov-east-1.amazonaws.com 443
```

## Troubleshooting Flowcharts

### Flowchart 1: Container Won't Start

```
[Run podman-compose up -d]
           |
           v
    [Check Logs]
           |
    +------+------+
    |             |
[WHITELIST    [INIT
 NOT FOUND]    ERROR]
    |             |
[Check path]  [Check script]
    |             |
[Fix volume]  [Fix syntax]
    |             |
[Restart]     [Restart]
```

### Flowchart 2: Connection Blocked

```
[Connection Times Out]
           |
           v
[Check if whitelisted]
           |
    +------+------+
    |             |
  [YES]         [NO]
    |             |
    v             v
[Check DNS]   [Add to whitelist]
(dig @127.0.0.1)  |
    |         [Restart containers]
[Resolved?]
    |
+---+---+
|       |
[YES]   [NO]
|       |
v       v
[Check  [REFUSED: exact name
ipset]   not whitelisted.
|        Other: fix upstream
|        DNS]
v
[IP in
ipset?]
|
+---+---+
|       |
[YES]   [NO]
|       |
v       v
[Check  [Client resolved it
port]    outside dnsmasq
         (/etc/hosts, cached
          or hard-coded IP)]
```

### Flowchart 3: Health Check Failing

```
[Firewall Unhealthy]
           |
           v
[Check Logs for Errors]
           |
    +------+------+
    |             |
[IPTABLES    [DNS
 ERROR]       ERROR]
    |             |
[Check NET_  [Check dnsmasq
 ADMIN and    running and
 NET_RAW]     resolv.conf]
    |             |
[Verify      [Fix DNS]
 kernel]          |
    |         [Restart]
[Install
 module]
    |
[Restart]
```

## Log Analysis

### Successful Initialization Logs

```
[INIT] Starting firewall initialization...
[RULES] Setting default DROP policy (deny by default)...
[WHITELIST] Loading whitelist from /firewall/whitelist.txt
[RULES] Flushing existing iptables rules...
[RULES] Rate-limiting DNS queries to dnsmasq (200/s, burst 1000)...
[RULES] Adding stateful rules for ESTABLISHED,RELATED connections...
[RULES] Adding loopback rules (localhost connections)...
[RULES] Allowing DNS egress for dnsmasq to upstream resolver(s)...
[WHITELIST] Parsing whitelist entries...
[WHITELIST] Allowing bedrock-runtime.us-gov-east-1.amazonaws.com:443 (resolved dynamically via dnsmasq)
[WHITELIST] Allowing bedrock.us-gov-east-1.amazonaws.com:443 (resolved dynamically via dnsmasq)
[WHITELIST] Writing dnsmasq config to /etc/dnsmasq-firewall.conf...
[INIT] Preparing audit logs in /var/log/firewall...
[INIT] Starting dnsmasq...
[WHITELIST] time.cloudflare.com:123 -> 162.159.200.1 162.159.200.123
[WHITELIST] bedrock-runtime.us-gov-east-1.amazonaws.com:443 -> 52.46.145.72
[WHITELIST] bedrock.us-gov-east-1.amazonaws.com:443 -> 52.222.147.69
[INIT] Starting ulogd (blocked-packet log)...
[RULES] Adding logging rules for blocked traffic (10/s per chain)...
[INIT] Firewall initialization complete
```

### Error Patterns

#### DNS Resolution Failure

```
[WARN] Warm-up lookup failed for nonexistent.example.com; will be allowed when a client resolves it.
```

**Action**: Verify domain exists, check DNS connectivity. The entry is not skipped; it is allowed on the next successful lookup.

#### Missing NET_RAW Capability

```
ipset v7.x: Can't open socket to ipset.
[ERROR] Could not add the iptables rule for ipset fw_allow_udp_123. If the error above is "Can't open socket to ipset", add NET_RAW to the firewall-manager service's cap_add (see starter/.devcontainer/docker-compose.firewall.yml).
```

**Action**: Add `NET_RAW` to the firewall-manager's `cap_add`

#### Whitelist File Missing

```
[ERROR] Whitelist file not found at /firewall/whitelist.txt
```

**Action**: Check volume mount path in docker-compose.yml

#### Invalid Whitelist Format

```
[WARN] Invalid port for entry 'example.com:99999': port must be 1-65535. Skipping.
```

**Action**: Fix whitelist entry format

#### Permission Denied

```
iptables: Operation not permitted
```

**Action**: Verify firewall container has NET_ADMIN capability

## Advanced Debugging

### Enable Script Debugging

Add to init-firewall.sh:

```bash
#!/usr/bin/env sh
set -x  # Enable trace mode
set -euo pipefail
```

Restart container to see detailed script execution.

### Packet Tracing

```bash
# Capture packets on OUTPUT chain
podman exec cui-firewall-manager iptables -A OUTPUT -j TRACE

# View trace logs (requires kernel support)
podman exec cui-firewall-manager cat /sys/kernel/debug/tracing/trace

# Disable trace
podman exec cui-firewall-manager iptables -D OUTPUT -j TRACE
```

### Manual Rule Testing

```bash
# Enter firewall container
podman exec -it cui-firewall-manager /bin/sh

# Manually add test rule
iptables -A OUTPUT -d 1.2.3.4 -p tcp --dport 443 -j ACCEPT

# Test rule
iptables -L OUTPUT -n | grep "1.2.3.4"

# Remove test rule
iptables -D OUTPUT -d 1.2.3.4 -p tcp --dport 443 -j ACCEPT
```

### Container Shell Access

```bash
# Firewall container shell
podman exec -it cui-firewall-manager /bin/sh

# AI container shell
podman exec -it cui-ai-assistant /bin/bash

# Run commands interactively
podman exec -it cui-firewall-manager sh -c "iptables -L -n; ip addr; ip route"
```

### Recreate Containers from Scratch

> **Warning:** `down -v` also deletes the firewall audit-log volume (`YOURPROJECT-firewall-logs`). Export the logs first if they may be needed as evidence: `podman cp cui-firewall-manager:/var/log/firewall ./firewall-logs-$(date +%Y%m%d)`. Use `down` without `-v` to recreate containers and keep the logs.

```bash
# Stop and remove everything, including named volumes (see warning above)
podman-compose down -v

# Remove images (optional - forces fresh pull)
podman rmi alpine:latest
podman rmi ghcr.io/rise8-us/xpai/ai-assistant-home:latest

# Start fresh
podman-compose up -d

# Watch logs
podman-compose logs -f
```

## Getting Help

If issues persist after trying these troubleshooting steps:

1. **Collect Diagnostic Information** (the firewall log includes DNS query names, which may be CUI; review the report before sharing it outside the CUI boundary):
   ```bash
   # Create diagnostic report
   {
     echo "=== Container Status ==="
     podman ps -a
     echo ""
     echo "=== Firewall Logs ==="
     podman logs cui-firewall-manager 2>&1 | tail -100
     echo ""
     echo "=== AI Container Logs ==="
     podman logs cui-ai-assistant 2>&1 | tail -50
     echo ""
     echo "=== iptables Rules ==="
     podman exec cui-firewall-manager iptables -L -n -v || echo "Cannot get rules"
     echo ""
     echo "=== Whitelist Content ==="
     cat /workspaces/XPai/firewall/whitelist.txt
     echo ""
     echo "=== Test Results ==="
     /workspaces/XPai/tests/test-firewall.sh 2>&1 || echo "Tests failed"
   } > firewall-diagnostic-$(date +%Y%m%d-%H%M%S).txt
   ```

2. **Review Documentation**:
   - [Firewall Architecture](./FIREWALL-ARCHITECTURE.md)
   - [Whitelist Management](./WHITELIST-MANAGEMENT.md)
   - [Feature Specification](../specs/001-firewall-sidecar-implementation/spec.md)

3. **Create GitHub Issue**:
   - Include diagnostic report
   - Describe what you were trying to do
   - What you expected to happen
   - What actually happened
   - Steps to reproduce

## References

- [iptables Debugging Guide](https://www.netfilter.org/documentation/HOWTO/packet-filtering-HOWTO-7.html)
- [Podman Troubleshooting](https://github.com/containers/podman/blob/main/troubleshooting.md)
- [Docker Compose Networking](https://docs.docker.com/compose/networking/)
