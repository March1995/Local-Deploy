#!/usr/bin/env bash
# ==============================
# Local-Deploy - Docker Build & Deploy Module
# ==============================

# Resolve Docker CLI command path
# Uses docker_cli config value, defaults to "docker"
DOCKER_CMD="${docker_cli:-docker}"

# Setup Docker remote connection and resolve CLI path
setup_docker_host() {
    local host="${docker_host}"

    # Resolve Docker CLI path from config
    DOCKER_CMD="${docker_cli:-docker}"

    if [ -z "$host" ]; then
        log_error "Docker host is not configured. Set 'docker.host' in local-deploy.yml"
        return 1
    fi

    export DOCKER_HOST="$host"
    log_info "Docker CLI: ${DOCKER_CMD}"
    log_info "DOCKER_HOST set to: ${DOCKER_HOST}"
    return 0
}

# Check Docker CLI and remote daemon connectivity
check_docker_connection() {
    # Check Docker CLI availability (command name on PATH or absolute path)
    if ! command -v "$DOCKER_CMD" &>/dev/null && [ ! -x "$DOCKER_CMD" ]; then
        log_error "Docker CLI is not available at: ${DOCKER_CMD}"
        log_error "Set 'docker.cli' in local-deploy.yml to the correct path."
        return 1
    fi

    # Check remote daemon connectivity
    log_info "Checking remote Docker daemon connectivity..."
    if "$DOCKER_CMD" info &>/dev/null; then
        log_success "Remote Docker daemon is reachable."
        return 0
    else
        log_error "Cannot connect to remote Docker daemon at: ${DOCKER_HOST}"
        log_error "Please ensure the Docker daemon is running and accessible."
        return 1
    fi
}

# Build Docker image on remote daemon
# Arguments: $1 = project root directory (where Dockerfile and target/ are)
build_docker_image() {
    local project_dir="${1:-.}"
    local profile="${maven_profile}"
    local image_tag="${docker_image_tag:-latest}"

    # Get artifactId from pom.xml
    local artifact_id
    artifact_id=$(get_artifact_id "${project_dir}/pom.xml")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Generate image name
    local image_name="${artifact_id}-${profile}"
    local full_image="${image_name}:${image_tag}"

    # Check Dockerfile exists
    local dockerfile="${project_dir}/${profile}.dockerfile"
    if [ ! -f "$dockerfile" ]; then
        log_error "Dockerfile not found: ${dockerfile}"
        log_error "Expected file: ${profile}.dockerfile in project root"
        return 1
    fi

    log_step "Building Docker image: ${full_image}"
    log_info "Using Dockerfile: ${profile}.dockerfile"
    log_separator

    "$DOCKER_CMD" build -f "$dockerfile" -t "$full_image" "$project_dir"
    local exit_code=$?

    log_separator

    if [ $exit_code -eq 0 ]; then
        log_success "Docker image built successfully: ${full_image}"
    else
        log_error "Docker image build failed with exit code: ${exit_code}"
    fi

    return $exit_code
}

# Deploy container on remote daemon
# Arguments: $1 = project root directory
deploy_docker_container() {
    local project_dir="${1:-.}"
    local profile="${maven_profile}"
    local image_tag="${docker_image_tag:-latest}"

    # Get artifactId from pom.xml
    local artifact_id
    artifact_id=$(get_artifact_id "${project_dir}/pom.xml")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Generate names
    local container_name="${artifact_id}-${profile}"
    local full_image="${container_name}:${image_tag}"

    log_step "Deploying container: ${container_name}"

    # Stop and remove existing container
    if "$DOCKER_CMD" ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_info "Stopping existing container: ${container_name}"
        "$DOCKER_CMD" stop "$container_name" 2>/dev/null
        log_info "Removing existing container: ${container_name}"
        "$DOCKER_CMD" rm "$container_name" 2>/dev/null
    fi

    # Build docker run command
    local run_cmd="\"${DOCKER_CMD}\" run -d --name ${container_name}"

    # Port mappings
    if [ -n "${docker_ports}" ]; then
        IFS=',' read -ra PORT_ARRAY <<< "${docker_ports}"
        for port in "${PORT_ARRAY[@]}"; do
            port=$(echo "$port" | xargs) # trim whitespace
            run_cmd="${run_cmd} -p ${port}"
        done
    fi

    # JVM options as JAVA_OPTS environment variable
    if [ -n "${docker_jvm_opts}" ]; then
        run_cmd="${run_cmd} -e \"JAVA_OPTS=${docker_jvm_opts}\""
    fi

    # Environment variables
    if [ -n "${docker_env}" ]; then
        IFS=',' read -ra ENV_ARRAY <<< "${docker_env}"
        for env_var in "${ENV_ARRAY[@]}"; do
            env_var=$(echo "$env_var" | xargs) # trim whitespace
            run_cmd="${run_cmd} -e ${env_var}"
        done
    fi

    # Volume mounts
    if [ -n "${docker_volumes}" ]; then
        IFS=',' read -ra VOL_ARRAY <<< "${docker_volumes}"
        for vol in "${VOL_ARRAY[@]}"; do
            vol=$(echo "$vol" | xargs) # trim whitespace
            run_cmd="${run_cmd} -v ${vol}"
        done
    fi

    # Network
    if [ -n "${docker_network}" ]; then
        run_cmd="${run_cmd} --network ${docker_network}"
    fi

    # Extra arguments
    if [ -n "${docker_extra_args}" ]; then
        run_cmd="${run_cmd} ${docker_extra_args}"
    fi

    # Image
    run_cmd="${run_cmd} ${full_image}"

    log_info "Executing: ${run_cmd}"
    log_separator

    eval "$run_cmd"
    local exit_code=$?

    log_separator

    if [ $exit_code -eq 0 ]; then
        log_success "Container deployed successfully: ${container_name}"
        log_info "Image: ${full_image}"
    else
        log_error "Container deployment failed with exit code: ${exit_code}"
    fi

    return $exit_code
}

# Full Docker workflow: setup host -> check connection -> build image -> deploy container
run_docker_deploy() {
    local project_dir="${1:-.}"

    setup_docker_host || return 1
    check_docker_connection || return 1
    build_docker_image "$project_dir" || return 1
    deploy_docker_container "$project_dir" || return 1

    return 0
}

# ==============================
# Container Management Operations
# ==============================

# Derive container name from config: {artifactId}-{profile}
get_container_name() {
    local project_dir="${1:-.}"
    local profile="${maven_profile}"

    local artifact_id
    artifact_id=$(get_artifact_id "${project_dir}/pom.xml")
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "${artifact_id}-${profile}"
}

# Stop a running container
docker_container_stop() {
    local container_name="$1"

    log_step "Stopping container: ${container_name}"
    "$DOCKER_CMD" stop "$container_name"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "Container stopped: ${container_name}"
    else
        log_error "Failed to stop container: ${container_name}"
    fi
    return $exit_code
}

# Start a stopped container
docker_container_start() {
    local container_name="$1"

    log_step "Starting container: ${container_name}"
    "$DOCKER_CMD" start "$container_name"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "Container started: ${container_name}"
    else
        log_error "Failed to start container: ${container_name}"
    fi
    return $exit_code
}

# Restart a container
docker_container_restart() {
    local container_name="$1"

    log_step "Restarting container: ${container_name}"
    "$DOCKER_CMD" restart "$container_name"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "Container restarted: ${container_name}"
    else
        log_error "Failed to restart container: ${container_name}"
    fi
    return $exit_code
}

# Remove a container
docker_container_rm() {
    local container_name="$1"

    log_step "Removing container: ${container_name}"
    "$DOCKER_CMD" rm "$container_name"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "Container removed: ${container_name}"
    else
        log_error "Failed to remove container: ${container_name}"
    fi
    return $exit_code
}

# View container logs
# Arguments: $1 = container_name, $2 = follow flag ("true" or "false")
docker_container_logs() {
    local container_name="$1"
    local follow="${2:-false}"

    if [ "$follow" = "true" ]; then
        log_info "Streaming logs for container: ${container_name} (Ctrl+C to stop)"
        "$DOCKER_CMD" logs -f "$container_name"
    else
        log_info "Logs for container: ${container_name}"
        "$DOCKER_CMD" logs "$container_name"
    fi
    return $?
}

# Show container status
docker_container_status() {
    local container_name="$1"

    log_info "Status for container: ${container_name}"
    echo ""
    "$DOCKER_CMD" ps -a --filter "name=^${container_name}$" --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}"
    return $?
}
