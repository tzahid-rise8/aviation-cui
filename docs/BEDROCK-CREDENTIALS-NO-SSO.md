# Bedrock Credentials Without SSO (Static Keys + AssumeRole)

How to get AWS Bedrock credentials for the CUI devcontainer when you **can't use
`aws sso login`** (e.g. company restrictions on non-Rise8 laptops). Instead of SSO,
you use long-lived IAM user keys issued by IT to automatically assume a
project-specific Bedrock access role.

> **Role name varies by project.** This guide uses `BedrockAccess-TA` throughout
> because this engagement is True Anomaly ("TA"). IT will tell you your project's
> role name (and account ID) when they issue your keys — substitute yours wherever
> `BedrockAccess-TA` or `431331090492` appears below.

If you *can* use SSO on your machine, see the last section — the original flow still works.

## How it works (30 seconds of background)

IT issues you keys for an IAM **user**. That user has no Bedrock permissions itself —
it is only allowed to call `sts:AssumeRole` on your project's Bedrock **role**, which
trades your permanent keys for temporary session credentials (key + secret + session
token) that carry the role's Bedrock permissions.

You never call AssumeRole manually. The AWS CLI does it automatically when a profile
is configured with `role_arn` + `source_profile` — every command run with that profile
gets fresh role credentials behind the scenes.

## Prerequisites

- AWS CLI v2 installed on your host machine (`aws --version`)
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` issued by IT, authorized to
  assume your project's Bedrock role — along with that role's name and account ID
- This repo cloned, with the devcontainer setup from [SETUP-CUI.md](SETUP-CUI.md)

## One-time setup

### 1. Store the static keys

Run these on your **host** (not in the container). Paste your keys when prompted —
this writes them to `~/.aws/credentials` under a profile named `ta-static`:

```bash
aws configure set aws_access_key_id     "PASTE_YOUR_KEY_ID"     --profile ta-static
aws configure set aws_secret_access_key "PASTE_YOUR_SECRET_KEY" --profile ta-static
aws configure set region                "us-gov-west-1"         --profile ta-static
```

> `~/.aws/credentials` now holds long-lived secrets. Treat it like a password file.

### 2. Add the assume-role profile

Add this to `~/.aws/config`:

```ini
[profile claude-bedrock]
role_arn = arn:aws-us-gov:iam::431331090492:role/BedrockAccess-TA
source_profile = ta-static
region = us-gov-west-1
duration_seconds = 3600
```

> If a `[profile claude-bedrock]` block already exists (the old SSO one), replace it —
> or keep both by renaming one (see the SSO section below).

### 3. Verify

```bash
aws sts get-caller-identity --profile claude-bedrock
```

You should see an ARN like
`arn:aws-us-gov:sts::431331090492:assumed-role/BedrockAccess-TA/...`.
If this works, role assumption is working and you're done with setup.

## Daily flow (when credentials expire)

```bash
# From the repo root — regenerates .env.bedrock with fresh role credentials
./scripts/refresh-bedrock-creds-for-non-sso.sh

# Then reload the container:
# VSCode: Cmd/Ctrl + Shift + P → "Dev Containers: Rebuild Container"
```

That's it — no login step. The script just runs:

```bash
aws configure export-credentials --profile claude-bedrock --format env-no-export > .env.bedrock
echo "AWS_REGION=us-gov-west-1" >> .env.bedrock
```

The docker-compose file feeds `.env.bedrock` into the container via `env_file`, same
as the old SSO flow.

## Session lifetime

Exported credentials currently last **1 hour** — the `BedrockAccess-TA` role's
`MaxSessionDuration` is the AWS default (3600s). When credentials expire mid-work,
Bedrock calls fail with `ExpiredTokenException`; rerun the daily flow above.

If IT raises `MaxSessionDuration` on the role (it can go up to 12 h / 43200s), bump
`duration_seconds` in `~/.aws/config` to match and you're back to a
refresh-once-per-workday rhythm.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `ExpiredTokenException` in the container | Session creds expired — rerun the daily flow. |
| `The requested DurationSeconds exceeds the MaxSessionDuration set for this role` | Your `duration_seconds` is higher than the role allows. Drop it to 3600 or ask IT to raise the role's max. |
| `AccessDenied ... sts:AssumeRole` | Your IAM user isn't authorized for the role yet — contact IT. |
| `InvalidClientTokenId` / `SignatureDoesNotMatch` on step 3 | Keys were mistyped in step 1 — rerun the `aws configure set` commands. |
| Container can't reach AWS at all | Credentials aren't the issue — check the firewall whitelist (`firewall/whitelist.txt`) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md). |

## Security notes

- **Never commit `.env` or `.env.bedrock`** (repo rule; both are gitignored — keep it that way).
- `.env.bedrock` only ever contains short-lived session credentials in this flow;
  the long-lived keys live only in `~/.aws/credentials` on your host.
- If you think the static keys leaked, tell IT immediately so they can rotate them.

## Alternative: the original SSO flow (Rise8 laptops)

On a machine where SSO is allowed, use this profile instead (no static keys involved):

```ini
[profile claude-bedrock-sso]
sso_session = bedrock-session
sso_account_id = 431331090492
sso_role_name = BedrockAccess-TA
region = us-gov-west-1

[sso-session bedrock-session]
sso_start_url = https://start.us-gov-west-1.us-gov-home.awsapps.com/directory/rise8
sso_region = us-gov-west-1
sso_registration_scopes = sso:account:access
```

Then every ~8 hours:

```bash
aws sso login --profile claude-bedrock-sso
aws configure export-credentials --profile claude-bedrock-sso --format env-no-export > .env.bedrock
echo "AWS_REGION=us-gov-west-1" >> .env.bedrock
# Rebuild the container as usual
```

Both profiles can coexist in `~/.aws/config`; pick per machine.
