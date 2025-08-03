#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

update_env_var() {
    local file="$1"
    local var="$2"
    local value="$3"
    
    if grep -q "^${var}=" "$file"; then
        sed -i "s|^${var}=.*|${var}=${value}|" "$file"
    else
        echo "${var}=${value}" >> "$file"
    fi
}

source_rust_env() {
    print_info "Sourcing Rust environment..."
    
    if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
        print_info "Sourced Rust environment from $HOME/.cargo/env"
    fi
    
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        local user_home="/home/$SUDO_USER"
        if [[ -f "$user_home/.cargo/env" ]]; then
            source "$user_home/.cargo/env"
            print_info "Sourced Rust environment from $user_home/.cargo/env"
        fi
    fi
    
    if [[ -d "$HOME/.cargo/bin" ]]; then
        export PATH="$HOME/.cargo/bin:$PATH"
        print_info "Added $HOME/.cargo/bin to PATH"
    fi
    
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        local user_home="/home/$SUDO_USER"
        if [[ -d "$user_home/.cargo/bin" ]]; then
            export PATH="$user_home/.cargo/bin:$PATH"
            print_info "Added $user_home/.cargo/bin to PATH"
        fi
    fi
    
    if command -v rustc &> /dev/null && command -v cargo &> /dev/null; then
        print_success "Rust environment successfully loaded"
        print_info "Rust version: $(rustc --version)"
        print_info "Cargo version: $(cargo --version)"
    else
        print_error "Failed to load Rust environment"
        return 1
    fi
}

print_step "Updating system and installing dependencies..."
sudo apt update && sudo apt install -y sudo git curl
print_success "Dependencies installed"

print_step "Replacing setup script..."
rm scripts/setup.sh
curl -o scripts/setup.sh https://raw.githubusercontent.com/zunxbt/boundless-prover/refs/heads/main/script.sh
chmod +x scripts/setup.sh
print_success "Setup script replaced"

print_step "Downloading custom configuration files..."
# Remove existing compose.yml and download the custom one
# if [[ -f "compose.yml" ]]; then
#     rm compose.yml
#     print_info "Removed existing compose.yml"
# fi

# Download custom broker.toml
# curl -o broker.toml https://raw.githubusercontent.com/Stevesv1/boundless/refs/heads/main/broker.toml
# print_success "Downloaded custom broker.toml"

# Download custom compose.yml
# curl -o compose.yml https://raw.githubusercontent.com/Stevesv1/boundless/refs/heads/main/compose.yml
# print_success "Downloaded custom compose.yml"

# print_step "Downloading custom Rust source files..."
# Remove existing order_monitor.rs and download the custom one
# if [[ -f "crates/broker/src/order_monitor.rs" ]]; then
#    rm crates/broker/src/order_monitor.rs
#    print_info "Removed existing order_monitor.rs"
# fi

# Remove existing order_picker.rs and download the custom one
# if [[ -f "crates/broker/src/order_picker.rs" ]]; then
#    rm crates/broker/src/order_picker.rs
#    print_info "Removed existing order_picker.rs"
# fi

# Download custom order_monitor.rs
# curl -o crates/broker/src/order_monitor.rs https://raw.githubusercontent.com/Stevesv1/boundless/refs/heads/main/crates/broker/src/order_monitor.rs
# print_success "Downloaded custom order_monitor.rs"

# Download custom order_picker.rs
# curl -o crates/broker/src/order_picker.rs https://raw.githubusercontent.com/Stevesv1/boundless/refs/heads/main/crates/broker/src/order_picker.rs
# print_success "Downloaded custom order_picker.rs"

print_step "Running setup script..."
sudo ./scripts/setup.sh
print_success "Setup script executed"

print_step "Installing Docker..."
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
print_success "Docker installed"

print_step "Installing additional development packages..."
sudo apt install -y build-essential pkg-config libssl-dev libclang-dev
print_success "Additional development packages installed"

curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup

print_step "Loading Rust environment..."
source_rust_env

print_step "Installing Risc Zero..."

curl -L https://risczero.com/install | bash

export PATH="/root/.risc0/bin:$PATH"
print_info "Added /root/.risc0/bin to PATH"

if [[ -d "$HOME/.rzup/bin" ]]; then
    export PATH="$HOME/.rzup/bin:$PATH"
    print_info "Added $HOME/.rzup/bin to PATH"
fi

source "$HOME/.bashrc"

if [[ -f "$HOME/.rzup/env" ]]; then
    source "$HOME/.rzup/env"
    print_info "Sourced rzup environment from $HOME/.rzup/env"
fi

if [[ -f "/root/.risc0/env" ]]; then
    source "/root/.risc0/env"
    print_info "Sourced rzup environment from /root/.risc0/env"
fi

if command -v rzup &> /dev/null; then
    print_info "rzup found, installing Rust toolchain..."
    rzup install rust
    print_info "Updating r0vm..."
    rzup update r0vm
    print_success "Risc Zero installed successfully"
else
    print_error "rzup still not found. Checking available paths..."
    print_info "Current PATH: $PATH"
    print_info "Contents of /root/.risc0/bin:"
    ls -la /root/.risc0/bin/ 2>/dev/null || print_info "Directory not found"
    
    if [[ -x "/root/.risc0/bin/rzup" ]]; then
        print_info "Found rzup binary, executing directly..."
        /root/.risc0/bin/rzup install rust
        /root/.risc0/bin/rzup update r0vm
        print_success "Risc Zero installed successfully using direct path"
    else
        print_error "rzup binary not found or not executable"
    fi
fi

source_rust_env

print_step "Installing additional tools..."

if ! command -v cargo &> /dev/null; then
    print_error "Cargo not found. Re-attempting to source Rust environment..."
    source_rust_env
fi

if command -v cargo &> /dev/null; then
    print_info "Installing bento-client..."
    cargo install --locked --git https://github.com/risc0/risc0 bento-client --branch release-2.1 --bin bento_cli
    
    print_info "Running just bento..."
    if command -v just &> /dev/null; then
        just bento
    else
        print_warning "just command not found, skipping 'just bento'"
    fi
    
    print_info "Installing boundless-cli..."
    cargo install --locked boundless-cli
    
    print_success "Additional tools installed"
else
    print_error "Cargo still not available. Please check Rust installation."
    exit 1
fi

print_step "Setting up environment for future sessions..."

{
    echo ""
    echo "# Rust environment"
    echo "if [ -f \"\$HOME/.cargo/env\" ]; then"
    echo "    source \"\$HOME/.cargo/env\""
    echo "fi"
    echo ""
    echo "# RISC Zero environment"
    echo "export PATH=\"/root/.risc0/bin:\$PATH\""
    echo "if [ -f \"\$HOME/.rzup/env\" ]; then"
    echo "    source \"\$HOME/.rzup/env\""
    echo "fi"
    echo "if [ -f \"/root/.risc0/env\" ]; then"
    echo "    source \"/root/.risc0/env\""
    echo "fi"
} >> ~/.bashrc

if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
    user_home="/home/$SUDO_USER"
    {
        echo ""
        echo "# Rust environment"
        echo "if [ -f \"\$HOME/.cargo/env\" ]; then"
        echo "    source \"\$HOME/.cargo/env\""
        echo "fi"
        echo ""
        echo "# RISC Zero environment"
        echo "export PATH=\"/root/.risc0/bin:\$PATH\""
        echo "if [ -f \"\$HOME/.rzup/env\" ]; then"
        echo "    source \"\$HOME/.rzup/env\""
        echo "fi"
        echo "if [ -f \"/root/.risc0/env\" ]; then"
            echo "    source \"/root/.risc0/env\""
        echo "fi"
    } | sudo -u "$SUDO_USER" tee -a "$user_home/.bashrc" > /dev/null
fi

print_success "Environment configured for future sessions"

print_success "Setup completed successfully!"
