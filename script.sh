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
}

success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

is_docker_container() {
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    return 1
}

is_package_installed() {
    dpkg -s "$1" &> /dev/null
}

has_nvidia_gpu() {
    if lspci | grep -i nvidia &> /dev/null; then
        return 0
    fi
    return 1
}

get_nvidia_driver_version() {
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -1
    else
        echo ""
    fi
}

get_cuda_version() {
    if command -v nvcc &> /dev/null; then
        nvcc --version | grep "release" | awk '{print $5}' | cut -d',' -f1
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
        fi
    else
        error "/etc/os-release not found. Unable to determine the operating system."
        exit 1
    fi
}

update_system() {
    info "Updating and upgrading the system packages..."
    apt update -y 2>&1 | tee -a "$LOG_FILE"
    apt upgrade -y 2>&1 | tee -a "$LOG_FILE"
    success "System packages updated and upgraded successfully."
}

install_packages() {
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
        linux-headers-$(uname -r)
        pciutils
        gcc
        g++
        make
        libc6-dev
        libncurses5-dev
        libncursesw5-dev
        libreadline-dev
        libdb5.3-dev
        libgdbm-dev
        libsqlite3-dev
        libssl-dev
        libbz2-dev
        libexpat1-dev
        liblzma-dev
        libffi-dev
        uuid-dev
        zlib1g-dev
    )

    # Add nvtop only if not in container
    if ! is_docker_container; then
        packages+=(nvtop ubuntu-drivers-common)
    fi

    info "Installing essential packages: ${packages[*]}..."
    apt install -y "${packages[@]}" 2>&1 | tee -a "$LOG_FILE"
    success "Essential packages installed successfully."
}

remove_conflicting_drivers() {
    info "Checking for conflicting GPU drivers..."
    
    # Remove nouveau if present
    if lsmod | grep -q nouveau; then
        warning "Nouveau driver detected. Adding to blacklist..."
        echo 'blacklist nouveau' | tee /etc/modprobe.d/blacklist-nouveau.conf
        echo 'options nouveau modeset=0' | tee -a /etc/modprobe.d/blacklist-nouveau.conf
        update-initramfs -u
        warning "Nouveau driver blacklisted. System reboot will be required."
    fi
    
    # Remove any existing NVIDIA packages that might conflict
    local conflicting_packages=(
        "nvidia-*"
        "libnvidia-*"
        "cuda-*"
    )
    
    for package_pattern in "${conflicting_packages[@]}"; do
        if dpkg -l | grep -E "^ii.*$package_pattern" &> /dev/null; then
            warning "Found potentially conflicting packages matching $package_pattern"
            # Don't auto-remove, just warn
        fi
    done
}

install_gpu_drivers() {
    if is_docker_container; then
        warning "Running inside Docker container. Skipping GPU driver installation."
        warning "GPU drivers should be installed on the host system."
        return 0
    fi

    if ! has_nvidia_gpu; then
        warning "No NVIDIA GPU detected. Skipping GPU driver installation."
        return 0
    fi

    info "NVIDIA GPU detected. Checking driver status..."

    # Check if driver is already working
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        local driver_version=$(get_nvidia_driver_version)
        success "NVIDIA driver is already installed and functional (version: $driver_version)."
        return 0
    fi

    remove_conflicting_drivers

    info "Detecting recommended GPU driver..."
    local driver
    driver=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3}' | head -1)

    if [ -z "$driver" ]; then
        error "No recommended GPU driver found. Trying to install latest driver..."
        driver="nvidia-driver-535"  # Fallback to a stable version
    fi

    info "Installing GPU driver package: $driver"
    if apt-get install -y "$driver" 2>&1 | tee -a "$LOG_FILE"; then
        success "GPU driver ($driver) installed successfully."
        warning "System reboot is required for GPU drivers to take effect."
        export DRIVER_INSTALLED=true
    else
        error "Failed to install GPU driver ($driver). Trying alternative installation..."
        
        # Try alternative installation method
        info "Trying ubuntu-drivers autoinstall..."
        if ubuntu-drivers autoinstall 2>&1 | tee -a "$LOG_FILE"; then
            success "GPU driver installed via ubuntu-drivers autoinstall."
            export DRIVER_INSTALLED=true
        else
            error "Failed to install GPU driver via alternative method."
            return 1
        fi
    fi
}

install_rust() {
    if command -v rustc &> /dev/null; then
        local rust_version=$(rustc --version)
        info "Rust is already installed: $rust_version"
    else
        info "Installing Rust programming language..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tee -a "$LOG_FILE"
        
        if [[ -f "$HOME/.cargo/env" ]]; then
            source "$HOME/.cargo/env"
            success "Rust installed successfully."
        else
            error "Rust installation failed. ~/.cargo/env not found."
            exit 1
        fi
    fi
    
    info "Configuring Rust environment for all users and sessions..."
    
    if ! grep -q 'source $HOME/.cargo/env' ~/.bashrc 2>/dev/null; then
        echo 'source $HOME/.cargo/env' >> ~/.bashrc
    fi
    
    if ! grep -q 'source $HOME/.cargo/env' ~/.profile 2>/dev/null; then
        echo 'source $HOME/.cargo/env' >> ~/.profile
    fi
    
    export PATH="$HOME/.cargo/bin:$PATH"
    success "Rust environment configured for current and future sessions."
}

install_just() {
    if command -v just &>/dev/null; then
        info "'just' is already installed."
        return
    fi

    info "Installing the 'just' command-runner..."
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
    | bash -s -- --to /usr/local/bin 2>&1 | tee -a "$LOG_FILE"
    success "'just' installed successfully."
}

get_cuda_repo_pin() {
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
            echo "ubuntu2204"  # Default fallback
            ;;
    esac
}

install_cuda_toolkit() {
    if is_docker_container; then
        info "Running inside Docker container. Checking for CUDA runtime availability..."
        if command -v nvidia-smi &> /dev/null; then
            success "CUDA runtime is available via host GPU drivers."
            return 0
        else
            warning "CUDA runtime not available. Ensure container is run with --gpus all flag."
            return 0
        fi
    fi

    if ! has_nvidia_gpu; then
        warning "No NVIDIA GPU detected. Skipping CUDA installation."
        return 0
    fi

    # Check if CUDA is already installed and working
    if command -v nvcc &> /dev/null; then
        local cuda_version=$(get_cuda_version)
        success "CUDA is already installed (version: $cuda_version)."
        return 0
    fi

    info "Installing CUDA Toolkit..."
    
    # Get the correct repository identifier
    local repo_id=$(get_cuda_repo_pin "$UBUNTU_VERSION")
    local arch=$(uname -m)
    
    # Download and install CUDA keyring
    info "Setting up CUDA repository..."
    local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/${arch}/cuda-keyring_1.1-1_all.deb"
    
    if wget -q "$keyring_url" -O cuda-keyring.deb 2>&1 | tee -a "$LOG_FILE"; then
        dpkg -i cuda-keyring.deb 2>&1 | tee -a "$LOG_FILE"
        rm -f cuda-keyring.deb
    else
        error "Failed to download CUDA keyring. Trying alternative method..."
        
        # Alternative method using apt-key (deprecated but may work)
        wget -O - https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/${arch}/7fa2af80.pub | apt-key add - 2>&1 | tee -a "$LOG_FILE"
        echo "deb https://developer.download.nvidia.com/compute/cuda/repos/${repo_id}/${arch}/ /" | tee /etc/apt/sources.list.d/cuda.list
    fi
    
    # Update package list
    apt-get update 2>&1 | tee -a "$LOG_FILE"
    
    # Install CUDA toolkit
    info "Installing CUDA Toolkit packages..."
    local cuda_packages=(
        "cuda-toolkit"
        "cuda-drivers"
        "cuda-runtime-12-3"
        "cuda-demo-suite-12-3"
        "cuda-documentation-12-3"
    )
    
    for package in "${cuda_packages[@]}"; do
        if apt-get install -y "$package" 2>&1 | tee -a "$LOG_FILE"; then
            success "Installed $package successfully."
        else
            warning "Failed to install $package, continuing with other packages..."
        fi
    done
    
    # Set up CUDA environment variables
    info "Setting up CUDA environment variables..."
    
    # Add CUDA to PATH and LD_LIBRARY_PATH
    cat >> /etc/environment << 'EOF'
PATH="/usr/local/cuda/bin:$PATH"
LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
CUDA_HOME="/usr/local/cuda"
EOF
    
    # Add to current session
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
    export CUDA_HOME="/usr/local/cuda"
    
    # Add to shell profiles
    local cuda_profile_script='/etc/profile.d/cuda.sh'
    cat > "$cuda_profile_script" << 'EOF'
export PATH="/usr/local/cuda/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
export CUDA_HOME="/usr/local/cuda"
EOF
    
    chmod +x "$cuda_profile_script"
    
    success "CUDA Toolkit installed successfully."
}

install_docker() {
    if is_docker_container; then
        warning "Running inside Docker container. Docker-in-Docker setup detected."
        info "Checking if Docker socket is mounted from host..."
        if [[ -S /var/run/docker.sock ]]; then
            success "Docker socket is available from host. Using host Docker daemon."
            return 0
        fi
    fi

    if command -v docker &> /dev/null; then
        info "Docker is already installed."
        docker --version
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
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Update package index
        apt-get update 2>&1 | tee -a "$LOG_FILE"
        
        # Install Docker Engine
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tee -a "$LOG_FILE"
        
        if ! is_docker_container; then
            systemctl enable docker 2>&1 | tee -a "$LOG_FILE"
            systemctl start docker 2>&1 | tee -a "$LOG_FILE"
        fi
        
        success "Docker installed successfully."
    fi
}

install_nvidia_container_toolkit() {
    if is_docker_container; then
        warning "Running inside Docker container. NVIDIA Container Toolkit should be installed on host."
        info "Checking GPU availability in container..."
        if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
            success "GPU is accessible in container via host NVIDIA runtime."
        else
            warning "GPU not accessible. Ensure container is run with --gpus all flag."
        fi
        return 0
    fi

    if ! has_nvidia_gpu; then
        warning "No NVIDIA GPU detected. Skipping NVIDIA Container Toolkit installation."
        return 0
    fi

    info "Installing NVIDIA Container Toolkit..."
    
    # Configure the repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    # Update package index
    apt-get update 2>&1 | tee -a "$LOG_FILE"
    
    # Install NVIDIA Container Toolkit
    apt-get install -y nvidia-container-toolkit 2>&1 | tee -a "$LOG_FILE"
    
    # Configure Docker to use NVIDIA runtime
    nvidia-ctk runtime configure --runtime=docker
    
    # Restart Docker service
    if ! is_docker_container; then
        systemctl restart docker 2>&1 | tee -a "$LOG_FILE"
    fi
    
    success "NVIDIA Container Toolkit installed successfully."
}

cleanup() {
    info "Cleaning up unnecessary packages..."
    apt autoremove -y 2>&1 | tee -a "$LOG_FILE"
    apt autoclean -y 2>&1 | tee -a "$LOG_FILE"
    
    # Clean up downloaded files
    rm -f cuda-keyring.deb
    
    success "Cleanup completed."
}

init_git_submodules() {
    if [[ -d .git ]]; then
        info "Initializing git submodules..."
        git submodule update --init --recursive 2>&1 | tee -a "$LOG_FILE"
        success "Git submodules initialized successfully."
    else
        warning "Not in a git repository. Skipping submodule initialization."
    fi
}

verify_rust_installation() {
    info "Verifying Rust installation..."
    if command -v rustc &> /dev/null && command -v cargo &> /dev/null; then
        local rust_version=$(rustc --version)
        local cargo_version=$(cargo --version)
        success "Rust verification successful: $rust_version"
        success "Cargo verification successful: $cargo_version"
    else
        error "Rust verification failed. Commands not available in current session."
        info "Try running: source ~/.cargo/env"
        return 1
    fi
}

verify_cuda_installation() {
    info "Verifying CUDA installation..."
    
    if is_docker_container; then
        info "Running inside container - checking GPU access..."
        if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
            success "GPU is accessible in container."
        else
            warning "GPU not accessible in container."
        fi
        return 0
    fi
    
    if ! has_nvidia_gpu; then
        info "No NVIDIA GPU detected. Skipping CUDA verification."
        return 0
    fi
    
    # Check nvidia-smi
    if command -v nvidia-smi &> /dev/null; then
        if nvidia-smi &> /dev/null; then
            local driver_version=$(get_nvidia_driver_version)
            success "NVIDIA driver is working (version: $driver_version)."
        else
            error "NVIDIA driver is installed but not functioning properly."
            return 1
        fi
    else
        error "nvidia-smi not found. Driver installation may have failed."
        return 1
    fi
    
    # Check nvcc
    if command -v nvcc &> /dev/null; then
        local cuda_version=$(get_cuda_version)
        success "NVCC is working (CUDA version: $cuda_version)."
    else
        warning "NVCC not found. CUDA Toolkit may not be properly installed."
        info "Try running: source /etc/profile.d/cuda.sh"
    fi
}

verify_docker_nvidia() {
    info "Verifying Docker with NVIDIA support..."
    
    if is_docker_container; then
        info "Running inside container - checking direct GPU access..."
        if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
            success "GPU is accessible in container."
        else
            warning "GPU not accessible in container."
        fi
        return 0
    fi
    
    if ! has_nvidia_gpu; then
        info "No NVIDIA GPU detected. Skipping Docker NVIDIA verification."
        return 0
    fi
    
    # Test Docker with NVIDIA runtime
    info "Testing Docker with NVIDIA runtime..."
    if docker run --rm --gpus all nvidia/cuda:12.3-base-ubuntu22.04 nvidia-smi 2>&1 | tee -a "$LOG_FILE"; then
        success "Docker with NVIDIA support verified successfully."
    else
        warning "Docker NVIDIA test failed. This may be normal if drivers need a reboot."
        info "Try running the test after system reboot: docker run --rm --gpus all nvidia/cuda:12.3-base-ubuntu22.04 nvidia-smi"
    fi
}

print_post_install_info() {
    info "============================================="
    info "Post-Installation Information:"
    info "============================================="
    
    if [[ "${DRIVER_INSTALLED:-false}" == "true" ]]; then
        warning "IMPORTANT: System reboot is required for GPU drivers to take effect."
        info "After reboot, verify installation with: nvidia-smi"
    fi
    
    if command -v nvcc &> /dev/null; then
        info "CUDA Toolkit installed. Verify with: nvcc --version"
    fi
    
    if command -v docker &> /dev/null && has_nvidia_gpu; then
        info "Test Docker GPU access with: docker run --rm --gpus all nvidia/cuda:12.3-base-ubuntu22.04 nvidia-smi"
    fi
    
    info "Environment variables are set in /etc/profile.d/cuda.sh"
    info "For current session, run: source /etc/profile.d/cuda.sh"
    info "============================================="
}

# Main execution
main() {
    info "===== GPU/CUDA Setup Script Started at $(date) ====="
    
    # Create log file
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    if is_docker_container; then
        warning "Docker container environment detected!"
        warning "Some operations will be skipped to prevent system conflicts."
    fi
    
    check_os
    
    if [[ -d .git ]]; then
        init_git_submodules
    fi
    
    update_system
    install_packages
    install_gpu_drivers
    install_cuda_toolkit
    install_docker
    install_nvidia_container_toolkit
    install_rust
    verify_rust_installation
    install_just
    cleanup
    
    # Verification steps
    verify_cuda_installation
    verify_docker_nvidia
    
    success "All tasks completed successfully!"
    
    print_post_install_info
    
    info "===== Script Execution Ended at $(date) ====="
}

# Run main function
main "$@"

exit 0
