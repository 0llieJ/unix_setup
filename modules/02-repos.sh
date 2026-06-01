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
        log_info "paru already installed, skipping"
        return
    fi

    log_info "Installing paru (AUR helper)..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would clone and build paru-bin from AUR"
        return
    fi

    # Install build prerequisites — base-devel contains make, gcc, fakeroot etc.
    sudo pacman -S --needed --noconfirm base-devel git

    local tmpdir
    tmpdir=$(mktemp -d)

    # Clone paru-bin (pre-compiled binary — faster than building paru from source)
    git clone --depth=1 https://aur.archlinux.org/paru-bin.git "$tmpdir/paru-bin"

    # makepkg builds the package and -si installs it + its dependencies
    (cd "$tmpdir/paru-bin" && makepkg -si --noconfirm)

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

    case "$DISTRO_FAMILY" in
        arch)   setup_repos_arch   ;;
        fedora) setup_repos_fedora ;;
        ubuntu) setup_repos_ubuntu ;;
        debian) setup_repos_debian ;;
        *)
            log_warn "Unknown distro family '$DISTRO_FAMILY' — skipping repo setup"
            ;;
    esac

    log_success "Module 02 complete"
}

main "$@"
