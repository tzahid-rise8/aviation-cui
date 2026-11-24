#!/bin/bash
################################################################################
# AI Assistant Container - Bedrock Profile Setup Script
# Target: macOS (Apple Silicon and Intel)
# Scope: CUI projects (AWS Bedrock SSO profile)
#
# Writes an AWS SSO profile for a project's BedrockAccess-<SUFFIX> permission
# set directly into ~/.aws/config via non-interactive `aws configure set`
# calls, instead of the interactive `aws configure sso` wizard.
#
# WHY: the interactive wizard has a "Default client Region" prompt that is
# easy to skip. A profile with no region set produces temporary GovCloud
# credentials that fail every AWS call with "InvalidClientTokenId", because
# GovCloud (us-gov-west-1) requests must be routed to the GovCloud STS
# endpoint. This script always writes that region, so the failure mode
# cannot occur.
#
# IDEMPOTENCY: Safe to re-run. Detects an existing profile of the same name
# and asks before overwriting it.
################################################################################

set -euo pipefail

################################################################################
# CONSTANTS & CONFIGURATION
################################################################################

readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="./ai-assistant-setup-bedrock-profile.log"
readonly AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-${HOME}/.aws/config}"

readonly SSO_SESSION_NAME="rise8"
readonly SSO_START_URL="https://start.us-gov-west-1.us-gov-home.awsapps.com/directory/rise8"
readonly SSO_REGION="us-gov-west-1"
readonly SSO_REGISTRATION_SCOPES="sso:account:access"
readonly AWS_ACCOUNT_ID="431331090492"
readonly BEDROCK_REGION="us-gov-west-1"

# Color codes for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'

# Emoji for visual feedback
readonly EMOJI_CHECK="✅"
readonly EMOJI_CROSS="❌"
readonly EMOJI_ARROW="→"
readonly EMOJI_GEAR="⚙️"
readonly EMOJI_INFO="📝"
readonly EMOJI_QUESTION="❓"

# Populated by parse_args/validate_role_suffix
ROLE_SUFFIX=""
PROFILE_NAME=""
ROLE_NAME=""
OVERWRITE=true

################################################################################
# LOGGING & OUTPUT FUNCTIONS
################################################################################

log_message() {
    local level=$1
    shift
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") [${level}] $*" >> "${LOG_FILE}"
}

log_info() { log_message "INFO" "$@"; }
log_error() { log_message "ERROR" "$@"; }

print_success() { echo -e "${COLOR_GREEN}${EMOJI_CHECK} $*${COLOR_RESET}"; }
print_error() { echo -e "${COLOR_RED}${EMOJI_CROSS} $*${COLOR_RESET}"; }
print_info() { echo -e "${COLOR_CYAN}${EMOJI_INFO} $*${COLOR_RESET}"; }

print_step() {
    echo ""
    echo "---"
    echo -e "${COLOR_CYAN}${EMOJI_ARROW} $*${COLOR_RESET}"
    echo ""
}

print_helpdesk_instructions() {
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Check the log file: ${LOG_FILE}"
    echo "  2. File a #helpdesk ticket"
    echo "  3. Attach the log file to your ticket"
    echo "  4. Include this error: 'setup-bedrock-profile.sh failed'"
    echo ""
}

print_header() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  AI Assistant Container - Bedrock Profile Setup            ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <ROLE_SUFFIX>

Set up an AWS SSO profile for your project's Bedrock permission set,
non-interactively, so the container can authenticate to AWS Bedrock.

ARGUMENTS:
    ROLE_SUFFIX   Your project's permission set suffix, e.g. "EMC" for
                  BedrockAccess-EMC. Ask your Delivery Lead if unsure.

OPTIONS:
    --help, -h    Show this help message and exit.

EXAMPLE:
    $(basename "$0") EMC

This writes profile "bedrockaccess-emc" (role "BedrockAccess-EMC") into
~/.aws/config, then signs you in via AWS SSO and verifies the credentials
work end to end.
EOF
    exit 0
}

################################################################################
# ARGUMENT PARSING
################################################################################

parse_args() {
    if [[ $# -eq 0 ]]; then
        print_error "Missing required argument: ROLE_SUFFIX"
        usage
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                usage
                ;;
            -*)
                print_error "Unknown option: $1"
                usage
                ;;
            *)
                ROLE_SUFFIX=$1
                shift
                ;;
        esac
    done

    if [[ -z "${ROLE_SUFFIX}" ]]; then
        print_error "Missing required argument: ROLE_SUFFIX"
        usage
    fi
}

################################################################################
# PHASE 0: PREREQUISITE VALIDATION
################################################################################

validate_prerequisites() {
    print_step "Phase 0: Prerequisite Validation"

    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found"
        echo ""
        echo "REMEDIATION:"
        echo "  brew install awscli"
        echo ""
        log_error "aws CLI not found in PATH"
        exit 1
    fi

    print_success "AWS CLI found: $(aws --version 2>&1)"
    log_info "AWS CLI verified: $(aws --version 2>&1)"
}

################################################################################
# PHASE 1: INPUT VALIDATION & CONFIRMATION
################################################################################

validate_role_suffix() {
    print_step "Phase 1: Input Validation"

    if [[ ! "${ROLE_SUFFIX}" =~ ^[A-Za-z][A-Za-z0-9]{0,31}$ ]]; then
        print_error "Invalid role suffix: '${ROLE_SUFFIX}'"
        echo ""
        echo "The suffix must start with a letter and contain only letters and"
        echo "numbers (e.g. EMC, KM, TAK). Ask your Delivery Lead for the exact"
        echo "suffix if you're unsure."
        echo ""
        log_error "Invalid role suffix rejected: '${ROLE_SUFFIX}'"
        exit 1
    fi

    PROFILE_NAME="bedrockaccess-$(echo "${ROLE_SUFFIX}" | tr '[:upper:]' '[:lower:]')"
    ROLE_NAME="BedrockAccess-${ROLE_SUFFIX}"

    echo "This will configure:"
    echo "  Profile name: ${PROFILE_NAME}"
    echo "  Role name:    ${ROLE_NAME}"
    echo "  Account ID:   ${AWS_ACCOUNT_ID}"
    echo "  Region:       ${BEDROCK_REGION}"
    echo ""

    local reply
    read -r -p "${EMOJI_QUESTION} Proceed with these values? [Y/n] " reply
    if [[ "${reply}" =~ ^[Nn]$ ]]; then
        print_info "Aborted by user. Re-run with the correct suffix."
        log_info "User aborted at confirmation prompt for suffix '${ROLE_SUFFIX}'"
        exit 0
    fi

    log_info "Confirmed profile=${PROFILE_NAME} role=${ROLE_NAME}"
}

################################################################################
# PHASE 2: IDEMPOTENCY CHECK
################################################################################

check_existing_profile() {
    print_step "Phase 2: Checking for Existing Profile"

    if [[ ! -f "${AWS_CONFIG_FILE}" ]] || ! grep -q "^\[profile ${PROFILE_NAME}\]" "${AWS_CONFIG_FILE}"; then
        print_info "No existing profile named '${PROFILE_NAME}' - will create it"
        log_info "No existing profile found for ${PROFILE_NAME}"
        OVERWRITE=true
        return 0
    fi

    print_info "Profile '${PROFILE_NAME}' already exists"
    local reply
    read -r -p "${EMOJI_QUESTION} Overwrite with fresh settings? [y/N] " reply
    if [[ "${reply}" =~ ^[Yy]$ ]]; then
        OVERWRITE=true
        log_info "User chose to overwrite existing profile ${PROFILE_NAME}"
    else
        OVERWRITE=false
        print_info "Keeping existing profile as-is - skipping to verification"
        log_info "User kept existing profile ${PROFILE_NAME} as-is"
    fi
}

################################################################################
# PHASE 3: WRITE PROFILE
################################################################################

write_bedrock_profile() {
    print_step "Phase 3: Writing AWS Profile"

    print_info "Writing shared SSO session '${SSO_SESSION_NAME}'..."
    if ! { aws configure set --sso-session "${SSO_SESSION_NAME}" sso_start_url "${SSO_START_URL}" \
        && aws configure set --sso-session "${SSO_SESSION_NAME}" sso_region "${SSO_REGION}" \
        && aws configure set --sso-session "${SSO_SESSION_NAME}" sso_registration_scopes "${SSO_REGISTRATION_SCOPES}"; }; then
        print_error "Failed to write SSO session configuration"
        echo ""
        echo "This usually means your AWS CLI is too old to support"
        echo "'aws configure set --sso-session'."
        echo ""
        echo "REMEDIATION:"
        echo "  brew upgrade awscli"
        echo "  Then re-run this script."
        echo ""
        log_error "aws configure set --sso-session failed"
        print_helpdesk_instructions
        exit 1
    fi

    print_info "Writing profile '${PROFILE_NAME}'..."
    if ! { aws configure set sso_session "${SSO_SESSION_NAME}" --profile "${PROFILE_NAME}" \
        && aws configure set sso_account_id "${AWS_ACCOUNT_ID}" --profile "${PROFILE_NAME}" \
        && aws configure set sso_role_name "${ROLE_NAME}" --profile "${PROFILE_NAME}" \
        && aws configure set region "${BEDROCK_REGION}" --profile "${PROFILE_NAME}"; }; then
        print_error "Failed to write profile '${PROFILE_NAME}'"
        log_error "aws configure set failed while writing profile ${PROFILE_NAME}"
        print_helpdesk_instructions
        exit 1
    fi

    print_success "Profile '${PROFILE_NAME}' written with region '${BEDROCK_REGION}'"
    log_info "Profile ${PROFILE_NAME} written successfully"
}

################################################################################
# PHASE 4: SIGN IN & VERIFY
################################################################################

sign_in_and_verify() {
    print_step "Phase 4: Sign In & Verify"

    echo "${EMOJI_GEAR} What will happen next:"
    echo "   1. Your web browser will open automatically"
    echo "   2. Sign in with your Rise8 identity, then approve access"
    echo "   3. Return to this terminal when done"
    echo ""

    log_info "Starting aws sso login for profile ${PROFILE_NAME}"
    if ! aws sso login --profile "${PROFILE_NAME}"; then
        print_error "AWS SSO login failed or was cancelled"
        log_error "aws sso login failed for profile ${PROFILE_NAME}"
        print_helpdesk_instructions
        exit 1
    fi

    print_info "Verifying credentials..."
    local identity
    if ! identity=$(aws sts get-caller-identity --profile "${PROFILE_NAME}" --output json 2>&1); then
        print_error "Failed to verify credentials"
        echo ""
        echo "TROUBLESHOOTING:"
        echo "  1. Confirm the profile has a region set:"
        echo "     aws configure get region --profile ${PROFILE_NAME}"
        echo "     (should print '${BEDROCK_REGION}' - if empty, re-run this script"
        echo "     and choose to overwrite)"
        echo "  2. 'InvalidClientTokenId' almost always means a missing/wrong region"
        echo "  3. 'AccessDenied' means you aren't authorized for ${ROLE_NAME} -"
        echo "     contact your Delivery Lead"
        echo ""
        echo "Details: ${identity}"
        echo ""
        log_error "get-caller-identity failed for profile ${PROFILE_NAME}: ${identity}"
        print_helpdesk_instructions
        exit 1
    fi

    local account
    account=$(echo "${identity}" | grep -o '"Account": *"[^"]*"' | grep -o '[0-9]\{6,\}')

    if [[ "${account}" != "${AWS_ACCOUNT_ID}" ]]; then
        print_error "Signed in, but to the wrong account (${account}, expected ${AWS_ACCOUNT_ID})"
        echo ""
        echo "You may have selected the wrong account during SSO login. Re-run"
        echo "this script and pick 'Rise8 Service - Bedrock' when prompted."
        echo ""
        log_error "Wrong account for profile ${PROFILE_NAME}: got ${account}, expected ${AWS_ACCOUNT_ID}"
        print_helpdesk_instructions
        exit 1
    fi

    print_success "Verified: signed in to account ${account} as ${ROLE_NAME}"
    log_info "Verification succeeded for profile ${PROFILE_NAME}: ${identity}"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    echo "========== NEW RUN: $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==========" >> "${LOG_FILE}"
    log_info "Script version: ${SCRIPT_VERSION}"

    parse_args "$@"

    print_header

    validate_prerequisites
    validate_role_suffix
    check_existing_profile

    if [[ "${OVERWRITE}" == "true" ]]; then
        write_bedrock_profile
    fi

    sign_in_and_verify

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  Bedrock Profile Setup Complete! ${EMOJI_CHECK}                        ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "${EMOJI_INFO} Your daily routine (repeat every 8 hours):"
    echo ""
    echo "   aws sso login --profile ${PROFILE_NAME}"
    echo "   aws configure export-credentials --profile ${PROFILE_NAME} --format env-no-export > .env.bedrock"
    echo ""
    echo "${EMOJI_GEAR} Then rebuild the container in VS Code:"
    echo "   • Press: Cmd+Shift+P"
    echo "   • Type: \"Dev Containers: Rebuild Container\""
    echo ""
    echo "📝 Log file: ${LOG_FILE}"
    echo ""

    log_info "setup-bedrock-profile.sh completed successfully for profile ${PROFILE_NAME}"
}

main "$@"
