#!/usr/bin/env bash
# ==============================================================================
# modules/10-sway-config.sh — Sway/SwayFX bootstrap configuration
# ==============================================================================
# Runs before dotfiles in the default setup sequence. It can also be run alone:
#
#   bash setup/modules/10-sway-config.sh
#   # or via setup.sh:
#   bash setup/setup.sh --only 10
#
# What this module does:
#
#   1. Login manager — configures the installed display manager for SwayFX
#                      (or Sway), enables it, and makes graphical.target the
#                      default boot target instead of a TTY-only login.
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
# Once your dotfiles are applied via module 08 (chezmoi), your real Sway config
# will replace the minimal one written here. The flameshot rule should already
# be in your dotfiles Sway config at that point — chezmoi apply will overwrite
# this file entirely.
#
# Depends on: 03-packages.sh (greetd, sway/swayfx must be installed first)
# ==============================================================================

[[ -n "${_MODULE_SWAY_CONFIG_LOADED:-}" ]] && return
_MODULE_SWAY_CONFIG_LOADED=1

if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

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

    _set_graphical_boot_target
}

# ------------------------------------------------------------------------------
# _ensure_wayland_session <compositor>
# Some third-party compositor packages install the executable without a matching
# desktop entry. SDDM and GDM need that entry to offer the session after login.
# ------------------------------------------------------------------------------
_ensure_wayland_session() {
    local compositor="$1"
    local session_file="/usr/share/wayland-sessions/${compositor}.desktop"
    local compositor_path
    compositor_path="$(command -v "$compositor")"

    if [[ -f "$session_file" ]]; then
        log_info "Wayland session found: $session_file"
        return 0
    fi

    log_warn "Wayland session file missing; creating: $session_file"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would create $session_file for $compositor_path"
        return 0
    fi

    sudo mkdir -p /usr/share/wayland-sessions
    sudo tee "$session_file" > /dev/null << EOF
[Desktop Entry]
Name=${compositor^}
Comment=An i3-compatible Wayland compositor
Exec=${compositor_path}
TryExec=${compositor_path}
Type=Application
DesktopNames=sway
EOF
}

# ------------------------------------------------------------------------------
# _set_graphical_boot_target
# Minimal Arch installations commonly default to multi-user.target. A display
# manager can be enabled correctly and still not be reached through that boot
# path, so make the intended graphical boot target explicit.
# ------------------------------------------------------------------------------
_set_graphical_boot_target() {
    if ! has_systemd; then
        log_warn "systemd is not active; cannot set the graphical boot target"
        return 0
    fi

    run_cmd sudo systemctl set-default graphical.target

    if [[ "$DRY_RUN" != true ]]; then
        local default_target
        default_target="$(systemctl get-default)"
        if [[ "$default_target" != "graphical.target" ]]; then
            log_error "Default systemd target is still: $default_target"
            return 1
        fi
    fi

    log_success "Default boot target set to graphical.target"
}

# ------------------------------------------------------------------------------
# _setup_sddm
# SDDM picks up Wayland sessions automatically from /usr/share/wayland-sessions/.
# Ensure the session exists, then enable and verify the service.
# ------------------------------------------------------------------------------
_setup_sddm() {
    local compositor="$1"
    log_info "Configuring SDDM..."

    _ensure_wayland_session "$compositor"

    if ! has_systemd; then
        log_warn "systemd is not active; SDDM cannot be enabled in this environment"
        return 0
    fi
    if ! systemctl list-unit-files sddm.service &>/dev/null; then
        log_error "SDDM is installed but sddm.service was not found"
        return 1
    fi

    run_cmd sudo systemctl enable --now sddm.service

    if [[ "$DRY_RUN" != true ]] && ! systemctl is-enabled --quiet sddm.service; then
        log_error "SDDM did not become enabled"
        return 1
    fi

    log_success "SDDM enabled and started"
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
# apply_vm_renderer_fix
# wlroots compositors (Sway/SwayFX) initialise an EGL/DRI GPU renderer on start.
# Inside a VM without 3D acceleration that fails hard:
#
#   VMware: No 3D enabled
#   libEGL warning: egl: failed to create dri2 screen
#   [sway/server.c] Failed to create renderer
#
# SwayFX's fx_renderer is GLES/EGL-only — it has NO pixman software path (unlike
# vanilla Sway), so WLR_RENDERER=pixman is ignored and EGL still fails. The fix
# that works for SwayFX is to give EGL a software GL context: LIBGL_ALWAYS_SOFTWARE
# forces Mesa's llvmpipe (CPU) driver, so fx_renderer initialises with no GPU.
# We set it in /etc/environment so it applies to the session the display manager
# launches (PAM reads /etc/environment for every login, graphical sessions
# included). Only done when a VM is detected.
#
# A better-performing alternative is enabling 3D acceleration in your hypervisor
# (e.g. VMware "Accelerate 3D graphics", virt-manager "virtio" + 3D / venus),
# but software rendering always works.
# ------------------------------------------------------------------------------
# _sway_is_fx
# True when the active compositor is SwayFX. SwayFX is typically installed AS
# /usr/bin/sway (a drop-in replacement — e.g. the WayBlue atomic image and the
# Arch swayfx package both do this), so there's no `swayfx` binary to look for.
# Detect it from the version string instead:
#   $ sway --version
#   swayfx version 0.5.2 (based on sway 1.10.1)
_sway_is_fx() {
    cmd_exists swayfx && return 0
    cmd_exists sway && sway --version 2>/dev/null | grep -qi swayfx
}

apply_vm_renderer_fix() {
    [[ "${IS_VM:-no}" != "yes" ]] && return 0

    log_section "VM graphics fix"
    log_info "Virtual machine detected ($VIRT_TYPE) — enabling wlroots software rendering"
    log_info "(For better performance, enable 3D acceleration in your hypervisor instead)"

    local envf="/etc/environment"

    # The right renderer var depends on the compositor:
    #   SwayFX — fx_renderer is GLES/EGL-only (no pixman path). Give EGL a software
    #            GL context via LIBGL_ALWAYS_SOFTWARE=1 (Mesa llvmpipe) so it inits
    #            with no GPU. WLR_RENDERER=pixman is IGNORED by SwayFX.
    #   Sway   — vanilla wlroots honours WLR_RENDERER=pixman (lighter: skips GL).
    local render_var stale_key
    if _sway_is_fx; then
        log_info "Compositor: SwayFX (GL-only) — using software GL (Mesa llvmpipe)"
        render_var="LIBGL_ALWAYS_SOFTWARE=1"
        stale_key="WLR_RENDERER"          # remove the vanilla-Sway var if present
    else
        log_info "Compositor: Sway — using the pixman software renderer"
        render_var="WLR_RENDERER=pixman"
        stale_key="LIBGL_ALWAYS_SOFTWARE" # remove the SwayFX var if present
    fi

    # WLR_NO_HARDWARE_CURSORS=1  — VMs often lack hardware cursor planes
    # QT_QUICK_BACKEND=software  — force Qt Quick's software renderer. Without it
    #                              Qt/Quickshell apps (Noctalia) try the GPU dmabuf
    #                              path, which fails in a VM with "importing the
    #                              supplied dmabufs failed" → Wayland protocol error
    #                              and the shell crashes on launch.
    local vars=("$render_var" "WLR_NO_HARDWARE_CURSORS=1" "QT_QUICK_BACKEND=software")

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would ensure ${vars[*]} in $envf (and drop ${stale_key}=)"
        return 0
    fi

    # Drop the other variant's renderer var so switching compositors doesn't
    # leave a stale/contradictory setting behind.
    sudo sed -i "/^${stale_key}=/d" "$envf" 2>/dev/null || true

    local v key
    for v in "${vars[@]}"; do
        key="${v%%=*}"
        if sudo grep -q "^${key}=" "$envf" 2>/dev/null; then
            sudo sed -i "s|^${key}=.*|${v}|" "$envf"
        else
            echo "$v" | sudo tee -a "$envf" > /dev/null
        fi
    done

    log_success "Software rendering enabled for VM ($render_var)"
    log_info "Takes effect on next login — reboot or re-login before starting Sway"
}

# ------------------------------------------------------------------------------
# noctalia_cmd
# Noctalia runs on a Quickshell runtime. The current `noctalia-qs` package
# provides the `qs` (and `quickshell`) binary — NOT a binary literally named
# `noctalia-qs` — plus the shell config under /etc/xdg/quickshell/noctalia-shell,
# which `qs -c noctalia-shell` finds via XDG_CONFIG_DIRS. A manual install puts
# the same config under ~/.config/quickshell. Older packages shipped a
# `noctalia-qs` wrapper binary, which is still honoured if present. Prints the
# right launcher command, or nothing if the runtime/config isn't installed.
# ------------------------------------------------------------------------------
noctalia_cmd() {
    if cmd_exists noctalia-qs; then
        echo "noctalia-qs -c noctalia-shell"
    elif cmd_exists qs && { [[ -d "${HOME}/.config/quickshell/noctalia-shell" ]] \
            || [[ -d /etc/xdg/quickshell/noctalia-shell ]]; }; then
        echo "qs -c noctalia-shell"
    fi
}

# ------------------------------------------------------------------------------
# ensure_noctalia
# Installs the Noctalia desktop shell so it works on a fresh machine rather than
# the autostart line silently skipping. Noctalia provides its own bar, launcher,
# and notifications, replacing waybar/mako/rofi (see create_minimal_sway_config).
#
# Install methods per https://docs.noctalia.dev/v4/getting-started/installation/:
#   Arch   — AUR `noctalia-shell` (pulls noctalia-qs); normally already installed
#            by module 03 from packages/arch-aur.txt. Installed on demand here too.
#   Fedora — Terra repo (Fyra Labs), then `dnf install noctalia-shell`.
#   Other  — Quickshell/noctalia-qs isn't packaged for Debian/Ubuntu; the manual
#            tarball provides only the config, not the runtime, so it's best-effort
#            with a clear warning rather than a half-working install.
# ------------------------------------------------------------------------------
ensure_noctalia() {
    [[ "$DISTRO_FAMILY" == "macos" ]] && return 0

    log_section "Noctalia shell"

    if [[ -n "$(noctalia_cmd)" ]]; then
        log_info "Noctalia runtime already present: $(noctalia_cmd)"
        return 0
    fi

    case "$DISTRO_FAMILY" in
        arch)
            if cmd_exists paru; then
                log_info "Installing noctalia-shell via paru (AUR)..."
                run_cmd paru -S --needed --noconfirm noctalia-shell \
                    || log_warn "Could not install noctalia-shell via paru"
                # Verify via the resolved launcher, not a `noctalia-qs` binary —
                # the package provides `qs`, so checking for noctalia-qs gives a
                # false "failed install" even when it installed correctly.
                [[ -n "$(noctalia_cmd)" ]] || record_failed_pkg "AUR" "noctalia-shell"
            else
                log_warn "paru not found — cannot install Noctalia"
            fi
            ;;
        fedora)
            if [[ "$SYSTEM_PROFILE" == "atomic" ]]; then
                log_warn "Atomic Fedora — layer Noctalia manually instead:"
                log_warn "  rpm-ostree install noctalia-shell  (after adding the Terra repo)"
                return 0
            fi
            log_info "Adding the Terra repository (provides noctalia-shell)..."
            # Terra is Fyra Labs' third-party Fedora repo; it carries noctalia-shell
            # and its noctalia-qs runtime. $releasever expands to the Fedora version.
            run_cmd sudo dnf install -y --nogpgcheck \
                --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
                terra-release || log_warn "Could not add the Terra repo"
            pkg_install noctalia-shell
            ;;
        *)
            log_warn "Noctalia (noctalia-qs runtime) is not packaged for $DISTRO_FAMILY"
            log_warn "Install it manually — see https://docs.noctalia.dev/v4/getting-started/installation/"
            ;;
    esac
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
# when module 08 runs.
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

    # Noctalia provides its own bar (and launcher/notifications). When it's
    # active, omit swaybar so you don't get two stacked bars. apply_noctalia_
    # autostart() adds the exec line that actually starts it.
    local bar_block
    if [[ -n "$(noctalia_cmd)" ]]; then
        bar_block="# ── Status bar ────────────────────────────────────────────────────────────────
# Provided by Noctalia (see the noctalia-shell exec below) — swaybar disabled."
        log_info "Noctalia detected — swaybar omitted from the minimal config"
    else
        # NOTE: sway's config parser strips one level of quoting from the
        # status_command before handing it to `sh -c`, so a quoted date format
        # containing a space (e.g. '+%Y-%m-%d %H:%M') is split into two args and
        # date fails with "extra operand" — that error then shows on the bar.
        # Use an ISO-8601 'T' separator so no quoting/space is needed at all.
        bar_block="# ── Status bar ────────────────────────────────────────────────────────────────
bar {
    status_command while date +%Y-%m-%dT%H:%M; do sleep 20; done
    position top
}"
    fi

    if [[ "$DRY_RUN" != true ]]; then
        mkdir -p "$SWAY_CONFIG_DIR"
        cat > "$SWAY_CONFIG" << EOF
# ==============================================================================
# Minimal Sway config — created by setup/modules/10-sway-config.sh
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

${bar_block}

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
# apply_noctalia_autostart
# Appends the Noctalia autostart exec line to ~/.config/sway/config, using the
# correct runtime command (noctalia-qs for the packaged install, qs for a manual
# one — see noctalia_cmd). It must be started as an exec in the Sway config
# rather than as a systemd user service because it needs the Wayland compositor
# to be running first.
#
# Because Noctalia provides the bar AND notifications, this also disables any
# leftover waybar/mako user services so they don't run alongside it and produce
# a duplicate bar or double notifications.
#
# The line is identified by a marker comment so this function is idempotent.
# ------------------------------------------------------------------------------
apply_noctalia_autostart() {
    log_section "Noctalia autostart"

    if [[ ! -f "$SWAY_CONFIG" ]]; then
        log_warn "No Sway config found at $SWAY_CONFIG — run create_minimal_sway_config first"
        return 1
    fi

    local launcher
    launcher="$(noctalia_cmd)"
    if [[ -z "$launcher" ]]; then
        log_warn "Noctalia runtime not found — autostart skipped"
        log_warn "Install it (module re-run, or see ensure_noctalia) then re-run this module"
        return
    fi

    # Noctalia replaces waybar and mako — stop any user services for them so they
    # don't draw a second bar or duplicate notifications next to Noctalia.
    if has_systemd && [[ "$DRY_RUN" != true ]]; then
        local svc
        for svc in waybar.service mako.service; do
            if systemctl --user list-unit-files "$svc" &>/dev/null; then
                log_info "Disabling $svc (Noctalia provides this) ..."
                systemctl --user disable --now "$svc" 2>/dev/null || true
            fi
        done
    fi

    if grep -q "noctalia-shell" "$SWAY_CONFIG"; then
        log_info "Noctalia autostart already present in $SWAY_CONFIG — skipping"
        return
    fi

    log_info "Appending Noctalia autostart ($launcher) to $SWAY_CONFIG..."
    if [[ "$DRY_RUN" != true ]]; then
        cat >> "$SWAY_CONFIG" << EOF

# ── Noctalia shell (bar, launcher, notifications) ─────────────────────────────
# Replaces waybar/mako/rofi. Launched via its Quickshell runtime.
exec ${launcher}
EOF
        log_success "Noctalia autostart added to $SWAY_CONFIG"
    else
        log_info "[DRY-RUN] Would append 'exec ${launcher}' to $SWAY_CONFIG"
    fi
}

# ------------------------------------------------------------------------------
# setup_system_services
# Enables system-level services that need to be running for a full desktop.
# These are all idempotent — enabling an already-enabled service is a no-op.
#
# Services enabled:
#   NetworkManager — network connectivity and desktop network management
#   bluetooth  — Bluetooth daemon (required for blueman and BT devices)
#   pcscd      — PC/SC smart card daemon (required for YubiKey)
#   libvirtd   — Virtualisation daemon (required for virt-manager / QEMU)
#   logid      — Logitech device configuration daemon (from logiops-git)
#   fstrim     — Weekly SSD discard
#   power-profiles-daemon — Laptop/desktop power profile management
#
# Pipewire is enabled as user services — must run as the current user,
# not as root, so we use `systemctl --user`.
# ------------------------------------------------------------------------------
setup_system_services() {
    log_section "System services"

    systemd_enable NetworkManager.service
    systemd_enable bluetooth
    systemd_enable pcscd
    systemd_enable libvirtd
    systemd_enable fstrim.timer
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        systemd_enable paccache.timer
    fi

    if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
        systemd_enable tuned.service
        systemd_enable tuned-ppd.service
    else
        systemd_enable power-profiles-daemon.service
    fi

    # logid is only relevant if logiops is installed
    if cmd_exists logid; then
        systemd_enable logid
    else
        log_info "logid not found — skipping (install logiops-git to configure Logitech devices)"
    fi

    log_info "Enabling Pipewire user services..."
    if [[ "$DRY_RUN" != true ]]; then
        systemctl --user enable --now pipewire.service
        systemctl --user enable --now pipewire-pulse.service
        systemctl --user enable --now wireplumber.service
    else
        log_info "[DRY-RUN] Would enable pipewire, pipewire-pulse, wireplumber user services"
    fi

    setup_desktop_user_services

    log_success "System services enabled"
}

setup_desktop_user_services() {
    log_info "Configuring desktop user services..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would configure polkit, keyring, and Flameshot services"
        return
    fi

    mkdir -p "${HOME}/.config/systemd/user"

    local polkit_agent=""
    for candidate in \
        /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
        /usr/libexec/polkit-gnome-authentication-agent-1; do
        if [[ -x "$candidate" ]]; then
            polkit_agent="$candidate"
            break
        fi
    done

    if [[ -n "$polkit_agent" ]]; then
        cat > "${HOME}/.config/systemd/user/polkit-agent.service" << EOF
[Unit]
Description=Graphical polkit authentication agent
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=${polkit_agent}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now polkit-agent.service
    else
        log_warn "polkit-gnome authentication agent binary not found"
    fi

    systemd_enable_user gnome-keyring-daemon.socket
    systemd_enable_user gcr-ssh-agent.socket

    # Remove the clipboard-history service created by older setup versions.
    systemctl --user disable --now cliphist.service 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/cliphist.service"
    systemctl --user daemon-reload

    if cmd_exists flameshot; then
        local flameshot_bin
        flameshot_bin="$(command -v flameshot)"
        cat > "${HOME}/.config/systemd/user/flameshot.service" << EOF
[Unit]
Description=Flameshot screenshot daemon
After=graphical-session.target

[Service]
ExecStart=${flameshot_bin}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now flameshot.service
    else
        log_warn "flameshot not found — screenshot daemon autostart skipped"
    fi

    if cmd_exists xdg-user-dirs-update; then
        run_cmd xdg-user-dirs-update
    fi
}

# ------------------------------------------------------------------------------
# setup_user_groups
# Adds the current user to the groups required for a full desktop environment.
#
# Groups:
#   wheel         — sudo access
#   networkmanager — manage network connections without root
#   video          — access to GPU / backlight control
#   audio          — direct audio device access (fallback alongside Pipewire)
#   input          — raw input device access (required by some Wayland compositors)
#   libvirtd       — manage VMs via libvirt without root
# ------------------------------------------------------------------------------
setup_user_groups() {
    log_section "User groups"

    local groups=("wheel" "networkmanager" "video" "audio" "input" "libvirtd")
    local user
    user="$(whoami)"

    for group in "${groups[@]}"; do
        if getent group "$group" &>/dev/null; then
            if id -nG "$user" | grep -qw "$group"; then
                log_info "$user already in $group — skipping"
            else
                log_info "Adding $user to $group..."
                run_cmd sudo usermod -aG "$group" "$user"
            fi
        else
            log_info "Group $group does not exist — skipping"
        fi
    done

    log_success "User groups configured (re-login for group changes to take effect)"
}

# ------------------------------------------------------------------------------
# setup_plasma_session
# Configures a working KDE Plasma session when the Sway/SwayFX install failed and
# module 03 installed Plasma as a fallback (DESKTOP_FALLBACK=kde). Plasma ships
# its own /usr/share/wayland-sessions entry, so we just point the display manager
# at it and set the graphical boot target.
# ------------------------------------------------------------------------------
setup_plasma_session() {
    log_section "KDE Plasma session (Sway fallback)"

    if ! cmd_exists startplasma-wayland && ! cmd_exists startplasma-x11; then
        log_warn "Plasma is not installed — cannot configure a desktop session"
        log_warn "Re-run module 03 or install a desktop environment manually"
        return 0
    fi

    if cmd_exists sddm; then
        log_info "Configuring SDDM for the Plasma session..."
        if has_systemd && systemctl list-unit-files sddm.service &>/dev/null; then
            run_cmd sudo systemctl enable --now sddm.service
        else
            log_warn "sddm.service not available — enable your display manager manually"
        fi
    elif cmd_exists gdm; then
        systemd_enable gdm
    else
        log_warn "No display manager found — install sddm to log into Plasma"
    fi

    _set_graphical_boot_target

    log_success "KDE Plasma configured as the desktop (Sway was unavailable)"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 10: Sway config"

    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        log_info "macOS: Sway is Linux-only — skipping"
        return 0
    fi

    if [[ "$SYSTEM_PROFILE" == "atomic" ]] && ! cmd_exists swayfx && ! cmd_exists sway; then
        log_info "Atomic system has no Sway compositor — skipping Sway configuration"
        return 0
    fi

    # Services and groups are needed for any desktop, Sway or the KDE fallback.
    setup_system_services
    setup_user_groups

    # If Sway/SwayFX never installed, module 03 falls back to KDE Plasma. Detect
    # that (either via the marker from module 03 or by the absence of a Sway
    # binary) and configure Plasma instead of writing a Sway config.
    if [[ "${DESKTOP_FALLBACK:-}" == "kde" ]] || { ! cmd_exists swayfx && ! cmd_exists sway; }; then
        log_warn "Sway/SwayFX not available — configuring the KDE Plasma fallback"
        setup_plasma_session
        echo ""
        log_success "Module 10 complete (KDE Plasma fallback)"
        log_info "Reboot to log into Plasma. Plasma 6 supports tiling via the built-in tile editor."
        return 0
    fi

    apply_vm_renderer_fix
    setup_login_manager
    ensure_noctalia

    # NOTE: Sway *configuration* is owned entirely by your dotfiles (chezmoi,
    # module 08) — e.g. ~/.config/sway/config.d/95-noctalia.conf (Noctalia vs the
    # standard bar) and 90-flameshot.conf. This module deliberately does NOT
    # generate or append a Sway config, so there is a single source of truth and
    # nothing clobbers your dotfiles. The Noctalia-vs-standard choice is made by
    # adding/removing that drop-in in your dotfiles, not here.
    #   (ensure_noctalia above still installs the package on non-atomic; on
    #    atomic the image bakes it. create_minimal_sway_config / apply_flameshot_
    #    fix / apply_noctalia_autostart remain defined below for manual use but
    #    are no longer called.)

    echo ""
    log_success "Module 10 complete"
    log_info "Next steps:"
    log_info "  • Re-login or reboot for group changes to take effect"
    log_info "  • Reboot to start the login manager and log into SwayFX"
    log_info "  • Apply your dotfiles (module 08 / chezmoi apply) — they provide"
    log_info "    your full Sway config, including the Noctalia/bar drop-in"
}

main "$@"
