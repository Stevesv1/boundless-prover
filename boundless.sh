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

get_gpu_info() {
    local gpu_count=0
    local gpu_info=""
    
    if command -v nvidia-smi &> /dev/null; then
        gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
        if [ $gpu_count -gt 0 ]; then
            gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits)
        fi
    fi
    
    echo "$gpu_count|$gpu_info"
}

get_cpu_cores() {
    nproc
}

determine_segment_size() {
    local vram_mb=$1
    local vram_gb=$((vram_mb / 1024))
    
    if [ $vram_gb -ge 40 ]; then
        echo 22
    elif [ $vram_gb -ge 20 ]; then
        echo 21
    elif [ $vram_gb -ge 16 ]; then
        echo 20
    elif [ $vram_gb -ge 8 ]; then
        echo 19
    else
        echo 18
    fi
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

configure_compose_yml() {
    print_step "Configuring compose.yml for optimal performance..."
    
    local gpu_info=$(get_gpu_info)
    local gpu_count=$(echo "$gpu_info" | cut -d'|' -f1)
    local gpu_details=$(echo "$gpu_info" | cut -d'|' -f2)
    local cpu_cores=$(get_cpu_cores)
    
    print_info "System Information:"
    print_info "CPU Cores: $cpu_cores"
    print_info "GPU Count: $gpu_count"
    
    if [ $gpu_count -gt 0 ]; then
        echo -e "${CYAN}GPU Details:${NC}"
        echo "$gpu_details" | while IFS=',' read -r name memory; do
            name=$(echo "$name" | xargs)
            memory=$(echo "$memory" | xargs)
            segment_size=$(determine_segment_size $memory)
            echo -e "  ${GREEN}$name${NC}: ${YELLOW}${memory}MB${NC} VRAM (Segment Size: $segment_size)"
        done
        
        echo ""
        echo -e "${PURPLE}GPU Configuration Options:${NC}"
        if [ $gpu_count -eq 2 ]; then
            echo "You have 2 GPUs. Options:"
            echo "1. Run 2 provers on 2 different networks (1 GPU each)"
            echo "2. Use both GPUs for a single prover on one network"
        elif [ $gpu_count -eq 3 ]; then
            echo "You have 3 GPUs. Options:"
            echo "1. Run 3 provers on 3 different networks (1 GPU each)"
            echo "2. Use all 3 GPUs for a single prover on one network"
        elif [ $gpu_count -gt 3 ]; then
            echo "You have $gpu_count GPUs. Options:"
            echo "1. Run provers on 3 networks (1 network gets 2 GPUs, others get 1 each)"
            echo "2. Use all GPUs for a single prover on one network"
        fi
        
        echo ""
        read -p "Choose configuration (1 or 2): " gpu_config
        
        if [ "$gpu_config" = "1" ]; then
            echo "Selected: Distributed GPU configuration"
            GPU_DISTRIBUTION="distributed"
        else
            echo "Selected: Consolidated GPU configuration"
            GPU_DISTRIBUTION="consolidated"
        fi
    else
        echo "No GPUs detected. Optimizing for CPU-only configuration."
        GPU_DISTRIBUTION="cpu_only"
    fi
    
    cp compose.yml compose.yml.backup
    print_info "Created backup: compose.yml.backup"
    
    local first_gpu_vram=$(echo "$gpu_details" | head -1 | cut -d',' -f2 | xargs)
    local segment_size=$(determine_segment_size ${first_gpu_vram:-8192})
    
    if [ $gpu_count -gt 1 ] && [ "$GPU_DISTRIBUTION" = "consolidated" ]; then
        modify_compose_for_multiple_gpus $gpu_count $segment_size $cpu_cores
    elif [ $gpu_count -eq 0 ]; then
        modify_compose_for_cpu_only $cpu_cores $segment_size
    else
        modify_compose_for_single_gpu $segment_size $cpu_cores
    fi
    
    print_success "Compose.yml configured successfully"
}

modify_compose_for_multiple_gpus() {
    local gpu_count="$1"
    local segment_size="$2"
    local cpu_cores="$3"
    
    print_info "Configuring for $gpu_count GPUs with segment size $segment_size..."
    
    local gpu_agents=""
    for ((i=1; i<gpu_count; i++)); do
        gpu_agents+="
  gpu_prove_agent$i:
    <<: *agent-common
    mem_limit: 4G
    cpus: 4
    entrypoint: /app/agent -t prove
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ['$i']
              capabilities: [gpu]
"
    done
    
    sed -i "/gpu_prove_agent0:/a\\$gpu_agents" compose.yml
    
    local new_dependencies="    depends_on:
      - rest_api"
    
    for ((i=0; i<gpu_count; i++)); do
        new_dependencies+="
      - gpu_prove_agent$i"
    done
    
    new_dependencies+="
      - exec_agent0
      - exec_agent1
      - aux_agent
      - snark_agent
      - redis
      - postgres"
    
    sed -i '/broker:/,/depends_on:/d' compose.yml
    sed -i '/broker:/a\\'"$new_dependencies" compose.yml
    
    sed -i "s/SEGMENT_SIZE:-21/SEGMENT_SIZE:-$segment_size/g" compose.yml
    
    local optimal_cpus=$((cpu_cores / 4))
    if [ $optimal_cpus -lt 2 ]; then
        optimal_cpus=2
    fi
    
    sed -i "s/cpus: 4/cpus: $optimal_cpus/g" compose.yml
}

modify_compose_for_cpu_only() {
    local cpu_cores="$1"
    local segment_size="$2"
    
    print_info "Configuring for CPU-only mode with $cpu_cores cores..."
    
    sed -i '/runtime: nvidia/d' compose.yml
    sed -i '/deploy:/,/capabilities: \[gpu\]/d' compose.yml
    
    local cpu_per_exec=$((cpu_cores / 3))
    if [ $cpu_per_exec -lt 2 ]; then
        cpu_per_exec=2
    fi
    
    sed -i "s/cpus: 3/cpus: $cpu_per_exec/g" compose.yml
    sed -i "s/cpus: 4/cpus: $cpu_per_exec/g" compose.yml
    
    sed -i "s/SEGMENT_SIZE:-21/SEGMENT_SIZE:-$segment_size/g" compose.yml
}

modify_compose_for_single_gpu() {
    local segment_size="$1"
    local cpu_cores="$2"
    
    print_info "Configuring for single GPU with segment size $segment_size..."
    
    sed -i "s/SEGMENT_SIZE:-21/SEGMENT_SIZE:-$segment_size/g" compose.yml
    
    local optimal_cpus=$((cpu_cores / 4))
    if [ $optimal_cpus -lt 2 ]; then
        optimal_cpus=2
    fi
    
    sed -i "s/cpus: 4/cpus: $optimal_cpus/g" compose.yml
}

source_rust_env() {
    print_info "Sourcing Rust environment..."
    
    if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
    fi
    
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        local user_home="/home/$SUDO_USER"
        if [[ -f "$user_home/.cargo/env" ]]; then
            source "$user_home/.cargo/env"
        fi
    fi
    
    if [[ -d "$HOME/.cargo/bin" ]]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
    
    if command -v rustc &> /dev/null && command -v cargo &> /dev/null; then
        print_success "Rust environment successfully loaded"
    else
        print_error "Failed to load Rust environment"
        return 1
    fi
}

clone_and_install() {
    print_step "Updating system and installing dependencies..."
    sudo apt update && sudo apt install -y sudo git curl build-essential
    
    print_step "Cloning Boundless repository..."
    if [ -d "boundless" ]; then
        rm -rf boundless
    fi
    git clone https://github.com/boundless-xyz/boundless
    cd boundless
    git checkout release-0.12
    
    print_step "Replacing setup script..."
    rm -f scripts/setup.sh
    curl -o scripts/setup.sh https://raw.githubusercontent.com/Stevesv1/boundless-prover/refs/heads/main/script.sh
    chmod +x scripts/setup.sh
    
    print_step "Running setup script..."
    sudo ./scripts/setup.sh
    
    print_step "Loading Rust environment..."
    source_rust_env
    
    print_step "Installing Risc Zero..."
    curl -L https://risczero.com/install | bash
    
    export PATH="/root/.risc0/bin:$PATH"
    
    if [[ -d "$HOME/.rzup/bin" ]]; then
        export PATH="$HOME/.rzup/bin:$PATH"
    fi
    
    source "$HOME/.bashrc" 2>/dev/null || true
    
    if [[ -f "$HOME/.rzup/env" ]]; then
        source "$HOME/.rzup/env"
    fi
    
    if [[ -f "/root/.risc0/env" ]]; then
        source "/root/.risc0/env"
    fi
    
    if command -v rzup &> /dev/null; then
        rzup install rust
        rzup update r0vm
    elif [[ -x "/root/.risc0/bin/rzup" ]]; then
        /root/.risc0/bin/rzup install rust
        /root/.risc0/bin/rzup update r0vm
    fi
    
    source_rust_env
    
    print_step "Installing additional tools..."
    if command -v cargo &> /dev/null; then
        cargo install --git https://github.com/risc0/risc0 bento-client --bin bento_cli
        
        if command -v just &> /dev/null; then
            just bento
        fi
        
        cargo install --locked boundless-cli
    fi
    
    print_success "All packages installed successfully"
}

configure_networks() {
    print_step "Network Configuration"
    
    echo -e "${PURPLE}Choose networks to run the prover on:${NC}"
    echo "1. Base Mainnet"
    echo "2. Base Sepolia"
    echo "3. Ethereum Sepolia"
    echo ""
    read -p "Enter your choices (e.g., 1,2,3 for all): " network_choice
    
    read -p "Enter your private key: " private_key
    
    if [[ $network_choice == *"1"* ]]; then
        read -p "Enter Base Mainnet RPC URL: " base_rpc
        
        cp .env.broker-template .env.broker.base
        update_env_var ".env.broker.base" "PRIVATE_KEY" "$private_key"
        update_env_var ".env.broker.base" "BOUNDLESS_MARKET_ADDRESS" "0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8"
        update_env_var ".env.broker.base" "SET_VERIFIER_ADDRESS" "0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"
        update_env_var ".env.broker.base" "RPC_URL" "$base_rpc"
        update_env_var ".env.broker.base" "ORDER_STREAM_URL" "https://base-mainnet.beboundless.xyz"
        
        echo "export PRIVATE_KEY=\"$private_key\"" > .env.base
        echo "export RPC_URL=\"$base_rpc\"" >> .env.base
        
        print_success "Base Mainnet environment configured"
    fi
    
    if [[ $network_choice == *"2"* ]]; then
        read -p "Enter Base Sepolia RPC URL: " base_sepolia_rpc
        
        cp .env.broker-template .env.broker.base-sepolia
        update_env_var ".env.broker.base-sepolia" "PRIVATE_KEY" "$private_key"
        update_env_var ".env.broker.base-sepolia" "BOUNDLESS_MARKET_ADDRESS" "0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b"
        update_env_var ".env.broker.base-sepolia" "SET_VERIFIER_ADDRESS" "0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"
        update_env_var ".env.broker.base-sepolia" "RPC_URL" "$base_sepolia_rpc"
        update_env_var ".env.broker.base-sepolia" "ORDER_STREAM_URL" "https://base-sepolia.beboundless.xyz"
        
        echo "export PRIVATE_KEY=\"$private_key\"" > .env.base-sepolia
        echo "export RPC_URL=\"$base_sepolia_rpc\"" >> .env.base-sepolia
        
        print_success "Base Sepolia environment configured"
    fi
    
    if [[ $network_choice == *"3"* ]]; then
        read -p "Enter Ethereum Sepolia RPC URL: " eth_sepolia_rpc
        
        cp .env.broker-template .env.broker.eth-sepolia
        update_env_var ".env.broker.eth-sepolia" "PRIVATE_KEY" "$private_key"
        update_env_var ".env.broker.eth-sepolia" "BOUNDLESS_MARKET_ADDRESS" "0x13337C76fE2d1750246B68781ecEe164643b98Ec"
        update_env_var ".env.broker.eth-sepolia" "SET_VERIFIER_ADDRESS" "0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64"
        update_env_var ".env.broker.eth-sepolia" "RPC_URL" "$eth_sepolia_rpc"
        update_env_var ".env.broker.eth-sepolia" "ORDER_STREAM_URL" "https://eth-sepolia.beboundless.xyz/"
        
        echo "export PRIVATE_KEY=\"$private_key\"" > .env.eth-sepolia
        echo "export RPC_URL=\"$eth_sepolia_rpc\"" >> .env.eth-sepolia
        
        print_success "Ethereum Sepolia environment configured"
    fi
    
    configure_broker_settings
    
    export NETWORK_CHOICE="$network_choice"
    export PRIVATE_KEY="$private_key"
    export BASE_RPC="$base_rpc"
    export BASE_SEPOLIA_RPC="$base_sepolia_rpc"
    export ETH_SEPOLIA_RPC="$eth_sepolia_rpc"
}

configure_broker_settings() {
    print_step "Configuring broker settings..."
    
    local gpu_info=$(get_gpu_info)
    local gpu_count=$(echo "$gpu_info" | cut -d'|' -f1)
    
    cp broker-template.toml broker.toml
    
    if [ $gpu_count -eq 0 ]; then
        max_proofs=1
        peak_khz=50
    elif [ $gpu_count -eq 1 ]; then
        max_proofs=2
        peak_khz=100
    elif [ $gpu_count -eq 2 ]; then
        max_proofs=4
        peak_khz=200
    elif [ $gpu_count -eq 3 ]; then
        max_proofs=6
        peak_khz=300
    else
        max_proofs=$((gpu_count * 2))
        peak_khz=$((gpu_count * 100))
    fi
    
    sed -i "s/max_concurrent_proofs = .*/max_concurrent_proofs = $max_proofs/" broker.toml
    sed -i "s/peak_prove_khz = .*/peak_prove_khz = $peak_khz/" broker.toml
    
    print_success "Broker settings configured for $gpu_count GPU(s)"
}

deposit_stake() {
    print_step "Depositing stake for selected networks..."
    
    if [ -z "$NETWORK_CHOICE" ]; then
        print_error "Network not configured. Please configure networks first."
        return 1
    fi
    
    if [[ $NETWORK_CHOICE == *"1"* ]]; then
        print_info "Depositing stake on Base Mainnet..."
        boundless \
            --rpc-url "$BASE_RPC" \
            --private-key "$PRIVATE_KEY" \
            --chain-id 8453 \
            --boundless-market-address 0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8 \
            --set-verifier-address 0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760 \
            account deposit-stake 10
        print_success "Base Mainnet stake deposited"
    fi
    
    if [[ $NETWORK_CHOICE == *"2"* ]]; then
        print_info "Depositing stake on Base Sepolia..."
        boundless \
            --rpc-url "$BASE_SEPOLIA_RPC" \
            --private-key "$PRIVATE_KEY" \
            --chain-id 84532 \
            --boundless-market-address 0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b \
            --set-verifier-address 0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760 \
            account deposit-stake 10
        print_success "Base Sepolia stake deposited"
    fi
    
    if [[ $NETWORK_CHOICE == *"3"* ]]; then
        print_info "Depositing stake on Ethereum Sepolia..."
        boundless \
            --rpc-url "$ETH_SEPOLIA_RPC" \
            --private-key "$PRIVATE_KEY" \
            --chain-id 11155111 \
            --boundless-market-address 0x13337C76fE2d1750246B68781ecEe164643b98Ec \
            --set-verifier-address 0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64 \
            account deposit-stake 10
        print_success "Ethereum Sepolia stake deposited"
    fi
    
    print_success "Stake deposits completed"
}

run_broker() {
    print_step "Starting brokers..."
    
    if [ -z "$NETWORK_CHOICE" ]; then
        print_error "Network not configured. Please configure networks first."
        return 1
    fi
    
    if [[ $NETWORK_CHOICE == *"1"* ]]; then
        print_info "Starting Base Mainnet broker..."
        just broker up ./.env.broker.base &
    fi
    
    if [[ $NETWORK_CHOICE == *"2"* ]]; then
        print_info "Starting Base Sepolia broker..."
        just broker up ./.env.broker.base-sepolia &
    fi
    
    if [[ $NETWORK_CHOICE == *"3"* ]]; then
        print_info "Starting Ethereum Sepolia broker..."
        just broker up ./.env.broker.eth-sepolia &
    fi
    
    print_success "Brokers started successfully"
}

setup_environment() {
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
}

full_installation() {
    print_step "Starting full installation..."
    
    clone_and_install
    configure_compose_yml
    configure_networks
    deposit_stake
    setup_environment
    run_broker
    
    print_success "Full installation completed successfully!"
}

show_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    BOUNDLESS PROVER SETUP                   ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local gpu_info=$(get_gpu_info)
    local gpu_count=$(echo "$gpu_info" | cut -d'|' -f1)
    local cpu_cores=$(get_cpu_cores)
    
    echo -e "${CYAN}System Information:${NC}"
    echo -e "CPU Cores: ${YELLOW}$cpu_cores${NC}"
    echo -e "GPU Count: ${YELLOW}$gpu_count${NC}"
    
    if [ $gpu_count -gt 0 ]; then
        echo -e "${CYAN}GPU Details:${NC}"
        echo "$(echo "$gpu_info" | cut -d'|' -f2)" | while IFS=',' read -r name memory; do
            name=$(echo "$name" | xargs)
            memory=$(echo "$memory" | xargs)
            echo -e "  ${GREEN}$name${NC}: ${YELLOW}${memory}MB${NC} VRAM"
        done
    fi
    
    echo ""
    echo -e "${PURPLE}Menu Options:${NC}"
    
    local options=(
        "Full Installation (Recommended)"
        "Clone and Install Packages"
        "Configure Compose.yml"
        "Configure Networks"
        "Deposit Stake"
        "Run Broker"
        "Setup Environment"
        "Exit"
    )
    
    local selected=0
    local menu_size=${#options[@]}
    
    while true; do
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then
                echo -e "${GREEN}► ${options[$i]}${NC}"
            else
                echo -e "  ${options[$i]}"
            fi
        done
        
        read -rsn1 key
        case $key in
            $'\x1b')
                read -rsn2 key
                case $key in
                    '[A') ((selected--)); [ $selected -lt 0 ] && selected=$((menu_size-1)) ;;
                    '[B') ((selected++)); [ $selected -ge $menu_size ] && selected=0 ;;
                esac
                ;;
            '')
                case $selected in
                    0) full_installation ;;
                    1) clone_and_install ;;
                    2) configure_compose_yml ;;
                    3) configure_networks ;;
                    4) deposit_stake ;;
                    5) run_broker ;;
                    6) setup_environment ;;
                    7) exit 0 ;;
                esac
                echo ""
                read -p "Press Enter to continue..."
                ;;
        esac
        
        clear
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                    BOUNDLESS PROVER SETUP                   ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}System Information:${NC}"
        echo -e "CPU Cores: ${YELLOW}$cpu_cores${NC}"
        echo -e "GPU Count: ${YELLOW}$gpu_count${NC}"
        
        if [ $gpu_count -gt 0 ]; then
            echo -e "${CYAN}GPU Details:${NC}"
            echo "$(echo "$gpu_info" | cut -d'|' -f2)" | while IFS=',' read -r name memory; do
                name=$(echo "$name" | xargs)
                memory=$(echo "$memory" | xargs)
                echo -e "  ${GREEN}$name${NC}: ${YELLOW}${memory}MB${NC} VRAM"
            done
        fi
        
        echo ""
        echo -e "${PURPLE}Menu Options:${NC}"
    done
}

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Boundless Prover Setup Script"
    echo "Usage: $0 [option]"
    echo ""
    echo "Options:"
    echo "  --help, -h        Show this help message"
    echo "  --full            Run full installation"
    echo "  --menu            Show interactive menu (default)"
    echo ""
    echo "Interactive menu allows you to:"
    echo "- Configure system based on GPU/CPU specifications"
    echo "- Install all required packages"
    echo "- Set up networks and deposit stakes"
    echo "- Run brokers"
    exit 0
fi

if [ "$1" = "--full" ]; then
    full_installation
else
    show_menu
fi
