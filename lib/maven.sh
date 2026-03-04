#!/usr/bin/env bash
# ==============================
# Local-Deploy - Maven Build Module
# ==============================

# Execute Maven build
# Uses global config variables: maven_profile, maven_goals, maven_options
run_maven_build() {
    log_step "Starting Maven build..."

    # Check Maven availability
    if ! command -v mvn &>/dev/null; then
        log_error "Maven (mvn) is not available. Please install Maven first."
        return 1
    fi

    # Check pom.xml exists
    check_pom_xml || return 1

    # Build the Maven command
    local goals="${maven_goals:-clean package}"
    local profile="${maven_profile}"
    local options="${maven_options}"

    local mvn_cmd="mvn ${goals}"

    if [ -n "$profile" ]; then
        mvn_cmd="${mvn_cmd} -P${profile}"
    fi

    if [ -n "$options" ]; then
        mvn_cmd="${mvn_cmd} ${options}"
    fi

    log_info "Executing: ${mvn_cmd}"
    log_separator

    # Execute Maven build
    eval "$mvn_cmd"
    local exit_code=$?

    log_separator

    if [ $exit_code -eq 0 ]; then
        log_success "Maven build completed successfully."
    else
        log_error "Maven build failed with exit code: ${exit_code}"
    fi

    return $exit_code
}
