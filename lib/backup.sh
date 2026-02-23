#!/bin/bash
# ── George: Backup & Persistence System ────────────────────────
# Preserves George's identity across repo updates. Backs up
# journal.md, soul.md, CLAUDE.md, and keys.conf to local files
# or a private git repo that the user controls.
#
# Philosophy: George's code can be rewritten, but his memories
# and personality are irreplaceable. Protect them.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── Config ─────────────────────────────────────────────────────
GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
GEORGE_BACKUP_DIR="$GEORGE_CONFIG_DIR/backups"
GEORGE_BACKUP_REPO="$GEORGE_CONFIG_DIR/backup-repo"

# Files that define George's identity and memory
GEORGE_IDENTITY_FILES=(
    "soul.md"
    "journal.md"
    "Modelfile"
)

# ── Initialize backup system ──────────────────────────────────
backup_init() {
    mkdir -p "$GEORGE_BACKUP_DIR" "$GEORGE_CONFIG_DIR"
    chmod 700 "$GEORGE_CONFIG_DIR"
}

# ── Local file backup ─────────────────────────────────────────
# Copies identity files + all CLAUDE.md files to a timestamped dir
backup_local() {
    backup_init

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$GEORGE_BACKUP_DIR/$timestamp"
    mkdir -p "$backup_path/projects"

    ui_step "Backing up George to $backup_path"

    local count=0

    # Identity files from LODGE_DIR
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$LODGE_DIR/$f" ]; then
            cp "$LODGE_DIR/$f" "$backup_path/$f"
            count=$((count + 1))
        fi
    done

    # Keys config (sensitive — backed up separately)
    if [ -f "$GEORGE_CONFIG_DIR/keys.conf" ]; then
        cp "$GEORGE_CONFIG_DIR/keys.conf" "$backup_path/keys.conf"
        chmod 600 "$backup_path/keys.conf"
        count=$((count + 1))
    fi

    # Collect all CLAUDE.md files from known project locations
    # Check common locations: home, sandboxes, current dir
    local claude_files=()
    # Current directory
    [ -f "$PWD/CLAUDE.md" ] && claude_files+=("$PWD/CLAUDE.md")
    # Sandboxes
    if [ -d "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" ]; then
        while IFS= read -r -d '' cf; do
            claude_files+=("$cf")
        done < <(find "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" -name "CLAUDE.md" -print0 2>/dev/null)
    fi
    # Home directory projects (1 level deep)
    while IFS= read -r -d '' cf; do
        claude_files+=("$cf")
    done < <(find "$HOME" -maxdepth 2 -name "CLAUDE.md" -not -path "*/.george/*" -not -path "*/blue-lodge/*" -print0 2>/dev/null)

    for cf in "${claude_files[@]}"; do
        local project_name
        project_name=$(basename "$(dirname "$cf")")
        mkdir -p "$backup_path/projects/$project_name"
        cp "$cf" "$backup_path/projects/$project_name/CLAUDE.md"
        count=$((count + 1))
    done

    # Write manifest
    cat > "$backup_path/MANIFEST.md" << MEOF
# George Backup — $timestamp

Created: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Lodge version: ${LODGE_VERSION:-unknown}
Files backed up: $count

## Contents
$(ls -la "$backup_path" | tail -n +2)

## Projects
$(ls "$backup_path/projects" 2>/dev/null || echo "None")
MEOF

    ui_ok "Backup complete: $count files → $backup_path"
    echo "$backup_path"
}

# ── List existing backups ──────────────────────────────────────
backup_list() {
    backup_init

    if [ ! -d "$GEORGE_BACKUP_DIR" ] || [ -z "$(ls -A "$GEORGE_BACKUP_DIR" 2>/dev/null)" ]; then
        ui_info "No backups found"
        ui_dim "Create one: /backup local"
        return
    fi

    ui_section "George Backups"
    for d in "$GEORGE_BACKUP_DIR"/*/; do
        [ -d "$d" ] || continue
        local name
        name=$(basename "$d")
        local size
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        local file_count
        file_count=$(find "$d" -type f | wc -l)
        printf "  %b%-20s%b %s  (%d files)\n" "$C_WHITE" "$name" "$C_RESET" "$size" "$file_count"
    done
}

# ── Restore from a backup ─────────────────────────────────────
backup_restore() {
    local backup_name="$1"

    if [ -z "$backup_name" ]; then
        # Use most recent
        backup_name=$(ls -t "$GEORGE_BACKUP_DIR" 2>/dev/null | head -1)
        if [ -z "$backup_name" ]; then
            ui_err "No backups found"
            return 1
        fi
        ui_info "Using most recent backup: $backup_name"
    fi

    local backup_path="$GEORGE_BACKUP_DIR/$backup_name"
    if [ ! -d "$backup_path" ]; then
        ui_err "Backup not found: $backup_name"
        return 1
    fi

    ui_warn "This will overwrite current identity files with the backup."
    if ! ui_confirm "Restore from $backup_name?" "n"; then
        return 0
    fi

    local count=0

    # Restore identity files
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$backup_path/$f" ]; then
            cp "$backup_path/$f" "$LODGE_DIR/$f"
            ui_dim "  Restored: $f"
            count=$((count + 1))
        fi
    done

    # Restore keys
    if [ -f "$backup_path/keys.conf" ]; then
        cp "$backup_path/keys.conf" "$GEORGE_CONFIG_DIR/keys.conf"
        chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
        ui_dim "  Restored: keys.conf"
        count=$((count + 1))
    fi

    ui_ok "Restored $count files from backup $backup_name"
    ui_dim "Project CLAUDE.md files are in: $backup_path/projects/"
    ui_dim "Restore those manually to your project directories if needed."
}

# ── Git-based backup (local repo) ─────────────────────────────
backup_git_init() {
    backup_init

    if [ -d "$GEORGE_BACKUP_REPO/.git" ]; then
        ui_info "Backup repo already exists at $GEORGE_BACKUP_REPO"
        return 0
    fi

    mkdir -p "$GEORGE_BACKUP_REPO"
    cd "$GEORGE_BACKUP_REPO" || return 1

    git init -q
    cat > .gitignore << 'EOF'
# Don't track temp files
*.tmp
*.swp
EOF

    cat > README.md << 'RMEOF'
# George Backup Repository

This repository preserves George's identity across updates:
- **soul.md** — Personality & ethical framework
- **journal.md** — Living memory with temporal decay
- **Modelfile** — LLM configuration
- **keys.conf** — API keys (encrypted or private repo only!)
- **projects/** — Per-project CLAUDE.md memory files

## Restoring George

```bash
# After cloning or updating blue-lodge:
lodge /backup restore
```

This repo is auto-managed by George's backup system.
RMEOF

    git add -A
    git commit -q -m "Initialize George backup repository"

    ui_ok "Backup repo initialized at $GEORGE_BACKUP_REPO"
    cd - > /dev/null
}

# ── Commit current state to git backup ────────────────────────
backup_git_save() {
    local message="${1:-Backup $(date +%Y-%m-%d_%H:%M)}"

    # Init if needed
    if [ ! -d "$GEORGE_BACKUP_REPO/.git" ]; then
        backup_git_init || return 1
    fi

    # Copy current files to repo
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$LODGE_DIR/$f" ]; then
            cp "$LODGE_DIR/$f" "$GEORGE_BACKUP_REPO/$f"
        fi
    done

    # Copy keys (user should use private repo or encrypt)
    if [ -f "$GEORGE_CONFIG_DIR/keys.conf" ]; then
        cp "$GEORGE_CONFIG_DIR/keys.conf" "$GEORGE_BACKUP_REPO/keys.conf"
    fi

    # Copy CLAUDE.md files
    mkdir -p "$GEORGE_BACKUP_REPO/projects"
    if [ -d "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" ]; then
        find "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" -name "CLAUDE.md" -print0 2>/dev/null | \
            while IFS= read -r -d '' cf; do
                local pname
                pname=$(basename "$(dirname "$cf")")
                mkdir -p "$GEORGE_BACKUP_REPO/projects/$pname"
                cp "$cf" "$GEORGE_BACKUP_REPO/projects/$pname/CLAUDE.md"
            done
    fi

    cd "$GEORGE_BACKUP_REPO" || return 1
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        ui_info "No changes to back up"
    else
        git commit -q -m "$message"
        ui_ok "Saved to backup repo: $message"
    fi
    cd - > /dev/null
}

# ── Push backup to GitHub ─────────────────────────────────────
# Interactive: walks the user through setting up a GitHub remote
backup_git_push() {
    if [ ! -d "$GEORGE_BACKUP_REPO/.git" ]; then
        backup_git_init || return 1
    fi

    cd "$GEORGE_BACKUP_REPO" || return 1

    # Check if remote exists
    local remote
    remote=$(git remote get-url origin 2>/dev/null)

    # ── GitHub push guard: require email + SSH key ─────────
    if [ -n "$remote" ] && declare -f github_push_guard &>/dev/null; then
        if ! github_push_guard "$remote"; then
            cd - > /dev/null
            return 1
        fi
    fi

    if [ -z "$remote" ]; then
        ui_section "GitHub Backup Setup"
        ui_info "Let's set up a GitHub repo to store George's backups."
        echo ""
        ui_dim "1. Go to github.com/new"
        ui_dim "2. Create a PRIVATE repository (name it 'george-backup' or similar)"
        ui_dim "3. Don't initialize with README (we already have one)"
        ui_dim "4. Copy the repository URL"
        echo ""
        printf "  %bRepository URL%b (e.g., https://github.com/you/george-backup.git): " \
            "$C_WHITE" "$C_RESET"
        read -r repo_url

        if [ -z "$repo_url" ]; then
            ui_err "No URL provided"
            cd - > /dev/null
            return 1
        fi

        git remote add origin "$repo_url"
        ui_ok "Remote added: $repo_url"

        # Check for auth
        ui_info "Testing connection..."
        echo ""
        ui_dim "If prompted for credentials, you can use:"
        ui_dim "  - A Personal Access Token (Settings → Developer → Tokens)"
        ui_dim "  - SSH key (if your URL starts with git@)"
        ui_dim "  - GitHub CLI: gh auth login"
        echo ""
    fi

    # Save latest state first
    backup_git_save "Pre-push backup $(date +%Y-%m-%d_%H:%M)"

    # Push
    ui_step "Pushing to remote..."
    if git push -u origin main 2>&1 || git push -u origin master 2>&1; then
        ui_ok "George backed up to GitHub!"
        ui_dim "Remote: $(git remote get-url origin)"
    else
        ui_err "Push failed — check your credentials"
        ui_dim "Try: git -C '$GEORGE_BACKUP_REPO' push -u origin main"
    fi

    cd - > /dev/null
}

# ── Pull from GitHub backup ───────────────────────────────────
backup_git_pull() {
    if [ ! -d "$GEORGE_BACKUP_REPO/.git" ]; then
        ui_err "No backup repo found. Set up with /backup github first."
        return 1
    fi

    cd "$GEORGE_BACKUP_REPO" || return 1

    ui_step "Pulling from remote..."
    if git pull origin main 2>&1 || git pull origin master 2>&1; then
        ui_ok "Pulled latest backup from GitHub"

        # Offer to restore
        if ui_confirm "Restore identity files from pulled backup?" "y"; then
            for f in "${GEORGE_IDENTITY_FILES[@]}"; do
                if [ -f "$GEORGE_BACKUP_REPO/$f" ]; then
                    cp "$GEORGE_BACKUP_REPO/$f" "$LODGE_DIR/$f"
                    ui_dim "  Restored: $f"
                fi
            done
            if [ -f "$GEORGE_BACKUP_REPO/keys.conf" ]; then
                cp "$GEORGE_BACKUP_REPO/keys.conf" "$GEORGE_CONFIG_DIR/keys.conf"
                chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
                ui_dim "  Restored: keys.conf"
            fi
            ui_ok "George's identity restored from GitHub backup"
        fi
    else
        ui_err "Pull failed"
    fi

    cd - > /dev/null
}

# ── Clone a GitHub backup to a new machine ────────────────────
backup_git_clone() {
    local repo_url="$1"

    if [ -z "$repo_url" ]; then
        printf "  %bBackup repo URL%b: " "$C_WHITE" "$C_RESET"
        read -r repo_url
    fi

    if [ -z "$repo_url" ]; then
        ui_err "No URL provided"
        return 1
    fi

    if [ -d "$GEORGE_BACKUP_REPO/.git" ]; then
        ui_warn "Backup repo already exists. Pull instead?"
        backup_git_pull
        return $?
    fi

    ui_step "Cloning backup from $repo_url"
    git clone "$repo_url" "$GEORGE_BACKUP_REPO" 2>&1

    if [ $? -eq 0 ]; then
        ui_ok "Backup cloned to $GEORGE_BACKUP_REPO"

        if ui_confirm "Restore George's identity from this backup?" "y"; then
            backup_restore_from_repo
        fi
    else
        ui_err "Clone failed"
        return 1
    fi
}

# ── Restore from git repo files ───────────────────────────────
backup_restore_from_repo() {
    if [ ! -d "$GEORGE_BACKUP_REPO" ]; then
        ui_err "No backup repo found"
        return 1
    fi

    local count=0
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$GEORGE_BACKUP_REPO/$f" ]; then
            cp "$GEORGE_BACKUP_REPO/$f" "$LODGE_DIR/$f"
            ui_dim "  Restored: $f"
            count=$((count + 1))
        fi
    done

    if [ -f "$GEORGE_BACKUP_REPO/keys.conf" ]; then
        mkdir -p "$GEORGE_CONFIG_DIR"
        cp "$GEORGE_BACKUP_REPO/keys.conf" "$GEORGE_CONFIG_DIR/keys.conf"
        chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
        ui_dim "  Restored: keys.conf"
        count=$((count + 1))
    fi

    ui_ok "Restored $count files from backup repo"
}

# ── Auto-backup before update ─────────────────────────────────
# Called by the update script to protect identity
backup_pre_update() {
    ui_section "Pre-Update Backup"
    ui_info "Saving George's identity before update..."

    # Always do a local file backup — fast and safe
    local backup_path
    backup_path=$(backup_local)

    # Also save to git if repo exists
    if [ -d "$GEORGE_BACKUP_REPO/.git" ]; then
        backup_git_save "Pre-update backup $(date +%Y-%m-%d_%H:%M)"
    fi

    ui_ok "Identity preserved at: $backup_path"
    echo "$backup_path"
}

# ── Post-update restore ──────────────────────────────────────
backup_post_update() {
    ui_section "Post-Update Restore"

    # Check git backup first (most likely up-to-date)
    if [ -d "$GEORGE_BACKUP_REPO" ]; then
        for f in "${GEORGE_IDENTITY_FILES[@]}"; do
            if [ -f "$GEORGE_BACKUP_REPO/$f" ] && [ ! -f "$LODGE_DIR/$f" ]; then
                cp "$GEORGE_BACKUP_REPO/$f" "$LODGE_DIR/$f"
                ui_dim "  Restored from git: $f"
            fi
        done
    fi

    # Check local backup
    local latest
    latest=$(ls -t "$GEORGE_BACKUP_DIR" 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        local backup_path="$GEORGE_BACKUP_DIR/$latest"
        for f in "${GEORGE_IDENTITY_FILES[@]}"; do
            if [ -f "$backup_path/$f" ] && [ ! -f "$LODGE_DIR/$f" ]; then
                cp "$backup_path/$f" "$LODGE_DIR/$f"
                ui_dim "  Restored from local: $f"
            fi
        done
    fi

    ui_ok "George's identity restored"
}

# ── Backup status ─────────────────────────────────────────────
backup_status() {
    ui_section "Backup Status"

    # Local backups
    local local_count=0
    if [ -d "$GEORGE_BACKUP_DIR" ]; then
        local_count=$(ls -d "$GEORGE_BACKUP_DIR"/*/ 2>/dev/null | wc -l)
    fi
    printf "  %bLocal backups:%b  %d\n" "$C_CYAN" "$C_RESET" "$local_count"

    if [ "$local_count" -gt 0 ]; then
        local latest
        latest=$(ls -t "$GEORGE_BACKUP_DIR" 2>/dev/null | head -1)
        printf "  %bLatest:%b         %s\n" "$C_CYAN" "$C_RESET" "$latest"
    fi

    # Git backup
    if [ -d "$GEORGE_BACKUP_REPO/.git" ]; then
        local remote
        remote=$(git -C "$GEORGE_BACKUP_REPO" remote get-url origin 2>/dev/null || echo "none")
        local last_commit
        last_commit=$(git -C "$GEORGE_BACKUP_REPO" log -1 --format='%cd' --date=relative 2>/dev/null || echo "never")
        printf "  %bGit backup:%b    ✓ ($last_commit)\n" "$C_CYAN" "$C_RESET"
        printf "  %bRemote:%b        %s\n" "$C_CYAN" "$C_RESET" "$remote"
    else
        printf "  %bGit backup:%b    not configured\n" "$C_CYAN" "$C_RESET"
        ui_dim "  Set up with: /backup git init"
    fi

    # Identity files
    echo ""
    printf "  %bIdentity files:%b\n" "$C_CYAN" "$C_RESET"
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$LODGE_DIR/$f" ]; then
            local size
            size=$(du -h "$LODGE_DIR/$f" 2>/dev/null | cut -f1)
            printf "    %b●%b %-15s %s\n" "$C_GREEN" "$C_RESET" "$f" "$size"
        else
            printf "    %b○%b %-15s missing\n" "$C_DIM" "$C_RESET" "$f"
        fi
    done
    echo ""
}

# ── Remove old backups (keep N most recent) ───────────────────
backup_prune() {
    local keep="${1:-5}"

    if [ ! -d "$GEORGE_BACKUP_DIR" ]; then
        return
    fi

    local count
    count=$(ls -d "$GEORGE_BACKUP_DIR"/*/ 2>/dev/null | wc -l)

    if [ "$count" -le "$keep" ]; then
        ui_info "Only $count backups exist (keeping $keep). Nothing to prune."
        return
    fi

    local to_remove=$((count - keep))
    ui_info "Removing $to_remove old backup(s), keeping $keep most recent"

    ls -dt "$GEORGE_BACKUP_DIR"/*/ 2>/dev/null | tail -n "$to_remove" | while read -r d; do
        local name
        name=$(basename "$d")
        rm -rf "$d"
        ui_dim "  Removed: $name"
    done

    ui_ok "Pruned to $keep backups"
}
