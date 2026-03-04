#!/usr/bin/env bash
# ==============================
# Local-Deploy - YAML Configuration Parser
# ==============================

# Parse a two-level YAML file into shell variables with format: section_key=value
# Usage: parse_yaml <yaml_file>
# Output: Sets global variables like maven_profile, docker_host, etc.
parse_yaml() {
    local yaml_file="$1"

    if [ ! -f "$yaml_file" ]; then
        log_error "Configuration file not found: $yaml_file"
        return 1
    fi

    log_info "Parsing configuration: $yaml_file"

    # Parse YAML using awk - handles two-level nesting
    eval "$(awk '
    /^[[:space:]]*#/ { next }           # Skip comment lines
    /^[[:space:]]*$/ { next }           # Skip empty lines

    # Top-level key (no leading whitespace, ends with colon)
    /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:/ {
        # Extract section name
        section = $0
        sub(/:.*/, "", section)
        gsub(/[[:space:]]/, "", section)

        # Check if this line also has a value (single-level)
        value = $0
        sub(/^[^:]*:[[:space:]]*/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value != "") {
            # Single level key: value
            printf "%s=\"%s\"\n", section, value
        }
        next
    }

    # Second-level key (has leading whitespace)
    /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:/ {
        key = $0
        # Remove leading whitespace
        gsub(/^[[:space:]]+/, "", key)
        # Extract key name
        sub(/:.*/, "", key)
        gsub(/[[:space:]]/, "", key)

        # Extract value
        value = $0
        sub(/^[^:]*:[[:space:]]*/, "", value)
        # Trim whitespace
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        # Remove inline comments
        # Handle value that is entirely a comment (starts with #)
        if (match(value, /^#/)) {
            value = ""
        }
        # Strip trailing comments that have a space before #
        else if (match(value, /[[:space:]]+#/)) {
            value = substr(value, 1, RSTART - 1)
            gsub(/[[:space:]]+$/, "", value)
        }

        if (section != "" && key != "") {
            printf "%s_%s=\"%s\"\n", section, key, value
        }
        next
    }
    ' "$yaml_file")"

    return 0
}

# Get a config value by section and key
# Usage: get_config "maven" "profile"
get_config() {
    local section="$1"
    local key="$2"
    local var_name="${section}_${key}"
    echo "${!var_name}"
}

# Load configuration with defaults
load_config() {
    local config_file="${1:-local-deploy.yml}"

    # Set defaults
    auto_deploy="true"
    maven_profile=""
    maven_goals="clean package"
    maven_options=""
    docker_cli="docker"
    docker_host=""
    docker_image_tag="latest"
    docker_jvm_opts=""
    docker_ports=""
    docker_env=""
    docker_volumes=""
    docker_network=""
    docker_extra_args=""

    # Parse the YAML file (overrides defaults)
    parse_yaml "$config_file"
}
