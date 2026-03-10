#!/bin/bash
# ── George: Container System (proot-distro) ────────────────────
# Lightweight Linux containers for Termux — no Docker, no root.
# Uses proot-distro to install and manage full distro environments.
#
# Supported distros:
#   ubuntu   — General dev container (default)
#   alpine   — Lightweight, fast boot
#   debian   — Stable, broad package support
#   fedora   — Red Hat ecosystem
#   kali     — Kali Nethunter (pentest tools)
#   archlinux — Rolling release

[ -n "${_LIB_CONTAINER_LOADED:-}" ] && return 0; _LIB_CONTAINER_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Distro aliases ─────────────────────────────────────────────
# Map friendly names to proot-distro IDs
_container_resolve_distro() {
    local name="$1"
    case "$name" in
        kali|kali-linux|nethunter)  echo "kali-nethunter" ;;
        ubuntu|ubuntu-lts)          echo "ubuntu" ;;
        alpine)                     echo "alpine" ;;
        debian)                     echo "debian" ;;
        fedora)                     echo "fedora" ;;
        arch|archlinux)             echo "archlinux" ;;
        void)                       echo "void" ;;
        opensuse)                   echo "opensuse" ;;
        *)                          echo "$name" ;;  # pass through for custom
    esac
}

# ── Check if proot-distro is available ─────────────────────────
container_available() {
    if command -v proot-distro &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ── Ensure proot-distro exists or fail gracefully ──────────────
_container_require() {
    if ! container_available; then
        ui_err "proot-distro not found"
        ui_dim "Install it in Termux: pkg install proot-distro"
        ui_dim "On desktop Linux, containers are not needed — use your native package manager."
        return 1
    fi
}

# ── List available distros ─────────────────────────────────────
container_list_available() {
    _container_require || return 1
    ui_section "Available Distros"
    proot-distro list 2>/dev/null | while IFS= read -r line; do
        # Highlight installed ones
        if echo "$line" | grep -q "installed"; then
            printf "  %b●%b %s\n" "$C_GREEN" "$C_RESET" "$line"
        else
            printf "  %b○%b %s\n" "$C_DIM" "$C_RESET" "$line"
        fi
    done
}

# ── List installed containers ──────────────────────────────────
container_list() {
    _container_require || return 1

    ui_section "Installed Containers"

    local found=0
    local line distro_id
    while IFS= read -r line; do
        # proot-distro list output has "Alias:" lines for installed distros
        # We parse for installed entries
        if echo "$line" | grep -qi "installed"; then
            distro_id=$(echo "$line" | awk '{print $1}')
            local size="?"
            local rootfs="$PREFIX/var/lib/proot-distro/installed-rootfs/$distro_id"
            if [ -d "$rootfs" ]; then
                size=$(du -sh "$rootfs" 2>/dev/null | cut -f1)
            fi
            printf "  %b%-20s%b %s\n" "$C_WHITE" "$distro_id" "$C_RESET" "$size"
            found=1
        fi
    done <<< "$(proot-distro list 2>/dev/null)"

    if [ "$found" -eq 0 ]; then
        ui_dim "  No containers installed yet."
        ui_dim "  Try: /container install ubuntu"
    fi
}

# ── Install a distro ──────────────────────────────────────────
container_install() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: container_install <distro>"
        ui_dim "Available: ubuntu, alpine, debian, fedora, kali, archlinux"
        return 1
    fi

    _container_require || return 1

    local distro
    distro=$(_container_resolve_distro "$name")

    ui_step "Installing $distro container..."
    ui_dim "This may take a few minutes on mobile."

    if proot-distro install "$distro" 2>&1; then
        ui_ok "Container '$distro' installed"

        # Auto-setup for known distros
        case "$distro" in
            ubuntu|debian)
                ui_step "Running initial setup..."
                proot-distro login "$distro" -- bash -c \
                    "apt-get update -qq && apt-get install -y -qq build-essential git curl" 2>&1
                ui_ok "Dev tools installed in $distro"
                ;;
            kali-nethunter)
                ui_step "Running initial Kali setup..."
                proot-distro login "$distro" -- bash -c \
                    "apt-get update -qq && apt-get install -y -qq kali-tools-top10 git curl" 2>&1
                ui_ok "Kali top-10 tools installed"
                ui_dim "For more: proot-distro login kali-nethunter -- apt install kali-linux-headless"
                ;;
            alpine)
                ui_step "Running initial setup..."
                proot-distro login "$distro" -- sh -c \
                    "apk update && apk add build-base git curl bash" 2>&1
                ui_ok "Dev tools installed in $distro"
                ;;
        esac
    else
        ui_err "Failed to install '$distro'"
        ui_dim "Check: proot-distro list   (for valid distro names)"
        return 1
    fi
}

# ── Login to a container (interactive shell) ──────────────────
container_login() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: container_login <distro>"
        return 1
    fi

    _container_require || return 1

    local distro
    distro=$(_container_resolve_distro "$name")

    ui_info "Entering $distro container. Type 'exit' to return to George."
    echo ""
    proot-distro login "$distro"
    echo ""
    ui_ok "Back in George."
}

# ── Execute a command in a container ──────────────────────────
container_exec() {
    local name="$1"
    shift
    local cmd="$*"

    if [ -z "$name" ] || [ -z "$cmd" ]; then
        ui_err "Usage: container_exec <distro> <command>"
        return 1
    fi

    _container_require || return 1

    local distro
    distro=$(_container_resolve_distro "$name")

    proot-distro login "$distro" -- bash -c "$cmd" 2>&1
}

# ── Execute with workspace bind mount ─────────────────────────
# Mounts current working directory into the container at /workspace
container_exec_here() {
    local name="$1"
    shift
    local cmd="$*"

    if [ -z "$name" ] || [ -z "$cmd" ]; then
        ui_err "Usage: container_exec_here <distro> <command>"
        return 1
    fi

    _container_require || return 1

    local distro
    distro=$(_container_resolve_distro "$name")

    proot-distro login "$distro" \
        --bind "$PWD:/workspace" \
        -- bash -c "cd /workspace && $cmd" 2>&1
}

# ── Remove a container ────────────────────────────────────────
container_remove() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: container_remove <distro>"
        return 1
    fi

    _container_require || return 1

    local distro
    distro=$(_container_resolve_distro "$name")

    if ui_confirm "Remove container '$distro' and all its data?" "n"; then
        proot-distro remove "$distro" 2>&1
        ui_ok "Container '$distro' removed"
    fi
}

# ── Reset a container (reinstall from scratch) ────────────────
container_reset() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: container_reset <distro>"
        return 1
    fi

    _container_require || return 1

    local distro
    distro=$(_container_resolve_distro "$name")

    if ui_confirm "Reset '$distro'? This removes and reinstalls it." "n"; then
        proot-distro remove "$distro" 2>&1
        container_install "$name"
    fi
}

# ── Pentest quick-start ───────────────────────────────────────
# Install Kali and common pentest tools in one command
container_pentest_setup() {
    ui_section "Pentest Container Setup"
    ui_dim "This installs Kali Nethunter with common pentesting tools."
    ui_dim "Estimated size: ~2-4GB. Estimated time: 10-20 min on mobile."
    echo ""

    if ! ui_confirm "Proceed with Kali pentest setup?" "y"; then
        return 0
    fi

    container_install "kali"

    ui_step "Installing additional pentest packages..."
    proot-distro login kali-nethunter -- bash -c '
        apt-get update -qq
        apt-get install -y -qq \
            nmap sqlmap nikto dirb gobuster hydra john hashcat \
            metasploit-framework exploitdb enum4linux \
            whatweb wpscan sslscan dnsrecon \
            python3 python3-pip
    ' 2>&1

    ui_ok "Kali pentest container ready"
    ui_info "Login with: /container login kali"
    ui_info "Or run: /container exec kali nmap -sV target.com"
}

# ── Info about a container ────────────────────────────────────
container_info() {
    local name="$1"
    if [ -z "$name" ]; then
        ui_err "Usage: container_info <distro>"
        return 1
    fi

    _container_require || return 1

    local distro
    distro=$(_container_resolve_distro "$name")

    local rootfs="$PREFIX/var/lib/proot-distro/installed-rootfs/$distro"

    if [ ! -d "$rootfs" ]; then
        ui_err "Container '$distro' is not installed"
        return 1
    fi

    ui_section "Container: $distro"
    local size
    size=$(du -sh "$rootfs" 2>/dev/null | cut -f1)
    printf "  %bSize:%b       %s\n" "$C_CYAN" "$C_RESET" "$size"
    printf "  %bRootfs:%b     %s\n" "$C_CYAN" "$C_RESET" "$rootfs"

    # Try to get OS info
    local os_info
    os_info=$(proot-distro login "$distro" -- cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')
    if [ -n "$os_info" ]; then
        printf "  %bOS:%b         %s\n" "$C_CYAN" "$C_RESET" "$os_info"
    fi

    # Package count
    local pkg_count
    pkg_count=$(proot-distro login "$distro" -- bash -c 'dpkg -l 2>/dev/null | wc -l || apk list --installed 2>/dev/null | wc -l || rpm -qa 2>/dev/null | wc -l' 2>/dev/null)
    if [ -n "$pkg_count" ] && [ "$pkg_count" -gt 0 ]; then
        printf "  %bPackages:%b   ~%s\n" "$C_CYAN" "$C_RESET" "$pkg_count"
    fi
    echo ""
}
