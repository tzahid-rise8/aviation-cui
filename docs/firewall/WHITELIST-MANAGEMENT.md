# Firewall Whitelist Management

This document describes how to manage the firewall whitelist for the AI assistant firewall sidecar implementation.

## Overview

The firewall whitelist (`firewall/whitelist.txt`) controls which external endpoints the AI assistant can access. It uses a deny-by-default security model where only explicitly whitelisted domains are accessible.

## Whitelist Format

### Entry Format

Each whitelist entry follows the format:
```
domain:port
```

**Example**:
```
bedrock-runtime.us-gov-east-1.amazonaws.com:443
```

### Rules

1. **One entry per line**: Each domain:port combination must be on its own line
2. **Comments**: Lines starting with `#` are treated as comments
3. **Empty lines**: Empty lines are ignored
4. **No spaces**: Do not include spaces in entries (except in comments)
5. **Valid ports**: Ports must be between 1-65535
6. **Valid domains**: Domains must be valid FQDNs (alphanumeric, hyphens, dots)
7. **Exact names**: An entry allows only that exact hostname. `example.com:443` does not allow `api.example.com`; list each hostname. Wildcards are not supported
8. **Names, not IPs**: Entries are resolved through the firewall's DNS resolver (dnsmasq). Hosts reached by raw IP are never added to the allowlist. Whitelisted names in `/etc/hosts` (for example `host.containers.internal`) are allowed from a copy taken on the firewall's first start, so recreate the containers (`podman-compose up -d`), not just restart them, after changing `extra_hosts`

### Valid Examples

```
# AWS Bedrock endpoints (us-gov-east-1)
bedrock-runtime.us-gov-east-1.amazonaws.com:443
bedrock.us-gov-east-1.amazonaws.com:443

# Additional services
api.example.com:8443
service.company.com:443
```

### Invalid Examples

```
# These will be rejected or skipped:
example.com                          # Missing port
example.com:443:extra               # Multiple colons
example.com: 443                    # Space after colon
example.com:99999                   # Invalid port range
-example.com:443                    # Invalid domain (starts with hyphen)
```

## Local Testing Workflow

When you need to test a new service that requires network access:

### Step 1: Edit Whitelist Locally

```bash
# Navigate to firewall directory
cd /workspaces/XPai/firewall

# Edit whitelist.txt (requires changing permissions temporarily)
chmod 644 whitelist.txt

# Add your new entry
echo "api.newservice.com:443" >> whitelist.txt

# Restore read-only permissions
chmod 444 whitelist.txt
```

### Step 2: Restart Containers

The firewall generates its DNS configuration from the whitelist at startup, so you must restart the containers for changes to take effect:

```bash
# Navigate to devcontainer directory
cd /workspaces/XPai/.devcontainer

# Stop containers
podman-compose down

# Start containers (firewall will reload whitelist)
podman-compose up -d

# Wait for firewall to become healthy (10-30 seconds)
podman-compose ps
```

### Step 3: Test Connectivity

```bash
# Enter the AI assistant container
podman exec -it cui-ai-assistant /bin/bash

# Test the newly whitelisted endpoint
curl -v https://api.newservice.com

# Expected: Connection succeeds (HTTP response received)
```

### Step 4: Verify Firewall Logs

```bash
# Check firewall logs to confirm the new rule was added
podman logs cui-firewall-manager | grep "api.newservice.com"
```

Expected output:
```
[WHITELIST] Allowing api.newservice.com:443 (resolved dynamically via dnsmasq)
[WHITELIST] api.newservice.com:443 -> 93.184.216.34
```

The second line is the startup warm-up lookup. If it shows `Warm-up lookup failed` instead, the entry is still allowed once a client lookup succeeds.

### Step 5: Run Integration Tests

```bash
# Run full firewall test suite
./tests/test-firewall.sh
```

## Git PR Workflow (Promoting Changes)

Once you've tested the whitelist changes locally and verified they work, promote them to the team via pull request:

### Step 1: Create Feature Branch

```bash
# Create a branch for your whitelist change
git checkout -b feature/whitelist-add-newservice

# Stage whitelist changes
git add firewall/whitelist.txt
```

### Step 2: Commit with Descriptive Message

```bash
git commit -m "firewall: add api.newservice.com to whitelist

Adds api.newservice.com:443 to firewall whitelist to enable
integration with NewService API.

Tested locally:
- Whitelist format validation passed
- Container restart successful
- Connectivity to api.newservice.com verified
- Integration tests passed

Rationale: Required for [FEATURE-123] NewService integration"
```

### Step 3: Push and Create Pull Request

```bash
# Push to remote
git push origin feature/whitelist-add-newservice

# Create pull request using GitHub CLI
gh pr create \
  --title "firewall: add api.newservice.com to whitelist" \
  --body "Adds api.newservice.com:443 to enable NewService integration.

## Testing
- ✅ Local whitelist validation passed
- ✅ Container restart successful
- ✅ Connectivity verified
- ✅ Integration tests passed

## Security Review
Required for CMMC compliance - security team review needed.

Closes #123"
```

### Step 4: Security Team Review

The `.github/CODEOWNERS` file designates the security team as required reviewers for `firewall/whitelist.txt` changes. Your PR will automatically request their review.

**Security team will verify**:
1. Business justification for the new endpoint
2. Endpoint is HTTPS (port 443) when possible
3. Domain belongs to trusted service
4. No overly broad wildcards (not supported, but good to check for attempts)
5. Test evidence provided

### Step 5: Merge and Deploy

Once approved:

```bash
# Merge via GitHub UI or CLI
gh pr merge --squash

# Other team members pull changes
git pull origin main

# Restart their containers to apply new whitelist
cd .devcontainer && podman-compose restart
```

## Removing Whitelist Entries

To remove an endpoint from the whitelist:

### Step 1: Edit Whitelist

```bash
# Edit whitelist.txt
chmod 644 firewall/whitelist.txt

# Remove or comment out the entry
# Before:
# api.oldservice.com:443

# After:
# Removed 2025-10-15: Service decommissioned
# api.oldservice.com:443

chmod 444 firewall/whitelist.txt
```

### Step 2: Test and Verify Blocking

```bash
# Restart containers
cd .devcontainer && podman-compose down && podman-compose up -d

# Verify the endpoint is now blocked
podman exec cui-ai-assistant curl --max-time 5 https://api.oldservice.com

# Expected: "Could not resolve host" (the firewall's DNS resolver refuses the name)
```

### Step 3: Follow Git PR Workflow

Same as adding entries - create branch, commit, PR, get security review, merge.

## Troubleshooting

### Problem: Whitelist changes not taking effect

**Symptoms**: Added endpoint still blocked after edit

**Diagnosis**:
```bash
# Check if firewall loaded the new entry
podman logs cui-firewall-manager | grep "newservice"

# Check that dnsmasq forwards the name ("status: REFUSED" = not loaded)
podman exec cui-firewall-manager dig @127.0.0.1 api.newservice.com A

# Check that the resolved IPs are in the port's allowlist ipset
podman exec cui-firewall-manager ipset list fw_allow_tcp_443
```

**Solution**:
```bash
# Ensure you restarted containers
podman-compose down && podman-compose up -d

# Wait for health check
watch podman-compose ps
```

### Problem: DNS resolution fails for whitelist entry

**Symptoms**: Firewall logs show "Warm-up lookup failed", or clients cannot resolve a whitelisted name

**Diagnosis**:
```bash
# Check firewall logs
podman logs cui-firewall-manager | grep "Warm-up lookup failed"

# Test DNS through the firewall's resolver
podman exec cui-firewall-manager dig @127.0.0.1 problematic-domain.com A
```

**Solution**:
1. Verify domain is correct (no typos)
2. Check network connectivity
3. If domain has no A records, contact service provider
4. Remove entry from whitelist if domain is invalid

### Problem: Whitelist format issues

**Symptoms**: Firewall logs show warnings about invalid entries

**Diagnosis**:
```bash
# Check firewall logs for warnings
podman logs cui-firewall-manager | grep WARN
```

**Common issues**:
- **Invalid port**: Port must be 1-65535
- **Invalid format**: Must be `domain:port` (no spaces)
- **Duplicate entries**: Remove duplicates
- **Invalid domain**: Check for typos, invalid characters

**Solution**: Fix the reported issues in whitelist.txt and restart containers

### Problem: Firewall container fails health check

**Symptoms**: `podman-compose ps` shows firewall as "unhealthy"

**Diagnosis**:
```bash
# Check health check logs
podman logs cui-firewall-manager 2>&1 | tail -50

# Manually run health check command
podman exec cui-firewall-manager /usr/local/bin/firewall-healthcheck.sh && echo OK || echo FAIL
```

**Solution**:
1. Check for errors in firewall initialization logs
2. Verify whitelist.txt is accessible (`podman exec cui-firewall-manager cat /firewall/whitelist.txt`)
3. Verify iptables rules were applied (`podman exec cui-firewall-manager iptables -L -n`)

## Performance Considerations

### Restart Time

- **Expected**: Container restart takes <1 minute
- **Warm-up DNS lookup**: up to 3 seconds per entry (serial, non-fatal on failure)
- **iptables rules**: one ipset and rule per distinct port, not per entry

### Large Whitelists

If you have more than 50 entries:
1. Consider grouping by service (comments for organization)
2. Be aware of warm-up lookup time during initialization
3. Monitor firewall initialization logs for slow DNS queries

### IP Address Changes

IP changes need no action. The firewall's dnsmasq resolver adds each IP it returns for a whitelisted name to an ipset (entries expire after `ALLOWLIST_IP_TTL_SECONDS`, default 3600), so CDN and load-balancer hosts with rotating addresses keep working.

Whitelist entries are exact: `example.com:443` does not allow `api.example.com:443`. Add each hostname you need as its own entry.

```bash
# See the IPs currently allowed on port 443
podman exec cui-firewall-manager ipset list fw_allow_tcp_443
```

## CODEOWNERS Configuration

Create `.github/CODEOWNERS` to enforce security team review:

```
# Firewall whitelist requires security team approval
/firewall/whitelist.txt @your-org/security-team
```

This ensures all whitelist changes are reviewed by security before merging.

## Best Practices

1. **Test locally first**: Always test changes in your local environment before creating a PR
2. **Run integration tests**: Use `./tests/test-firewall.sh` to verify security properties
3. **Descriptive commits**: Explain why the endpoint is needed
4. **Security justification**: Include business reason for whitelisting
5. **Monitor logs**: Check firewall logs after changes
6. **Document removals**: Comment out removed entries with date and reason
7. **Review regularly**: Periodically audit whitelist for unused entries
8. **Use HTTPS**: Prefer port 443 (HTTPS) over HTTP for security
9. **Minimize entries**: Only whitelist what's necessary
10. **Group related entries**: Use comments to organize by service or purpose

## Examples

### Example 1: Adding AWS Service Endpoint

```bash
# Add to whitelist.txt
echo "# S3 endpoint for artifact storage" >> firewall/whitelist.txt
echo "s3.us-gov-east-1.amazonaws.com:443" >> firewall/whitelist.txt
```

### Example 2: Adding Multiple Related Endpoints

```bash
# Add to whitelist.txt
cat >> firewall/whitelist.txt <<EOF

# GitHub API for repository access
api.github.com:443
github.com:443
EOF
```

### Example 3: Temporarily Disabling an Entry

```bash
# Comment out instead of deleting
# old-api.service.com:443  # Disabled 2025-10-15: Migrating to new-api.service.com
new-api.service.com:443
```

## Security Considerations

### Threat Model

The whitelist protects against:
- **Prompt injection → data exfiltration**: Attacker cannot exfiltrate data to non-whitelisted endpoints
- **Compromised AI model**: Even if model is compromised, network access is restricted
- **Accidental data leaks**: Only approved endpoints can receive data

### What the Whitelist Does NOT Protect Against

- **Content of requests**: Firewall inspects destination only, not payload
- **Malicious responses**: Whitelisted endpoints could return malicious content
- **Application-layer attacks**: Firewall works at network layer only

### Compliance

This whitelist-based firewall helps satisfy:
- **CMMC Level 2 SC.L2-3.13.6**: Deny network communications traffic by default; allow network communications traffic by exception
- **CMMC Level 2 SC.L2-3.13.1**: Monitor and control communications at external system boundaries and key internal boundaries

## References

- [Firewall Architecture Documentation](./FIREWALL-ARCHITECTURE.md)
- [Firewall Troubleshooting Guide](./FIREWALL-TROUBLESHOOTING.md)
- [Feature Specification](../specs/001-firewall-sidecar-implementation/spec.md)
- [Test Scripts](../tests/)
