#!/bin/bash
# ── George: Git & GitHub Configuration ─────────────────────────
# Unified tooling for George's git environment: identity, SSH,
# GPG commit signing, remotes, and GitHub auth. Ties together
# the SSH layer (lib/email.sh) and the GPG layer (lib/pgp.sh)
# into a cohesive, persistent git configuration.
#
# Design goals:
#   - Auto-configure everything possible (zero friction)
#   - Make configuration persistent (survives session restarts)
#   - George can set up his own git/GitHub with minimal operator input
#   - Clear error messages when manual steps are needed

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-$HOME/.george}"
GEORGE_SSH_DIR="${GEORGE_SSH_DIR:-$GEORGE_CONFIG_DIR/.ssh}"
GEORGE_SSH_KEY="${GEORGE_SSH_KEY:-$GEORGE_SSH_DIR/id_ed25519}"
GEORGE_GIT_CONFIG="${GEORGE_GIT_CONFIG:-$GEORGE_CONFIG_DIR/gitconfig}"

# ═══════════════════════════════════════════════════════════════
# Git Identity
# ═══════════════════════════════════════════════════════════════

# ── Set git user.name + user.email globally ────────────────────
# Pulls email from George's email config. Falls back to local identity.
git_set_identity() {
    local name="${1:-George (Blue Lodge)}"
    local email="${2:-}"
    local scope="${3:---global}"

    # Auto-detect email from George's email config
    if [ -z "$email" ] && declare -f email_init &>/dev/null; then
        email_init >/dev/null 2>&1
        email="${EMAIL_ADDRESS:-}"
    fi
    if [ -z "$email" ]; then
        email="george@blue-lodge.local"
        ui_dim "No email configured — using local identity: $email"
    fi

    git config $scope user.name "$name" 2>/dev/null
    git config $scope user.email "$email" 2>/dev/null
    ui_ok "Git identity: $name <$email>"
}

# ── Show current git identity ──────────────────────────────────
git_show_identity() {
    local name email
    name=$(git config --global user.name 2>/dev/null || echo "not set")
    email=$(git config --global user.email 2>/dev/null || echo "not set")
    printf "  Name:   %b%s%b\n" "$C_WHITE" "$name" "$C_RESET"
    printf "  Email:  %b%s%b\n" "$C_WHITE" "$email" "$C_RESET"
}

# ═══════════════════════════════════════════════════════════════
# SSH Configuration (persistent)
# ═══════════════════════════════════════════════════════════════

# ── Write SSH config entry for GitHub ──────────────────────────
# Creates ~/.george/.ssh/config so the key is used automatically
# for any git@github.com connection — persists across sessions.
git_write_ssh_config() {
    if ! declare -f ssh_has_key &>/dev/null || ! ssh_has_key; then
        ui_err "No SSH key. Generate one first: /git ssh-keygen"
        return 1
    fi

    local ssh_config="$GEORGE_SSH_DIR/config"
    mkdir -p "$GEORGE_SSH_DIR"

    # Only add the GitHub block if not already present
    if [ -f "$ssh_config" ] && grep -q "Host github.com" "$ssh_config" 2>/dev/null; then
        ui_dim "SSH config already has GitHub entry"
        return 0
    fi

    cat >> "$ssh_config" << EOF

# George's GitHub SSH identity
Host github.com
    HostName github.com
    User git
    IdentityFile $GEORGE_SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
    chmod 600 "$ssh_config"
    ui_ok "SSH config written: $ssh_config"
    return 0
}

# ── Set GIT_SSH_COMMAND and write includeIf to global gitconfig ─
# This makes git automatically use George's SSH key for GitHub.
git_configure_ssh() {
    if ! declare -f ssh_has_key &>/dev/null || ! ssh_has_key; then
        ui_err "No SSH key. Generate one first: /git ssh-keygen"
        return 1
    fi

    # 1. Set session-level env var (immediate effect)
    export GIT_SSH_COMMAND="ssh -F $GEORGE_SSH_DIR/config -i $GEORGE_SSH_KEY -o IdentitiesOnly=yes"

    # 2. Write SSH config entry (persistent across sessions)
    git_write_ssh_config

    # 3. Write global git config for SSH command
    git config --global core.sshCommand \
        "ssh -F $GEORGE_SSH_DIR/config -i $GEORGE_SSH_KEY -o IdentitiesOnly=yes" 2>/dev/null

    ui_ok "Git SSH configured (persistent)"
}

# ═══════════════════════════════════════════════════════════════
# GPG Commit Signing
# ═══════════════════════════════════════════════════════════════

# ── Configure git to sign commits with George's GPG key ────────
# Uses the GPG key from lib/pgp.sh. Writes to global gitconfig.
git_configure_signing() {
    if ! declare -f pgp_has_key &>/dev/null; then
        ui_err "PGP library not loaded"
        return 1
    fi

    if ! pgp_has_key; then
        ui_info "George doesn't have a GPG key yet. Generating one..."
        pgp_generate_key || return 1
    fi

    # Get the key fingerprint
    local fpr
    fpr=$(_pgp_gpg --fingerprint --with-colons "${PGP_KEY_EMAIL:-george@blue-lodge.local}" 2>/dev/null | \
          grep '^fpr:' | head -1 | cut -d: -f10)

    if [ -z "$fpr" ]; then
        ui_err "Could not find GPG key fingerprint"
        return 1
    fi

    # Point git at George's isolated GPG keyring
    git config --global gpg.program gpg 2>/dev/null
    git config --global user.signingkey "$fpr" 2>/dev/null
    git config --global commit.gpgsign true 2>/dev/null
    git config --global tag.gpgsign true 2>/dev/null

    # Tell git to use George's GNUPGHOME
    local gnupg_dir="${GEORGE_GNUPG_DIR:-$GEORGE_CONFIG_DIR/.gnupg}"
    if [ -d "$gnupg_dir" ]; then
        # Write a wrapper script that sets GNUPGHOME
        local gpg_wrapper="$GEORGE_CONFIG_DIR/gpg-george.sh"
        cat > "$gpg_wrapper" << WRAPEOF
#!/bin/bash
GNUPGHOME="$gnupg_dir" exec gpg "\$@"
WRAPEOF
        chmod +x "$gpg_wrapper"
        git config --global gpg.program "$gpg_wrapper" 2>/dev/null
    fi

    local short_fpr="${fpr: -16}"
    local formatted
    formatted=$(echo "$short_fpr" | sed 's/.\{4\}/& /g' | sed 's/ $//')
    ui_ok "Git commit signing enabled"
    ui_dim "  Key: $formatted"
    ui_dim "  Commits and tags will be signed automatically"
}

# ── Disable commit signing ─────────────────────────────────────
git_disable_signing() {
    git config --global --unset commit.gpgsign 2>/dev/null
    git config --global --unset tag.gpgsign 2>/dev/null
    git config --global --unset user.signingkey 2>/dev/null
    ui_ok "Commit signing disabled"
}

# ── Check if signing is configured ─────────────────────────────
git_signing_enabled() {
    local sign
    sign=$(git config --global commit.gpgsign 2>/dev/null)
    [[ "$sign" == "true" ]]
}

# ═══════════════════════════════════════════════════════════════
# Remote Management
# ═══════════════════════════════════════════════════════════════

# ── Add a GitHub remote (converts HTTPS → SSH if appropriate) ──
git_add_remote() {
    local name="${1:-origin}"
    local url="${2:-}"

    if [ -z "$url" ]; then
        ui_err "Usage: /git remote <name> <url>"
        return 1
    fi

    # Auto-convert HTTPS GitHub URLs to SSH format
    if [[ "$url" =~ ^https://github\.com/([^/]+)/(.+)$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        repo="${repo%.git}"
        local ssh_url="git@github.com:${owner}/${repo}.git"
        ui_dim "Converting HTTPS → SSH: $ssh_url"
        url="$ssh_url"
    fi

    if git remote get-url "$name" &>/dev/null; then
        git remote set-url "$name" "$url" 2>&1
        ui_ok "Remote '$name' updated: $url"
    else
        git remote add "$name" "$url" 2>&1
        ui_ok "Remote '$name' added: $url"
    fi
}

# ── List remotes ───────────────────────────────────────────────
git_list_remotes() {
    local remotes
    remotes=$(git remote -v 2>/dev/null)
    if [ -z "$remotes" ]; then
        ui_info "No remotes configured"
        return
    fi
    ui_section "Git Remotes"
    echo "$remotes" | while read -r name url type; do
        printf "  %b%s%b  %s  %s\n" "$C_CYAN" "$name" "$C_RESET" "$url" "$type"
    done
}

# ═══════════════════════════════════════════════════════════════
# Full Setup (one-shot)
# ═══════════════════════════════════════════════════════════════

# ── Full git + GitHub setup ────────────────────────────────────
# Auto-configures: identity, SSH key, SSH config, GPG signing,
# and tests the GitHub SSH connection. Handles as much as possible
# automatically, prompts only when manual steps are needed.
git_full_setup() {
    ui_section "Git & GitHub Setup for George"
    echo ""

    local warnings=0

    # ── Step 1: Email ──────────────────────────────────────────
    if declare -f email_init &>/dev/null; then
        email_init >/dev/null 2>&1
    fi
    if [ -n "${EMAIL_ADDRESS:-}" ]; then
        ui_ok "Email: $EMAIL_ADDRESS"
    else
        ui_err "No email configured"
        ui_info "  Run: /email setup"
        ui_dim "  George needs an email for GitHub registration and git identity."
        return 1
    fi

    # ── Step 2: SSH key ────────────────────────────────────────
    if declare -f ssh_has_key &>/dev/null && ssh_has_key; then
        ui_ok "SSH key: $(cat "$GEORGE_SSH_KEY.pub" 2>/dev/null | awk '{print $1, $NF}')"
    else
        ui_step "Generating SSH key..."
        if declare -f ssh_generate_key &>/dev/null; then
            ssh_generate_key || { ui_err "SSH key generation failed"; return 1; }
        else
            ui_err "SSH key functions not available"
            return 1
        fi
    fi

    # ── Step 3: SSH config (persistent) ────────────────────────
    git_write_ssh_config
    git_configure_ssh
    ui_ok "SSH configured for GitHub (persistent)"

    # ── Step 4: Git identity ───────────────────────────────────
    git_set_identity "George (Blue Lodge)" "${EMAIL_ADDRESS:-}" "--global"

    # ── Step 5: GPG commit signing ─────────────────────────────
    if declare -f pgp_available &>/dev/null && pgp_available; then
        git_configure_signing
        ui_ok "GPG commit signing enabled"
    else
        ui_warn "GPG not available — commits will not be signed"
        ui_dim "  Install: apt install gnupg  (or: pkg install gnupg)"
        (( warnings++ ))
    fi

    # ── Step 6: Export GPG public key for GitHub ───────────────
    if git_signing_enabled && declare -f pgp_export_public_key &>/dev/null; then
        pgp_export_public_key >/dev/null 2>&1
        local pubkey_file="${GEORGE_PGP_PUBKEY_FILE:-$GEORGE_CONFIG_DIR/george_public.asc}"
        if [ -s "$pubkey_file" ]; then
            ui_ok "GPG public key exported: $pubkey_file"
            ui_dim "  Add to GitHub → Settings → SSH and GPG keys → New GPG key"
        fi
    fi

    # ── Step 7: Test GitHub SSH ────────────────────────────────
    echo ""
    if declare -f ssh_test_github &>/dev/null; then
        if ssh_test_github; then
            echo ""
            ui_ok "George is ready to push to GitHub!"
            if git_signing_enabled; then
                ui_ok "Commits will be signed and verified on GitHub"
            fi
        else
            echo ""
            ui_warn "SSH key not yet added to GitHub. Manual steps:"
            echo ""
            ui_info "  1. Copy George's SSH public key:"
            ui_dim "     cat $GEORGE_SSH_KEY.pub"
            echo ""
            ui_info "  2. Add it to GitHub:"
            ui_dim "     https://github.com/settings/ssh/new"
            echo ""
            if git_signing_enabled; then
                ui_info "  3. Add George's GPG public key:"
                ui_dim "     https://github.com/settings/gpg/new"
                ui_dim "     cat ${GEORGE_PGP_PUBKEY_FILE:-$GEORGE_CONFIG_DIR/george_public.asc}"
                echo ""
            fi
            ui_info "  Then verify: /git test"
            (( warnings++ ))
        fi
    fi

    return $warnings
}

# ═══════════════════════════════════════════════════════════════
# Status — unified view of git configuration
# ═══════════════════════════════════════════════════════════════

git_status_overview() {
    ui_section "Git Configuration"
    echo ""

    # Identity
    printf "  %b── Identity ──%b\n" "$C_CYAN" "$C_RESET"
    git_show_identity

    # SSH
    echo ""
    printf "  %b── SSH ──%b\n" "$C_CYAN" "$C_RESET"
    if declare -f ssh_has_key &>/dev/null && ssh_has_key; then
        printf "  Key:    %b%s%b\n" "$C_GREEN" "configured" "$C_RESET"
        printf "  Type:   Ed25519\n"
        local pubkey_snippet
        pubkey_snippet=$(cat "$GEORGE_SSH_KEY.pub" 2>/dev/null | awk '{print $1, $NF}')
        printf "  Pub:    %s\n" "$pubkey_snippet"
        if [ -f "$GEORGE_SSH_DIR/config" ] && grep -q "Host github.com" "$GEORGE_SSH_DIR/config" 2>/dev/null; then
            printf "  Config: %b%s%b\n" "$C_GREEN" "persistent (ssh config)" "$C_RESET"
        else
            printf "  Config: %b%s%b\n" "$C_YELLOW" "session only" "$C_RESET"
        fi
        # Check git core.sshCommand
        local ssh_cmd
        ssh_cmd=$(git config --global core.sshCommand 2>/dev/null)
        if [ -n "$ssh_cmd" ]; then
            printf "  Git:    %b%s%b\n" "$C_GREEN" "core.sshCommand set" "$C_RESET"
        fi
    else
        printf "  Key:    %b%s%b\n" "$C_RED" "not generated" "$C_RESET"
        ui_dim "  Run: /git ssh-keygen"
    fi

    # GPG Signing
    echo ""
    printf "  %b── Commit Signing ──%b\n" "$C_CYAN" "$C_RESET"
    if git_signing_enabled; then
        local sigkey
        sigkey=$(git config --global user.signingkey 2>/dev/null)
        local short="${sigkey: -16}"
        printf "  Status: %b%s%b\n" "$C_GREEN" "enabled" "$C_RESET"
        printf "  Key:    %s\n" "$short"
        printf "  Scope:  commits + tags\n"
    else
        printf "  Status: %b%s%b\n" "$C_DIM" "disabled" "$C_RESET"
        ui_dim "  Enable: /git sign"
    fi

    # Remotes (if in a git repo)
    if git rev-parse --git-dir &>/dev/null 2>&1; then
        echo ""
        printf "  %b── Remotes ──%b\n" "$C_CYAN" "$C_RESET"
        local remotes
        remotes=$(git remote -v 2>/dev/null | grep '(push)')
        if [ -n "$remotes" ]; then
            echo "$remotes" | while read -r rname rurl _; do
                printf "  %s  %s\n" "$rname" "$rurl"
            done
        else
            printf "  %b(none)%b\n" "$C_DIM" "$C_RESET"
        fi
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════
# GitHub push guard integration
# ═══════════════════════════════════════════════════════════════

# Reuse the existing github_push_guard from email.sh if loaded;
# otherwise provide a local one.
if ! declare -f github_push_guard &>/dev/null; then
    github_push_guard() {
        local remote_url="${1:-}"
        [ -z "$remote_url" ] && return 0
        [[ "$remote_url" != *"github.com"* ]] && return 0

        if declare -f email_init &>/dev/null; then
            email_init >/dev/null 2>&1
        fi
        if [ -z "${EMAIL_ADDRESS:-}" ] || ! declare -f ssh_has_key &>/dev/null || ! ssh_has_key; then
            ui_err "Cannot push to GitHub — run: /git setup"
            return 1
        fi
        git_configure_ssh >/dev/null 2>&1
        return 0
    }
fi
