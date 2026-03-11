#!/bin/bash
# ── George: Pure-Bash MCP Git Server ──────────────────────────
# A self-contained MCP server that speaks JSON-RPC 2.0 over stdio.
# Exposes Git & GitHub operations as MCP tools so the agent can
# use them via the MCP client before falling back to /git and /github.
#
# Tools exposed:
#   git_status       — Show working tree status (staged, modified, untracked)
#   git_log          — Show recent commit history
#   git_diff         — Show diff of working tree or staged changes
#   git_commit       — Stage files and commit with a message
#   git_push         — Push current branch to remote
#   git_pull         — Pull from remote
#   git_branch       — List, create, or switch branches
#   git_clone        — Clone a repository
#   git_remote       — List or manage remotes
#   github_search    — Search GitHub repositories by keyword
#   github_check     — Verify a GitHub repository exists
#   git_setup_status — Show George's git configuration overview
#
# Usage:
#   Register as MCP server:
#     /mcp add george-git "bash $LODGE_DIR/lib/mcp_server_git.sh"
#
#   Or run standalone:
#     echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bash lib/mcp_server_git.sh

set -uo pipefail

# ── Bootstrap George libraries ─────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/cache.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/git.sh"

# Web library needed for GitHub search/check
source "$LODGE_DIR/lib/web.sh" 2>/dev/null || true

# Ensure cache dir exists
GEORGE_CACHE_DIR="${GEORGE_CACHE_DIR:-$GEORGE_DIR/cache/web}"
mkdir -p "$GEORGE_CACHE_DIR" 2>/dev/null

# ── jq (hard dependency — installed by install.sh) ────────────
_JQ="jq"
command -v gojq >/dev/null 2>&1 && _JQ="gojq"

# ── JSON-RPC Response Helpers ──────────────────────────────────

_respond_result() {
    local id="$1"
    local result_json="$2"
    $_JQ -n -c \
        --argjson id "$id" \
        --argjson result "$result_json" \
        '{"jsonrpc":"2.0","id":$id,"result":$result}'
}

_respond_error() {
    local id="$1"
    local code="$2"
    local message="$3"
    if [ "$id" = "null" ]; then
        $_JQ -n -c \
            --argjson code "$code" \
            --arg message "$message" \
            '{"jsonrpc":"2.0","id":null,"error":{"code":$code,"message":$message}}'
    else
        $_JQ -n -c \
            --argjson id "$id" \
            --argjson code "$code" \
            --arg message "$message" \
            '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$message}}'
    fi
}

_text_content() {
    local text="$1"
    $_JQ -n -c --arg text "$text" \
        '{"content":[{"type":"text","text":$text}]}'
}

# ── Tool Definitions ───────────────────────────────────────────

_TOOLS_JSON='[
  {
    "name": "git_status",
    "description": "Show the working tree status: staged, modified, and untracked files. Includes branch name and short diff stats.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        }
      }
    }
  },
  {
    "name": "git_log",
    "description": "Show recent commit history with hash, author, date, and message.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "count": {
          "type": "integer",
          "description": "Number of commits to show (default: 10)"
        },
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        },
        "oneline": {
          "type": "boolean",
          "description": "Use compact one-line format (default: false)"
        }
      }
    }
  },
  {
    "name": "git_diff",
    "description": "Show diff of working tree changes. Can show staged changes, changes against a specific commit, or diff between two refs.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "staged": {
          "type": "boolean",
          "description": "Show staged (cached) changes only (default: false)"
        },
        "ref": {
          "type": "string",
          "description": "Diff against this ref (commit, branch, tag)"
        },
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        },
        "stat_only": {
          "type": "boolean",
          "description": "Show only diffstat summary, no patch (default: false)"
        }
      }
    }
  },
  {
    "name": "git_commit",
    "description": "Stage files and create a commit. If no files specified, stages all changes (git add -A).",
    "inputSchema": {
      "type": "object",
      "properties": {
        "message": {
          "type": "string",
          "description": "Commit message (required)"
        },
        "files": {
          "type": "string",
          "description": "Space-separated list of files to stage (default: all changes)"
        },
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        }
      },
      "required": ["message"]
    }
  },
  {
    "name": "git_push",
    "description": "Push the current branch to a remote.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "remote": {
          "type": "string",
          "description": "Remote name (default: origin)"
        },
        "branch": {
          "type": "string",
          "description": "Branch to push (default: current branch)"
        },
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        }
      }
    }
  },
  {
    "name": "git_pull",
    "description": "Pull from a remote, updating the current branch.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "remote": {
          "type": "string",
          "description": "Remote name (default: origin)"
        },
        "branch": {
          "type": "string",
          "description": "Branch to pull (default: current branch)"
        },
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        }
      }
    }
  },
  {
    "name": "git_branch",
    "description": "List branches, create a new branch, or switch to an existing branch.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "description": "Action: list (default), create, switch, delete",
          "enum": ["list", "create", "switch", "delete"]
        },
        "name": {
          "type": "string",
          "description": "Branch name (required for create/switch/delete)"
        },
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        }
      }
    }
  },
  {
    "name": "git_clone",
    "description": "Clone a repository. Accepts full URLs or owner/repo shorthand (auto-expands to GitHub HTTPS URL).",
    "inputSchema": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "Repository URL or owner/repo shorthand (required)"
        },
        "dest": {
          "type": "string",
          "description": "Destination directory name"
        }
      },
      "required": ["url"]
    }
  },
  {
    "name": "git_remote",
    "description": "List remotes or add/update a remote URL.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "description": "Action: list (default), add, remove",
          "enum": ["list", "add", "remove"]
        },
        "name": {
          "type": "string",
          "description": "Remote name (default: origin)"
        },
        "url": {
          "type": "string",
          "description": "Remote URL (required for add)"
        },
        "path": {
          "type": "string",
          "description": "Repository path (default: current directory)"
        }
      }
    }
  },
  {
    "name": "github_search",
    "description": "Search GitHub repositories by keyword. Returns repo name, stars, language, and description. No auth needed for public repos.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The search query"
        },
        "count": {
          "type": "integer",
          "description": "Number of results to return (default: 5)"
        }
      },
      "required": ["query"]
    }
  },
  {
    "name": "github_check",
    "description": "Verify that a GitHub repository exists and is accessible. Returns confirmation or not-found.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "repo": {
          "type": "string",
          "description": "Repository in owner/repo format (required)"
        }
      },
      "required": ["repo"]
    }
  },
  {
    "name": "git_setup_status",
    "description": "Show George git configuration overview: identity, SSH key status, GPG signing status, and remotes.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  }
]'

# ── Tool Dispatch ──────────────────────────────────────────────

_handle_tool_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"

    case "$tool_name" in
        git_status)
            local path
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            local branch status_out stats
            branch=$(git branch --show-current 2>/dev/null || echo "detached")
            status_out=$(git status --short 2>/dev/null)
            stats=$(git diff --stat 2>/dev/null)

            local result="Branch: $branch"
            if [ -n "$status_out" ]; then
                result="${result}\n\nStatus:\n${status_out}"
            else
                result="${result}\n\nWorking tree clean"
            fi
            [ -n "$stats" ] && result="${result}\n\nDiff stats:\n${stats}"

            _respond_result "$id" "$(_text_content "$(printf '%b' "$result")")"
            ;;

        git_log)
            local count path oneline
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            oneline=$(printf '%s' "$arguments" | $_JQ -r '.oneline // empty' 2>/dev/null)
            [ -z "$count" ] && count=10
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            local log_out
            if [ "$oneline" = "true" ]; then
                log_out=$(git log --oneline -n "$count" --no-color 2>/dev/null)
            else
                log_out=$(git log --format="%h %an %ad %s" --date=short -n "$count" --no-color 2>/dev/null)
            fi

            if [ -z "$log_out" ]; then
                _respond_result "$id" "$(_text_content "No commits found")"
                return
            fi
            _respond_result "$id" "$(_text_content "$log_out")"
            ;;

        git_diff)
            local staged ref path stat_only
            staged=$(printf '%s' "$arguments" | $_JQ -r '.staged // empty' 2>/dev/null)
            ref=$(printf '%s' "$arguments" | $_JQ -r '.ref // empty' 2>/dev/null)
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            stat_only=$(printf '%s' "$arguments" | $_JQ -r '.stat_only // empty' 2>/dev/null)
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            local diff_args=()
            [ "$staged" = "true" ] && diff_args+=(--cached)
            [ -n "$ref" ] && diff_args+=("$ref")
            [ "$stat_only" = "true" ] && diff_args+=(--stat)
            diff_args+=(--no-color)

            local diff_out
            diff_out=$(git diff "${diff_args[@]}" 2>/dev/null | head -500)

            if [ -z "$diff_out" ]; then
                _respond_result "$id" "$(_text_content "No differences found")"
                return
            fi
            _respond_result "$id" "$(_text_content "$diff_out")"
            ;;

        git_commit)
            local message files path
            message=$(printf '%s' "$arguments" | $_JQ -r '.message // empty' 2>/dev/null)
            files=$(printf '%s' "$arguments" | $_JQ -r '.files // empty' 2>/dev/null)
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if [ -z "$message" ]; then
                _respond_result "$id" "$(_text_content "Error: message parameter is required")"
                return
            fi

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            # Stage files
            if [ -n "$files" ]; then
                git add -- $files 2>&1
            else
                git add -A 2>&1
            fi

            local commit_out
            commit_out=$(git commit -m "$message" 2>&1)
            local rc=$?

            if [ $rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "$commit_out")"
            else
                _respond_result "$id" "$(_text_content "Error: Commit failed\n$commit_out")"
            fi
            ;;

        git_push)
            local remote branch path
            remote=$(printf '%s' "$arguments" | $_JQ -r '.remote // empty' 2>/dev/null)
            branch=$(printf '%s' "$arguments" | $_JQ -r '.branch // empty' 2>/dev/null)
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            [ -z "$remote" ] && remote="origin"
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            [ -z "$branch" ] && branch=$(git branch --show-current 2>/dev/null)
            if [ -z "$branch" ]; then
                _respond_result "$id" "$(_text_content "Error: Cannot determine current branch")"
                return
            fi

            # GitHub push guard — ensure SSH key is configured
            local remote_url
            remote_url=$(git remote get-url "$remote" 2>/dev/null || echo "")
            if declare -f github_push_guard &>/dev/null; then
                if ! github_push_guard "$remote_url" 2>/dev/null; then
                    _respond_result "$id" "$(_text_content "Error: GitHub push guard failed — run /git setup first")"
                    return
                fi
            fi

            local push_out
            push_out=$(git push "$remote" "$branch" 2>&1)
            local rc=$?

            if [ $rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "Pushed to $remote/$branch\n$push_out")"
            else
                _respond_result "$id" "$(_text_content "Error: Push failed\n$push_out")"
            fi
            ;;

        git_pull)
            local remote branch path
            remote=$(printf '%s' "$arguments" | $_JQ -r '.remote // empty' 2>/dev/null)
            branch=$(printf '%s' "$arguments" | $_JQ -r '.branch // empty' 2>/dev/null)
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            [ -z "$remote" ] && remote="origin"
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            local pull_args=("$remote")
            [ -n "$branch" ] && pull_args+=("$branch")

            local pull_out
            pull_out=$(git pull "${pull_args[@]}" 2>&1)
            local rc=$?

            if [ $rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "$pull_out")"
            else
                _respond_result "$id" "$(_text_content "Error: Pull failed\n$pull_out")"
            fi
            ;;

        git_branch)
            local action name path
            action=$(printf '%s' "$arguments" | $_JQ -r '.action // empty' 2>/dev/null)
            name=$(printf '%s' "$arguments" | $_JQ -r '.name // empty' 2>/dev/null)
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            [ -z "$action" ] && action="list"
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            case "$action" in
                list)
                    local branches
                    branches=$(git branch -a --no-color 2>/dev/null)
                    if [ -z "$branches" ]; then
                        _respond_result "$id" "$(_text_content "No branches found")"
                    else
                        _respond_result "$id" "$(_text_content "$branches")"
                    fi
                    ;;
                create)
                    if [ -z "$name" ]; then
                        _respond_result "$id" "$(_text_content "Error: name parameter is required for create")"
                        return
                    fi
                    local out
                    out=$(git checkout -b "$name" 2>&1)
                    _respond_result "$id" "$(_text_content "$out")"
                    ;;
                switch)
                    if [ -z "$name" ]; then
                        _respond_result "$id" "$(_text_content "Error: name parameter is required for switch")"
                        return
                    fi
                    local out
                    out=$(git checkout "$name" 2>&1)
                    _respond_result "$id" "$(_text_content "$out")"
                    ;;
                delete)
                    if [ -z "$name" ]; then
                        _respond_result "$id" "$(_text_content "Error: name parameter is required for delete")"
                        return
                    fi
                    local out
                    out=$(git branch -d "$name" 2>&1)
                    _respond_result "$id" "$(_text_content "$out")"
                    ;;
                *)
                    _respond_result "$id" "$(_text_content "Error: Unknown branch action: $action (use list, create, switch, delete)")"
                    ;;
            esac
            ;;

        git_clone)
            local url dest
            url=$(printf '%s' "$arguments" | $_JQ -r '.url // empty' 2>/dev/null)
            dest=$(printf '%s' "$arguments" | $_JQ -r '.dest // empty' 2>/dev/null)

            if [ -z "$url" ]; then
                _respond_result "$id" "$(_text_content "Error: url parameter is required")"
                return
            fi

            # Expand owner/repo shorthand to GitHub HTTPS URL
            if [[ "$url" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]]; then
                url="https://github.com/$url.git"
            fi

            local clone_args=("$url")
            [ -n "$dest" ] && clone_args+=("$dest")

            local clone_out
            clone_out=$(git clone "${clone_args[@]}" 2>&1)
            local rc=$?

            if [ $rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "Cloned $url\n$clone_out")"
            else
                _respond_result "$id" "$(_text_content "Error: Clone failed\n$clone_out")"
            fi
            ;;

        git_remote)
            local action name url path
            action=$(printf '%s' "$arguments" | $_JQ -r '.action // empty' 2>/dev/null)
            name=$(printf '%s' "$arguments" | $_JQ -r '.name // empty' 2>/dev/null)
            url=$(printf '%s' "$arguments" | $_JQ -r '.url // empty' 2>/dev/null)
            path=$(printf '%s' "$arguments" | $_JQ -r '.path // empty' 2>/dev/null)
            [ -z "$action" ] && action="list"
            [ -z "$name" ] && name="origin"
            [ -n "$path" ] && cd "$path" 2>/dev/null

            if ! git rev-parse --git-dir &>/dev/null; then
                _respond_result "$id" "$(_text_content "Error: Not a git repository")"
                return
            fi

            case "$action" in
                list)
                    local remotes
                    remotes=$(git remote -v 2>/dev/null)
                    if [ -z "$remotes" ]; then
                        _respond_result "$id" "$(_text_content "No remotes configured")"
                    else
                        _respond_result "$id" "$(_text_content "$remotes")"
                    fi
                    ;;
                add)
                    if [ -z "$url" ]; then
                        _respond_result "$id" "$(_text_content "Error: url parameter is required for add")"
                        return
                    fi
                    local out
                    if git remote get-url "$name" &>/dev/null; then
                        out=$(git remote set-url "$name" "$url" 2>&1)
                        _respond_result "$id" "$(_text_content "Remote '$name' updated: $url\n$out")"
                    else
                        out=$(git remote add "$name" "$url" 2>&1)
                        _respond_result "$id" "$(_text_content "Remote '$name' added: $url\n$out")"
                    fi
                    ;;
                remove)
                    local out
                    out=$(git remote remove "$name" 2>&1)
                    _respond_result "$id" "$(_text_content "$out")"
                    ;;
                *)
                    _respond_result "$id" "$(_text_content "Error: Unknown remote action: $action (use list, add, remove)")"
                    ;;
            esac
            ;;

        github_search)
            local query count
            query=$(printf '%s' "$arguments" | $_JQ -r '.query // empty' 2>/dev/null)
            count=$(printf '%s' "$arguments" | $_JQ -r '.count // empty' 2>/dev/null)
            [ -z "$count" ] && count=5

            if [ -z "$query" ]; then
                _respond_result "$id" "$(_text_content "Error: query parameter is required")"
                return
            fi

            local results
            results=$(web_search_github "$query" "$count" 2>/dev/null)
            if [ -z "$results" ]; then
                _respond_result "$id" "$(_text_content "No GitHub results for: $query")"
                return
            fi

            _respond_result "$id" "$(_text_content "$results")"
            ;;

        github_check)
            local repo
            repo=$(printf '%s' "$arguments" | $_JQ -r '.repo // empty' 2>/dev/null)

            if [ -z "$repo" ]; then
                _respond_result "$id" "$(_text_content "Error: repo parameter is required")"
                return
            fi

            if web_github_repo_exists "$repo" 2>/dev/null; then
                _respond_result "$id" "$(_text_content "Repository exists: $repo (https://github.com/$repo)")"
            else
                _respond_result "$id" "$(_text_content "Repository not found: $repo")"
            fi
            ;;

        git_setup_status)
            local result=""

            # Identity
            local name email
            name=$(git config --global user.name 2>/dev/null || echo "not set")
            email=$(git config --global user.email 2>/dev/null || echo "not set")
            result="Identity: $name <$email>"

            # SSH key
            if [ -f "${GEORGE_SSH_KEY:-/dev/null}.pub" ]; then
                local pubkey_info
                pubkey_info=$(awk '{print $1, $NF}' "${GEORGE_SSH_KEY}.pub" 2>/dev/null)
                result="${result}\nSSH key: configured ($pubkey_info)"
            else
                result="${result}\nSSH key: not generated"
            fi

            # SSH config
            if [ -f "${GEORGE_SSH_DIR:-/dev/null}/config" ] && grep -q "Host ${GEORGE_GIT_HOST:-github.com-george}" "${GEORGE_SSH_DIR}/config" 2>/dev/null; then
                result="${result}\nSSH config: persistent (Host alias: ${GEORGE_GIT_HOST:-github.com-george})"
            else
                result="${result}\nSSH config: not configured"
            fi

            # GPG signing
            local signing
            signing=$(git config --global commit.gpgsign 2>/dev/null)
            if [ "$signing" = "true" ]; then
                local sigkey
                sigkey=$(git config --global user.signingkey 2>/dev/null)
                result="${result}\nGPG signing: enabled (key: ${sigkey: -16})"
            else
                result="${result}\nGPG signing: disabled"
            fi

            # Remotes (if in a repo)
            if git rev-parse --git-dir &>/dev/null 2>&1; then
                local remotes
                remotes=$(git remote -v 2>/dev/null | grep '(push)')
                if [ -n "$remotes" ]; then
                    result="${result}\nRemotes:\n$remotes"
                else
                    result="${result}\nRemotes: none"
                fi
            fi

            _respond_result "$id" "$(_text_content "$(printf '%b' "$result")")"
            ;;

        *)
            _respond_error "$id" -32601 "Unknown tool: $tool_name"
            ;;
    esac
}

# ── Main JSON-RPC Loop ────────────────────────────────────────

while IFS= read -r line; do
    [ -z "$line" ] && continue

    local_id=$(printf '%s' "$line" | $_JQ -r '.id // "null"' 2>/dev/null)
    local_method=$(printf '%s' "$line" | $_JQ -r '.method // empty' 2>/dev/null)

    [ -z "$local_method" ] && continue

    case "$local_method" in
        initialize)
            _respond_result "$local_id" '{
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "george-git",
                    "version": "1.0"
                }
            }'
            ;;

        tools/list)
            _respond_result "$local_id" "{\"tools\":$_TOOLS_JSON}"
            ;;

        tools/call)
            tool_name=$(printf '%s' "$line" | $_JQ -r '.params.name // empty' 2>/dev/null)
            tool_args=$(printf '%s' "$line" | $_JQ -r '.params.arguments // {}' 2>/dev/null)
            _handle_tool_call "$local_id" "$tool_name" "$tool_args"
            ;;

        notifications/*)
            ;;

        *)
            _respond_error "$local_id" -32601 "Method not found: $local_method"
            ;;
    esac
done
