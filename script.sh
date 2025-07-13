#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"
}

success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1" >> "$LOG_FILE"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"
}

warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >> "$LOG_FILE"
}

# Enhanced environment detection
is_docker_container() {
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    return 1
}

is_wsl() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        return 0
    fi
    return 1
}

has_nvidia_gpu() {
    # Check multiple ways to detect NVIDIA GPU
    if lspci 2>/dev/null | grep -i nvidia &> /dev/null; then
        return 0
    fi
    
    if [[ -d /proc/driver/nvidia ]]; then
        return 0
    fi
    
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        return 0
    fi
    
    return 1
}

get_environment_type() {
    if is_docker_container; then
        if has_nvidia_gpu; then
            echo "docker_with_gpu"
        else
            echo "docker_without_gpu"
        fi
    elif is_wsl; then
        echo "wsl"
    else
        echo "bare_metal"
    fi
}

is_package_installed() {
    dpkg -s "$1" &> /dev/null
}

get_nvidia_driver_version() {
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "unknown"
    else
        echo ""
    fi
}

get_cuda_version() {
    if command -v nvcc &> /dev/null; then
        nvcc --version 2>/dev/null | grep "release" | awk '{print $5}' | cut -d',' -f1 || echo "unknown"
    else
        echo ""
    fi
}

get_cuda_runtime_version() {
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=cuda_version --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "unknown"
    else
        echo ""
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID,,}" != "ubuntu" ]]; then
            error "Unsupported operating system: $NAME. This script is intended for Ubuntu."
            exit 1
        elif [[ "${VERSION_ID,,}" != "22.04" && "${VERSION_ID,,}" != "20.04" && "${VERSION_ID,,}" != "24.04" ]]; then
            error "Unsupported operating system version: $VERSION. This script supports Ubuntu 20.04, 22.04, and 24.04."
            exit 1
        else
            info "Operating System: $PRETTY_NAME"
            export UBUNTU_VERSION="${VERSION_ID}"
            export UBUNTU_CODENAME="${VERSION_CODENAME}"
        fi
    else
        error "/etc/os-release not found. Unable to determine the operating system."
        exit 1
    fi
}

detect_and_report_environment() {
    local env_type=$(get_environment_type)
    
    info "Environment Detection Results:"
    info "=============================="
    
    case "$env_type" in
        "docker_with_gpu")
            success "Running in Docker container WITH GPU access"
            info "NVIDIA GPU detected and accessible"
            export ENV_TYPE="docker_with_gpu"
            ;;
        "docker_without_gpu")
            warning "Running in Docker container WITHOUT GPU access"
            info "Container may need to be started with --gpus all flag"
            export ENV_TYPE="docker_without_gpu"
            ;;
        "wsl")
            info "Running in WSL environment"
            export ENV_TYPE="wsl"
            ;;
        "bare_metal")
            info "Running on bare metal system"
            if has_nvidia_gpu; then
                success "NVIDIA GPU detected"
            else
                warning "No NVIDIA GPU detected"
            fi
            export ENV_TYPE="bare_metal"
            ;;
    esac
    
    info "=============================="
}

update_system() {
    info "Updating and upgrading the system packages..."
    apt update -y 2>&1 | tee -a "$LOG_FILE"
    DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1 | tee -a "$LOG_FILE"
    success "System packages updated and upgraded successfully."
}

install_base_packages() {
    local packages=(
        build-essential
        libssl-dev
        pkg-config
        curl
        wget
        gnupg
        ca-certificates
        lsb-release
        jq
        apt-transport-https
        software-properties-common
        gnupg-agent
        dkms
        pciutils
        gcc
        g++
        make
        cmake
        git
        vim
        htop
        tree
        unzip
        libc6-dev
        libncurses5-dev
        libncursesw5-dev
        libreadline-dev
        libdb5.3-dev
        libgdbm-dev
        libsqlite3-dev
        libbz2-dev
        libexpat1-dev
        liblzma-dev
        libffi-dev
        uuid-dev
        zlib1g-dev
        python3-dev
        python3-pip
    )

    # Add kernel headers only for bare metal
    if [[ "$ENV_TYPE" == "bare_metal" ]]; then
        packages+=(linux-headers-$(uname -r))
    fi

    # Add GPU monitoring tools based on environment
    if [[ "$ENV_TYPE" == "bare_metal" ]] || [[ "$ENV_TYPE" == "docker_with_gpu" ]]; then
        packages+=(nvtop)
    fi
    
    # Add driver tools only for bare metal
    if [[ "$ENV_TYPE" == "bare_metal" ]]; then
        packages+=(ubuntu-drivers-common)
    fi

    info "Installing base packages: ${packages[*]}..."
    DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}" 2>&1 | tee -a "$LOG_FILE"
    success "Base packages installed successfully."
}

handle_driver_conflicts() {
    if [[ "$ENV_TYPE" != "bare_metal" ]]; then
        info "Skipping driver conflict resolution (not on bare metal)."
        return 0
    fi

    info "Checking for conflicting GPU drivers..."
    
    # Check for nouveau
    if lsmod | grep -q nouveau; then
        warning "Nouveau driver detected. Blacklisting..."
        echo 'blacklist nouveau' | tee /etc/modprobe.d/blacklist-nouveau.conf
        echo 'options nouveau modeset=0' | tee -a /etc/modprobe.d/blacklist-nouveau.conf
        update-initramfs -u
        export REBOOT_REQUIRED=true
        warning "Nouveau driver blacklisted. System reboot will be required."
    fi
    
    # Check for conflicting NVIDIA packages
    if dpkg -l | grep -E "^ii.*nvidia-.*-open" &> /dev/null; then
        warning "Open-source NVIDIA drivers detected. These may conflict with proprietary drivers."
        info "Consider removing with: apt remove nvidia-*-open"
    fi
    
    success "Driver conflict check completed."
}

install_gpu_drivers() {
    case "$ENV_TYPE" in
        "docker_with_gpu"|"docker_without_gpu")
            info "Running in Docker container. GPU drivers managed by host system."
            if [[ "$ENV_TYPE" == "docker_with_gpu" ]]; then
                local driver_version=$(get_nvidia_driver_version)
                success "Host GPU driver accessible (version: $driver_version)"
            else
                warning "No GPU access detected. Ensure container started with --gpus all"
            fi
            return 0
            ;;
        "wsl")
            info "Running in WSL. GPU drivers managed by Windows host."
            return 0
            ;;
        "bare_metal")
            # Continue with bare metal installation
            ;;
    esac

    if ! has_nvidia_gpu; then
        warning "No NVIDIA GPU detected. Skipping GPU driver installation."
        return 0
    fi

    info "Installing NVIDIA GPU drivers on bare metal system..."

    # Check if driver is already working
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        local driver_version=$(get_nvidia_driver_version)
        success "NVIDIA driver already functional (version: $driver_version)"
        return 0
    fi

    handle_driver_conflicts

    # Multiple installation strategies
    local strategies=(
        "ubuntu_drivers_autoinstall"
        "ubuntu_drivers_recommended"
        "manual_latest_driver"
        "manual_stable_driver"
    )

    for strategy in "${strategies[@]}"; do
        info "Trying installation strategy: $strategy"
        
        case "$strategy" in
            "ubuntu_drivers_autoinstall")
                if ubuntu-drivers autoinstall 2>&1 | tee -a "$LOG_FILE"; then
                    success "Driver installed via ubuntu-drivers autoinstall"
                    export REBOOT_REQUIRED=true
                    return 0
                fi
                ;;
            "ubuntu_drivers_recommended")
                local driver=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3}' | head -1)
                if [[ -n "$driver" ]] && apt-get install -y "$driver" 2>&1 | tee -a "$LOG_FILE"; then
                    success "Driver installed: $driver"
                    export REBOOT_REQUIRED=true
                    return 0
                fi
                ;;
            "manual_latest_driver")
                if apt-get install -y nvidia-driver-545 2>&1 | tee -a "$LOG_FILE"; then
                    success "Latest driver (545) installed"
                    export REBOOT_REQUIRED=true
                    return 0
                fi
                ;;
            "manual_stable_driver")
                if apt-get install -y nvidia-driver-535 2>&1 | tee -a "$LOG_FILE"; then
                    success "Stable driver (535) installed"
                    export REBOOT_REQUIRED=true
                    return 0
                fi
                ;;
        esac
        
        warning "Strategy $strategy failed, trying next..."
    done

    error "All GPU driver installation strategies failed."
    return 1
}

get_cuda_repo_identifier() {
    local ubuntu_version="$1"
    case "$ubuntu_version" in
        "20.04")
            echo "ubuntu2004"
            ;;
        "22.04")
            echo "ubuntu2204"
            ;;
        "24.04")
            echo "ubuntu2404"
            ;;
        *)
            echo "ubuntu2204"  # Safe fallback
            ;;
    esac
}

setup_cuda_environment() {
    info "Setting up CUDA environment variables..."
    
    # Multiple CUDA installation paths to check
    local cuda_paths=(
        "/usr/local/cuda"
        "/usr/local/cuda-12.3"
        "/usr/local/cuda-12.2"
        "/usr/local/cuda-12.1"
        "/usr/local/cuda-12.0"
        "/usr/local/cuda-11.8"
    )
    
    local cuda_home=""
    for path in "${cuda_paths[@]}"; do
        if [[ -d "$path" ]]; then
            cuda_home="$path"
            break
        fi
    done
    
    if [[ -z "$cuda_home" ]]; then
        cuda_home="/usr/local/cuda"
    fi
    
    info "Using CUDA_HOME: $cuda_home"
    
    # Set up environment for current session
    export CUDA_HOME="$cuda_home"
    export PATH="$cuda_home/bin:$PATH"
    export LD_LIBRARY_PATH="$cuda_home/lib64:${LD_LIBRARY_PATH:-}"
    export CUDA_ROOT="$cuda_home"
    
    # Create system-wide environment setup
    cat > /etc/profile.d/cuda.sh << EOF
#!/bin/bash
export CUDA_HOME="$cuda_home"
export PATH="$cuda_home/bin:\$PATH"
export LD_LIBRARY_PATH="$cuda_home/lib64:\${LD_LIBRARY_PATH:-}"
export CUDA_ROOT="$cuda_home"
EOF
    
    chmod +x /etc/profile.d/cuda.sh
    
    # Add to /etc/environment for system-wide access
    if ! grep -q "CUDA_HOME" /etc/environment; then
        echo "CUDA_HOME=\"$cuda_home\"" >> /etc/environment
    fi
    
    # Update current user's shell profiles
    local shell_profiles=(
        "$HOME/.bashrc"
        "$HOME/.profile"
        "$HOME/.zshrc"
    )
    
    for profile in "${shell_profiles[@]}"; do
        if [[ -f "$profile" ]]; then
            if ! grep -q "source /etc/profile.d/cuda.sh" "$profile"; then
                echo "source /etc/profile.d/cuda.sh" >> "$profile"
            fi
        fi
    done
    
    success "CUDA environment configured successfully."
}

install_cuda_toolkit() {
    if [[ "$ENV_TYPE" == "docker_with_gpu" ]]; then
        info "Docker container with GPU access detected."
        if command -v nvcc &> /dev/null; then
            local cuda_version=$(get_cuda_version)
            success "CUDA toolkit available (version: $cuda_version)"
        else
            warning "CUDA toolkit not available in container. Installing..."
            # Continue with installation
        fi
    elif [[ "$ENV_TYPE" == "docker_without_gpu" ]]; then
        warning "Docker container without GPU access. CUDA toolkit installation may not be useful."
        info "Consider restarting container with --gpus all flag."
        return 0
    fi

    # Check if CUDA is already installed and working
    if command -v nvcc &> /dev/null; then
        local cuda_version=$(get_cuda_version)
        if [[ "$cuda_version" != "unknown" ]]; then
            success "CUDA toolkit already installed (version: $cuda_version)"
            setup_cuda_environment
            return 0
        fi
    fi

    info "Installing CUDA Toolkit..."
    
    # Get repository identifier
    local repo_id=$(get_cuda_repo_identifier "$UBUNTU_VERSION")
    local arch=$(uname -m)
    
    # Multiple CUDA installation strategies
    local cuda_strategies=(
        "cuda_keyring_method"
        "manual_repo_method"
        "nvidia_repo_method"
    )
    
    for strategy in "${cuda_strategies[@]}"; do
        info "Trying CUDA installation strategy: $strategy"
        
        case "$strategy" in
            "cuda_keyring_method")
                # Modern keyring method
                local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/${arch}/cuda-keyring_1.1-1_all.deb"
                if wget -q "$keyring_url" -O cuda-keyring.deb 2>&1 | tee -a "$LOG_FILE"; then
                    dpkg -i cuda-keyring.deb 2>&1 | tee -a "$LOG_FILE"
                    rm -f cuda-keyring.deb
                    apt-get update 2>&1 | tee -a "$LOG_FILE"
                    
                    if apt-get install -y cuda-toolkit 2>&1 | tee -a "$LOG_FILE"; then
                        success "CUDA installed via keyring method"
                        setup_cuda_environment
                        return 0
                    fi
                fi
                ;;
            "manual_repo_method")
                # Manual repository setup
                wget -O - https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/${arch}/3bf863cc.pub | apt-key add - 2>&1 | tee -a "$LOG_FILE"
                echo "deb https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/${arch}/ /" | tee /etc/apt/sources.list.d/cuda.list
                apt-get update 2>&1 | tee -a "$LOG_FILE"
                
                if apt-get install -y cuda-toolkit 2>&1 | tee -a "$LOG_FILE"; then
                    success "CUDA installed via manual repository method"
                    setup_cuda_environment
                    return 0
                fi
                ;;
            "nvidia_repo_method")
                # Try installing specific CUDA version
                if apt-get install -y cuda-toolkit-12-3 2>&1 | tee -a "$LOG_FILE"; then
                    success "CUDA 12.3 installed via package manager"
                    setup_cuda_environment
                    return 0
                fi
                ;;
        esac
        
        warning "CUDA installation strategy $strategy failed, trying next..."
    done

    error "All CUDA installation strategies failed."
    return 1
}

install_rust() {
    if command -v rustc &> /dev/null; then
        local rust_version=$(rustc --version)
        info "Rust already installed: $rust_version"
    else
        info "Installing Rust programming language..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tee -a "$LOG_FILE"
        
        if [[ -f "$HOME/.cargo/env" ]]; then
            source "$HOME/.cargo/env"
            success "Rust installed successfully."
        else
            error "Rust installation failed."
            return 1
        fi
    fi
    
    # Configure Rust environment
    local shell_profiles=(
        "$HOME/.bashrc"
        "$HOME/.profile"
        "$HOME/.zshrc"
    )
    
    for profile in "${shell_profiles[@]}"; do
        if [[ -f "$profile" ]]; then
            if ! grep -q 'source $HOME/.cargo/env' "$profile"; then
                echo 'source $HOME/.cargo/env' >> "$profile"
            fi
        fi
    done
    
    export PATH="$HOME/.cargo/bin:$PATH"
    success "Rust environment configured."
}

install_just() {
    if command -v just &>/dev/null; then
        info "'just' already installed: $(just --version)"
        return 0
    fi

    info "Installing 'just' command runner..."
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
    | bash -s -- --to /usr/local/bin 2>&1 | tee -a "$LOG_FILE"
    success "'just' installed successfully."
}

install_docker() {
    if [[ "$ENV_TYPE" == "docker_with_gpu" ]] || [[ "$ENV_TYPE" == "docker_without_gpu" ]]; then
        info "Running inside Docker container."
        if [[ -S /var/run/docker.sock ]]; then
            success "Docker socket available from host."
        else
            warning "Docker socket not available. Docker-in-Docker not configured."
        fi
        return 0
    fi

    if command -v docker &> /dev/null; then
        info "Docker already installed: $(docker --version)"
    else
        info "Installing Docker..."
        
        # Remove old versions
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        
        # Install Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Add Docker repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          ${UBUNTU_CODENAME} stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update 2>&1 | tee -a "$LOG_FILE"
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tee -a "$LOG_FILE"
        
        systemctl enable docker 2>&1 | tee -a "$LOG_FILE"
        systemctl start docker 2>&1 | tee -a "$LOG_FILE"
        
        success "Docker installed successfully."
    fi
}

install_nvidia_container_toolkit() {
    if [[ "$ENV_TYPE" == "docker_with_gpu" ]] || [[ "$ENV_TYPE" == "docker_without_gpu" ]]; then
        info "Running inside Docker container. NVIDIA Container Toolkit managed by host."
        return 0
    fi

    if [[ "$ENV_TYPE" == "wsl" ]]; then
        info "Running in WSL. NVIDIA Container Toolkit should be installed on Windows host."
        return 0
    fi

    if ! has_nvidia_gpu; then
        warning "No NVIDIA GPU detected. Skipping NVIDIA Container Toolkit."
        return 0
    fi

    info "Installing NVIDIA Container Toolkit..."
    
    # Configure repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    apt-get update 2>&1 | tee -a "$LOG_FILE"
    apt-get install -y nvidia-container-toolkit 2>&1 | tee -a "$LOG_FILE"
    
    # Configure Docker runtime
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker 2>&1 | tee -a "$LOG_FILE"
    
    success "NVIDIA Container Toolkit installed successfully."
}

cleanup_system() {
    info "Performing system cleanup..."
    apt autoremove -y 2>&1 | tee -a "$LOG_FILE"
    apt autoclean -y 2>&1 | tee -a "$LOG_FILE"
    
    # Clean up downloaded files
    rm -f cuda-keyring.deb
    rm -f /tmp/cuda-*.deb
    
    success "System cleanup completed."
}

init_git_submodules() {
    if [[ -d .git ]]; then
        info "Initializing git submodules..."
        git submodule update --init --recursive 2>&1 | tee -a "$LOG_FILE"
        success "Git submodules initialized."
    else
        info "Not in a git repository. Skipping submodule initialization."
    fi
}

comprehensive_verification() {
    info "============================================="
    info "Comprehensive System Verification"
    info "============================================="
    
    # Environment verification
    info "Environment: $ENV_TYPE"
    
    # GPU verification
    if has_nvidia_gpu; then
        success "✓ NVIDIA GPU detected"
        if command -v nvidia-smi &> /dev/null; then
            local driver_version=$(get_nvidia_driver_version)
            if nvidia-smi &> /dev/null; then
                success "✓ NVIDIA driver functional (version: $driver_version)"
            else
                error "✗ NVIDIA driver not functional"
            fi
        else
            error "✗ nvidia-smi not available"
        fi
    else
        warning "! No NVIDIA GPU detected"
    fi
    
    # CUDA verification
    if command -v nvcc &> /dev/null; then
        local cuda_version=$(get_cuda_version)
        success "✓ NVCC available (CUDA version: $cuda_version)"
    else
        warning "! NVCC not available"
        info "  Try: source /etc/profile.d/cuda.sh"
    fi
    
    # Runtime verification
    if command -v nvidia-smi &> /dev/null; then
        local runtime_version=$(get_cuda_runtime_version)
        if [[ "$runtime_version" != "unknown" ]]; then
            success "✓ CUDA runtime available (version: $runtime_version)"
        fi
    fi
    
    # Rust verification
    if command -v rustc &> /dev/null && command -v cargo &> /dev/null; then
        success "✓ Rust toolchain available"
    else
        error "✗ Rust toolchain not available"
    fi
    
    # Docker verification
    if command -v docker &> /dev/null; then
        success "✓ Docker available"
        
        # Test Docker GPU access
        if [[ "$ENV_TYPE" == "bare_metal" ]] && has_nvidia_gpu; then
            info "Testing Docker GPU access..."
            if docker run --rm --gpus all nvidia/cuda:12.3-base-ubuntu22.04 nvidia-smi &> /dev/null; then
                success "✓ Docker GPU access working"
            else
                warning "! Docker GPU access not working"
                info "  May require system reboot if drivers were just installed"
            fi
        fi
    else
        warning "! Docker not available"
    fi
    
    info "============================================="
}

print_post_install_summary() {
    info "============================================="
    info "Installation Summary"
    info "============================================="
    
    echo "Environment Type: $ENV_TYPE"
    echo "Ubuntu Version: $UBUNTU_VERSION"
    
    if [[ "${REBOOT_REQUIRED:-false}" == "true" ]]; then
        warning "SYSTEM REBOOT REQUIRED!"
        warning "GPU drivers were installed and require a reboot to function properly."
    fi
    
    echo ""
    echo "Next Steps:"
    echo "==========="
    
    case "$ENV_TYPE" in
        "docker_with_gpu")
            echo "• Your container has GPU access"
            echo "• Test with: nvidia-smi"
            echo "• CUDA should be available if installed"
            ;;
        "docker_without_gpu")
            echo "• Restart container with: --gpus all"
            echo "• Or use: docker run --gpus all ..."
            ;;
        "bare_metal")
            if [[ "${REBOOT_REQUIRED:-false}" == "true" ]]; then
                echo "1. REBOOT YOUR SYSTEM"
                echo "2. After reboot, test with: nvidia-smi"
                echo "3. Test CUDA with: nvcc --version"
                echo "4. Test Docker GPU: docker run --rm --gpus all nvidia/cuda:12.3-base-ubuntu22.04 nvidia-smi"
            else
                echo "• Test GPU: nvidia-smi"
                echo "• Test CUDA: nvcc --version"
                echo "• Test Docker GPU: docker run --rm --gpus all nvidia/cuda:12.3-base-ubuntu22.04 nvidia-smi"
            fi
            ;;
        "wsl")
            echo "• Test GPU: nvidia-smi"
            echo "• CUDA should work if Windows drivers are installed"
            ;;
    esac
    
    echo ""
    echo "Environment Setup:"
    echo "=================="
    echo "• CUDA environment: source /etc/profile.d/cuda.sh"
    echo "• Rust environment: source ~/.cargo/env"
    echo "• All changes will be active in new terminal sessions"
    
    info "============================================="
}

# Main execution function
main() {
    info "===== Universal GPU/CUDA Setup Script Started at $(date) ====="
    
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # Detect environment first
    check_os
    detect_and_report_environment
    
    # Initialize git submodules if present
    init_git_submodules
    
    # Core system setup
    update_system
    install_base_packages
    
    # GPU/CUDA setup based on environment
    install_gpu_drivers
    install_cuda_toolkit
    
    # Development tools
    install_rust
    install_just
    
    # Container tools
    install_docker
    install_nvidia_container_toolkit
    
    # Cleanup
    cleanup_system
    
    # Comprehensive verification
    comprehensive_verification
    
    # Final summary
    print_post_install_summary
    
    success "Script execution completed successfully!"
    info "===== Script Execution Ended at $(date) ====="
}

# Execute main function
main "$@"

exit 0
