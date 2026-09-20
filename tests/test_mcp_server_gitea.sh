#!/bin/bash
# ── Tests: Sovereign Gitea MCP Server (lib/mcp_server_gitea.sh) ──────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/mcp_server_gitea.sh"

test_start "Sovereign Gitea MCP Server"

describe "gitea_status function"
    it "should return valid JSON status from online container" && {
        status_json=$(gitea_status)
        assert_ok $? "gitea_status should return exit code 0"
        online=$(echo "$status_json" | jq -r .online)
        assert_eq "$online" "true" "Gitea container must report online=true"
        url=$(echo "$status_json" | jq -r .url)
        assert_eq "$url" "http://127.0.0.1:3088" "Gitea URL must be port 3088"
        default_br=$(echo "$status_json" | jq -r .default_branch)
        assert_eq "$default_br" "develop" "Default branch must be develop"
    }

describe "mcp_server_gitea.sh stdio JSON-RPC"
    it "should handle initialize method" && {
        init_req='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
        resp=$(echo "$init_req" | bash "$LODGE_DIR/lib/mcp_server_gitea.sh")
        sname=$(echo "$resp" | jq -r .result.serverInfo.name)
        assert_eq "$sname" "george-gitea-mcp" "Server name must match"
    }

    it "should list gitea tools on tools/list" && {
        list_req='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        resp=$(echo "$list_req" | bash "$LODGE_DIR/lib/mcp_server_gitea.sh")
        has_status=$(echo "$resp" | jq -r '.result.tools[] | select(.name=="gitea_status") | .name')
        has_pr=$(echo "$resp" | jq -r '.result.tools[] | select(.name=="gitea_pr_create") | .name')
        assert_eq "$has_status" "gitea_status" "tools/list must include gitea_status"
        assert_eq "$has_pr" "gitea_pr_create" "tools/list must include gitea_pr_create"
    }

    it "should execute gitea_status on tools/call" && {
        call_req='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gitea_status","arguments":{}}}'
        resp=$(echo "$call_req" | bash "$LODGE_DIR/lib/mcp_server_gitea.sh")
        content=$(echo "$resp" | jq -r '.result.content[0].text')
        is_online=$(echo "$content" | jq -r .online)
        assert_eq "$is_online" "true" "gitea_status tool call must return online=true"
    }

describe "mcp_server_git.sh cross-registration"
    it "should include gitea tools in git MCP server tools/list" && {
        git_list_req='{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}'
        resp=$(echo "$git_list_req" | bash "$LODGE_DIR/lib/mcp_server_git.sh")
        has_gitea_status=$(echo "$resp" | jq -r '.result.tools[] | select(.name=="gitea_status") | .name')
        assert_eq "$has_gitea_status" "gitea_status" "Git MCP server must expose gitea_status"
    }

    it "should dispatch gitea_status via git MCP server tools/call" && {
        git_call_req='{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"gitea_status","arguments":{}}}'
        resp=$(echo "$git_call_req" | bash "$LODGE_DIR/lib/mcp_server_git.sh")
        content=$(echo "$resp" | jq -r '.result.content[0].text')
        is_online=$(echo "$content" | jq -r .online)
        assert_eq "$is_online" "true" "Git MCP server must return gitea status"
    }

test_end
