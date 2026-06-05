#!/usr/bin/env bash
# ==============================================================================
# modules/09-done.sh — Final summary
# ==============================================================================
# Prints a summary of what was set up and any follow-up actions the user needs
# to take manually (things that can't be automated, like adding SSH keys or
# rebooting to apply group changes).
# ==============================================================================

[[ -n "${_MODULE_DONE_LOADED:-}" ]] && return
_MODULE_DONE_LOADED=1

main() {
    echo ""
    printf "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              System setup complete!                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    printf "${NC}"
    echo ""

    log_section "What was configured"
    echo "  01. Base system update"
    echo "  02. Third-party repositories (RPM Fusion / AUR / COPRs / Brave)"
    echo "  03. CPU microcode, system packages, firewall, groups, ClamAV, Podman"
    echo "  04. mise tools, Flatpak apps, Homebrew formulae"
    echo "  05. GitHub and install-script tools"
    echo "  06. Snapper snapshots + $BOOTLOADER boot menu integration"
    echo "  07. Proton Drive rclone mount (~/ProtonDrive)"
    echo "  08. Dotfiles applied via chezmoi"
    echo "  09. Weekly system and user application updates"
    echo "  10. Sway and login-manager configuration"
    echo ""

    log_section "Required follow-up actions"
    echo "  • Reboot to apply group membership changes (libvirt, video, input, etc.)"
    echo "  • If Proton Drive was skipped: run  rclone config  then re-run module 07"
    echo "  • Check the log for any warnings:  cat ${LOG_FILE}"
    echo ""

    log_section "Useful commands"
    echo "  Snapshot list:   snapper list"
    echo "  Roll back:       sudo snapper rollback <number>"
    echo "  Update mise:     mise upgrade"
    echo "  Update Flatpak:  flatpak update"
    echo "  Update Homebrew: brew upgrade"
    echo "  Update logs:     journalctl -u unix-setup-system-update"
    echo "                   cat ~/.local/state/unix-setup/weekly-update.log"
    echo "  Reapply dots:    chezmoi apply"
    echo ""

    log_info "Full log saved to: ${LOG_FILE}"
}

main "$@"
