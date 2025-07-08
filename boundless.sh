#!/bin/bash

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Utility functions for printing messages
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

# Function to update or append environment variables in a file
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

# Function to configure compose.yml based on GPU count, CPU cores, and network choices
configure_compose_yml() {
    local gpu_count="$1"
    local num_exec_agents="$2"
    shift 2
    local selected_networks=("$@")
    
    print_step "Configuring compose.yml for $gpu_count GPUs and $num_exec_agents exec_agents..."

    # Backup the original compose.yml
    cp compose.yml compose.yml.backup
    print_info "Created backup: compose.yml.backup"

    # Define GPU agents (start from 0)
    local additional_gpu_agents=""
    for ((i=0; i<gpu_count; i++)); do
        additional_gpu_agents+="\n  gpu_prove_agent$i:"
        additional_gpu_agents+="\n    <<: *agent-common"
        additional_gpu_agents+="\n    mem_limit: 4G"
        additional_gpu_agents+="\n    cpus: 4"
        additional_gpu_agents+="\n    entrypoint: /app/agent -t prove"
        additional_gpu_agents+="\n    deploy:"
        additional_gpu_agents+="\n      resources:"
        additional_gpu_agents+="\n        reservations:"
        additional_gpu_agents+="\n          devices:"
        additional_gpu_agents+="\n            - driver: nvidia"
        additional_gpu_agents+="\n              device_ids: ['$i']"
        additional_gpu_agents+="\n              capabilities: [gpu]"
    done

    # Define exec agents (start from 0)
    local additional_exec_agents=""
    for ((i=0; i<num_exec_agents; i++)); do
        additional_exec_agents+="\n  exec_agent$i:"
        additional_exec_agents+="\n    <<: *exec-agent-common"
    done

    # Build depends_on list for brokers
    local depends_on="    depends_on:"
    depends_on+="\n      - rest_api"
    for ((i=0; i<gpu_count; i++)); do
        depends_on+="\n      - gpu_prove_agent$i"
    done
    for ((i=0; i<num_exec_agents; i++)); do
        depends_on+="\n      - exec_agent$i"
    done
    depends_on+="\n      - aux_agent"
    depends_on+="\n      - snark_agent"
    depends_on+="\n      - redis"
    depends_on+="\n      - postgres"

    # Define broker services for each selected network
    local additional_brokers=""
    for network in "${selected_networks[@]}"; do
        additional_brokers+="\n  broker_$network:"
        additional_brokers+="\n    <<: *broker-common"
        additional_brokers+="\n    env_file:"
        additional_brokers+="\n      - .env.broker.$network"
        additional_brokers+="\n    volumes:"
        additional_brokers+="\n      - broker_${network}_data:/db/"
        additional_brokers+="\n    entrypoint: /app/broker --db-url 'sqlite:///db/broker_$network.db' --config-file /app/broker.toml --bento-api-url http://localhost:8081"
        additional_brokers+="\n$depends_on"
    done

    # Define additional volumes for brokers
    local additional_volumes=""
    for network in "${selected_networks[@]}"; do
        additional_volumes+="\n  broker_${network}_data:"
    done

    # Locate the volumes section
    local volumes_line=$(grep -n "^volumes:" compose.yml | cut -d: -f1)
    if [ -z "$volumes_line" ]; then
        print_error "Could not find volumes section in compose.yml"
        exit 1
    fi

    # Remove original services
    sed -i '/^  gpu_prove_agent0:/,/^  [a-zA-Z_-]*:/{/^  [a-zA-Z_-]*:/!d;};/^  gpu_prove_agent0:/d' compose.yml
    sed -i '/^  exec_agent0:/,/^  [a-zA-Z_-]*:/{/^  [a-zA-Z_-]*:/!d;};/^  exec_agent0:/d' compose.yml
    sed -i '/^  exec_agent1:/,/^  [a-zA-Z_-]*:/{/^  [a-zA-Z_-]*:/!d;};/^  exec_agent1:/d' compose.yml
    sed -i '/^  broker:/,/^  [a-zA-Z_-]*:/{/^  [a-zA-Z_-]*:/!d;};/^  broker:/d' compose.yml

    # Insert new services before volumes
    {
        head -n $((volumes_line - 1)) compose.yml
        echo -e "$additional_gpu_agents"
        echo -e "$additional_exec_agents"
        echo -e "$additional_brokers"
        tail -n +"$volumes_line" compose.yml
    } > compose.yml.tmp && mv compose.yml.tmp compose.yml

    # Update volumes section
    sed -i "/^volumes:/,/^$/c\volumes:$additional_volumes\n  redis-data:\n  postgres-data:\n  minio-data:\n  grafana-data:" compose.yml

    print_success "Configured compose.yml with $gpu_count GPU agents, $num_exec_agents exec agents, and ${#selected_networks[@]} brokers"
}

# Function to source Rust environment
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
        print_success "Rust environment loaded"
    else
        print_error "Failed to load Rust environment"
        return 1
    fi
}

# Main script execution
print_step "Updating system and installing dependencies..."
sudo apt update && sudo apt install -y sudo git curl
print_success "Dependencies installed"

print_step "Cloning Boundless repository..."
git clone https://github.com/boundless-xyz/boundless
cd boundless
git checkout release-0.12
print_success "Repository cloned and checked out to release-0.12"

print_step "Replacing setup script..."
rm scripts/setup.sh
curl -o scripts/setup.sh https://raw.githubusercontent.com/Stevesv1/boundless-prover/refs/heads/main/script.sh
chmod +x scripts/setup.sh
print_success "Setup script replaced"

print_step "Running setup script..."
sudo ./scripts/setup.sh
print_success "Setup script executed"

print_step "Loading Rust environment..."
source_rust_env

print_step "Installing Risc Zero..."
curl -L https://risczero.com/install | bash
export PATH="/root/.risc0/bin:$PATH"
if [[ -f "$HOME/.rzup/env" ]]; then
    source "$HOME/.rzup/env"
fi
rzup install rust
rzup update r0vm
print_success "Risc Zero installed"

print_step "Installing additional tools..."
cargo install --git https://github.com/risc0/risc0 bento-client --bin bento_cli
cargo install --locked boundless-cli
print_success "Additional tools installed"

# Check GPU configuration
print_step "Checking GPU configuration..."
gpu_count=0
min_vram=0
if command -v nvidia-smi &> /dev/null; then
    gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
    if [ "$gpu_count" -gt 0 ]; then
        vram_list=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
        min_vram=$(echo "$vram_list" | sort -n | head -1)
    fi
fi
print_info "Found $gpu_count GPU(s)"

# Set SEGMENT_SIZE based on minimum VRAM
if [ "$gpu_count" -gt 0 ]; then
    if [ "$min_vram" -ge 40960 ]; then
        segment_size=22
    elif [ "$min_vram" -ge 20480 ]; then
        segment_size=21
    elif [ "$min_vram" -ge 16384 ]; then
        segment_size=20
    elif [ "$min_vram" -ge 8192 ]; then
        segment_size=19
    else
        segment_size=18
        print_warning "GPU VRAM ($min_vram MiB) below 8GB; set SEGMENT_SIZE to 18"
    fi
else
    segment_size=18
    print_info "No GPUs detected; set SEGMENT_SIZE to 18 for CPU mode"
fi
echo "SEGMENT_SIZE=$segment_size" > .env
print_info "Set SEGMENT_SIZE to $segment_size"

# Detect CPU cores
total_cpus=$(nproc)
if [ "$gpu_count" -eq 1 ]; then
    num_exec_agents=$((total_cpus / 4))
    num_exec_agents=$((num_exec_agents > 2 ? num_exec_agents : 2))
    print_info "Single GPU with $total_cpus cores; set $num_exec_agents exec agents"
else
    num_exec_agents=2
    print_info "Default $num_exec_agents exec agents for $gpu_count GPUs"
fi

# GPU allocation options
max_networks=3  # Default for <2 GPUs
if [ "$gpu_count" -ge 2 ]; then
    print_step "GPU Allocation Options"
    if [ "$gpu_count" -eq 2 ]; then
        echo -e "${PURPLE}You have 2 GPUs. Choose an option:${NC}"
        echo "1. Run 2 provers on 2 different networks (1 GPU each)"
        echo "2. Use both GPUs for a single prover on one network"
    elif [ "$gpu_count" -eq 3 ]; then
        echo -e "${PURPLE}You have 3 GPUs. Choose an option:${NC}"
        echo "1. Run 3 provers on 3 different networks (1 GPU each)"
        echo "2. Use all 3 GPUs for a single prover on one network"
    else
        echo -e "${PURPLE}You have $gpu_count GPUs. Choose an option:${NC}"
        echo "1. Use 1 GPU per network for up to 3 networks, extra GPUs assigned to one network"
        echo "2. Use all $gpu_count GPUs for a single prover on one network"
    fi
    read -p "Enter your choice (1 or 2): " gpu_allocation_choice

    if [ "$gpu_allocation_choice" -eq 1 ]; then
        max_networks=$((gpu_count > 3 ? 3 : gpu_count))
    elif [ "$gpu_allocation_choice" -eq 2 ]; then
        max_networks=1
    else
        print_error "Invalid choice"
        exit 1
    fi
fi

# Network selection based on GPU allocation
print_step "Network Selection"
if [ "$max_networks" -eq 1 ]; then
    echo -e "${PURPLE}Select one network to run the prover on:${NC}"
else
    echo -e "${PURPLE}Choose up to $max_networks networks to run the prover on:${NC}"
fi
echo "1. Base Mainnet"
echo "2. Base Sepolia"
echo "3. Ethereum Sepolia"
echo ""
read -p "Enter your choices (e.g., 1,2): " network_choice

# Parse network choice
selected_numbers=($(echo "$network_choice" | tr ',' ' '))
selected_networks=()
for num in "${selected_numbers[@]}"; do
    case "$num" in
        1) selected_networks+=("base") ;;
        2) selected_networks+=("base-sepolia") ;;
        3) selected_networks+=("eth-sepolia") ;;
    esac
done

# Adjust based on max_networks
if [ "${#selected_networks[@]}" -gt "$max_networks" ]; then
    print_warning "Selected ${#selected_networks[@]} networks, but max is $max_networks. Using first $max_networks."
    selected_networks=("${selected_networks[@]:0:$max_networks}")
elif [ "${#selected_networks[@]}" -eq 0 ]; then
    print_error "No networks selected"
    exit 1
fi

# Create environment files
for network in "${selected_networks[@]}"; do
    cp .env.broker-template ".env.broker.$network"
    cp ".env.$network" ".env.$network.backup" 2>/dev/null || touch ".env.$network.backup"
    print_info "Created $network environment files"
done

# Prompt for private key
read -p "Enter your private key: " private_key

# Configure environment for each network
for network in "${selected_networks[@]}"; do
    case "$network" in
        "base")
            read -p "Enter Base Mainnet RPC URL: " base_rpc
            update_env_var ".env.broker.base" "PRIVATE_KEY" "$private_key"
            update_env_var ".env.broker.base" "BOUNDLESS_MARKET_ADDRESS" "0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8"
            update_env_var ".env.broker.base" "SET_VERIFIER_ADDRESS" "0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"
            update_env_var ".env.broker.base" "RPC_URL" "$base_rpc"
            update_env_var ".env.broker.base" "ORDER_STREAM_URL" "https://base-mainnet.beboundless.xyz"
            echo "export PRIVATE_KEY=\"$private_key\"" >> .env.base
            echo "export RPC_URL=\"$base_rpc\"" >> .env.base
            print_success "Base Mainnet configured"
            ;;
        "base-sepolia")
            read -p "Enter Base Sepolia RPC URL: " base_sepolia_rpc
            update_env_var ".env.broker.base-sepolia" "PRIVATE_KEY" "$private_key"
            update_env_var ".env.broker.base-sepolia" "BOUNDLESS_MARKET_ADDRESS" "0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b"
            update_env_var ".env.broker.base-sepolia" "SET_VERIFIER_ADDRESS" "0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"
            update_env_var ".env.broker.base-sepolia" "RPC_URL" "$base_sepolia_rpc"
            update_env_var ".env.broker.base-sepolia" "ORDER_STREAM_URL" "https://base-sepolia.beboundless.xyz"
            echo "export PRIVATE_KEY=\"$private_key\"" >> .env.base-sepolia
            echo "export RPC_URL=\"$base_sepolia_rpc\"" >> .env.base-sepolia
            print_success "Base Sepolia configured"
            ;;
        "eth-sepolia")
            read -p "Enter Ethereum Sepolia RPC URL: " eth_sepolia_rpc
            update_env_var ".env.broker.eth-sepolia" "PRIVATE_KEY" "$private_key"
            update_env_var ".env.broker.eth-sepolia" "BOUNDLESS_MARKET_ADDRESS" "0x13337C76fE2d1750246B68781ecEe164643b98Ec"
            update_env_var ".env.broker.eth-sepolia" "SET_VERIFIER_ADDRESS" "0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64"
            update_env_var ".env.broker.eth-sepolia" "RPC_URL" "$eth_sepolia_rpc"
            update_env_var ".env.broker.eth-sepolia" "ORDER_STREAM_URL" "https://eth-sepolia.beboundless.xyz/"
            echo "export PRIVATE_KEY=\"$private_key\"" >> .env.eth-sepolia
            echo "export RPC_URL=\"$eth_sepolia_rpc\"" >> .env.eth-sepolia
            print_success "Ethereum Sepolia configured"
            ;;
    esac
done

# Configure broker settings
print_step "Configuring broker settings..."
cp broker-template.toml broker.toml
if [ "$gpu_count" -eq 1 ]; then
    max_proofs=2
    peak_khz=100
elif [ "$gpu_count" -eq 2 ]; then
    max_proofs=4
    peak_khz=200
elif [ "$gpu_count" -eq 3 ]; then
    max_proofs=6
    peak_khz=300
else
    max_proofs=$((gpu_count * 2))
    peak_khz=$((gpu_count * 100))
fi
sed -i "s/max_concurrent_proofs = .*/max_concurrent_proofs = $max_proofs/" broker.toml
sed -i "s/peak_prove_khz = .*/peak_prove_khz = $peak_khz/" broker.toml
print_success "Broker settings configured for $gpu_count GPU(s)"

# Configure compose.yml
configure_compose_yml "$gpu_count" "$num_exec_agents" "${selected_networks[@]}"

# Deposit stake
print_step "Depositing stake for selected networks..."
for network in "${selected_networks[@]}"; do
    case "$network" in
        "base")
            print_info "Depositing stake on Base Mainnet..."
            boundless \
                --rpc-url "$base_rpc" \
                --private-key "$private_key" \
                --chain-id 8453 \
                --boundless-market-address 0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8 \
                --set-verifier-address 0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760 \
                account deposit-stake 10
            print_success "Base Mainnet stake deposited"
            ;;
        "base-sepolia")
            print_info "Depositing stake on Base Sepolia..."
            boundless \
                --rpc-url "$base_sepolia_rpc" \
                --private-key "$private_key" \
                --chain-id 84532 \
                --boundless-market-address 0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b \
                --set-verifier-address 0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760 \
                account deposit-stake 10
            print_success "Base Sepolia stake deposited"
            ;;
        "eth-sepolia")
            print_info "Depositing stake on Ethereum Sepolia..."
            boundless \
                --rpc-url "$eth_sepolia_rpc" \
                --private-key "$private_key" \
                --chain-id 11155111 \
                --boundless-market-address 0x13337C76fE2d1750246B68781ecEe164643b98Ec \
                --set-verifier-address 0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64 \
                account deposit-stake 10
            print_success "Ethereum Sepolia stake deposited"
            ;;
    esac
done
print_success "Stake deposits completed"

# Set up environment for future sessions
print_step "Setting up environment for future sessions..."
{
    echo "# Rust environment"
    echo "if [ -f \"\$HOME/.cargo/env\" ]; then"
    echo "    source \"\$HOME/.cargo/env\""
    echo "fi"
    echo "# RISC Zero environment"
    echo "export PATH=\"/root/.risc0/bin:\$PATH\""
    echo "if [ -f \"\$HOME/.rzup/env\" ]; then"
    echo "    source \"\$HOME/.rzup/env\""
    echo "fi"
} >> ~/.bashrc
print_success "Environment configured"

# Start services
print_step "Starting all services..."
docker-compose up -d
print_success "All services started"

print_success "Setup completed successfully!"
