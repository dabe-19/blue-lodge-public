#!/bin/bash
# ── George: Backup & Persistence System ────────────────────────
# Preserves George's identity across repo updates. Backs up
# journal.md, soul.md, GEORGE.md, and keys.conf to local files
# or a private git repo that the user controls.
#
# Philosophy: George's code can be rewritten, but his memories
# and personality are irreplaceable. Protect them.

[ -n "${_LIB_BACKUP_LOADED:-}" ] && return 0; _LIB_BACKUP_LOADED=1

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
# Copies identity files + all GEORGE.md files to a timestamped dir
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

    # Collect all GEORGE.md files from known project locations
    # (backwards-compatible: also collects legacy CLAUDE.md)
    local claude_files=()
    # Current directory
    if [ -f "$PWD/GEORGE.md" ]; then
        claude_files+=("$PWD/GEORGE.md")
    elif [ -f "$PWD/CLAUDE.md" ]; then
        claude_files+=("$PWD/CLAUDE.md")
    fi
    # Sandboxes
    if [ -d "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" ]; then
        while IFS= read -r -d '' cf; do
            claude_files+=("$cf")
        done < <(find "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" \( -name "GEORGE.md" -o -name "CLAUDE.md" \) -print0 2>/dev/null)
    fi
    # Home directory projects (1 level deep)
    while IFS= read -r -d '' cf; do
        claude_files+=("$cf")
    done < <(find "$HOME" -maxdepth 2 \( -name "GEORGE.md" -o -name "CLAUDE.md" \) -not -path "*/.george/*" -not -path "*/blue-lodge/*" -print0 2>/dev/null)

    for cf in "${claude_files[@]}"; do
        local project_name
        project_name=$(basename "$(dirname "$cf")")
        mkdir -p "$backup_path/projects/$project_name"
        cp "$cf" "$backup_path/projects/$project_name/GEORGE.md"
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
    ui_dim "Project GEORGE.md files are in: $backup_path/projects/"
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
- **projects/** — Per-project GEORGE.md memory files

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

    # Copy GEORGE.md files (backwards-compatible: also finds CLAUDE.md)
    mkdir -p "$GEORGE_BACKUP_REPO/projects"
    if [ -d "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" ]; then
        find "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" \( -name "GEORGE.md" -o -name "CLAUDE.md" \) -print0 2>/dev/null | \
            while IFS= read -r -d '' cf; do
                local pname
                pname=$(basename "$(dirname "$cf")")
                mkdir -p "$GEORGE_BACKUP_REPO/projects/$pname"
                cp "$cf" "$GEORGE_BACKUP_REPO/projects/$pname/GEORGE.md"
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

# ── Export .george to a directory ──────────────────────────────
# Copies the entire .george directory to target (default: parent of LODGE_DIR)
backup_export() {
    local target="${1:-$(dirname "$LODGE_DIR")}"

    if [ ! -d "$GEORGE_CONFIG_DIR" ]; then
        ui_err "No .george directory found at $GEORGE_CONFIG_DIR"
        return 1
    fi

    # Resolve to absolute path
    target=$(cd "$target" 2>/dev/null && pwd || echo "$target")
    local dest="$target/.george"

    if [ "$dest" = "$GEORGE_CONFIG_DIR" ]; then
        ui_err "Source and destination are the same: $dest"
        return 1
    fi

    ui_step "Exporting .george to $target"

    # If destination exists, confirm overwrite
    if [ -d "$dest" ]; then
        if ! ui_confirm "$dest already exists. Overwrite?" "n"; then
            return 0
        fi
        rm -rf "$dest"
    fi

    cp -a "$GEORGE_CONFIG_DIR" "$dest"
    local status=$?

    if [ $status -eq 0 ]; then
        local size
        size=$(du -sh "$dest" 2>/dev/null | cut -f1)
        local file_count
        file_count=$(find "$dest" -type f | wc -l)
        ui_ok "Exported .george → $dest ($file_count files, $size)"
    else
        ui_err "Export failed (cp exit $status)"
        return 1
    fi
}

# ── Import .george from a directory ───────────────────────────
# Restores the .george directory from a specified path
backup_import() {
    local source_path="$1"

    if [ -z "$source_path" ]; then
        ui_err "Usage: /backup import <directory>"
        ui_dim "  Specify the directory containing a .george folder"
        ui_dim "  Example: /backup import /home/user"
        ui_dim "  Example: /backup import /sdcard/george-backup"
        return 1
    fi

    # Check if they pointed directly at .george or the parent
    if [ -d "$source_path/.george" ]; then
        source_path="$source_path/.george"
    elif [ "$(basename "$source_path")" = ".george" ] && [ -d "$source_path" ]; then
        : # Already pointing at .george directly
    else
        ui_err "No .george directory found at $source_path"
        ui_dim "  Expected: $source_path/.george/ or $source_path/ (if it IS the .george dir)"
        return 1
    fi

    # Resolve to absolute path
    source_path=$(cd "$source_path" 2>/dev/null && pwd || echo "$source_path")

    if [ "$source_path" = "$GEORGE_CONFIG_DIR" ]; then
        ui_err "Source and destination are the same: $source_path"
        return 1
    fi

    local file_count
    file_count=$(find "$source_path" -type f | wc -l)
    local size
    size=$(du -sh "$source_path" 2>/dev/null | cut -f1)

    ui_section "Import from $source_path"
    printf "  Files: %d  Size: %s\n" "$file_count" "$size"
    echo ""

    # Show what's in there
    ui_dim "  Contents:"
    ls -la "$source_path" 2>/dev/null | tail -n +2 | while read -r line; do
        ui_dim "    $line"
    done
    echo ""

    if [ -d "$GEORGE_CONFIG_DIR" ]; then
        ui_warn "This will REPLACE your current .george directory."
        if ! ui_confirm "Continue with import?" "n"; then
            return 0
        fi
        # Back up current before overwriting
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        local stash="${GEORGE_CONFIG_DIR}.pre-import.$timestamp"
        mv "$GEORGE_CONFIG_DIR" "$stash"
        ui_dim "  Current .george stashed at: $stash"
    fi

    cp -a "$source_path" "$GEORGE_CONFIG_DIR"
    chmod 700 "$GEORGE_CONFIG_DIR"
    [ -f "$GEORGE_CONFIG_DIR/keys.conf" ] && chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"

    ui_ok "Imported .george from $source_path ($file_count files)"
    ui_dim "  Restart George to pick up changes: /quit then relaunch"
}

# ═══════════════════════════════════════════════════════════════
# Auth & Config Backup/Restore
# ═══════════════════════════════════════════════════════════════
# Portable backup of authentication credentials and service
# configuration only — no memory, history, transcripts, cache,
# or other runtime data. Designed for migrating George to a new
# machine or recovering from a fresh install.
#
# What's included:
#   .ssh/                   SSH keys
#   .gnupg/                 GPG/PGP keyring
#   gpg-george.sh           GPG wrapper script
#   george_public.asc       GPG public key
#   keys.conf               API keys (plaintext)
#   .vault/                 Encrypted secrets vault
#   email.conf              Legacy email credentials
#   email_*.conf            Per-provider email configs
#   mastodon_instances.db   Mastodon instance registry
#   discord_channels.db     Discord channel mappings
#   lodge.conf              User configuration overrides
#
# What's NOT included:
#   recall.db               Knowledge base (rebuilt on start)
#   transcripts/            Session transcripts
#   backups/                Backup history
#   backup-repo/            Git backup repository
#   cache/                  API response cache
#   cookies/                Web session cookies
#   sandbox_journal.jsonl   Sandbox history
#   slash/                  Custom slash commands (code, not creds)

# Files and directories that belong in an auth/config backup.
# Paths are relative to $GEORGE_CONFIG_DIR.
_BACKUP_AUTH_ITEMS=(
    ".ssh"
    ".gnupg"
    "gpg-george.sh"
    "george_public.asc"
    "keys.conf"
    ".vault"
    "email.conf"
    "mastodon_instances.db"
    "discord_channels.db"
)

# Glob patterns for items that can have variable names
_BACKUP_AUTH_GLOBS=(
    "email_*.conf"
)

# ── Create auth/config backup ─────────────────────────────────
# Copies only auth & config items to a timestamped directory.
# Usage: backup_auth_create [target_directory]
#   If target_directory is supplied, the timestamped auth-* folder
#   is created there instead of inside $GEORGE_BACKUP_DIR.
backup_auth_create() {
    backup_init

    local target_dir="$GEORGE_BACKUP_DIR"
    if [ "${1:-}" != "" ] && [ "${1:-}" != "--" ]; then
        target_dir="$1"
        mkdir -p "$target_dir" || { ui_err "Cannot create directory: $target_dir"; return 1; }
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$target_dir/auth-$timestamp"
    mkdir -p "$backup_path"

    ui_step "Creating auth & config backup"

    local count=0

    # Fixed-name items
    for item in "${_BACKUP_AUTH_ITEMS[@]}"; do
        local src="$GEORGE_CONFIG_DIR/$item"
        if [ -e "$src" ]; then
            if [ -d "$src" ]; then
                cp -a "$src" "$backup_path/$item"
            else
                cp -p "$src" "$backup_path/$item"
            fi
            count=$((count + 1))
        fi
    done

    # Glob-pattern items (e.g., email_gmail.conf, email_outlook.conf)
    for pattern in "${_BACKUP_AUTH_GLOBS[@]}"; do
        for src in "$GEORGE_CONFIG_DIR"/$pattern; do
            [ -f "$src" ] || continue
            cp -p "$src" "$backup_path/$(basename "$src")"
            count=$((count + 1))
        done
    done

    # lodge.conf from LODGE_DIR (not inside .george)
    if [ -f "$LODGE_DIR/lodge.conf" ]; then
        cp -p "$LODGE_DIR/lodge.conf" "$backup_path/lodge.conf"
        count=$((count + 1))
    fi

    if [ "$count" -eq 0 ]; then
        rmdir "$backup_path" 2>/dev/null
        ui_warn "Nothing to back up — no auth or config files found"
        return 1
    fi

    # Lock down permissions
    chmod 700 "$backup_path"
    [ -f "$backup_path/keys.conf" ] && chmod 600 "$backup_path/keys.conf"
    [ -d "$backup_path/.vault" ] && chmod 700 "$backup_path/.vault"

    # Write manifest
    cat > "$backup_path/MANIFEST.md" << MEOF
# Auth & Config Backup — $timestamp

Created: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Lodge version: ${LODGE_VERSION:-unknown}
Items backed up: $count

## Contents
$(ls -la "$backup_path" | tail -n +2)

## Notes
This backup contains ONLY authentication credentials and service
configuration. No memory, transcripts, or runtime data is included.
Restore with: /backup auth restore auth-$timestamp
MEOF

    local size
    size=$(du -sh "$backup_path" 2>/dev/null | cut -f1)
    ui_ok "Auth backup complete: $count items → auth-$timestamp ($size)"
    echo "$backup_path"
}

# ── List auth/config backups ──────────────────────────────────
# Usage: backup_auth_list [directory]
backup_auth_list() {
    backup_init

    local search_dir="$GEORGE_BACKUP_DIR"
    if [ -n "${1:-}" ] && [ -d "${1:-}" ]; then
        search_dir="$1"
    fi

    local found=0
    for d in "$search_dir"/auth-*/; do
        [ -d "$d" ] || continue
        if [ "$found" -eq 0 ]; then
            ui_section "Auth & Config Backups (${search_dir})"
            found=1
        fi
        local name
        name=$(basename "$d")
        local size
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        local file_count
        file_count=$(find "$d" -type f | wc -l)
        printf "  %b%-28s%b %s  (%d files)\n" "$C_WHITE" "$name" "$C_RESET" "$size" "$file_count"
    done

    if [ "$found" -eq 0 ]; then
        ui_info "No auth backups found in $search_dir"
        ui_dim "Create one: /backup auth create [directory]"
    fi
}

# ── Restore auth/config backup ────────────────────────────────
# Usage: backup_auth_restore [backup_name] [source_directory]
#   backup_name   — Name of backup (e.g. auth-20260303_120000).
#                   Omit to auto-select latest.
#   source_directory — Directory to search for auth-* backups.
#                      Defaults to $GEORGE_BACKUP_DIR.
backup_auth_restore() {
    local backup_name="${1:-}"
    local source_dir="${2:-}"

    # If backup_name looks like a directory path, treat it as source_dir
    if [ -n "$backup_name" ] && [ -d "$backup_name" ] && [[ "$backup_name" == /* || "$backup_name" == .* || "$backup_name" == ~* ]]; then
        source_dir="$backup_name"
        backup_name=""
    fi

    local search_dir="${source_dir:-$GEORGE_BACKUP_DIR}"

    if [ -z "$backup_name" ]; then
        # Use most recent auth backup from search_dir
        backup_name=$(ls -dt "$search_dir"/auth-*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null)
        if [ -z "$backup_name" ]; then
            ui_err "No auth backups found in $search_dir"
            ui_dim "Create one: /backup auth create [directory]"
            return 1
        fi
        ui_info "Using most recent auth backup: $backup_name"
    fi

    local backup_path="$search_dir/$backup_name"
    if [ ! -d "$backup_path" ]; then
        ui_err "Backup not found: $backup_path"
        return 1
    fi

    # Show what will be restored
    ui_section "Restore Auth & Config from $backup_name"
    echo ""
    ui_dim "  Items to restore:"
    for item in "${_BACKUP_AUTH_ITEMS[@]}"; do
        [ -e "$backup_path/$item" ] && printf "    ● %s\n" "$item"
    done
    for f in "$backup_path"/email_*.conf; do
        [ -f "$f" ] && printf "    ● %s\n" "$(basename "$f")"
    done
    [ -f "$backup_path/lodge.conf" ] && printf "    ● lodge.conf\n"
    echo ""

    ui_warn "This will overwrite any existing auth files with the backup copies."
    if ! ui_confirm "Continue?" "n"; then
        return 0
    fi

    mkdir -p "$GEORGE_CONFIG_DIR"

    local count=0

    # Fixed-name items
    for item in "${_BACKUP_AUTH_ITEMS[@]}"; do
        local src="$backup_path/$item"
        local dest="$GEORGE_CONFIG_DIR/$item"
        if [ -e "$src" ]; then
            # Remove existing before restoring directories
            [ -d "$dest" ] && rm -rf "$dest"
            if [ -d "$src" ]; then
                cp -a "$src" "$dest"
            else
                cp -p "$src" "$dest"
            fi
            ui_dim "  Restored: $item"
            count=$((count + 1))
        fi
    done

    # Glob items
    for f in "$backup_path"/email_*.conf; do
        [ -f "$f" ] || continue
        cp -p "$f" "$GEORGE_CONFIG_DIR/$(basename "$f")"
        ui_dim "  Restored: $(basename "$f")"
        count=$((count + 1))
    done

    # lodge.conf goes to LODGE_DIR, not .george
    if [ -f "$backup_path/lodge.conf" ]; then
        cp -p "$backup_path/lodge.conf" "$LODGE_DIR/lodge.conf"
        ui_dim "  Restored: lodge.conf → $LODGE_DIR/"
        count=$((count + 1))
    fi

    # Fix permissions
    chmod 700 "$GEORGE_CONFIG_DIR"
    [ -f "$GEORGE_CONFIG_DIR/keys.conf" ] && chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
    [ -d "$GEORGE_CONFIG_DIR/.vault" ] && chmod 700 "$GEORGE_CONFIG_DIR/.vault"
    [ -d "$GEORGE_CONFIG_DIR/.ssh" ] && chmod 700 "$GEORGE_CONFIG_DIR/.ssh"
    [ -d "$GEORGE_CONFIG_DIR/.gnupg" ] && chmod 700 "$GEORGE_CONFIG_DIR/.gnupg"

    ui_ok "Restored $count auth/config items from $backup_name"
    ui_dim "  Restart George to pick up changes: /quit then relaunch"
}
