#!/usr/bin/env bash
# ==============================================================================
# modules/03-system-config.sh — Configure installed system services
# ==============================================================================
# Runs after package installation so firewall, ClamAV, Podman, groups, and sudo
# configuration can see the packages and units installed by module 03.
# ==============================================================================

[[ -n "${_MODULE_SYSTEM_CONFIG_LOADED:-}" ]] && return
_MODULE_SYSTEM_CONFIG_LOADED=1

# When this module is selected directly, load the function definitions from
# module 01 without running its preflight entry point.
if ! declare -F setup_firewall &>/dev/null; then
    SYSTEM_MODULE_NO_MAIN=true
    # shellcheck source=modules/01-system.sh
    source "$SETUP_DIR/modules/01-system.sh"
    unset SYSTEM_MODULE_NO_MAIN
fi

main() {
    log_section "Module 03: System configuration"

    setup_firewall
    setup_user_groups
    setup_sudo_feedback
    setup_clamav
    setup_podman

    log_success "Post-package system configuration complete"
}

main "$@"
