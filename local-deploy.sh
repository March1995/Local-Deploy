#!/usr/bin/env bash
# ==============================
# Local-Deploy - Main Entry Script
# A lightweight local CI/CD tool based on Git Hooks
# ==============================

set -euo pipefail

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library modules
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/maven.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

# Version
VERSION="1.1.1"

# Print usage information
usage() {
    echo "Local-Deploy v${VERSION} - Lightweight local CI/CD tool"
    echo ""
    echo "Usage: local-deploy <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init [--force]      Initialize: generate config template + install Git Hook"
    echo "  deploy              Trigger build & deploy pipeline"
    echo "  container <action>  Manage deployed Docker containers"
    echo "  log [--follow]      View the latest deployment log"
    echo ""
    echo "Deploy Options:"
    echo "  --profile <name>    Override Maven profile from config file"
    echo "  --skip-maven        Skip Maven build (Docker build & deploy only)"
    echo "  --skip-docker       Skip Docker build & deploy (Maven build only)"
    echo "  --hook              Mark as triggered by Git hook (respects auto_deploy config)"
    echo ""
    echo "Container Actions:"
    echo "  stop                Stop the running container"
    echo "  start               Start a stopped container"
    echo "  restart             Restart the container"
    echo "  rm                  Remove the container"
    echo "  logs [--follow]     View container logs (--follow for live streaming)"
    echo "  status              Show container status"
    echo ""
    echo "General Options:"
    echo "  --help, -h          Show this help message"
    echo "  --version, -v       Show version"
    echo ""
    echo "Examples:"
    echo "  local-deploy init"
    echo "  local-deploy init --force"
    echo "  local-deploy deploy"
    echo "  local-deploy deploy --profile prod"
    echo "  local-deploy deploy --skip-docker"
    echo "  local-deploy deploy --skip-maven"
    echo "  local-deploy container status"
    echo "  local-deploy container logs --follow"
    echo "  local-deploy log"
    echo "  local-deploy log --follow"
}

# Init command: generate config template + install Git Hook
cmd_init() {
    local force=false

    # Parse init options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                echo "Usage: local-deploy init [--force]"
                return 1
                ;;
        esac
    done

    echo ""
    log_separator
    echo "  Local-Deploy - Project Initialization"
    log_separator
    echo ""

    # Check if we're in a git repo
    check_git_repo || return 1

    # Generate config file
    local config_file="local-deploy.yml"
    if [ -f "$config_file" ] && [ "$force" = false ]; then
        log_warn "Configuration file already exists: ${config_file}"
        log_info "Skipping config generation. Use --force to overwrite."
    else
        cp "${SCRIPT_DIR}/templates/local-deploy.yml" "$config_file"
        log_success "Generated configuration file: ${config_file}"
        log_info "Please edit ${config_file} to match your project settings."
    fi

    echo ""

    # Install pre-push hook
    local hook_dir=".git/hooks"
    local hook_file="${hook_dir}/pre-push"

    if [ ! -d "$hook_dir" ]; then
        mkdir -p "$hook_dir"
    fi

    if [ -f "$hook_file" ] && [ "$force" = false ]; then
        log_warn "pre-push hook already exists: ${hook_file}"
        log_info "Skipping hook installation. Use --force to overwrite."
    else
        cp "${SCRIPT_DIR}/templates/pre-push" "$hook_file"
        # Replace placeholder with actual Local-Deploy installation path
        sed -i '' "s|__LOCAL_DEPLOY_HOME__|${SCRIPT_DIR}|g" "$hook_file"
        chmod +x "$hook_file"
        log_success "Installed pre-push hook: ${hook_file}"
    fi

    echo ""

    # Load config if it exists (for environment check to pick up custom paths)
    local config_file="local-deploy.yml"
    if [ -f "$config_file" ]; then
        load_config "$config_file"
    fi

    # Check environment
    check_environment

    echo ""
    log_separator
    echo "  Initialization complete!"
    log_separator
    echo ""
}

# Deploy command: run full build & deploy pipeline
cmd_deploy() {
    local profile_override=""
    local from_hook=false
    local skip_maven=false
    local skip_docker=false

    # Parse deploy options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                profile_override="$2"
                shift 2
                ;;
            --hook)
                from_hook=true
                shift
                ;;
            --skip-maven)
                skip_maven=true
                shift
                ;;
            --skip-docker)
                skip_docker=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                return 1
                ;;
        esac
    done

    echo ""
    log_separator
    echo "  Local-Deploy - Build & Deploy Pipeline"
    log_separator
    echo ""

    # Check prerequisites
    check_pom_xml || return 1

    # Load configuration
    local config_file="local-deploy.yml"
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: ${config_file}"
        log_error "Run 'local-deploy init' first to generate the config file."
        return 1
    fi

    load_config "$config_file"

    # Check auto_deploy when triggered from hook
    if [ "$from_hook" = true ] && [ "${auto_deploy}" = "false" ]; then
        log_info "Auto-deploy is disabled (auto_deploy: false). Skipping deployment."
        return 0
    fi

    # Apply profile override if specified
    if [ -n "$profile_override" ]; then
        maven_profile="$profile_override"
        log_info "Profile overridden to: ${maven_profile}"
    fi

    # Validate required config
    if [ -z "${maven_profile}" ]; then
        log_error "Maven profile is not configured. Set 'maven.profile' in local-deploy.yml"
        return 1
    fi

    log_info "Profile: ${maven_profile}"
    log_info "Maven Goals: ${maven_goals}"
    echo ""

    # Step 1: Maven Build
    if [ "$skip_maven" = false ]; then
        run_maven_build
        if [ $? -ne 0 ]; then
            log_error "Pipeline aborted: Maven build failed."
            return 1
        fi
        echo ""
    else
        log_info "Skipping Maven build (--skip-maven)"
        echo ""
    fi

    # Step 2: Docker Build & Deploy
    if [ "$skip_docker" = false ]; then
        run_docker_deploy "$(pwd)"
        if [ $? -ne 0 ]; then
            log_error "Pipeline aborted: Docker deploy failed."
            return 1
        fi
    else
        log_info "Skipping Docker deploy (--skip-docker)"
    fi

    echo ""
    log_separator
    echo "  Pipeline completed successfully!"
    log_separator
    echo ""
}

# Container command: manage deployed Docker containers
cmd_container() {
    local action="${1:-}"

    if [ -z "$action" ]; then
        log_error "No container action specified."
        echo ""
        echo "Usage: local-deploy container <action>"
        echo "Actions: stop, start, restart, rm, logs [--follow], status"
        return 1
    fi
    shift

    # Check prerequisites
    check_pom_xml || return 1

    # Load configuration
    local config_file="local-deploy.yml"
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: ${config_file}"
        log_error "Run 'local-deploy init' first to generate the config file."
        return 1
    fi

    load_config "$config_file"

    # Validate required config
    if [ -z "${maven_profile}" ]; then
        log_error "Maven profile is not configured. Set 'maven.profile' in local-deploy.yml"
        return 1
    fi

    # Setup Docker host
    setup_docker_host || return 1

    # Derive container name
    local container_name
    container_name=$(get_container_name "$(pwd)")
    if [ $? -ne 0 ]; then
        log_error "Could not determine container name."
        return 1
    fi

    log_info "Container: ${container_name}"
    echo ""

    case "$action" in
        stop)
            docker_container_stop "$container_name"
            ;;
        start)
            docker_container_start "$container_name"
            ;;
        restart)
            docker_container_restart "$container_name"
            ;;
        rm)
            docker_container_rm "$container_name"
            ;;
        logs)
            local follow=false
            if [ "${1:-}" = "--follow" ] || [ "${1:-}" = "-f" ]; then
                follow=true
            fi
            docker_container_logs "$container_name" "$follow"
            ;;
        status)
            docker_container_status "$container_name"
            ;;
        *)
            log_error "Unknown container action: ${action}"
            echo ""
            echo "Available actions: stop, start, restart, rm, logs [--follow], status"
            return 1
            ;;
    esac
}

# Log command: view the latest deployment log
cmd_log() {
    local follow=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --follow|-f)
                follow=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                echo "Usage: local-deploy log [--follow]"
                return 1
                ;;
        esac
    done

    local log_file="local-deploy.log"

    if [ ! -f "$log_file" ]; then
        log_error "Deployment log not found: ${log_file}"
        log_info "Log file is created automatically when deploy runs via git push hook."
        return 1
    fi

    if [ "$follow" = true ]; then
        log_info "Streaming deployment log (Ctrl+C to stop): ${log_file}"
        echo ""
        tail -f "$log_file"
    else
        log_info "Deployment log: ${log_file}"
        echo ""
        cat "$log_file"
    fi
}

# Main entry point
main() {
    local command="${1:-}"

    case "$command" in
        init)
            shift
            cmd_init "$@"
            ;;
        deploy)
            shift
            cmd_deploy "$@"
            ;;
        container)
            shift
            cmd_container "$@"
            ;;
        log)
            shift
            cmd_log "$@"
            ;;
        --skip-maven|--skip-docker|--hook|--profile)
            # Allow deploy flags as top-level shortcuts
            cmd_deploy "$@"
            ;;
        --help|-h)
            usage
            ;;
        --version|-v)
            echo "Local-Deploy v${VERSION}"
            ;;
        "")
            usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
