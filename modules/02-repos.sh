#!/usr/bin/env bash
# ==============================================================================
# modules/02-repos.sh — Third-party repository setup
# ==============================================================================
# Adds the extra package sources needed before packages can be installed.
# Must run before 03-packages.sh.
#
# What gets added per distro:
#
#   Arch    — paru AUR helper (built from source via makepkg)
#   Fedora  — RPM Fusion (free + nonfree), Brave repo, ProtonVPN repo,
#              NetBird repo, Ghostty COPR, WezTerm COPR
#   Ubuntu  — Universe/Multiverse, Brave repo, ProtonVPN repo, NetBird repo
#   Debian  — Brave repo, ProtonVPN repo, NetBird repo
#
# All repo additions are idempotent — safe to re-run on an existing system.
# ==============================================================================

[[ -n "${_MODULE_REPOS_LOADED:-}" ]] && return
_MODULE_REPOS_LOADED=1

# ------------------------------------------------------------------------------
# setup_repos_arch
# Arch's official repos already cover most software. The main task here is
# installing paru, the AUR helper, so packages from the AUR can be installed
# in 03-packages.sh.
#
# paru is built from source using makepkg (Arch's package build tool).
# We use paru-bin from the AUR rather than building paru from scratch to avoid
# needing a full Rust toolchain at bootstrap time.
# ------------------------------------------------------------------------------
setup_repos_arch() {
    log_info "Arch: checking AUR helper..."

    if cmd_exists paru; then
        # paru binary exists — check it actually works. A pacman upgrade can
        # bump libalpm to a new version and break paru even though the binary
        # is still present on disk.
        repair_paru_if_broken
        return
    fi

    log_info "Installing paru (AUR helper)..."
    _build_paru
}

# ------------------------------------------------------------------------------
# repair_paru_if_broken
# Tests whether paru can load successfully by running `paru --version`.
# If it fails with a shared library error (libalpm version mismatch after a
# pacman upgrade), automatically rebuilds paru-bin from the AUR against the
# current libalpm version.
#
# This can happen mid-setup: module 02 installs paru, module 03 upgrades
# pacman (bumping libalpm), and then paru is broken for the AUR install step.
# Running this check at the start of module 02 catches it on re-runs.
# ------------------------------------------------------------------------------
repair_paru_if_broken() {
    # Try running paru — capture both stdout and stderr.
    # || true prevents set -e from killing the script if paru fails to load.
    # 2>&1 must come AFTER 1>/dev/null to correctly capture only stderr;
    # the reversed order (2>&1 >/dev/null) discards stderr into the void.
    local paru_err
    paru_err=$(paru --version 2>&1) || true

    if echo "$paru_err" | grep -q "cannot open shared object file"; then
        log_warn "paru is broken: $paru_err"
        log_warn "libalpm was likely upgraded by pacman — rebuilding paru-bin..."

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Would rebuild paru-bin from AUR"
            return
        fi

        _build_paru
        log_success "paru rebuilt successfully"
    else
        log_info "paru is working correctly"
    fi
}

# ------------------------------------------------------------------------------
# _build_paru
# Shared helper that clones paru-bin from the AUR and builds it with makepkg.
# Called by both setup_repos_arch (fresh install) and repair_paru_if_broken.
# ------------------------------------------------------------------------------
_build_paru() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would clone and build paru-bin from AUR"
        return
    fi

    # Install build prerequisites — base-devel contains make, gcc, fakeroot etc.
    sudo pacman -S --needed --noconfirm base-devel git

    # Remove any existing paru packages before building — orphaned packages
    # (e.g. paru-bin-debug left from a failed install) will conflict otherwise.
    local existing
    existing=$(pacman -Qq 2>/dev/null | grep '^paru' || true)
    if [[ -n "$existing" ]]; then
        log_info "Removing existing paru packages before build: $existing"
        # shellcheck disable=SC2086
        sudo pacman -Rns --noconfirm $existing
    fi

    local tmpdir
    tmpdir=$(mktemp -d)

    # Try paru-bin first (pre-compiled binary — faster than building from source).
    # If it fails due to a libalpm version mismatch, fall back to source build.
    log_info "Trying paru-bin (pre-compiled)..."
    git clone --depth=1 https://aur.archlinux.org/paru-bin.git "$tmpdir/paru-bin"
    if (cd "$tmpdir/paru-bin" && makepkg -si --noconfirm); then
        if paru --version &>/dev/null; then
            rm -rf "$tmpdir"
            log_success "paru installed"
            return
        fi
        log_warn "paru-bin installed but binary is broken (libalpm mismatch) — falling back to source build..."
        existing=$(pacman -Qq 2>/dev/null | grep '^paru' || true)
        [[ -n "$existing" ]] && sudo pacman -Rns --noconfirm $existing
    else
        log_warn "paru-bin build failed — falling back to source build..."
    fi

    log_info "Building paru from source..."
    sudo pacman -S --needed --noconfirm rust
    git clone --depth=1 https://aur.archlinux.org/paru.git "$tmpdir/paru"
    (cd "$tmpdir/paru" && makepkg -si --noconfirm)

    rm -rf "$tmpdir"
    log_success "paru installed"
}

# ------------------------------------------------------------------------------
# setup_repos_fedora
# Fedora's default repos are conservative about licences and patents.
# RPM Fusion adds multimedia codecs, drivers, and software Fedora can't ship.
# Individual vendor repos are added for apps that publish their own RPMs.
# COPRs are community-maintained repos (Fedora's equivalent of Ubuntu PPAs).
# ------------------------------------------------------------------------------
setup_repos_fedora() {
    log_info "Fedora: adding third-party repositories..."

    # RPM Fusion — two repos: free (open source) and nonfree (proprietary/patent)
    # $(rpm -E %fedora) expands to the current Fedora version number (e.g. 40)
    log_info "Enabling RPM Fusion (free + nonfree)..."
    run_cmd sudo dnf install -y \
        "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
        2>/dev/null || log_warn "RPM Fusion may already be installed"

    # Brave Browser — official repo from Brave Software
    log_info "Adding Brave Browser repository..."
    run_cmd sudo dnf config-manager addrepo \
        --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo \
        2>/dev/null || true

    # ProtonVPN — official repo from Proton
    log_info "Adding ProtonVPN repository..."
    run_cmd sudo dnf config-manager addrepo \
        --from-repofile="https://repo.protonvpn.com/fedora-$(rpm -E %fedora)-stable/protonvpn-stable.repo" \
        2>/dev/null || true

    # NetBird — WireGuard-based mesh VPN; provides its own install script
    # that sets up the repo and GPG key
    log_info "Adding NetBird repository..."
    run_cmd bash -c "curl -sSL https://pkgs.netbird.io/install.sh | sudo bash" \
        2>/dev/null || log_warn "NetBird repo setup failed, skipping"

    # Ghostty — modern terminal emulator; not yet in official Fedora repos
    log_info "Enabling Ghostty COPR..."
    run_cmd sudo dnf copr enable -y pgdev/ghostty 2>/dev/null || true

    # WezTerm — GPU-accelerated terminal; nightly COPR for latest builds
    log_info "Enabling WezTerm COPR..."
    run_cmd sudo dnf copr enable -y wezfurlong/wezterm-nightly 2>/dev/null || true

    log_success "Fedora repositories configured"
}

# ------------------------------------------------------------------------------
# setup_repos_ubuntu
# Enables Universe and Multiverse (Ubuntu's community and restricted repos),
# then adds vendor repos for apps not in the Ubuntu archives.
# ------------------------------------------------------------------------------
setup_repos_ubuntu() {
    log_info "Ubuntu: enabling extra repositories..."

    # Universe — community-maintained packages; many dev tools live here
    # Multiverse — software with restricted licences (codecs, fonts, etc.)
    run_cmd sudo add-apt-repository -y universe
    run_cmd sudo add-apt-repository -y multiverse

    _setup_repos_debian_common
    log_success "Ubuntu repositories configured"
}

# ------------------------------------------------------------------------------
# setup_repos_debian
# Adds vendor repos for apps not in the Debian archives.
# ------------------------------------------------------------------------------
setup_repos_debian() {
    log_info "Debian: adding third-party repositories..."
    _setup_repos_debian_common
    log_success "Debian repositories configured"
}

# ------------------------------------------------------------------------------
# _setup_repos_debian_common
# Shared repo setup for both Ubuntu and Debian — they use the same GPG + .list
# pattern for Brave, ProtonVPN, and NetBird.
# ------------------------------------------------------------------------------
_setup_repos_debian_common() {
    # Brave Browser
    log_info "Adding Brave Browser repository..."
    if [[ "$DRY_RUN" != true ]]; then
        sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
            https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=amd64] \
https://brave-browser-apt-release.s3.brave.com/ stable main" \
            | sudo tee /etc/apt/sources.list.d/brave-browser.list > /dev/null
    else
        log_info "[DRY-RUN] Would add Brave Browser apt repo"
    fi

    # NetBird
    log_info "Adding NetBird repository..."
    run_cmd bash -c "curl -sSL https://pkgs.netbird.io/install.sh | sudo bash" \
        2>/dev/null || log_warn "NetBird repo setup failed, skipping"

    # Refresh package lists after adding repos
    run_cmd sudo apt-get update
}

# ------------------------------------------------------------------------------
# main — dispatches to the correct distro function based on DISTRO_FAMILY
# ------------------------------------------------------------------------------
main() {
    log_section "Module 02: Repositories"

    if [[ "$SYSTEM_PROFILE" == "atomic" ]]; then
        log_info "Atomic system detected — leaving the immutable base repositories unchanged"
        return 0
    fi

    case "$DISTRO_FAMILY" in
        arch)   setup_repos_arch   ;;
        fedora) setup_repos_fedora ;;
        ubuntu) setup_repos_ubuntu ;;
        debian) setup_repos_debian ;;
        macos)
            # On macOS, Homebrew itself is the package source — no separate repos
            # to add. Homebrew is installed in 04-userland.sh if not already present.
            log_info "macOS: Homebrew is the package source — no repos to add"
            ;;
        *)
            log_warn "Unknown distro family '$DISTRO_FAMILY' — skipping repo setup"
            ;;
    esac

    log_success "Module 02 complete"
}

main "$@"
