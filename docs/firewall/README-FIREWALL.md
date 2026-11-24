# Firewall Sidecar Implementation for CUI Compliance

## Overview

**This firewall protection is mandatory for all CUI projects** to meet CMMC Level 2 compliance requirements.

This implementation provides a deny-by-default network firewall for AI assistants operating in Controlled Unclassified Information (CUI) environments. It uses a privileged firewall container with iptables and an allowlist-only DNS resolver (dnsmasq) to enforce whitelist-based network access, protecting against data exfiltration via prompt injection attacks.

**Key Security Properties**:
- ✅ **Deny by Default**: Only explicitly whitelisted endpoints are accessible; other names do not resolve
- ✅ **Zero Capabilities**: AI container has no network privileges (cap_drop: ALL)
- ✅ **Fail-Secure**: Network unavailable if firewall fails
- ✅ **Audit Trail**: All blocked attempts are logged to a volume the AI container cannot reach
- ✅ **CMMC Level 2 Compliant**: Meets boundary protection requirements

## Quick Start

### Prerequisites

- **Container Runtime**: Docker or Podman installed
- **Platform**: Linux or macOS (with Podman machine)
- **VSCode**: With Remote-Containers extension (for devcontainer integration)
- **Network Access**: Ability to reach AWS Bedrock endpoints

### Step 1: Navigate to Project

```bash
# Navigate to your project directory
cd /path/to/your/project
```

### Step 2: Review Whitelist

The whitelist contains approved network destinations:

```bash
cat firewall/whitelist.txt
```

Default entries:
- `bedrock-runtime.us-gov-east-1.amazonaws.com:443`
- `bedrock.us-gov-east-1.amazonaws.com:443`

Entries are exact hostnames: `example.com:443` does not allow `api.example.com`.

### Step 3: Name the Project Volumes

In `.devcontainer/docker-compose.firewall.yml`, replace every `YOURPROJECT` with your project name (no spaces or dashes). This names the Claude config volume (`YOURPROJECT-claude-config`) and the firewall audit-log volume (`YOURPROJECT-firewall-logs`), so they don't collide with other projects on the same machine.

### Step 4: Start Containers

```bash
cd .devcontainer
podman-compose up -d

# Wait for firewall to become healthy (~30 seconds)
watch podman-compose ps
```

Expected output:
```
NAME                    STATUS
cui-firewall-manager    Up (healthy)
cui-ai-assistant        Up
```

### Step 5: Verify Security Properties

Run the automated test suite:

```bash
# Run all security tests
./tests/test-firewall.sh
```

Expected result: All tests pass ✅

### Step 6: Connect with VSCode

1. Open VSCode in project directory
2. Click green "Remote" button (bottom-left)
3. Select "Reopen in Container"
4. Choose `devcontainer.cui.json` configuration (automatically includes firewall protection)
5. VSCode connects to firewall-protected AI assistant

## Architecture

This firewall uses a sidecar container pattern with network namespace sharing to enforce deny-by-default network access control.

For detailed architecture documentation including container design, network flow, iptables rules, and threat model, see [Firewall Architecture](FIREWALL-ARCHITECTURE.md).

## Usage

### Adding a New Whitelist Entry

1. **Edit whitelist locally**:
   ```bash
   cd firewall
   chmod 644 whitelist.txt
   echo "api.newservice.com:443" >> whitelist.txt
   chmod 444 whitelist.txt
   ```

2. **Restart containers**:
   ```bash
   cd .devcontainer
   podman-compose down && podman-compose up -d
   ```

3. **Test connectivity**:
   ```bash
   podman exec cui-ai-assistant curl -v https://api.newservice.com
   ```

4. **Verify firewall security**:
   ```bash
   ./tests/test-firewall.sh
   ```

5. **Promote via pull request** (see [Whitelist Management](WHITELIST-MANAGEMENT.md))

### Viewing Firewall Logs

```bash
# Real-time logs (live view, capped at 10 MB)
podman logs -f cui-firewall-manager

# Blocked attempts by IP address (full history, on the firewall log volume)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | grep "FW-BLOCKED-OUT"

# Blocked attempts by name (refused DNS lookups)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/dns.log*' | grep -E -B1 "config .* is (REFUSED|NXDOMAIN)"

# View iptables rules and the currently allowed IPs
podman exec cui-firewall-manager iptables -L OUTPUT -n -v
podman exec cui-firewall-manager ipset list
```

The logs may contain CUI (DNS query names are logged verbatim). See [Firewall Compliance](FIREWALL-COMPLIANCE.md) Residual Risk 5 for retention and limits.

### Troubleshooting

If you encounter issues:

1. **Check container status**: `podman-compose ps`
2. **View logs**: `podman logs cui-firewall-manager`
3. **Run tests**: `./tests/test-firewall.sh`
4. **Consult guide**: [Troubleshooting Guide](FIREWALL-TROUBLESHOOTING.md)

## Testing

To verify the firewall is working correctly:

```bash
./tests/test-firewall.sh
```

Expected result: All tests pass ✅

For detailed testing documentation, see [Firewall Testing Guide](FIREWALL-TESTING.md).

## Security Checklist

After setup, verify these properties:

- [ ] Firewall container has only NET_ADMIN, NET_RAW, and SYS_TIME capabilities
- [ ] AI container has cap_drop: ALL
- [ ] AI container shares firewall's network namespace
- [ ] iptables default policy is DROP
- [ ] Whitelisted endpoints are accessible
- [ ] Non-whitelisted endpoints are blocked
- [ ] Blocked attempts are logged
- [ ] Firewall log volume (`YOURPROJECT-firewall-logs`) is mounted on the firewall container only
- [ ] whitelist.txt is read-only (chmod 444)
- [ ] All tests pass

## Compliance

This firewall implementation meets CMMC Level 2 requirements for CUI projects.

For detailed compliance documentation, audit evidence, and control mappings, see [Firewall Compliance Guide](FIREWALL-COMPLIANCE.md).

## Documentation

- **[Firewall Architecture](FIREWALL-ARCHITECTURE.md)**: Detailed security design
- **[Firewall Compliance](FIREWALL-COMPLIANCE.md)**: CMMC Level 2 requirements and audit evidence
- **[Firewall Testing](FIREWALL-TESTING.md)**: Test suites and validation procedures
- **[Whitelist Management](WHITELIST-MANAGEMENT.md)**: How to manage whitelist entries
- **[Troubleshooting Guide](FIREWALL-TROUBLESHOOTING.md)**: Common issues and solutions

## Known Limitations

1. **DNS-based exfiltration**: Only exact whitelisted names are forwarded upstream (low-bandwidth residual risk)
2. **No IPv6 support**: Only IPv4 addresses whitelisted
3. **No wildcard domains**: Each hostname must be explicitly listed; subdomains are not allowed
4. **Names outside DNS**: Hosts reached by raw IP are never allowed. Whitelisted names in `/etc/hosts` are allowed from the copy taken on the firewall's first start; recreate the containers to pick up `extra_hosts` changes
5. **No content filtering**: HTTPS payload is encrypted (not inspected)
6. **Audit log limits**: Logging is rate-limited and retention is capped (default 1 GB)

For detailed risk analysis, see [Firewall Compliance Guide](FIREWALL-COMPLIANCE.md).
