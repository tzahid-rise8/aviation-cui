#!/usr/bin/env bash
# Refresh .env.bedrock with fresh BedrockAccess-TA session credentials.
# The claude-bedrock profile (~/.aws/config) assumes the role using the
# long-lived keys stored under the ta-static profile — no SSO login needed.
# After running, rebuild the devcontainer to pick up the new credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
aws configure export-credentials --profile claude-bedrock --format env-no-export > .env.bedrock
echo "AWS_REGION=us-gov-west-1" >> .env.bedrock
echo "Refreshed .env.bedrock (expires $(grep AWS_CREDENTIAL_EXPIRATION .env.bedrock | cut -d= -f2))"
