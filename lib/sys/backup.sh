#!/bin/bash
# ── George: Backup & Persistence System ────────────────────────
# Preserves George's identity, config, and credentials across updates.

[ -n "${_LIB_BACKUP_LOADED:-}" ] && return 0; _LIB_BACKUP_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-${LODGE_DIR:-.}/.george}"
GEORGE_BACKUP_DIR="$GEORGE_CONFIG_DIR/backups"
GEORGE_BACKUP_REPO="$GEORGE_CONFIG_DIR/backup-repo"

GEORGE_IDENTITY_FILES=("soul.md" "journal.md" "Modelfile")

_BACKUP_AUTH_ITEMS=(
    "ssh" ".gnupg" ".keyring" "gpg-george.sh" "george_public.asc"
    "keys.conf" "remote.conf" ".vault" "email.conf"
    "mastodon_instances.db" "discord_channels.db"
)
_BACKUP_AUTH_GLOBS=("email_*.conf")

backup_init() {
    mkdir -p "$GEORGE_BACKUP_DIR" "$GEORGE_CONFIG_DIR"
    chmod 700 "$GEORGE_CONFIG_DIR"
}

backup_local() {
    backup_init
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local bp="$GEORGE_BACKUP_DIR/$ts"
    mkdir -p "$bp/projects"
    ui_step "Backing up George to $bp"
    local count=0

    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$LODGE_DIR/$f" ]; then cp "$LODGE_DIR/$f" "$bp/$f"; (( count++ )); fi
    done
    if [ -f "$GEORGE_CONFIG_DIR/keys.conf" ]; then
        cp "$GEORGE_CONFIG_DIR/keys.conf" "$bp/keys.conf"; chmod 600 "$bp/keys.conf"; (( count++ ))
    fi
    if [ -f "$GEORGE_CONFIG_DIR/remote.conf" ]; then
        cp "$GEORGE_CONFIG_DIR/remote.conf" "$bp/remote.conf"; chmod 600 "$bp/remote.conf"; (( count++ ))
    fi

    local george_files=()
    [ -f "$PWD/GEORGE.md" ] && george_files+=("$PWD/GEORGE.md")
    if [ -d "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" ]; then
        while IFS= read -r -d '' cf; do george_files+=("$cf"); done < <(find "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" -name "GEORGE.md" -print0 2>/dev/null)
    fi
    while IFS= read -r -d '' cf; do george_files+=("$cf"); done < <(find "$HOME" -maxdepth 2 -name "GEORGE.md" -not -path "*/.george/*" -not -path "*/blue-lodge/*" -print0 2>/dev/null)

    for cf in "${george_files[@]}"; do
        local pname; pname=$(basename "$(dirname "$cf")")
        mkdir -p "$bp/projects/$pname"
        cp "$cf" "$bp/projects/$pname/GEORGE.md"
        (( count++ ))
    done

    cat > "$bp/MANIFEST.md" << MEOF
# George Backup — $ts
Created: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Lodge version: ${LODGE_VERSION:-unknown}
Files backed up: $count
## Contents
$(ls -la "$bp" | tail -n +2)
## Projects
$(ls "$bp/projects" 2>/dev/null || echo "None")
MEOF

    ui_ok "Backup complete: $count files → $bp"
    echo "$bp"
}

backup_list() {
    backup_init
    if [ ! -d "$GEORGE_BACKUP_DIR" ] || [ -z "$(ls -A "$GEORGE_BACKUP_DIR" 2>/dev/null)" ]; then
        ui_info "No backups found"; ui_dim "Create one: /backup local"; return
    fi
    ui_section "George Backups"
    for d in "$GEORGE_BACKUP_DIR"/*/; do
        [ -d "$d" ] || continue
        local name; name=$(basename "$d")
        local size; size=$(du -sh "$d" 2>/dev/null | cut -f1)
        local fc; fc=$(find "$d" -type f | wc -l)
        printf "  %b%-20s%b %s  (%d files)\n" "$C_WHITE" "$name" "$C_RESET" "$size" "$fc"
    done
}

backup_restore() {
    local backup_name="$1"
    if [ -z "$backup_name" ]; then
        backup_name=$(ls -t "$GEORGE_BACKUP_DIR" 2>/dev/null | head -1)
        [ -z "$backup_name" ] && { ui_err "No backups found"; return 1; }
        ui_info "Using most recent backup: $backup_name"
    fi
    local bp="$GEORGE_BACKUP_DIR/$backup_name"
    [ ! -d "$bp" ] && { ui_err "Backup not found: $backup_name"; return 1; }

    ui_warn "This will overwrite current identity files with the backup."
    ui_confirm "Restore from $backup_name?" "n" || return 0

    local count=0
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$bp/$f" ]; then cp "$bp/$f" "$LODGE_DIR/$f"; ui_dim "  Restored: $f"; (( count++ )); fi
    done
    if [ -f "$bp/keys.conf" ]; then
        cp "$bp/keys.conf" "$GEORGE_CONFIG_DIR/keys.conf"; chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"; ui_dim "  Restored: keys.conf"; (( count++ ))
    fi
    if [ -f "$bp/remote.conf" ]; then
        cp "$bp/remote.conf" "$GEORGE_CONFIG_DIR/remote.conf"; chmod 600 "$GEORGE_CONFIG_DIR/remote.conf"; ui_dim "  Restored: remote.conf"; (( count++ ))
    fi
    declare -f _remote_load_config >/dev/null 2>&1 && _remote_load_config
    ui_ok "Restored $count files from backup $backup_name"
    ui_dim "Project GEORGE.md files are in: $bp/projects/"
}

backup_git_init() {
    backup_init
    [ -d "$GEORGE_BACKUP_REPO/.git" ] && { ui_info "Backup repo already exists at $GEORGE_BACKUP_REPO"; return 0; }
    mkdir -p "$GEORGE_BACKUP_REPO"
    cd "$GEORGE_BACKUP_REPO" || return 1
    git init -q
    echo -e "*.tmp\n*.swp" > .gitignore
    echo "# George Backup Repository" > README.md
    git add -A && git commit -q -m "Initialize George backup repository"
    ui_ok "Backup repo initialized at $GEORGE_BACKUP_REPO"
    cd - > /dev/null
}

backup_git_save() {
    local msg="${1:-Backup $(date +%Y-%m-%d_%H:%M)}"
    [ ! -d "$GEORGE_BACKUP_REPO/.git" ] && { backup_git_init || return 1; }

    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        [ -f "$LODGE_DIR/$f" ] && cp "$LODGE_DIR/$f" "$GEORGE_BACKUP_REPO/$f"
    done
    [ -f "$GEORGE_CONFIG_DIR/keys.conf" ] && cp "$GEORGE_CONFIG_DIR/keys.conf" "$GEORGE_BACKUP_REPO/keys.conf"
    [ -f "$GEORGE_CONFIG_DIR/remote.conf" ] && cp "$GEORGE_CONFIG_DIR/remote.conf" "$GEORGE_BACKUP_REPO/remote.conf"

    mkdir -p "$GEORGE_BACKUP_REPO/projects"
    if [ -d "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" ]; then
        while IFS= read -r -d '' cf; do
            local pname; pname=$(basename "$(dirname "$cf")")
            mkdir -p "$GEORGE_BACKUP_REPO/projects/$pname"
            cp "$cf" "$GEORGE_BACKUP_REPO/projects/$pname/GEORGE.md"
        done < <(find "${LODGE_SANDBOXES:-$LODGE_DIR/.sandboxes}" -name "GEORGE.md" -print0 2>/dev/null)
    fi

    cd "$GEORGE_BACKUP_REPO" || return 1
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        ui_info "No changes to back up"
    else
        git commit -q -m "$msg"
        ui_ok "Saved to backup repo: $msg"
    fi
    cd - > /dev/null
}

backup_git_push() {
    [ ! -d "$GEORGE_BACKUP_REPO/.git" ] && { backup_git_init || return 1; }
    cd "$GEORGE_BACKUP_REPO" || return 1
    local remote; remote=$(git remote get-url origin 2>/dev/null)
    if [ -n "$remote" ] && declare -f github_push_guard &>/dev/null; then
        if ! github_push_guard "$remote"; then cd - > /dev/null; return 1; fi
    fi
    if [ -z "$remote" ]; then
        ui_section "GitHub Backup Setup"
        printf "  %bRepository URL%b: " "$C_WHITE" "$C_RESET"
        read -r repo_url
        [ -z "$repo_url" ] && { ui_err "No URL provided"; cd - > /dev/null; return 1; }
        git remote add origin "$repo_url"
        ui_ok "Remote added: $repo_url"
    fi
    backup_git_save "Pre-push backup $(date +%Y-%m-%d_%H:%M)"
    ui_step "Pushing to remote..."
    if git push -u origin main 2>&1 || git push -u origin master 2>&1; then
        ui_ok "George backed up to GitHub!"
    else
        ui_err "Push failed — check your credentials"
    fi
    cd - > /dev/null
}

backup_git_pull() {
    [ ! -d "$GEORGE_BACKUP_REPO/.git" ] && { ui_err "No backup repo found. Set up with /backup github first."; return 1; }
    cd "$GEORGE_BACKUP_REPO" || return 1
    ui_step "Pulling from remote..."
    if git pull origin main 2>&1 || git pull origin master 2>&1; then
        ui_ok "Pulled latest backup from GitHub"
        if ui_confirm "Restore identity files from pulled backup?" "y"; then
            for f in "${GEORGE_IDENTITY_FILES[@]}"; do
                [ -f "$GEORGE_BACKUP_REPO/$f" ] && { cp "$GEORGE_BACKUP_REPO/$f" "$LODGE_DIR/$f"; ui_dim "  Restored: $f"; }
            done
            if [ -f "$GEORGE_BACKUP_REPO/keys.conf" ]; then
                cp "$GEORGE_BACKUP_REPO/keys.conf" "$GEORGE_CONFIG_DIR/keys.conf"; chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
                ui_dim "  Restored: keys.conf"
            fi
            ui_ok "George's identity restored from GitHub backup"
        fi
    else
        ui_err "Pull failed"
    fi
    cd - > /dev/null
}

backup_git_clone() {
    local repo_url="$1"
    [ -z "$repo_url" ] && { printf "  %bBackup repo URL%b: " "$C_WHITE" "$C_RESET"; read -r repo_url; }
    [ -z "$repo_url" ] && { ui_err "No URL provided"; return 1; }
    if [ -d "$GEORGE_BACKUP_REPO/.git" ]; then
        ui_warn "Backup repo already exists. Pull instead?"
        backup_git_pull; return $?
    fi
    ui_step "Cloning backup from $repo_url"
    if git clone "$repo_url" "$GEORGE_BACKUP_REPO" 2>&1; then
        ui_ok "Backup cloned to $GEORGE_BACKUP_REPO"
        ui_confirm "Restore George's identity from this backup?" "y" && backup_restore_from_repo
    else
        ui_err "Clone failed"; return 1
    fi
}

backup_restore_from_repo() {
    [ ! -d "$GEORGE_BACKUP_REPO" ] && { ui_err "No backup repo found"; return 1; }
    local count=0
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$GEORGE_BACKUP_REPO/$f" ]; then cp "$GEORGE_BACKUP_REPO/$f" "$LODGE_DIR/$f"; ui_dim "  Restored: $f"; (( count++ )); fi
    done
    if [ -f "$GEORGE_BACKUP_REPO/keys.conf" ]; then
        mkdir -p "$GEORGE_CONFIG_DIR"; cp "$GEORGE_BACKUP_REPO/keys.conf" "$GEORGE_CONFIG_DIR/keys.conf"; chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
        ui_dim "  Restored: keys.conf"; (( count++ ))
    fi
    ui_ok "Restored $count files from backup repo"
}

backup_pre_update() {
    ui_section "Pre-Update Backup"
    ui_info "Saving George's identity before update..."
    local bp; bp=$(backup_local)
    [ -d "$GEORGE_BACKUP_REPO/.git" ] && backup_git_save "Pre-update backup $(date +%Y-%m-%d_%H:%M)"
    ui_ok "Identity preserved at: $bp"
    echo "$bp"
}

backup_post_update() {
    ui_section "Post-Update Restore"
    if [ -d "$GEORGE_BACKUP_REPO" ]; then
        for f in "${GEORGE_IDENTITY_FILES[@]}"; do
            if [ -f "$GEORGE_BACKUP_REPO/$f" ] && [ ! -f "$LODGE_DIR/$f" ]; then
                cp "$GEORGE_BACKUP_REPO/$f" "$LODGE_DIR/$f"; ui_dim "  Restored from git: $f"
            fi
        done
    fi
    local latest; latest=$(ls -t "$GEORGE_BACKUP_DIR" 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        local bp="$GEORGE_BACKUP_DIR/$latest"
        for f in "${GEORGE_IDENTITY_FILES[@]}"; do
            if [ -f "$bp/$f" ] && [ ! -f "$LODGE_DIR/$f" ]; then
                cp "$bp/$f" "$LODGE_DIR/$f"; ui_dim "  Restored from local: $f"
            fi
        done
    fi
    ui_ok "George's identity restored"
}

backup_status() {
    ui_section "Backup Status"
    local local_count=0
    [ -d "$GEORGE_BACKUP_DIR" ] && local_count=$(ls -d "$GEORGE_BACKUP_DIR"/*/ 2>/dev/null | wc -l)
    printf "  %bLocal backups:%b  %d\n" "$C_CYAN" "$C_RESET" "$local_count"
    if [ "$local_count" -gt 0 ]; then
        local latest; latest=$(ls -t "$GEORGE_BACKUP_DIR" 2>/dev/null | head -1)
        printf "  %bLatest:%b         %s\n" "$C_CYAN" "$C_RESET" "$latest"
    fi
    if [ -d "$GEORGE_BACKUP_REPO/.git" ]; then
        local remote last_commit
        remote=$(git -C "$GEORGE_BACKUP_REPO" remote get-url origin 2>/dev/null || echo "none")
        last_commit=$(git -C "$GEORGE_BACKUP_REPO" log -1 --format='%cd' --date=relative 2>/dev/null || echo "never")
        printf "  %bGit backup:%b    ✓ (%s)\n  %bRemote:%b        %s\n" "$C_CYAN" "$C_RESET" "$last_commit" "$C_CYAN" "$C_RESET" "$remote"
    else
        printf "  %bGit backup:%b    not configured\n" "$C_CYAN" "$C_RESET"
    fi
    echo ""; printf "  %bIdentity files:%b\n" "$C_CYAN" "$C_RESET"
    for f in "${GEORGE_IDENTITY_FILES[@]}"; do
        if [ -f "$LODGE_DIR/$f" ]; then
            printf "    %b●%b %-15s %s\n" "$C_GREEN" "$C_RESET" "$f" "$(du -h "$LODGE_DIR/$f" 2>/dev/null | cut -f1)"
        else
            printf "    %b○%b %-15s missing\n" "$C_DIM" "$C_RESET" "$f"
        fi
    done
    echo ""
}

backup_prune() {
    local keep="${1:-5}"
    [ ! -d "$GEORGE_BACKUP_DIR" ] && return
    local count; count=$(ls -d "$GEORGE_BACKUP_DIR"/*/ 2>/dev/null | wc -l)
    [ "$count" -le "$keep" ] && { ui_info "Only $count backups exist (keeping $keep). Nothing to prune."; return; }
    local to_remove=$((count - keep))
    ui_info "Removing $to_remove old backup(s), keeping $keep most recent"
    ls -dt "$GEORGE_BACKUP_DIR"/*/ 2>/dev/null | tail -n "$to_remove" | while read -r d; do
        rm -rf "$d"; ui_dim "  Removed: $(basename "$d")"
    done
    ui_ok "Pruned to $keep backups"
}

backup_export() {
    local target="${1:-$(dirname "$LODGE_DIR")}"
    [ ! -d "$GEORGE_CONFIG_DIR" ] && { ui_err "No .george directory found at $GEORGE_CONFIG_DIR"; return 1; }
    target=$(cd "$target" 2>/dev/null && pwd || echo "$target")
    local dest="$target/.george"
    [ "$dest" = "$GEORGE_CONFIG_DIR" ] && { ui_err "Source and destination are the same: $dest"; return 1; }
    ui_step "Exporting .george to $target"
    if [ -d "$dest" ]; then
        ui_confirm "$dest already exists. Overwrite?" "n" || return 0
        rm -rf "$dest"
    fi
    if cp -a "$GEORGE_CONFIG_DIR" "$dest"; then
        ui_ok "Exported .george → $dest ($(find "$dest" -type f | wc -l) files, $(du -sh "$dest" 2>/dev/null | cut -f1))"
    else
        ui_err "Export failed"; return 1
    fi
}

backup_import() {
    local source_path="$1"
    [ -z "$source_path" ] && { ui_err "Usage: /backup import <directory>"; return 1; }
    if [ -d "$source_path/.george" ]; then
        source_path="$source_path/.george"
    elif [ "$(basename "$source_path")" != ".george" ] || [ ! -d "$source_path" ]; then
        ui_err "No .george directory found at $source_path"; return 1
    fi
    source_path=$(cd "$source_path" 2>/dev/null && pwd || echo "$source_path")
    [ "$source_path" = "$GEORGE_CONFIG_DIR" ] && { ui_err "Source and destination are the same: $source_path"; return 1; }

    ui_section "Import from $source_path"
    printf "  Files: %d  Size: %s\n\n" "$(find "$source_path" -type f | wc -l)" "$(du -sh "$source_path" 2>/dev/null | cut -f1)"
    if [ -d "$GEORGE_CONFIG_DIR" ]; then
        ui_warn "This will REPLACE your current .george directory."
        ui_confirm "Continue with import?" "n" || return 0
        local stash="${GEORGE_CONFIG_DIR}.pre-import.$(date +%Y%m%d_%H%M%S)"
        mv "$GEORGE_CONFIG_DIR" "$stash"; ui_dim "  Current .george stashed at: $stash"
    fi
    cp -a "$source_path" "$GEORGE_CONFIG_DIR"
    chmod 700 "$GEORGE_CONFIG_DIR"
    [ -f "$GEORGE_CONFIG_DIR/keys.conf" ] && chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
    ui_ok "Imported .george from $source_path ($(find "$GEORGE_CONFIG_DIR" -type f | wc -l) files)"
}

backup_auth_create() {
    backup_init
    local target_dir="$GEORGE_BACKUP_DIR"
    if [ "${1:-}" != "" ] && [ "${1:-}" != "--" ]; then
        target_dir="$1"; mkdir -p "$target_dir" || { ui_err "Cannot create directory: $target_dir"; return 1; }
    fi
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local bp="$target_dir/auth-$ts"
    mkdir -p "$bp"
    ui_step "Creating auth & config backup"
    local count=0

    for item in "${_BACKUP_AUTH_ITEMS[@]}"; do
        local src="$GEORGE_CONFIG_DIR/$item"
        if [ -e "$src" ]; then
            if [ -d "$src" ]; then cp -a "$src" "$bp/$item"; else cp -p "$src" "$bp/$item"; fi
            (( count++ ))
        fi
    done
    for pattern in "${_BACKUP_AUTH_GLOBS[@]}"; do
        for src in "$GEORGE_CONFIG_DIR"/$pattern; do
            [ -f "$src" ] && { cp -p "$src" "$bp/$(basename "$src")"; (( count++ )); }
        done
    done
    if [ -f "$LODGE_DIR/lodge.conf" ]; then
        cp -p "$LODGE_DIR/lodge.conf" "$bp/lodge.conf"; (( count++ ))
    fi
    [ "$count" -eq 0 ] && { rmdir "$bp" 2>/dev/null; ui_warn "Nothing to back up — no auth or config files found"; return 1; }

    chmod 700 "$bp"
    [ -f "$bp/keys.conf" ] && chmod 600 "$bp/keys.conf"
    [ -d "$bp/.vault" ] && chmod 700 "$bp/.vault"
    [ -d "$bp/.keyring" ] && chmod 700 "$bp/.keyring"
    [ -f "$bp/.keyring/signing.key" ] && chmod 600 "$bp/.keyring/signing.key"

    cat > "$bp/MANIFEST.md" << MEOF
# Auth & Config Backup — $ts
Created: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Lodge version: ${LODGE_VERSION:-unknown}
Items backed up: $count
## Contents
$(ls -la "$bp" | tail -n +2)
MEOF
    ui_ok "Auth backup complete: $count items → auth-$ts ($(du -sh "$bp" 2>/dev/null | cut -f1))"
    echo "$bp"
}

backup_auth_list() {
    backup_init
    local search_dir="${1:-$GEORGE_BACKUP_DIR}"
    local found=0
    for d in "$search_dir"/auth-*/; do
        [ -d "$d" ] || continue
        if [ "$found" -eq 0 ]; then ui_section "Auth & Config Backups (${search_dir})"; found=1; fi
        printf "  %b%-28s%b %s  (%d files)\n" "$C_WHITE" "$(basename "$d")" "$C_RESET" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$(find "$d" -type f | wc -l)"
    done
    if [ "$found" -eq 0 ]; then
        ui_info "No auth backups found in $search_dir"; ui_dim "Create one: /backup auth create [directory]"
    fi
}

backup_auth_restore() {
    local backup_name="${1:-}" source_dir="${2:-}"
    if [ -n "$backup_name" ] && [ -d "$backup_name" ] && [[ "$backup_name" == /* || "$backup_name" == .* || "$backup_name" == ~* ]]; then
        source_dir="$backup_name"; backup_name=""
    fi
    local search_dir="${source_dir:-$GEORGE_BACKUP_DIR}"
    if [ -z "$backup_name" ]; then
        backup_name=$(ls -dt "$search_dir"/auth-*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null)
        [ -z "$backup_name" ] && { ui_err "No auth backups found in $search_dir"; ui_dim "Create one: /backup auth create [directory]"; return 1; }
        ui_info "Using most recent auth backup: $backup_name"
    fi
    local bp="$search_dir/$backup_name"
    [ ! -d "$bp" ] && { ui_err "Backup not found: $bp"; return 1; }

    ui_section "Restore Auth & Config from $backup_name"
    echo ""; ui_dim "  Items to restore:"
    for item in "${_BACKUP_AUTH_ITEMS[@]}"; do [ -e "$bp/$item" ] && printf "    ● %s\n" "$item"; done
    for f in "$bp"/email_*.conf; do [ -f "$f" ] && printf "    ● %s\n" "$(basename "$f")"; done
    [ -f "$bp/lodge.conf" ] && printf "    ● lodge.conf\n"
    echo ""
    ui_warn "This will overwrite any existing auth files with the backup copies."
    ui_confirm "Continue?" "n" || return 0

    mkdir -p "$GEORGE_CONFIG_DIR"
    local count=0
    for item in "${_BACKUP_AUTH_ITEMS[@]}"; do
        local src="$bp/$item" dest="$GEORGE_CONFIG_DIR/$item"
        if [ -e "$src" ]; then
            [ -d "$dest" ] && rm -rf "$dest"
            if [ -d "$src" ]; then cp -a "$src" "$dest"; else cp -p "$src" "$dest"; fi
            ui_dim "  Restored: $item"; (( count++ ))
        fi
    done
    for f in "$bp"/email_*.conf; do
        [ -f "$f" ] && { cp -p "$f" "$GEORGE_CONFIG_DIR/$(basename "$f")"; ui_dim "  Restored: $(basename "$f")"; (( count++ )); }
    done
    if [ -f "$bp/lodge.conf" ]; then
        cp -p "$bp/lodge.conf" "$LODGE_DIR/lodge.conf"; ui_dim "  Restored: lodge.conf → $LODGE_DIR/"; (( count++ ))
    fi

    chmod 700 "$GEORGE_CONFIG_DIR"
    [ -f "$GEORGE_CONFIG_DIR/keys.conf" ] && chmod 600 "$GEORGE_CONFIG_DIR/keys.conf"
    [ -d "$GEORGE_CONFIG_DIR/.vault" ] && chmod 700 "$GEORGE_CONFIG_DIR/.vault"
    [ -d "$GEORGE_CONFIG_DIR/.keyring" ] && chmod 700 "$GEORGE_CONFIG_DIR/.keyring"
    [ -f "$GEORGE_CONFIG_DIR/.keyring/signing.key" ] && chmod 600 "$GEORGE_CONFIG_DIR/.keyring/signing.key"
    [ -d "$GEORGE_CONFIG_DIR/ssh" ] && chmod 700 "$GEORGE_CONFIG_DIR/ssh"
    [ -d "$GEORGE_CONFIG_DIR/.gnupg" ] && chmod 700 "$GEORGE_CONFIG_DIR/.gnupg"

    declare -f remote_disconnect >/dev/null 2>&1 && remote_disconnect 2>/dev/null
    declare -f _remote_load_config >/dev/null 2>&1 && _remote_load_config
    ui_ok "Restored $count auth/config items from $backup_name"
}
