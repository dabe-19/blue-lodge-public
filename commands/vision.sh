#!/bin/bash
# DESC: Analyze images using AI vision
# Usage: /vision <image_path_or_url> [prompt]
#   image: local file path, URL, or camera capture
#   prompt: what to analyze (default: describe the image)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

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

    # Default prompt
    [ -z "$prompt" ] && prompt="Describe this image in detail. Note any text, objects, people, and relevant details."

    # Check if vision support is available
    if declare -f models_has_vision &>/dev/null && ! models_has_vision; then
        ui_warn "Current model ($LODGE_MODEL) may not support vision."
        ui_dim "  Vision-tested models: minist-inst, llava, moondream, minicpm-v"
        ui_dim "  Switch with: /model minist-inst"
        ui_dim "  Trying anyway..."
        echo ""
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
        source "$LODGE_DIR/lib/llm.sh"
    fi

    local LLM_SCENARIO=vision
    llm_vision "$image" "$prompt"
}
