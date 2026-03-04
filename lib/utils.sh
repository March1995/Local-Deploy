#!/usr/bin/env bash
# ==============================
# Local-Deploy - Utility Functions
# ==============================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $*"
}

# Print a separator line
log_separator() {
    echo "============================================"
}

# Check if a command is available (supports both command names and absolute paths)
check_command() {
    local cmd="$1"
    local name="${2:-$cmd}"
    if command -v "$cmd" &>/dev/null || [ -x "$cmd" ]; then
        log_success "$name is available: $cmd"
        return 0
    else
        log_error "$name is NOT available: $cmd"
        return 1
    fi
}

# Check required environment: git, mvn, docker
check_environment() {
    local all_ok=true

    log_step "Checking environment..."
    echo ""

    check_command "git" "Git" || all_ok=false
    check_command "mvn" "Maven" || all_ok=false

    # Docker CLI: support custom path from config
    local docker_bin="${docker_cli:-docker}"
    check_command "$docker_bin" "Docker CLI" || all_ok=false

    echo ""
    if [ "$all_ok" = true ]; then
        log_success "All required tools are available."
    else
        log_warn "Some tools are missing. Please install them before using local-deploy."
    fi

    return 0
}

# Check if current directory is a git repository
check_git_repo() {
    if [ ! -d ".git" ]; then
        log_error "Not a Git repository. Please run this command from a Git project root."
        return 1
    fi
    return 0
}

# Check if pom.xml exists
check_pom_xml() {
    if [ ! -f "pom.xml" ]; then
        log_error "pom.xml not found. This tool only supports Maven projects."
        return 1
    fi
    return 0
}

# Parse artifactId from pom.xml
# Extracts the first <artifactId> that is a direct child of <project>, skipping parent's artifactId
get_artifact_id() {
    local pom_file="${1:-pom.xml}"
    if [ ! -f "$pom_file" ]; then
        log_error "pom.xml not found at: $pom_file"
        return 1
    fi

    # Use awk to extract the first artifactId that is NOT inside a <parent> block
    local artifact_id
    artifact_id=$(awk '
        /<parent>/    { in_parent=1 }
        /<\/parent>/  { in_parent=0; next }
        !in_parent && /<artifactId>/ {
            gsub(/.*<artifactId>/, "")
            gsub(/<\/artifactId>.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
        }
    ' "$pom_file")

    if [ -z "$artifact_id" ]; then
        log_error "Could not parse artifactId from pom.xml"
        return 1
    fi

    echo "$artifact_id"
}
