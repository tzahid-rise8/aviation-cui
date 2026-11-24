#!/bin/bash
################################################################################
# AI Assistant Container - CUI Onboarding Script
# Target: ARM macOS (Apple Silicon)
# Scope: CUI projects - GitHub + Container Registry authentication only.
#        For AWS Bedrock SSO profile setup, see ./scripts/setup-bedrock-profile.sh
#
# Authenticates GitHub CLI and logs Podman into GitHub Container Registry
# (ghcr.io) so the CUI devcontainer images (ai-assistant-home,
# firewall-manager) can be pulled.
#
# PREREQUISITE: Run the standard onboarding first (./scripts/onboard.sh) -
# it installs the tools this script depends on (Homebrew, Podman, gh CLI).
#
# IDEMPOTENCY: Safe to re-run. Detects stale credentials and fixes them.
################################################################################

set -euo pipefail

################################################################################
# CONSTANTS & CONFIGURATION
################################################################################

readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="./ai-assistant-onboard-cui.log"
readonly REGISTRY="ghcr.io"

# Color codes for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'

# Emoji for visual feedback
readonly EMOJI_CHECK="✅"
readonly EMOJI_CROSS="❌"
readonly EMOJI_ARROW="→"
readonly EMOJI_GEAR="⚙️"
readonly EMOJI_INFO="📝"
readonly EMOJI_QUESTION="❓"

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
    echo "  4. Include this error: 'AI assistant CUI onboard script failed'"
    echo ""
}

print_header() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  AI Assistant Container - CUI Onboarding Script           ║"
    echo "║  Container Registry Authentication (ghcr.io)              ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
}

################################################################################
# PHASE 0: PREREQUISITE VALIDATION
################################################################################

# Verify a required tool exists, pointing to standard onboarding if missing
require_tool() {
    local tool_command=$1
    local tool_name=$2

    if command -v "${tool_command}" &> /dev/null; then
        print_success "${tool_name} found: $("${tool_command}" --version 2>&1 | head -n1)"
        log_info "${tool_name} verified: $("${tool_command}" --version 2>&1 | head -n1)"
        return 0
    fi

    print_error "${tool_name} not found"
    echo ""
    echo "PREREQUISITE MISSING: ${tool_name}"
    echo ""
    echo "This script expects the standard onboarding to have run first -"
    echo "it installs the tools this script depends on."
    echo ""
    echo "REMEDIATION:"
    echo "  1. Complete the standard (non-CUI) quick start guide"
    echo "  2. Run the standard onboarding: ./scripts/onboard.sh"
    echo "  3. Re-run this script"
    echo ""
    log_error "Prerequisite missing: ${tool_name} (${tool_command}) not in PATH"
    exit 1
}

validate_prerequisites() {
    print_step "Phase 0: Prerequisite Validation"

    require_tool "gh" "GitHub CLI"
    require_tool "podman" "Podman"

    # Ensure the Podman machine is running (needed for podman login)
    if podman machine list --format "{{.Name}}\t{{.Running}}" 2>/dev/null | grep -q "podman-machine-default.*true"; then
        print_success "Podman machine is running"
        log_info "Podman machine already running"
    else
        print_info "Podman machine not running - starting it..."
        if podman machine start; then
            print_success "Podman machine started"
            log_info "Podman machine started"
        else
            print_error "Failed to start Podman machine"
            print_helpdesk_instructions
            log_error "podman machine start failed"
            exit 1
        fi
    fi

    echo ""
    print_success "All prerequisites validated!"
    log_info "Phase 0: Prerequisite validation completed"
}

################################################################################
# PHASE 1: GITHUB AUTHENTICATION
################################################################################

# Check GitHub authentication has read:packages scope
check_gh_packages_scope() {
    gh api "user/packages?package_type=container" &> /dev/null
}

configure_github_auth() {
    print_step "Phase 1: GitHub Authentication"

    echo "${EMOJI_QUESTION} Why is this needed?"
    echo "   The CUI container images are stored in GitHub Container Registry"
    echo "   (${REGISTRY}) and require GitHub authentication with the"
    echo "   read:packages permission to download."
    echo ""

    log_info "Phase 1: GitHub authentication started"

    if gh auth status &> /dev/null && check_gh_packages_scope; then
        local gh_user
        gh_user=$(gh api user --jq .login 2>/dev/null || echo "unknown")
        print_success "Already authenticated to GitHub as: ${gh_user}"
        log_info "GitHub authentication already valid: ${gh_user}"
        return 0
    fi

    print_info "GitHub authentication missing or lacking read:packages scope"
    print_info "Re-authenticating..."
    echo ""
    echo "${EMOJI_GEAR} What will happen next:"
    echo "   1. Your web browser will open automatically"
    echo "   2. Login to GitHub if prompted, then authorize GitHub CLI"
    echo "   3. Return to this terminal when done"
    echo ""

    # Clear any stale session before re-authenticating
    gh auth logout --hostname github.com &> /dev/null || true

    if gh auth login -s read:packages -w; then
        local gh_user
        gh_user=$(gh api user --jq .login 2>/dev/null || echo "unknown")
        print_success "GitHub authentication completed as: ${gh_user}"
        log_info "GitHub authentication successful: ${gh_user}"
        return 0
    fi

    print_error "GitHub authentication failed"
    echo ""
    echo "TROUBLESHOOTING:"
    echo "  • Browser did not open: check that you have a default browser set"
    echo "  • Authorization cancelled: re-run this script and complete it"
    echo "  • Manual fallback: gh auth login -s read:packages"
    echo ""
    print_helpdesk_instructions
    log_error "gh auth login failed"
    exit 1
}

################################################################################
# PHASE 2: CONTAINER REGISTRY AUTHENTICATION
################################################################################

configure_container_registry_auth() {
    print_step "Phase 2: Container Registry Authentication"

    echo "${EMOJI_QUESTION} Why is this needed?"
    echo "   Podman must be logged in to ${REGISTRY} to pull the CUI images:"
    echo "   • ghcr.io/rise8-us/xpai/ai-assistant-home"
    echo "   • ghcr.io/rise8-us/xpai/firewall-manager"
    echo ""

    log_info "Phase 2: Container registry authentication started"

    local gh_user
    if ! gh_user=$(gh api user --jq .login 2>/dev/null); then
        print_error "Failed to get GitHub username"
        print_helpdesk_instructions
        log_error "Could not retrieve GitHub username via gh CLI"
        exit 1
    fi

    # Clear stale registry credentials before logging in fresh.
    # A previously stored token that has expired causes
    # "invalid username/password: unauthorized" on image pulls.
    print_info "Clearing any stale ${REGISTRY} credentials..."
    podman logout "${REGISTRY}" &> /dev/null || true
    log_info "Cleared existing registry credentials (if any)"

    print_info "Logging in to ${REGISTRY} as ${gh_user}..."
    local login_output
    if login_output=$(gh auth token | podman login "${REGISTRY}" -u "${gh_user}" --password-stdin 2>&1); then
        print_success "Successfully authenticated to ${REGISTRY}"
        log_info "Registry authentication successful: ${REGISTRY} as ${gh_user}"
    else
        print_error "Failed to authenticate to ${REGISTRY}"
        log_error "podman login failed: ${login_output}"
        echo ""

        if echo "${login_output}" | grep -qi "unauthorized"; then
            echo "ERROR: Organization Access Denied"
            echo ""
            echo "You are authenticated to GitHub but may not have access to the"
            echo "rise8-us/XPai organization container registry."
            echo ""
            echo "REMEDIATION STEPS:"
            echo "  1. Contact your administrator or team lead"
            echo "  2. Request access to the rise8-us organization on GitHub"
            echo "  3. Accept the organization invite when it arrives"
            echo "  4. Re-run this script"
            echo ""
        fi

        print_helpdesk_instructions
        exit 1
    fi

    # Verify the stored login
    if podman login --get-login "${REGISTRY}" &> /dev/null; then
        print_success "Registry login verified"
        log_info "Registry login verification successful"
    else
        print_error "Registry login verification failed"
        print_helpdesk_instructions
        log_error "podman login succeeded but verification failed"
        exit 1
    fi

    # The CUI devcontainer uses docker compose, which reads registry
    # credentials from ~/.docker/config.json - NOT Podman's auth file.
    # Without this, image pulls fail with "invalid username/password:
    # unauthorized" even though podman itself is logged in.
    print_info "Writing credentials for Docker Compose (~/.docker/config.json)..."
    mkdir -p "${HOME}/.docker"
    if gh auth token | podman login --compat-auth-file "${HOME}/.docker/config.json" "${REGISTRY}" -u "${gh_user}" --password-stdin &> /dev/null; then
        print_success "Docker Compose credentials written"
        log_info "Registry credentials written to ~/.docker/config.json (compat format)"
    elif gh auth token | podman login --authfile "${HOME}/.docker/config.json" "${REGISTRY}" -u "${gh_user}" --password-stdin &> /dev/null; then
        # Older podman without --compat-auth-file; the plain authfile
        # structure is still readable by docker compose.
        print_success "Docker Compose credentials written (fallback format)"
        log_info "Registry credentials written to ~/.docker/config.json via --authfile fallback"
    else
        print_error "Failed to write Docker Compose credentials"
        print_helpdesk_instructions
        log_error "Both --compat-auth-file and --authfile logins failed for ~/.docker/config.json"
        exit 1
    fi
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    echo "========== NEW RUN: $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==========" >> "${LOG_FILE}"
    log_info "Script version: ${SCRIPT_VERSION}"

    print_header

    validate_prerequisites
    configure_github_auth
    configure_container_registry_auth

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  CUI Registry Setup Complete! ${EMOJI_CHECK}                          ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "${EMOJI_INFO} What was accomplished:"
    echo "   ${EMOJI_CHECK} GitHub authenticated with read:packages scope"
    echo "   ${EMOJI_CHECK} Podman logged in to ${REGISTRY}"
    echo ""
    echo "${EMOJI_GEAR} Next: rebuild the container in VS Code"
    echo "   • Press: Cmd+Shift+P"
    echo "   • Type: \"Dev Containers: Rebuild Container\""
    echo "   • Press Enter"
    echo ""
    echo "📝 Log file: ${LOG_FILE}"
    echo ""

    log_info "CUI onboarding script completed successfully"
}

main "$@"
