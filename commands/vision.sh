#!/bin/bash
# DESC: Analyze images using AI vision
# Usage: /vision <image_path_or_url> [prompt]
#   image: local file path, URL, or camera capture
#   prompt: what to analyze (default: describe the image)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

cmd_vision() {
    local args="$1"
    local workdir="${2:-.}"

    if [ -z "$args" ]; then
        ui_err "Usage: /vision <image_path_or_url> [prompt]"
        ui_dim "Examples:"
        ui_dim "  /vision photo.jpg"
        ui_dim "  /vision photo.jpg What text is in this image?"
        ui_dim "  /vision https://example.com/chart.png Analyze this chart"
        ui_dim "  /vision screenshot.png Summarize this error message"
        ui_dim ""
        ui_dim "Supports: jpg, png, gif, webp, bmp"
        ui_dim "From URL: automatically downloads the image first"
        return 1
    fi

    # Parse: first token is image path/URL, rest is prompt
    local image prompt
    image=$(echo "$args" | awk '{print $1}')
    prompt=$(echo "$args" | sed 's/^[^ ]* *//')
    [ "$prompt" = "$image" ] && prompt=""

    # Check for reverse search subcommand
    if [ "$image" = "reverse" ] || [ "$image" = "search" ]; then
        local target_img hint
        target_img=$(echo "$prompt" | awk '{print $1}')
        hint=$(echo "$prompt" | sed 's/^[^ ]* *//')
        [ "$hint" = "$target_img" ] && hint=""
        if [ -z "$target_img" ]; then
            ui_err "Usage: /vision reverse <image_path_or_url> [hint]"
            return 1
        fi
        if [[ "$target_img" != http* ]] && [[ "$target_img" != /* ]]; then
            target_img="$workdir/$target_img"
        fi
        if [[ "$target_img" != http* ]] && [ ! -f "$target_img" ]; then
            ui_err "Image not found: $target_img"
            return 1
        fi
        ui_step "Executing Sovereign Reverse Visual Search on: $target_img"
        local py_bin="python3"
        [ -x "$LODGE_DIR/.venv/bin/python" ] && py_bin="$LODGE_DIR/.venv/bin/python"
        local cmd=("$py_bin" "$LODGE_DIR/lib/tools/reverse_image_search.py" "$target_img" --format markdown)
        [ -n "$hint" ] && cmd+=(--hint "$hint")
        "${cmd[@]}"
        return $?
    fi

    # Default prompt
    [ -z "$prompt" ] && prompt="Describe this image in detail. Note any text, objects, people, and relevant details."


    # Check if vision support is available via dynamic endpoint discovery
    if [ -f "$LODGE_DIR/lib/core/endpoints.sh" ]; then
        source "$LODGE_DIR/lib/core/endpoints.sh" 2>/dev/null || true
    fi
    if declare -f endpoints_find_vision_endpoint &>/dev/null; then
        local _v_url
        _v_url=$(endpoints_find_vision_endpoint 2>/dev/null || true)
        if [ -z "$_v_url" ]; then
            ui_err "No active endpoint has an offloaded Vision Tower."
            ui_dim "  Ensure Tier 1 (GPU 0) is running with an offloaded multimodal projector."
            return 1
        fi
    fi

    # Resolve relative path
    if [[ "$image" != http* ]] && [[ "$image" != /* ]]; then
        image="$workdir/$image"
    fi

    # Validate file exists (for local files)
    if [[ "$image" != http* ]] && [ ! -f "$image" ]; then
        ui_err "Image not found: $image"
        return 1
    fi

    # Show what we're analyzing
    local display_name
    if [[ "$image" == http* ]]; then
        display_name="$image"
    else
        display_name=$(basename "$image")
        local file_size
        file_size=$(wc -c < "$image" 2>/dev/null | tr -d ' ')
        if [ -n "$file_size" ]; then
            local size_kb=$(( file_size / 1024 ))
            display_name="$display_name (${size_kb}KB)"
        fi
    fi
    ui_info "Analyzing: $display_name"

    # Source llm.sh if not already loaded
    if ! declare -f llm_vision &>/dev/null; then
        source "$LODGE_DIR/lib/core/llm.sh"
    fi

    local LLM_SCENARIO=vision
    llm_vision "$image" "$prompt"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_vision "$*"
fi

