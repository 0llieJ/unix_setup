#!/usr/bin/env bash
# ==============================================================================
# lib/log.sh — Logging helpers
# ==============================================================================
# Provides coloured terminal output and log file writing.
# Source this file from any module — do not execute it directly.
#
# Usage:
#   source "$SETUP_DIR/lib/log.sh"
#   log_info    "Installing packages..."
#   log_success "Done."
#   log_warn    "Package foo not found, skipping."
#   log_error   "Failed to install bar."
#   log_section "Phase 2: Packages"
# ==============================================================================

# ------------------------------------------------------------------------------
# ANSI colour codes
# These make terminal output easier to scan at a glance.
# NC (No Colour) resets the terminal back to its default after each message.
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# LOG_FILE
# All messages are written here in plain text (no colour codes) alongside the
# terminal output, so there's a record of the full run to inspect afterwards.
# Can be overridden before sourcing: LOG_FILE=/var/log/mysetup.log
# ------------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-/tmp/setup.log}"

# ------------------------------------------------------------------------------
# _log — internal helper called by all public log_* functions
# $1 = colour code  $2 = label (INFO / OK / WARN / ERROR)  $3+ = message
# Prints a coloured, bold label then the message to stdout.
# Strips colour codes when writing to the log file (plain text only).
# ------------------------------------------------------------------------------
_log() {
    local colour="$1" label="$2"
    shift 2
    local msg="$*"
    printf "${colour}${BOLD}[%s]${NC} %s\n" "$label" "$msg"
    printf "[%s] %s\n" "$label" "$msg" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Public logging functions
# Each wraps _log with a fixed colour and label.
# ------------------------------------------------------------------------------

# General progress messages — blue
log_info()    { _log "$BLUE"   "INFO"  "$@"; }

# Step completed successfully — green
log_success() { _log "$GREEN"  "OK"    "$@"; }

# Non-fatal issue, setup continues — yellow
log_warn()    { _log "$YELLOW" "WARN"  "$@"; }

# Fatal or serious problem — red, printed to stderr
log_error()   { _log "$RED"    "ERROR" "$@" >&2; }

# ------------------------------------------------------------------------------
# log_section — prints a bold divider line to mark the start of a new phase.
# Makes it easy to find where each module begins in both the terminal and the
# log file.
# ------------------------------------------------------------------------------
log_section() {
    echo ""
    printf "${BOLD}━━━ %s ━━━${NC}\n" "$*"
    printf "\n--- %s ---\n" "$*" >> "$LOG_FILE"
}
