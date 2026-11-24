# Firewall Testing Documentation

## Overview

This document describes the test suites available for validating the firewall implementation.

## Quick Test

To run all tests:

```bash
# Default: Creates test-* containers
./tests/test-firewall.sh

# Use cui-* prefix instead
./tests/test-firewall.sh cui
```

Expected result: All tests pass ✅

## Test Suite

### Integration Tests (Self-Managing)

**Purpose**: Validates actual firewall behavior with running containers

**Prerequisites**:
- Docker or Podman installed and running
- `podman-compose` or `docker-compose` installed

**Command**:
```bash
./tests/test-firewall.sh
```

**How it works**: The test script automatically:
1. Cleans up any existing containers with the specified prefix
2. Creates fresh test containers (default: test-firewall-manager, test-ai-assistant)
3. Runs all integration tests
4. Cleans up test containers on exit (even if tests fail)

This ensures tests validate the exact same configuration as production deployment with a clean slate each time.

**Testing Options:**
```bash
# Default: Create test-firewall-manager, test-ai-assistant containers
./tests/test-firewall.sh

# Use different prefix: cui-firewall-manager, cui-ai-assistant
./tests/test-firewall.sh cui

# Custom prefix: myproject-firewall-manager, myproject-ai-assistant
./tests/test-firewall.sh myproject
```

**Note**: The script always creates fresh containers for testing. If containers with the specified prefix already exist, they are cleaned up first.

**Validates**:
- Containers are running
- Firewall container is healthy
- Whitelisted endpoints are accessible
- Non-whitelisted endpoints are blocked
- AI container has zero capabilities
- Blocked attempts are logged
- Network namespace is shared

**Example Output**:
```
✅ Firewall container is running and healthy
✅ AI container is running
✅ Whitelisted endpoint accessible (bedrock-runtime.us-gov-east-1.amazonaws.com)
✅ Non-whitelisted endpoint blocked (example.com)
✅ AI container has no capabilities (cap_drop: ALL)
✅ Blocked attempts are logged
✅ Network namespace properly shared
```

## Manual Testing

### Test Whitelisted Access

Verify that whitelisted endpoints are accessible:

```bash
podman exec cui-ai-assistant curl -v https://bedrock-runtime.us-gov-east-1.amazonaws.com
```

**Expected**: Connection succeeds, HTTP response received

### Test Blocked Access

Verify that non-whitelisted endpoints are blocked:

```bash
podman exec cui-ai-assistant curl --max-time 5 https://example.com
```

**Expected**: Fails immediately with "Could not resolve host" (the firewall's resolver refuses the name). A non-whitelisted raw IP (e.g. `https://1.1.1.1`) times out instead.

### Verify Zero Capabilities

Verify the AI container has no Linux capabilities:

```bash
podman inspect cui-ai-assistant --format='{{.HostConfig.CapDrop}}'
```

**Expected**: `[ALL]`

### Verify Firewall Capabilities

Verify the firewall has only the capabilities it needs:

```bash
podman inspect cui-firewall-manager --format='{{.HostConfig.CapAdd}}'
```

**Expected**: `[NET_ADMIN NET_RAW SYS_TIME]`

### View Blocked Attempts

Check the firewall audit logs (on the firewall log volume) for blocked attempts:

```bash
# Raw-IP attempts
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/blocked.log*' | grep "FW-BLOCKED-OUT"

# Name-based attempts (refused lookups)
podman exec cui-firewall-manager sh -c 'cat /var/log/firewall/dns.log*' | grep -E -B1 "config .* is (REFUSED|NXDOMAIN)"
```

**Expected**: Log entries showing blocked destinations (if any attempts were made). The firewall's own health check appears as `healthcheck.invalid` lookups every 10 seconds.

### View iptables Rules

Inspect the actual firewall rules:

```bash
podman exec cui-firewall-manager iptables -L OUTPUT -v -n
```

**Expected**:
- Default policy: DROP
- `FW_DNS_LIMIT` jumps for DNS queries to 127.0.0.1:53
- ACCEPT rules for ESTABLISHED/RELATED connections and loopback
- ACCEPT rules for DNS (port 53) to the upstream resolver, limited to the dnsmasq UID (`owner UID match 60053`)
- One `match-set fw_allow_<proto>_<port>` ACCEPT rule per whitelisted port (`ipset list` shows the IPs)
- Rate-limited NFLOG rule at the end (`nflog-prefix "FW-BLOCKED-OUT: "`), then the DROP policy

## Continuous Integration

### Running Tests in CI

Integration tests can be run in CI/CD pipelines. The test script is self-contained:

```bash
# Simple - test script handles container lifecycle
./tests/test-firewall.sh
```

The test script automatically:
- Cleans up any existing containers with the specified prefix
- Creates fresh test containers using `docker-compose.firewall.yml`
- Waits for firewall initialization
- Runs all tests
- Cleans up test containers (even on failure)

**Note**: Specify a container prefix (e.g., `./tests/test-firewall.sh cui`) or use default "test" prefix.

### Test Exit Codes

The test script follows standard exit codes:
- `0` - All tests passed
- `1` - One or more tests failed

## Troubleshooting Test Failures

### Integration Test Fails

**Common causes**:
- Containers not running
- Firewall not healthy yet
- Network connectivity issues

**Fix**:
```bash
# Check container status
podman-compose ps

# Check firewall logs
podman logs cui-firewall-manager

# Wait longer for health check
sleep 30
```

### Blocked Access Test Fails (Non-whitelisted site accessible)

**Common causes**:
- Firewall rules not applied
- Container using wrong network
- DNS resolution bypassing firewall
- The site shares a CDN IP with a whitelisted host (an allowed IP is reachable on that port for any hostname)

**Fix**:
```bash
# Verify network configuration
podman inspect cui-ai-assistant --format='{{.HostConfig.NetworkMode}}'
# Should be: container:cui-firewall-manager

# Verify the shared resolver is dnsmasq
podman exec cui-ai-assistant cat /etc/resolv.conf
# Should be: nameserver 127.0.0.1

# Restart containers
podman-compose down && podman-compose up -d
```

## Adding New Tests

When adding new firewall features, follow TDD:

1. **Write test first** (RED phase)
   - Add test case to appropriate test script
   - Run test - it should fail

2. **Implement feature** (GREEN phase)
   - Implement the feature
   - Run test - it should pass

3. **Refactor** (REFACTOR phase)
   - Improve code quality
   - Ensure test still passes

**Example**: Adding test for new whitelist entry

```bash
# Add to test-firewall.sh
test_new_endpoint() {
  echo "Testing new endpoint..."
  if podman exec cui-ai-assistant curl --max-time 5 -s https://new-service.com; then
    echo "✅ New endpoint accessible"
  else
    echo "❌ New endpoint blocked"
    return 1
  fi
}
```

## Performance Benchmarks

Expected test execution time:

- **test-firewall.sh**: 10-30 seconds (depends on network and container startup)
