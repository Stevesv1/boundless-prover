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

configure_compose() {
    print_step "Configuring compose.yml..."
    if ! command -v nvidia-smi &> /dev/null; then
        print_error "nvidia-smi not found. Please ensure NVIDIA drivers are installed."
        return 1
    fi

    gpu_count=$(nvidia-smi -L | wc -l)
    print_info "Found $gpu_count GPU(s)"

    if [ $gpu_count -eq 0 ]; then
        print_error "No GPUs found. Exiting."
        return 1
    fi

    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 0)
    vram_gb=$((vram / 1024))
    print_info "GPU VRAM: ${vram_gb}GB"

    if [ $vram_gb -le 8 ]; then
        segment_size=19
    elif [ $vram_gb -le 16 ]; then
        segment_size=20
    elif [ $vram_gb -le 20 ]; then
        segment_size=21
    else
        segment_size=22
    fi

    print_info "Setting SEGMENT_SIZE to $segment_size"
    if [ -f .env ]; then
        if grep -q "^SEGMENT_SIZE=" .env; then
            sed -i "s/^SEGMENT_SIZE=.*/SEGMENT_SIZE=$segment_size/" .env
        else
            echo "SEGMENT_SIZE=$segment_size" >> .env
        fi
    else
        echo "SEGMENT_SIZE=$segment_size" > .env
    fi

    cp compose.yml compose.yml.backup
    print_info "Created backup: compose.yml.backup"

    if [ $gpu_count -gt 1 ]; then
        volumes_line=$(grep -n "^volumes:" compose.yml | cut -d: -f1)
        additional_agents=""
        for i in $(seq 1 $((gpu_count - 1))); do
            additional_agents+="  gpu_prove_agent$i:\n"
            additional_agents+="    <<: *agent-common\n"
            additional_agents+="    mem_limit: 4G\n"
            additional_agents+="    cpus: 4\n"
            additional_agents+="    entrypoint: /app/agent -t prove\n"
            additional_agents+="    deploy:\n"
            additional_agents+="      resources:\n"
            additional_agents+="        reservations:\n"
            additional_agents+="          devices:\n"
            additional_agents+="            - driver: nvidia\n"
            additional_agents+="              device_ids: ['$i']\n"
            additional_agents+="              capabilities: [gpu]\n\n"
        done
        echo -e "$additional_agents" > temp.txt
        sed -i "$((volumes_line - 1)) r temp.txt" compose.yml
        rm temp.txt

        gpu_agent_line=$(grep -n "- gpu_prove_agent0" compose.yml | cut -d: -f1)
        for i in $(seq 1 $((gpu_count - 1))); do
            sed -i "$gpu_agent_line a \ \ \ \ - gpu_prove_agent$i" compose.yml
        done
    else
        cpu_cores=$(nproc)
        print_info "Single GPU detected with $cpu_cores CPU cores"
        if [ $cpu_cores -gt 6 ]; then
            exec_agents=$((cpu_cores / 3))
            volumes_line=$(grep -n "^volumes:" compose.yml | cut -d: -f1)
            additional_exec=""
            for i in $(seq 2 $((exec_agents - 1))); do
                additional_agents+="  exec_agent$i:\n"
                additional_agents+="    <<: *exec-agent-common\n"
                additional_agents+="    mem_limit: 4G\n"
                additional_agents+="    cpus: 3\n"
                additional_agents+="    environment:\n"
                additional_agents+="      <<: *base-environment\n"
                additional_agents+="      RISC0_KECCAK_PO2: \${RISC0_KECCAK_PO2:-17}\n"
                additional_agents+="    entrypoint: /app/agent -t exec --segment-po2 \${SEGMENT_SIZE:-$segment_size}\n\n"
            done
            echo -e "$additional_exec" > temp.txt
            sed -i "$((volumes_line - 1)) r temp.txt" compose.yml
            rm temp.txt

            exec_agent_line=$(grep -n "- exec_agent1" compose.yml | cut -d: -f1)
            for i in $(seq 2 $((exec_agents - 1))); do
                sed -i "$exec_agent_line a \ \ \ \ - exec_agent$i" compose.yml
            done
            print_info "Added $((exec_agents - 2)) additional exec_agents for CPU utilization"
        fi
    fi

    if [ $gpu_count -eq 2 ]; then
        print_info "You have 2 GPUs. You can run either 2 provers on 2 different networks or utilize both GPUs for one prover on one network."
    elif [ $gpu_count -eq 3 ]; then
        print_info "You have 3 GPUs. You can run either 3 provers on 3 different networks or utilize all GPUs for one prover on one network."
    elif [ $gpu_count -gt 3 ]; then
        print_info "You have $gpu_count GPUs. You can either use one GPU per network across 3 networks (with one network getting 2 GPUs and the others 1 each) or utilize all GPUs for one prover on one network."
    fi

    print_success "compose.yml configured successfully"
}

clone_and_install() {
    print_step "Cloning Boundless repository..."
    git clone https://github.com/boundless-xyz/boundless
    cd boundless
    git checkout release-0.12
    print_success "Repository cloned and checked out to release-0.12"

    print_step "Replacing setup script..."
    rm scripts/setup.sh
    curl -o scripts/setup.sh https://raw.githubusercontent.com/Stevesv1/boundless-prover/refs/heads/main/script.sh
    chmod +x scripts/setup.sh
    sudo ./scripts/setup.sh
    print_success "Setup script executed"

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
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        local user_home="/home/$SUDO_USER"
        if [[ -d "$user_home/.cargo/bin" ]]; then
            export PATH="$user_home/.cargo/bin:$PATH"
        fi
    fi

    print_step "Installing Risc Zero..."
    curl -L https://risczero.com/install | bash
    export PATH="/root/.risc0/bin:$PATH"
    if [[ -d "$HOME/.rzup/bin" ]]; then
        export PATH="$HOME/.rzup/bin:$PATH"
    fi
    source "$HOME/.bashrc"
    if [[ -f "$HOME/.rzup/env" ]]; then
        source "$HOME/.rzup/env"
    fi
    if [[ -f "/root/.risc0/env" ]]; then
        source "/root/.risc0/env"
    fi
    if command -v rzup &> /dev/null; then
        rzup install rust
        rzup update r0vm
    else
        if [[ -x "/root/.risc0/bin/rzup" ]]; then
            /root/.risc0/bin/rzup install rust
            /root/.risc0/bin/rzup update r0vm
        else
            print_error "rzup installation failed"
            return 1
        fi
    fi
    print_success "Risc Zero installed"

    print_step "Installing additional tools..."
    if command -v cargo &> /dev/null; then
        cargo install --git https://github.com/risc0/risc0 bento-client --bin bento_cli
        if command -v just &> /dev/null; then
            just bento
        fi
        cargo install --locked boundless-cli
        print_success "Additional tools installed"
    else
        print_error "Cargo not available"
        return 1
    fi
}

configure_network() {
    print_step "Network Selection"
    echo -e "${PURPLE}Choose networks to run the prover on (comma-separated, e.g., 1,2):${NC}"
    echo "1. Base Mainnet"
    echo "2. Base Sepolia"
    echo "3. Ethereum Sepolia"
    read -p "Enter your choices: " network_choice

    selected_networks=()
    if [[ $network_choice == *"1"* ]]; then
        selected_networks+=("base")
    fi
    if [[ $network_choice == *"2"* ]]; then
        selected_networks+=("base-sepolia")
    fi
    if [[ $network_choice == *"3"* ]]; then
        selected_networks+=("eth-sepolia")
    fi

    if [ ${#selected_networks[@]} -eq 0 ]; then
        print_error "No networks selected"
        return 1
    fi

    print_info "Selected networks: ${selected_networks[*]}"
    for net in "${selected_networks[@]}"; do
        cp .env.broker-template .env.broker.$net
        print_info "Created .env.broker.$net"
    done
    print_success "Network configuration completed"
}

deposit_stake() {
    if [ ${#selected_networks[@]} -eq 0 ]; then
        print_error "No networks selected. Please configure network first."
        return 1
    fi

    read -p "Enter your private key: " private_key
    for net in "${selected_networks[@]}"; do
        case $net in
            "base")
                read -p "Enter Base Mainnet RPC URL: " rpc_url
                update_env_var ".env.broker.base" "PRIVATE_KEY" "$private_key"
                update_env_var ".env.broker.base" "RPC_URL" "$rpc_url"
                update_env_var ".env.broker.base" "BOUNDLESS_MARKET_ADDRESS" "0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8"
                update_env_var].env.broker.base" "SET_VERIFIER_ADDRESS" "0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"
                update_env_var ".env.broker.base" "ORDER_STREAM_URL" "https://base-mainnet.beboundless.xyz"
                boundless \
                    --rpc-url $rpc_url \
                    --private-key $private_key \
                    --chain-id 8453 \
                    --boundless-market-address 0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8 \
                    --set-verifier-address 0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760 \
                    account deposit-stake 10
                print_success "Configured and deposited stake on Base Mainnet"
                ;;
            "base-sepolia")
                read -p "Enter Base Sepolia RPC URL: " rpc_url
                update_env_var ".env.broker.base-sepolia" "PRIVATE_KEY" "$private_key"
                update_env_var ".env.broker.base-sepolia" "RPC_URL" "$rpc_url"
                update_env_var ".env.broker.base-sepolia" "BOUNDLESS_MARKET_ADDRESS" "0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b"
                update_env_var ".env.broker.base-sepolia" "SET_VERIFIER_ADDRESS" "0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"
                update_env_var ".env.broker.base-sepolia" "ORDER_STREAM_URL" "https://base-sepolia.beboundless.xyz"
                boundless \
                    --rpc-url $rpc_url \
                    --private-key $private_key \
                    --chain-id 84532 \
                    --boundless-market-address 0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b \
                    --set-verifier-address 0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760 \
                    account deposit-stake 10
                print_success "Configured and deposited stake on Base Sepolia"
                ;;
            "eth-sepolia")
                read -p "Enter Ethereum Sepolia RPC URL: " rpc_url
                update_env_var ".env.broker.eth-sepolia" "PRIVATE_KEY" "$private_key"
                update_env_var ".env.broker.eth-sepolia" "RPC_URL" "$rpc_url"
                update_env_var ".env.broker.eth-sepolia" "BOUNDLESS_MARKET_ADDRESS" "0x13337C76fE2d1750246B68781ecEe164643b98Ec"
                update_env_var ".env.broker.eth-sepolia" "SET_VERIFIER_ADDRESS" "0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64"
                update_env_var ".env.broker.eth-sepolia" "ORDER_STREAM_URL" "https://eth-sepolia.beboundless.xyz/"
                boundless \
                    --rpc-url $rpc_url \
                    --private-key $private_key \
                    --chain-id 11155111 \
                    --boundless-market-address 0x13337C76fE2d1750246B68781ecEe164643b98Ec \
                    --set-verifier-address 0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64 \
                    account deposit-stake 10
                print_success "Configured and deposited stake on Ethereum Sepolia"
                ;;
        esac
    done
    print_success "Stake deposits completed"
}

run_broker() {
    if [ ${#selected_networks[@]} -eq 0 ]; then
        print_error "No networks selected. Please configure network first."
        return 1
    fi

    for net in "${selected_networks[@]}"; do
        print_info "Starting broker for $net..."
        just broker up ./.env.broker.$net &
    done
    print_success "Brokers started for all selected networks"
}

full_installation() {
    clone_and_install
    configure_compose
    configure_network
    deposit_stake
    run_broker
}

if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi
if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
    user_home="/home/$SUDO_USER"
    if [[ -f "$user_home/.cargo/env" ]]; then
        source "$user_home/.cargo/env"
    fi
fi
if [[ -d "$HOME/.cargo/bin" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
    user_home="/home/$SUDO_USER"
    if [[ -d "$user_home/.cargo/bin" ]]; then
        export PATH="$user_home/.cargo/bin:$PATH"
    fi
fi

selected_networks=()

PS3="Use up/down arrow keys to navigate, then press Enter to select: "
options=("Configure compose.yml" "Clone and install packages" "Deposit stake" "Configure network" "Run broker" "Full installation" "Exit")
select opt in "${options[@]}"; do
    case $opt in
        "Configure compose.yml")
            configure_compose
            ;;
        "Clone and install packages")
            clone_and_install
            ;;
        "Deposit stake")
            deposit_stake
            ;;
        "Configure network")
            configure_network
            ;;
        "Run broker")
            run_broker
            ;;
        "Full installation")
            full_installation
            ;;
        "Exit")
            exit 0
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done
