#!/bin/bash

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m'

print_message() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check dependencies
check_dependencies() {
    print_message "Checking dependencies..."
    local missing=()
    
    for cmd in nc lsof node npm python3; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_warning "Missing dependencies: ${missing[*]}"
        install_dependencies
    fi
}

install_dependencies() {
    print_message "Installing dependencies..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt-get update
        sudo apt-get install -y netcat-openbsd lsof nodejs npm python3
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if ! command -v brew &>/dev/null; then
            print_error "Homebrew not found. Please install it first."
            exit 1
        fi
        brew install netcat lsof node python
    else
        print_error "Unsupported OS: $OSTYPE"
        exit 1
    fi
    
    # Install localtunnel globally
    if ! npm install -g localtunnel; then
        print_error "Failed to install localtunnel"
        exit 1
    fi
}

# File location handling
locate_files() {
    declare -A files=(
        ["swarm.pem"]="$RL_SWARM_DIR/swarm.pem"
        ["userData.json"]="$RL_SWARM_DIR/modal-login/temp-data/userData.json"
        ["userApiKey.json"]="$RL_SWARM_DIR/modal-login/temp-data/userApiKey.json"
    )
    
    # Search in common alternative locations
    declare -A alt_locations=(
        ["swarm.pem"]=("$HOME/swarm.pem" "/tmp/swarm.pem")
        ["userData.json"]=("$HOME/modal-login/temp-data/userData.json" "$HOME/userData.json")
        ["userApiKey.json"]=("$HOME/modal-login/temp-data/userApiKey.json" "$HOME/userApiKey.json")
    )
    
    # Create directory structure if it doesn't exist
    mkdir -p "$RL_SWARM_DIR/modal-login/temp-data"
    
    for file in "${!files[@]}"; do
        if [[ ! -f "${files[$file]}" ]]; then
            print_warning "${files[$file]} not found"
            
            # Check alternative locations
            for alt in "${alt_locations[$file][@]}"; do
                if [[ -f "$alt" ]]; then
                    print_message "Found $file at $alt"
                    cp "$alt" "${files[$file]}"
                    print_success "Copied $file to ${files[$file]}"
                    break
                fi
            done
            
            # If still not found, ask user
            if [[ ! -f "${files[$file]}" ]]; then
                read -p "Enter path to $file (or press Enter to skip): " custom_path
                if [[ -n "$custom_path" && -f "$custom_path" ]]; then
                    cp "$custom_path" "${files[$file]}"
                    print_success "Copied $file to ${files[$file]}"
                else
                    print_warning "Skipping $file"
                fi
            fi
        fi
    done
    
    # Verify at least one file exists
    local count=0
    for file in "${!files[@]}"; do
        if [[ -f "${files[$file]}" ]]; then
            ((count++))
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        print_error "No required files found! Please ensure at least one file exists."
        echo "Possible locations:"
        echo "1. swarm.pem: $RL_SWARM_DIR/ or $HOME/"
        echo "2. userData.json: $RL_SWARM_DIR/modal-login/temp-data/ or $HOME/"
        echo "3. userApiKey.json: $RL_SWARM_DIR/modal-login/temp-data/ or $HOME/"
        exit 1
    fi
}

# Main script execution
RL_SWARM_DIR="$PWD"
if [[ $(basename "$PWD") != "rl-swarm" ]]; then
    if [[ -d "$HOME/rl-swarm" ]]; then
        RL_SWARM_DIR="$HOME/rl-swarm"
    else
        mkdir -p "$HOME/rl-swarm"
        RL_SWARM_DIR="$HOME/rl-swarm"
    fi
fi

cd "$RL_SWARM_DIR" || exit 1

check_dependencies
locate_files

# Start HTTP server
PORT=8000
while nc -z localhost $PORT &>/dev/null; do
    ((PORT++))
done

print_message "Starting HTTP server on port $PORT..."
python3 -m http.server "$PORT" > /tmp/http_server.log 2>&1 &
HTTP_SERVER_PID=$!

sleep 2
if ! ps -p $HTTP_SERVER_PID &>/dev/null; then
    print_error "Failed to start HTTP server:"
    cat /tmp/http_server.log
    exit 1
fi

# Start localtunnel
print_message "Starting localtunnel..."
lt --port "$PORT" > /tmp/localtunnel.log 2>&1 &
LOCALTUNNEL_PID=$!

sleep 5

TUNNEL_URL=$(grep -o 'https://[^ ]*\.loca\.lt' /tmp/localtunnel.log | head -n 1)
if [[ -z "$TUNNEL_URL" ]]; then
    print_error "Failed to get localtunnel URL:"
    cat /tmp/localtunnel.log
    kill $HTTP_SERVER_PID
    exit 1
fi

# Display results
clear
print_success "File sharing server is running!"
echo -e "\n${BOLD}Access your files at:${NC}"
for file in swarm.pem userData.json userApiKey.json; do
    if [[ -f "$RL_SWARM_DIR/$file" ]]; then
        echo -e "${BLUE}${TUNNEL_URL}/$file${NC}"
    elif [[ -f "$RL_SWARM_DIR/modal-login/temp-data/$file" ]]; then
        echo -e "${BLUE}${TUNNEL_URL}/modal-login/temp-data/$file${NC}"
    fi
done

echo -e "\n${BOLD}Download commands:${NC}"
for file in swarm.pem userData.json userApiKey.json; do
    if [[ -f "$RL_SWARM_DIR/$file" ]]; then
        echo -e "${YELLOW}wget ${TUNNEL_URL}/$file${NC}"
    elif [[ -f "$RL_SWARM_DIR/modal-login/temp-data/$file" ]]; then
        echo -e "${YELLOW}wget ${TUNNEL_URL}/modal-login/temp-data/$file${NC}"
    fi
done

echo -e "\n${BOLD}Press Ctrl+C to stop the server${NC}"

# Cleanup function
cleanup() {
    print_message "\nStopping servers..."
    kill $HTTP_SERVER_PID 2>/dev/null
    kill $LOCALTUNNEL_PID 2>/dev/null
    print_success "Servers stopped. Goodbye!"
    exit 0
}

trap cleanup INT TERM EXIT
wait
