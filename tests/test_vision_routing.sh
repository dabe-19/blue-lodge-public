#!/bin/bash
# ── Test: Dynamic Vision Endpoint Probing & Routing ───────────────
source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/endpoints.sh"

test_start "Vision Endpoint Probing & Routing"

describe "endpoints_probe_vision"
    it "detects multimodal capability when capability list contains 'multimodal'" && {
        # Mock curl to return multimodal capabilities
        curl() {
            cat << 'EOF'
{
  "models": [
    {
      "name": "ternary-bonsai-27b",
      "capabilities": ["completion", "multimodal"]
    }
  ]
}
EOF
            return 0
        }
        _ENDPOINT_VISION_CACHE=()
        endpoints_probe_vision "http://mock-vision:8080"
        assert_ok "$?" "Should return 0 when multimodal capability is present"
    }

    it "rejects endpoint when capabilities only contain 'completion'" && {
        # Mock curl to return text-only capabilities
        curl() {
            cat << 'EOF'
{
  "models": [
    {
      "name": "ternary-bonsai-27b",
      "capabilities": ["completion"]
    }
  ]
}
EOF
            return 0
        }
        _ENDPOINT_VISION_CACHE=()
        endpoints_probe_vision "http://mock-text-only:18080"
        assert_fail "$?" "Should return 1 when multimodal capability is absent"
    }

    it "handles connection errors gracefully" && {
        curl() {
            return 7 # Connection refused
        }
        _ENDPOINT_VISION_CACHE=()
        endpoints_probe_vision "http://dead-host:8080"
        assert_fail "$?" "Should return 1 on connection failure"
    }

describe "endpoints_find_vision_endpoint"
    it "cascades from text-only active endpoint to vision-capable Tier 1" && {
        unset -f curl 2>/dev/null || true
        # Mock curl based on URL argument
        curl() {
            local url=""
            for arg in "$@"; do
                if [[ "$arg" == http* ]]; then
                    url="$arg"
                fi
            done

            if [[ "$url" == *"8080"* && "$url" != *"18080"* ]]; then
                # Tier 1 on 8080 has multimodal
                if [[ "$url" == *"/health"* ]]; then
                    echo '{"status": "ok"}'
                    return 0
                fi
                cat << 'EOF'
{
  "models": [
    {
      "name": "ternary-bonsai-27b",
      "capabilities": ["completion", "multimodal"]
    }
  ]
}
EOF
                return 0
            elif [[ "$url" == *"18080"* ]]; then
                # Tier 2 on 18080 is text-only
                if [[ "$url" == *"/health"* ]]; then
                    echo '{"status": "ok"}'
                    return 0
                fi
                cat << 'EOF'
{
  "models": [
    {
      "name": "ternary-bonsai-27b",
      "capabilities": ["completion"]
    }
  ]
}
EOF
                return 0
            fi
            return 1
        }

        _ENDPOINT_PROBE_CACHE=()
        _ENDPOINT_VISION_CACHE=()

        # Simulate currently active on Tier 2 (text-only)
        ACTIVE_TIER="2"
        ACTIVE_ENDPOINT_URL="http://127.0.0.1:18080"
        TIER1_ENABLED=1
        TIER1_URL="http://127.0.0.1:8080"
        TIER2_ENABLED=1
        TIER2_URL="http://127.0.0.1:18080"

        vision_url=$(endpoints_find_vision_endpoint)
        assert_eq "$vision_url" "http://127.0.0.1:8080" "Should resolve to Tier 1 URL"
    }

    it "fails cleanly when no endpoints possess vision capability" && {
        unset -f curl 2>/dev/null || true
        curl() {
            cat << 'EOF'
{
  "models": [
    {
      "name": "ternary-bonsai-27b",
      "capabilities": ["completion"]
    }
  ]
}
EOF
            return 0
        }

        _ENDPOINT_PROBE_CACHE=()
        _ENDPOINT_VISION_CACHE=()

        ACTIVE_TIER="1"
        ACTIVE_ENDPOINT_URL="http://127.0.0.1:8080"
        TIER1_ENABLED=1
        TIER1_URL="http://127.0.0.1:8080"
        TIER2_ENABLED=0

        vision_url=$(endpoints_find_vision_endpoint 2>/dev/null || echo "FAILED")
        assert_eq "$vision_url" "FAILED" "Should fail when no endpoint has multimodal"
    }

test_end
