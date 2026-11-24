# Firewall Compliance Documentation

## CMMC Level 2 Compliance

This firewall implementation helps satisfy the following CMMC Level 2 requirements for CUI projects:

### Requirements Mapping

| Requirement | Control | Implementation |
|-------------|---------|----------------|
| **SC.L2-3.13.6** | Deny by default, allow by exception | iptables DROP policy with whitelist |
| **SC.L2-3.13.1** | Boundary protection | Firewall at container network boundary |
| **AC.L2-3.1.20** | Least privilege | AI container: cap_drop: ALL |

### Control Details

#### SC.L2-3.13.6: Deny by Default, Allow by Exception

**Requirement**: "Deny network communications traffic by default and allow network communications traffic by exception (i.e., deny all, permit by exception)."

**Implementation**:
- iptables default OUTPUT policy set to DROP, before any other rule is added (a failed init leaves traffic blocked)
- The firewall's DNS resolver (dnsmasq) answers only exact whitelisted names and refuses all others
- Only IPs that dnsmasq resolved for a whitelisted name are accepted, and only on that entry's port (per-port ipsets)
- All non-whitelisted traffic is logged and dropped

**Verification**:
```bash
# View iptables rules showing DROP policy
podman exec cui-firewall-manager iptables -L OUTPUT -v -n

# View the IPs currently allowed per port
podman exec cui-firewall-manager ipset list

# Test that non-whitelisted domains are blocked
podman exec cui-ai-assistant curl --max-time 5 https://example.com
# Expected: "Could not resolve host" (name refused by the firewall's resolver)

# Test that a non-whitelisted IP is blocked
podman exec cui-ai-assistant curl --max-time 5 https://1.1.1.1
# Expected: Connection timeout
```

#### SC.L2-3.13.1: Boundary Protection

**Requirement**: "Monitor, control, and protect organizational communications (i.e., information transmitted or received by organizational information systems) at the external boundaries and key internal boundaries of the information systems."

**Implementation**:
- Network namespace boundary between AI container and external networks
- All outbound traffic passes through firewall container
- Firewall logs all blocked connection attempts
- Container cannot bypass firewall due to shared network namespace

**Verification**:
```bash
# Verify AI container uses firewall's network namespace
podman inspect cui-ai-assistant --format='{{.HostConfig.NetworkMode}}'
# Expected: container:cui-firewall-manager

# View blocked connection logs (full history, on the firewall log volume)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | grep "FW-BLOCKED-OUT"
```

> **Note:** The firewall keeps two audit logs on a volume mounted only into the firewall-manager container, so the AI container cannot read or alter them and they survive container rebuilds:
> - `/var/log/firewall/blocked.log`: blocked packets (`FW-BLOCKED-IN/OUT/FWD`), DNS query floods (`FW-DNS-FLOOD`), and counts of blocked packets over the log rate (`FW-BLOCKED-SUMMARY`).
> - `/var/log/firewall/dns.log`: every DNS query and its outcome.
>
> Connection attempts to names that are not whitelisted are refused by the firewall's DNS resolver (dnsmasq) before any connection is made, so they do not produce `FW-BLOCKED-OUT` entries. Only attempts by raw IP address are logged there. The refused lookups are logged in `dns.log` as a `query[...] <name>` line followed by a `REFUSED` line (the name appears only on the query line). Subdomains of a whitelisted name are answered locally instead, as a `config <name> is NXDOMAIN` line. DNS query logging is on by default; setting `FW_DNS_LOG=0` on the firewall-manager service turns it off and removes this evidence. Both logs are also streamed to `podman logs cui-firewall-manager` as a live view, which is capped at 10 MB and lost when the container is removed. See Residual Risk 5 for retention and the limits of this evidence.

#### AC.L2-3.1.20: Least Privilege

**Requirement**: "Authorize access to security functions and security-relevant information."

**Implementation**:
- AI container has ALL capabilities dropped (cap_drop: ALL)
- AI container cannot modify network rules
- Only firewall container has CAP_NET_ADMIN and CAP_NET_RAW (minimum required for iptables and ipset matching), plus CAP_SYS_TIME for clock resync
- Only the firewall's dnsmasq resolver, running as fixed UID 60053, may reach the upstream DNS resolver. No process in the AI container (or an image derived from it) may run as UID 60053
- The AI container can write the `/etc/resolv.conf` and `/etc/hosts` it shares with the firewall, so the firewall uses only private copies taken on its first start, before the AI container runs. AI-container edits cannot change the upstream resolver or the allowlist
- No privileged containers

**Verification**:
```bash
# Verify AI container has no capabilities
podman inspect cui-ai-assistant --format='{{.HostConfig.CapDrop}}'
# Expected: [ALL]

# Verify firewall capabilities
podman inspect cui-firewall-manager --format='{{.HostConfig.CapAdd}}'
# Expected: [NET_ADMIN NET_RAW SYS_TIME]
```

## Audit Evidence

Compliance auditors can verify the following:

### 1. Configuration Files (Version Controlled)

**Location**: `firewall/` directory

**Files**:
- `whitelist.txt` - Approved network destinations (read-only, chmod 444)

**Prebuilt Image**:
- `ghcr.io/rise8-us/xpai/firewall-manager:latest` - Contains the firewall initialization script, the dnsmasq resolver, the ulogd blocked-packet logger, the health check, and the log rotation scripts
- Image built via GitHub Actions with security scanning (Trivy)
- Image digest pinned in docker-compose for reproducibility

**Audit Trail**:
- Whitelist changes tracked in Git
- Pull request review required (see `.github/CODEOWNERS.example`)
- Change history available via `git log firewall/`
- Image builds tracked via GitHub Actions workflow runs

### 2. Container Configuration

**Location**: `.devcontainer/docker-compose.firewall.yml`

**Security Controls**:
```yaml
# Firewall container
cap_add:
  - NET_ADMIN  # Configure iptables and ipsets
  - NET_RAW    # iptables ipset match (-m set) needs a raw socket
  - SYS_TIME   # Periodic clock resync
volumes:
  - ../firewall/whitelist.txt:/firewall/whitelist.txt:ro  # Read-only whitelist
  - YOURPROJECT-firewall-logs:/var/log/firewall           # Audit logs, firewall only
healthcheck:
  test: ["CMD", "/usr/local/bin/firewall-healthcheck.sh"]

# AI assistant container
cap_drop:
  - ALL  # Zero capabilities
network_mode: "service:firewall-manager"  # Uses firewall's network
depends_on:
  firewall-manager:
    condition: service_healthy  # Won't start until the firewall is healthy
```

### 3. Runtime Verification

**Firewall Logs**:
```bash
# Full history is on the firewall log volume; rotated files are numbered
# (.1 is the newest). Recent entries are also in `podman logs cui-firewall-manager`.

# View blocked connection attempts (by IP address)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | grep "FW-BLOCKED-OUT"

# View blocked packets that were over the log rate, and DNS query floods
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | grep -E "FW-BLOCKED-SUMMARY|FW-DNS-FLOOD"

# View refused lookups of non-whitelisted names and their subdomains
# (healthcheck.invalid entries are the firewall's own healthcheck)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/dns.log*' | grep -E -B1 "config .* is (REFUSED|NXDOMAIN)"

# Export both logs for longer retention (handle the copy as CUI)
podman cp cui-firewall-manager:/var/log/firewall ./firewall-logs-$(date +%Y%m%d)
```

**Test Results**:
```bash
# Run security validation suite
./tests/test-firewall.sh
```

All tests must pass to demonstrate:
- Deny-by-default enforcement
- Whitelist-only access (non-whitelisted names refused at DNS)
- Zero capabilities on AI container
- Proper network isolation

The firewall-manager image's own suite (`firewall-manager/integration-test.sh`, run in CI before each image is promoted) additionally covers DNS bypass attempts, subdomain blocking, audit logging, log rotation, and log persistence across container recreation.

### 4. Documentation

**Evidence Package**:
- Security architecture: `docs/firewall/FIREWALL-ARCHITECTURE.md`
- Implementation details: `docs/firewall/README-FIREWALL.md`
- Troubleshooting procedures: `docs/firewall/FIREWALL-TROUBLESHOOTING.md`
- Whitelist management process: `docs/firewall/WHITELIST-MANAGEMENT.md`
- Test procedures: `docs/firewall/FIREWALL-TESTING.md`

## Residual Risks

The following limitations are accepted trade-offs:

1. **DNS-based exfiltration**: DNS is served by a dnsmasq resolver inside the firewall-manager, and only dnsmasq may reach the upstream resolver. Names not on the whitelist are refused, and clients cannot query other resolvers directly. The residual path is a lookup of an allowlisted name (exact match; subdomains are never forwarded), whose upstream authoritative server can see the query. Mitigated by:
   - Only exact whitelisted names are forwarded upstream; subdomains are answered locally, so arbitrary `<data>.<allowlisted-name>` lookups never leave the firewall
   - Using trusted upstream DNS servers only
   - Short data exfiltration via DNS is impractical for CUI volumes

2. **HTTPS content inspection**: HTTPS payloads are encrypted and not inspected. Mitigated by:
   - Whitelist controls destination domains
   - AWS Bedrock endpoints are trusted
   - Prompt injection attacks are limited by destination whitelist

3. **IPv6 traffic**: Only IPv4 addresses are whitelisted. Mitigated by:
   - AWS Bedrock uses IPv4
   - IPv6 is not required for CUI operations

4. **NTP time sync**: Outbound NTP (UDP port 123) is allowed to keep the shared Podman VM clock corrected after host sleep/wake cycles, which would otherwise break TLS certificate validation and AWS SigV4 request signing. Unlike DNS, this is scoped to the IP(s) that dnsmasq resolved for a single time server (`time.cloudflare.com` by default, held in an ipset), not left open to any destination. Mitigated by:
   - Destination restricted to the resolved IP set of one named server (not a rotating pool)
   - NTP payloads are small and the protocol is not content-inspected, so this carries a low-bandwidth residual risk similar to the DNS path above
   - The firewall-manager sidecar is the only container with this rule; the ai-assistant container remains fully capability-dropped

5. **Audit log completeness and content**: The firewall logs are the audit evidence for blocked attempts. They are protected from the AI container, but they have limits:
   - **Retention**: the log volume holds at most `FW_LOG_MAX_MB` (default 1024 MB), split evenly between `dns.log` and `blocked.log` so a flood of one cannot evict the other. Each log is rotated at `FW_LOG_FILE_MB` (default 50 MB) and the oldest rotation is deleted first. Deleting the volume (for example `compose down -v`) deletes the logs.
   - **Rate limits**: DNS queries are limited to `FW_DNS_RATE` per second (default 200, burst `FW_DNS_BURST` 1000). Queries over the limit are dropped and logged as `FW-DNS-FLOOD` (at most 1 line per second). Blocked packets are logged at up to `FW_BLOCK_LOG_RATE` per second per chain (default 10, burst 50); packets over that rate are still blocked and are counted in periodic `FW-BLOCKED-SUMMARY` lines. At these defaults, a sustained flood of long query names (about 400 bytes of log per query) can fill the DNS log's 512 MB share in about 2 hours, pushing out older DNS entries. The flood cannot evict `blocked.log`, which records it as `FW-DNS-FLOOD` and `FW-BLOCKED-SUMMARY` lines.
   - **Dropped lines**: dnsmasq writes its log asynchronously (`log-async`) so a stalled write cannot block DNS. If its queue fills during a burst, it drops lines and reports how many were lost.
   - **Attribution**: the containers share one network namespace, so every DNS query is logged as coming from `127.0.0.1`, including the firewall's own lookups.
   - **Content**: query names are logged verbatim. Data encoded into a lookup (for example `<data>.attacker.com`) is blocked from leaving, but is written to the log volume on the host, so treat the firewall logs as potentially containing CUI. Blocked packets are logged by header only; their payload is not recorded.
   - **Firewall integrity**: the logs are only as trustworthy as the firewall-manager container. dnsmasq can write only its own log, and the blocked-packet logger (ulogd) runs as its own unprivileged user, not root.

   Mitigated by:
   - Exporting the firewall logs (see Runtime Verification) if longer retention is required
   - Storing and handling the log volume and exported logs as CUI

## References

- [CMMC Level 2 Requirements](https://www.acq.osd.mil/cmmc/)
- [NIST SP 800-171 Rev 2](https://csrc.nist.gov/publications/detail/sp/800-171/rev-2/final)
- [iptables Documentation](https://www.netfilter.org/documentation/)
- [Linux Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)
