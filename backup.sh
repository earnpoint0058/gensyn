#!/bin/bash

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m'

print_message() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_message "Checking and installing dependencies (nc and lsof)..."

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if ! command -v nc &>/dev/null || ! command -v lsof &>/dev/null; then
        print_message "Installing netcat and lsof..."
        sudo apt-get update
        sudo apt-get install -y netcat lsof
        if ! command -v nc &>/dev/null || ! command -v lsof &>/dev/null; then
            print_error "Failed to install netcat or lsof. Please install them manually."
            exit 1
        fi
        print_success "Dependencies installed successfully."
    else
        print_success "Dependencies already installed."
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    if ! command -v nc &>/dev/null || ! command -v lsof &>/dev/null; then
        if command -v brew &>/dev/null; then
            print_message "Installing netcat and lsof via Homebrew..."
            brew install netcat lsof
        else
            print_error "Homebrew not found. Please install netcat and lsof manually."
            exit 1
        fi
    fi
    print_success "Dependencies installed successfully."
else
    print_warning "Unsupported OS for automatic dependency installation. Ensure nc and lsof are installed."
fi

print_message "Checking rl-swarm directory..."

if [[ $(basename "$PWD") == "rl-swarm" ]]; then
    RL_SWARM_DIR="$PWD"
    print_success "Currently in rl-swarm directory."
elif [[ -d "$HOME/rl-swarm" ]]; then
    RL_SWARM_DIR="$HOME/rl-swarm"
    print_success "Found rl-swarm directory in HOME."
else
    print_error "rl-swarm directory not found in current directory or HOME."
    exit 1
fi

cd "$RL_SWARM_DIR" || exit 1

print_message "Checking cloudflared..."

ARCH=$(uname -m)
case $ARCH in
    x86_64) CLOUDFLARED_ARCH="amd64" ;;
    aarch64|arm64) CLOUDFLARED_ARCH="arm64" ;;
    *) print_error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

if ! command -v cloudflared &>/dev/null; then
    print_message "Installing cloudflared for $ARCH architecture..."
    mkdir -p /tmp/cloudflared-install && cd /tmp/cloudflared-install || exit 1
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}.deb" -o cloudflared.deb
        sudo dpkg -i cloudflared.deb || sudo apt-get install -f -y
        if ! command -v cloudflared &>/dev/null; then
            curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}" -o cloudflared
            chmod +x cloudflared && sudo mv cloudflared /usr/local/bin/
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            brew install cloudflared
        else
            curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${CLOUDFLARED_ARCH}.tgz" -o cloudflared.tgz
            tar -xzf cloudflared.tgz
            chmod +x cloudflared && sudo mv cloudflared /usr/local/bin/
        fi
    fi
    cd "$RL_SWARM_DIR" || exit 1
    command -v cloudflared &>/dev/null || { print_error "Failed to install cloudflared. Install manually."; exit 1; }
    print_success "cloudflared installation completed successfully."
else
    print_success "cloudflared is already installed."
fi

print_message "Checking python3..."
if ! command -v python3 &>/dev/null; then
    print_message "Installing python3..."
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt-get update && sudo apt-get install -y python3 python3-pip
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        command -v brew &>/dev/null && brew install python || { print_error "Homebrew not found. Install python3 manually."; exit 1; }
    fi
fi
command -v python3 &>/dev/null || { print_error "Failed to install python3. Install manually."; exit 1; }
print_success "python3 is available."

print_message "Starting HTTP server..."

PORT=8000
MAX_RETRIES=10
RETRY_COUNT=0
SERVER_STARTED=false
HTTP_SERVER_PID=""
CLOUDFLARED_PID=""

is_port_in_use() {
    nc -z localhost "$1" &>/dev/null || lsof -i:"$1" &>/dev/null
}

start_http_server() {
    local port="$1"
    local log="/tmp/http_server_$$.log"
    python3 -m http.server "$port" >"$log" 2>&1 &
    HTTP_SERVER_PID=$!
    sleep 3
    if ps -p "$HTTP_SERVER_PID" &>/dev/null; then
        print_success "HTTP server started successfully on port $port."
        return 0
    else
        grep -q "Address already in use" "$log" && return 1
        print_error "HTTP server failed on port $port:"
        cat "$log"
        return 1
    fi
}

while [[ $RETRY_COUNT -lt $MAX_RETRIES && $SERVER_STARTED == false ]]; do
    print_message "Attempting to start HTTP server on port $PORT..."
    if is_port_in_use "$PORT"; then
        print_warning "Port $PORT in use. Trying next..."
        ((PORT++)); ((RETRY_COUNT++))
        continue
    fi

    if start_http_server "$PORT"; then
        print_message "Starting cloudflared tunnel..."
        cloudflared tunnel --url "http://localhost:$PORT" > /tmp/cloudflared_$$.log 2>&1 &
        CLOUDFLARED_PID=$!
        sleep 10
        TUNNEL_URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' /tmp/cloudflared_$$.log | sed 's/\r//g' | head -n 1)
        if [[ -n "$TUNNEL_URL" ]]; then
            print_success "Cloudflare tunnel established: $TUNNEL_URL"
            SERVER_STARTED=true
        else
            print_error "Failed to establish tunnel. Retrying..."
            [[ -n "$HTTP_SERVER_PID" ]] && kill "$HTTP_SERVER_PID" 2>/dev/null
            [[ -n "$CLOUDFLARED_PID" ]] && kill "$CLOUDFLARED_PID" 2>/dev/null
            ((PORT++)); ((RETRY_COUNT++))
        fi
    else
        ((PORT++)); ((RETRY_COUNT++))
    fi
done

[[ $SERVER_STARTED == false ]] && { print_error "Failed to start after $MAX_RETRIES attempts."; exit 1; }

echo
echo -e "${GREEN}${BOLD}========== VPS/GPU/WSL to PC ===========${NC}"
echo -e "${BOLD}Download files using these URLs:${NC}"
echo -e "1. swarm.pem          ${BLUE}${TUNNEL_URL}/swarm.pem${NC}"
echo -e "2. userData.json      ${BLUE}${TUNNEL_URL}/modal-login/temp-data/userData.json${NC}"
echo -e "3. userApiKey.json    ${BLUE}${TUNNEL_URL}/modal-login/temp-data/userApiKey.json${NC}"
echo
echo -e "${GREEN}${BOLD}======= One VPS/GPU/WSL to Another =======${NC}"
echo -e "${YELLOW}wget -O swarm.pem ${TUNNEL_URL}/swarm.pem${NC}"
echo -e "${YELLOW}wget -O userData.json ${TUNNEL_URL}/modal-login/temp-data/userData.json${NC}"
echo -e "${YELLOW}wget -O userApiKey.json ${TUNNEL_URL}/modal-login/temp-data/userApiKey.json${NC}"
echo
echo -e "${BLUE}${BOLD}Press Ctrl+C to stop.${NC}"

# Cleanup on exit
trap 'print_warning "Stopping servers..."; [[ -n "$HTTP_SERVER_PID" ]] && kill "$HTTP_SERVER_PID" 2>/dev/null; [[ -n "$CLOUDFLARED_PID" ]] && kill "$CLOUDFLARED_PID" 2>/dev/null; print_success "Servers stopped."; exit 0' INT
wait
