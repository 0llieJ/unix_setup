#!/usr/bin/env bash
# ==============================================================================
# modules/14-webapps.sh — Web-app launchers
# ==============================================================================
# Installs the `webapp` generator to ~/.local/bin and creates launcher entries
# for the sites listed in packages/webapps.txt, using a Chromium-based browser
# (Helium preferred, then Brave) in --app mode. The entries show up in rofi /
# your launcher as standalone apps.
#
# Add more later with:  webapp add "Name" https://url
#
# Depends on: a Chromium-based browser (helium-browser-bin / brave-bin on Arch,
# installed in module 03). If none is present, entries are still written but the
# generator warns; install a browser and re-run module 14.
# ==============================================================================

[[ -n "${_MODULE_WEBAPPS_LOADED:-}" ]] && return
_MODULE_WEBAPPS_LOADED=1

if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

WEBAPP_LIST="${SETUP_DIR}/packages/webapps.txt"
WEBAPP_SRC="${SETUP_DIR}/bin/webapp"
WEBAPP_BIN="${HOME}/.local/bin/webapp"

# ------------------------------------------------------------------------------
# install_generator — copy bin/webapp into ~/.local/bin so it's on PATH for later
# ------------------------------------------------------------------------------
install_generator() {
    if [[ ! -f "$WEBAPP_SRC" ]]; then
        log_warn "Generator not found at $WEBAPP_SRC — skipping web apps"
        return 1
    fi
    log_info "Installing webapp generator → $WEBAPP_BIN"
    run_cmd install -D -m 0755 "$WEBAPP_SRC" "$WEBAPP_BIN"
}

# ------------------------------------------------------------------------------
# create_webapps — read webapps.txt (Name | URL) and create a launcher for each
# ------------------------------------------------------------------------------
create_webapps() {
    if [[ ! -f "$WEBAPP_LIST" ]]; then
        log_info "No webapps.txt — nothing to create"
        return 0
    fi

    local name url created=0
    while IFS='|' read -r name url; do
        # Strip comments and surrounding whitespace from each field.
        name="${name%%#*}"; url="${url%%#*}"
        name="$(echo "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        url="$(echo "$url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "$name" || -z "$url" ]] && continue

        log_info "Web app: $name → $url"
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] webapp add \"$name\" \"$url\""
        elif "$WEBAPP_BIN" add "$name" "$url"; then
            (( ++created ))
        else
            log_warn "Could not create web app: $name (need a Chromium-based browser)"
        fi
    done < "$WEBAPP_LIST"

    [[ "$DRY_RUN" != true ]] && log_info "Created $created web-app launcher(s)"
}

main() {
    log_section "Module 14: Web apps"

    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        log_info "macOS: skipping Linux web-app launchers (use Safari/Chrome 'Add to Dock')"
        return 0
    fi

    install_generator || return 0
    create_webapps

    log_success "Module 14 complete"
    log_info "Add more web apps any time:  webapp add \"Name\" https://url"
    log_info "List them:  webapp list"
}

main "$@"
