#!/usr/bin/env bash
# ==============================================================================
# modules/09-sway-config.sh — Sway/SwayFX bootstrap configuration
# ==============================================================================
# OPTIONAL MODULE — not run as part of the default setup.sh sequence.
# Run it manually when you don't have dotfiles yet and need a working desktop:
#
#   bash setup/modules/09-sway-config.sh
#   # or via setup.sh:
#   bash setup/setup.sh --only 09
#
# What this module does:
#
#   1. greetd — configures /etc/greetd/config.toml to launch swayfx (or sway
#               on non-Arch distros) via tuigreet, then enables greetd as a
#               systemd service so it starts on boot instead of a TTY login.
#
#   2. Sway config — creates ~/.config/sway/config with a minimal working
#                    configuration if none exists. This is intentionally bare —
#                    just enough to get a usable desktop until chezmoi applies
#                    your real dotfiles. If a config already exists it is NOT
#                    overwritten; only the flameshot rule is appended if missing.
#
#   3. Flameshot fix — appends the window rule that makes flameshot work
#                      correctly on wlroots-based compositors (Sway/SwayFX).
#                      Without it the capture window positions itself wrong or
#                      doesn't appear. Skipped if the rule is already present.
#
# Once your dotfiles are applied via module 07 (chezmoi), your real Sway config
# will replace the minimal one written here. The flameshot rule should already
# be in your dotfiles Sway config at that point — chezmoi apply will overwrite
# this file entirely.
#
# Depends on: 03-packages.sh (greetd, sway/swayfx must be installed first)
# ==============================================================================

[[ -n "${_MODULE_SWAY_CONFIG_LOADED:-}" ]] && return
_MODULE_SWAY_CONFIG_LOADED=1

SWAY_CONFIG_DIR="${HOME}/.config/sway"
SWAY_CONFIG="${SWAY_CONFIG_DIR}/config"

# The flameshot window rule — explained in detail below in apply_flameshot_fix()
FLAMESHOT_RULE='for_window [app_id="flameshot"] border pixel 0, floating enable, fullscreen disable, move absolute position 0 0'

# ------------------------------------------------------------------------------
# setup_login_manager
# Detects which login manager is installed and configures it to launch
# swayfx (on Arch) or sway (on other distros) after login.
#
# Supported managers, in detection order:
#   SDDM    — Qt-based, most popular for tiling WMs (recommended)
#   GDM     — GNOME's manager, polished but heavyweight
#   LightDM — lightweight and modular, works with various greeters
#   greetd  — minimal daemon, pairs with a separate greeter (tuigreet etc.)
#
# SDDM and GDM handle compositor selection automatically via the desktop
# session file — no extra config needed beyond enabling the service.
# LightDM needs its session set via lightdm.conf.
# greetd needs a config.toml pointing at the compositor directly.
# ------------------------------------------------------------------------------
setup_login_manager() {
    log_section "Login manager"

    # Pick the compositor command based on what's installed
    local compositor
    if cmd_exists swayfx; then
        compositor="swayfx"
    elif cmd_exists sway; then
        compositor="sway"
    else
        log_error "Neither swayfx nor sway found — install one before running this module"
        return 1
    fi
    log_info "Compositor: $compositor"

    if cmd_exists sddm; then
        _setup_sddm "$compositor"
    elif cmd_exists gdm; then
        _setup_gdm
    elif cmd_exists lightdm; then
        _setup_lightdm "$compositor"
    elif cmd_exists greetd; then
        _setup_greetd "$compositor"
    else
        log_warn "No supported login manager found."
        log_warn "Install one from packages/sway.txt then re-run this module."
        log_warn "Recommended: sddm"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# _setup_sddm
# SDDM picks up Wayland sessions automatically from /usr/share/wayland-sessions/.
# swayfx and sway both install a .desktop file there when packaged correctly,
# so no extra config is needed — just enable the service.
# ------------------------------------------------------------------------------
_setup_sddm() {
    local compositor="$1"
    log_info "Configuring SDDM..."

    # Ensure the wayland session directory exists and the compositor has a
    # session file. Most packages provide this; warn if it's missing.
    local session_file="/usr/share/wayland-sessions/${compositor}.desktop"
    if [[ ! -f "$session_file" ]]; then
        log_warn "Session file not found: $session_file"
        log_warn "SDDM may not show $compositor in the session list."
        log_warn "It may be provided by the $compositor package — check after install."
    fi

    systemd_enable sddm
    log_success "SDDM enabled — will present login screen on next boot"
}

# ------------------------------------------------------------------------------
# _setup_gdm
# GDM auto-detects installed Wayland sessions from /usr/share/wayland-sessions/
# the same way SDDM does. Just enable the service.
# ------------------------------------------------------------------------------
_setup_gdm() {
    log_info "Configuring GDM..."
    systemd_enable gdm
    log_success "GDM enabled — will present login screen on next boot"
}

# ------------------------------------------------------------------------------
# _setup_lightdm
# LightDM needs to be told which session to start. This writes the autologin
# session name into /etc/lightdm/lightdm.conf so it defaults to sway/swayfx.
# The user still sees the greeter and can pick a different session if needed.
# ------------------------------------------------------------------------------
_setup_lightdm() {
    local compositor="$1"
    log_info "Configuring LightDM (session: $compositor)..."

    if [[ "$DRY_RUN" != true ]]; then
        sudo mkdir -p /etc/lightdm
        # Set the default Wayland session — lightdm matches this against
        # the Name= field in /usr/share/wayland-sessions/*.desktop
        sudo sed -i "s/^#*user-session=.*/user-session=${compositor}/" \
            /etc/lightdm/lightdm.conf 2>/dev/null || \
        sudo tee -a /etc/lightdm/lightdm.conf > /dev/null << EOF

[Seat:*]
user-session=${compositor}
EOF
    else
        log_info "[DRY-RUN] Would set LightDM default session to $compositor"
    fi

    systemd_enable lightdm
    log_success "LightDM enabled with session: $compositor"
}

# ------------------------------------------------------------------------------
# _setup_greetd
# greetd is a minimal login daemon that delegates the UI to a separate greeter.
# Writes /etc/greetd/config.toml pointing at whichever greeter is installed,
# which in turn launches the compositor after successful login.
# ------------------------------------------------------------------------------
_setup_greetd() {
    local compositor="$1"
    log_info "Configuring greetd (compositor: $compositor)..."

    # Pick a greeter — prefer GUI options, fall back to TUI, then bundled agreety
    local greeter_cmd
    if cmd_exists regreet; then
        greeter_cmd="regreet"
    elif cmd_exists nwg-hello; then
        greeter_cmd="nwg-hello"
    elif cmd_exists tuigreet; then
        greeter_cmd="tuigreet --time --remember --cmd ${compositor}"
    else
        log_warn "No greeter found — falling back to agreety (install greetd-regreet for a GUI greeter)"
        greeter_cmd="agreety --cmd ${compositor}"
    fi

    if [[ "$DRY_RUN" != true ]]; then
        sudo mkdir -p /etc/greetd
        sudo tee /etc/greetd/config.toml > /dev/null << EOF
[terminal]
vt = 1

[default_session]
command = "${greeter_cmd}"
user = "greeter"
EOF
    else
        log_info "[DRY-RUN] Would write /etc/greetd/config.toml with cmd: $greeter_cmd"
    fi

    systemd_enable greetd
    log_success "greetd configured with greeter: $greeter_cmd"
}

# ------------------------------------------------------------------------------
# create_minimal_sway_config
# Creates ~/.config/sway/config with a bare minimum configuration so you have
# a usable desktop without dotfiles. This is intentionally sparse — it gives
# you a working Sway session with a terminal and app launcher, nothing more.
#
# Key bindings written:
#   $mod+Return — open a terminal (tries common terminals in order)
#   $mod+d      — open rofi app launcher
#   $mod+Shift+q — kill focused window
#   $mod+Shift+e — exit sway
#
# The flameshot rule is NOT added here — apply_flameshot_fix() handles that
# separately so it can also patch an existing config safely.
#
# If ~/.config/sway/config already exists, this function does nothing.
# Your real config from chezmoi/dotfiles will replace this file entirely
# when module 07 runs.
# ------------------------------------------------------------------------------
create_minimal_sway_config() {
    log_section "Minimal Sway config"

    if [[ -f "$SWAY_CONFIG" ]]; then
        log_info "Sway config already exists at $SWAY_CONFIG — skipping creation"
        log_info "(The flameshot fix will still be applied if missing)"
        return
    fi

    log_info "Creating minimal Sway config at $SWAY_CONFIG..."

    # Detect a terminal emulator to set as the default.
    # Priority: ghostty (preferred) → wezterm → foot → xterm (fallback)
    local terminal="xterm"
    for term in ghostty wezterm foot; do
        if cmd_exists "$term"; then
            terminal="$term"
            break
        fi
    done
    log_info "Using terminal: $terminal"

    if [[ "$DRY_RUN" != true ]]; then
        mkdir -p "$SWAY_CONFIG_DIR"
        cat > "$SWAY_CONFIG" << EOF
# ==============================================================================
# Minimal Sway config — created by setup/modules/09-sway-config.sh
# Replace this with your real dotfiles via: chezmoi apply
# ==============================================================================

# Mod key: Mod4 = Super/Windows key, Mod1 = Alt
set \$mod Mod4
set \$terminal ${terminal}
set \$menu rofi -show drun

# Use Mouse+\$mod to drag floating windows
floating_modifier \$mod normal

# ── Basics ────────────────────────────────────────────────────────────────────
bindsym \$mod+Return exec \$terminal
bindsym \$mod+d exec \$menu
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+e exit

# ── Focus ─────────────────────────────────────────────────────────────────────
bindsym \$mod+Left  focus left
bindsym \$mod+Down  focus down
bindsym \$mod+Up    focus up
bindsym \$mod+Right focus right

# ── Move ──────────────────────────────────────────────────────────────────────
bindsym \$mod+Shift+Left  move left
bindsym \$mod+Shift+Down  move down
bindsym \$mod+Shift+Up    move up
bindsym \$mod+Shift+Right move right

# ── Workspaces ────────────────────────────────────────────────────────────────
bindsym \$mod+1 workspace number 1
bindsym \$mod+2 workspace number 2
bindsym \$mod+3 workspace number 3
bindsym \$mod+4 workspace number 4
bindsym \$mod+5 workspace number 5
bindsym \$mod+Shift+1 move container to workspace number 1
bindsym \$mod+Shift+2 move container to workspace number 2
bindsym \$mod+Shift+3 move container to workspace number 3
bindsym \$mod+Shift+4 move container to workspace number 4
bindsym \$mod+Shift+5 move container to workspace number 5

# ── Layout ────────────────────────────────────────────────────────────────────
bindsym \$mod+b splith
bindsym \$mod+v splitv
bindsym \$mod+f fullscreen
bindsym \$mod+Shift+space floating toggle

# ── Status bar ────────────────────────────────────────────────────────────────
bar {
    status_command date '+%Y-%m-%d %H:%M'
    position top
}

# ── Output ────────────────────────────────────────────────────────────────────
# Remove this block once your dotfiles set up kanshi for multi-monitor support
output * bg #1e1e2e solid_color

# ── Input ─────────────────────────────────────────────────────────────────────
input type:touchpad {
    tap enabled
    natural_scroll enabled
}

# ── XDG autostart ─────────────────────────────────────────────────────────────
exec systemctl --user import-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK
exec hash dbus-update-activation-environment 2>/dev/null && \
     dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK

EOF
        log_success "Minimal Sway config written to $SWAY_CONFIG"
    else
        log_info "[DRY-RUN] Would write minimal Sway config to $SWAY_CONFIG"
    fi
}

# ------------------------------------------------------------------------------
# apply_flameshot_fix
# Appends the flameshot Wayland window rule to ~/.config/sway/config.
#
# Why this rule is needed:
#   Flameshot spawns a full-screen transparent window to capture from. On
#   wlroots compositors (Sway/SwayFX), that window doesn't receive the
#   correct position or border treatment by default, causing it to render
#   in the wrong place or not appear at all.
#
#   The rule does four things:
#     border pixel 0        — removes the window border (prevents a visible frame
#                             around the capture overlay)
#     floating enable       — forces the window into floating mode (tiling breaks
#                             the full-screen capture overlay)
#     fullscreen disable    — prevents Sway from treating it as a fullscreen app
#                             (which would hide the overlay behind other windows)
#     move absolute position 0 0 — pins the window to the top-left corner of the
#                             display so the capture area aligns with screen coords
#
# The rule is identified by a marker comment so this function is idempotent —
# running it twice won't duplicate the rule.
# ------------------------------------------------------------------------------
apply_flameshot_fix() {
    log_section "Flameshot Wayland fix"

    if [[ ! -f "$SWAY_CONFIG" ]]; then
        log_warn "No Sway config found at $SWAY_CONFIG — run create_minimal_sway_config first"
        return 1
    fi

    # Check if the rule is already present (either from dotfiles or a previous run)
    if grep -q "app_id=\"flameshot\"" "$SWAY_CONFIG"; then
        log_info "Flameshot window rule already present in $SWAY_CONFIG — skipping"
        return
    fi

    log_info "Appending flameshot window rule to $SWAY_CONFIG..."
    if [[ "$DRY_RUN" != true ]]; then
        cat >> "$SWAY_CONFIG" << EOF

# ── Flameshot (Wayland fix) ───────────────────────────────────────────────────
# Required for flameshot to work correctly on wlroots compositors.
# See: https://github.com/flameshot-org/flameshot/issues/2881
${FLAMESHOT_RULE}
EOF
        log_success "Flameshot window rule added to $SWAY_CONFIG"
    else
        log_info "[DRY-RUN] Would append flameshot rule to $SWAY_CONFIG"
    fi
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 09: Sway config (optional)"

    setup_login_manager
    create_minimal_sway_config
    apply_flameshot_fix

    echo ""
    log_success "Module 09 complete"
    log_info "Next steps:"
    log_info "  • Reboot to start greetd and log into SwayFX"
    log_info "  • Once you have SSH set up, run module 07 to apply your real dotfiles"
    log_info "    chezmoi apply will replace the minimal Sway config with your full one"
}

main "$@"
