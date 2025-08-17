#!/bin/bash

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m'

print_message() {
    echo -e "${BLUE}[INFO]${NC} $1"
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

# Check dependencies
print_message "Checking and installing dependencies..."

install_dependencies() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt-get update
        sudo apt-get install -y netcat lsof nodejs npm python3
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
}

# Verify all required commands are available
for cmd in nc lsof node npm python3; do
    if ! command -v $cmd &>/dev/null; then
        print_warning "$cmd not found, installing dependencies..."
        install_dependencies
        break
    fi
done

# Check rl-swarm directory
RL_SWARM_DIR="$PWD"
if [[ $(basename "$PWD") != "rl-swarm" ]]; then
    if [[ -d "$HOME/rl-swarm" ]]; then
        RL_SWARM_DIR="$HOME/rl-swarm"
        cd "$RL_SWARM_DIR" || exit 1
    else
        print_warning "Not in rl-swarm directory, using current directory: $PWD"
    fi
fi

# Install localtunnel if not found
if ! command -v lt &>/dev/null; then
    print_message "Installing localtunnel..."
    if ! npm install -g localtunnel; then
        print_error "Failed to install localtunnel"
        exit 1
    fi
fi

# Verify files exist
print_message "Checking required files..."
mkdir -p "$RL_SWARM_DIR/modal-login/temp-data"

declare -A files=(
    ["swarm.pem"]="$RL_SWARM_DIR/swarm.pem"
    ["userData.json"]="$RL_SWARM_DIR/modal-login/temp-data/userData.json"
    ["userApiKey.json"]="$RL_SWARM_DIR/modal-login/temp-data/userApiKey.json"
)

missing_files=()
for file in "${!files[@]}"; do
    if [[ ! -f "${files[$file]}" ]]; then
        missing_files+=("$file")
        print_warning "$file not found at ${files[$file]}"
    fi
done

if [[ ${#missing_files[@]} -eq 3 ]]; then
    print_error "No required files found! Please ensure files exist in:"
    echo -e "swarm.pem: $RL_SWARM_DIR/"
    echo -e "userData.json: $RL_SWARM_DIR/modal-login/temp-data/"
    echo -e "userApiKey.json: $RL_SWARM_DIR/modal-login/temp-data/"
    exit 1
fi

# Start HTTP server
find_available_port() {
    local port=8000
    while nc -z localhost $port &>/dev/null; do
        port=$((port + 1))
    done
    echo $port
}

PORT=$(find_available_port)
print_message "Starting HTTP server on port $PORT..."

python3 -m http.server "$PORT" > /tmp/http_server.log 2>&1 &
HTTP_SERVER_PID=$!

sleep 2
if ! ps -p $HTTP_SERVER_PID > /dev/null; then
    print_error "Failed to start HTTP server"
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
    print_error "Failed to get localtunnel URL"
    cat /tmp/localtunnel.log
    kill $HTTP_SERVER_PID
    exit 1
fi

print_success "Tunnel established at: ${GREEN}$TUNNEL_URL${NC}"
echo

# Display download instructions
echo -e "${GREEN}${BOLD}========== DOWNLOAD LINKS ===========${NC}"
for file in "${!files[@]}"; do
    if [[ -f "${files[$file]}" ]]; then
        echo -e "${BOLD}$file${NC}"
        if [[ "$file" == "swarm.pem" ]]; then
            echo -e "   ${BLUE}${TUNNEL_URL}/$file${NC}"
        else
            echo -e "   ${BLUE}${TUNNEL_URL}/modal-login/temp-data/$file${NC}"
        fi
        echo
    fi
done

echo -e "${GREEN}${BOLD}======= WGET COMMANDS ========${NC}"
for file in "${!files[@]}"; do
    if [[ -f "${files[$file]}" ]]; then
        if [[ "$file" == "swarm.pem" ]]; then
            echo -e "${YELLOW}wget -O $file ${TUNNEL_URL}/$file${NC}"
        else
            echo -e "${YELLOW}wget -O $file ${TUNNEL_URL}/modal-login/temp-data/$file${NC}"
        fi
    fi
done

echo
echo -e "${BLUE}${BOLD}Press Ctrl+C to stop servers when done${NC}"

# Cleanup on exit
trap 'cleanup' INT TERM EXIT

cleanup() {
    print_message "Stopping servers..."
    kill $HTTP_SERVER_PID 2>/dev/null
    kill $LOCALTUNNEL_PID 2>/dev/null
    print_success "Servers stopped"
    exit 0
}

wait
