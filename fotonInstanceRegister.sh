#!/bin/bash

# Auto-registering Pixel Streaming Instance Wrapper
# Usage: ./auto_register_instance.sh --player_port=80 --streamer_port=8888 --sfu_port=9888 --server_url=https://app.fotonlabs.com

set -e

# Default values
PLAYER_PORT=""
STREAMER_PORT=""
SFU_PORT=""
SERVER_URL="https://app.fotonlabs.com"
PUBLIC_IP=""
INSTANCE_ID=""
PING_INTERVAL=10
MAX_MISSED_PINGS=3
MISSED_PINGS=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

# Parse command line arguments and build passthrough args
PASSTHROUGH_ARGS=()

for arg in "$@"; do
    case $arg in
        --player_port=*)
            PLAYER_PORT="${arg#*=}"
            PASSTHROUGH_ARGS+=("$arg")  # Pass to underlying script
            ;;
        --streamer_port=*)
            STREAMER_PORT="${arg#*=}"
            PASSTHROUGH_ARGS+=("$arg")  # Pass to underlying script
            ;;
        --sfu_port=*)
            SFU_PORT="${arg#*=}"
            PASSTHROUGH_ARGS+=("$arg")  # Pass to underlying script
            ;;
        --server_url=*)
            SERVER_URL="${arg#*=}"
            # Don't pass server_url to underlying script
            ;;
        *)
            # Unknown option, pass through to start_with_turn.sh
            PASSTHROUGH_ARGS+=("$arg")
            ;;
    esac
done

# Validate required parameters
if [ -z "$PLAYER_PORT" ]; then
    log_error "Player port is required. Use --player_port=PORT"
    exit 1
fi

if [ -z "$STREAMER_PORT" ]; then
    log_error "Streamer port is required. Use --streamer_port=PORT"
    exit 1
fi

# Get public IP address
get_public_ip() {
    local ip=""
    
    # Try multiple services to get public IP
    for service in "http://checkip.amazonaws.com" "http://whatismyip.akamai.com" "http://ipecho.net/plain"; do
        ip=$(curl -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    log_error "Failed to get public IP address"
    return 1
}

# Register instance with the main server
register_instance() {
    local response
    local curl_exit_code
    
    log_info "🔗 Attempting to register with: ${SERVER_URL}/api/instances/register"
    
    response=$(curl -k -s -w "HTTP_CODE:%{http_code}" -X POST "${SERVER_URL}/api/instances/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"instanceId\": \"$INSTANCE_ID\",
            \"publicIP\": \"$PUBLIC_IP\",
            \"playerPort\": $PLAYER_PORT,
            \"streamerPort\": $STREAMER_PORT,
            \"sfuPort\": ${SFU_PORT:-0},
            \"timestamp\": $(date +%s)
        }" 2>&1)
    
    curl_exit_code=$?
    
    log_info "🔍 Curl exit code: $curl_exit_code"
    log_info "🔍 Full response: $response"
    
    if [ $curl_exit_code -ne 0 ]; then
        log_error "❌ Network error (curl exit code: $curl_exit_code)"
        log_error "📡 Check if server is running and accessible: $SERVER_URL"
        return 1
    fi
    
    # Extract HTTP code
    local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "🔍 HTTP Status: $http_code"
    log_info "🔍 Response body: $response_body"
    
    if [[ "$http_code" == "200" ]] && [[ $response_body == *"success"* ]]; then
        log "✅ Instance registered successfully: $INSTANCE_ID"
        return 0
    else
        log_error "❌ Failed to register instance"
        log_error "📊 HTTP Status: $http_code"
        log_error "📝 Response: $response_body"
        return 1
    fi
}

# Send health ping to server (with instance data for auto-registration)
send_ping() {
    local response
    response=$(curl -k -s -X POST "${SERVER_URL}/api/instances/ping" \
        -H "Content-Type: application/json" \
        -d "{
            \"instanceId\": \"$INSTANCE_ID\",
            \"timestamp\": $(date +%s),
            \"publicIP\": \"$PUBLIC_IP\",
            \"playerPort\": $PLAYER_PORT,
            \"streamerPort\": $STREAMER_PORT,
            \"sfuPort\": ${SFU_PORT:-0}
        }" 2>/dev/null)
    
    if [ $? -eq 0 ] && [[ $response == *"success"* ]]; then
        MISSED_PINGS=0
        
        # Check if instance was auto-registered from ping
        if [[ $response == *"autoRegistered\":true"* ]]; then
            log "🔄 Instance was auto-registered from ping (server restart detected)"
        fi
        
        log_info "💓 Ping sent successfully"
        return 0
    else
        ((MISSED_PINGS++))
        log_warn "⚠️  Ping failed (${MISSED_PINGS}/${MAX_MISSED_PINGS}): $response"
        return 1
    fi
}

# Unregister instance from server
unregister_instance() {
    log_info "🧹 Unregistering instance..."
    curl -k -s -X DELETE "${SERVER_URL}/api/instances/unregister" \
        -H "Content-Type: application/json" \
        -d "{\"instanceId\": \"$INSTANCE_ID\"}" >/dev/null 2>&1
    log "👋 Instance unregistered: $INSTANCE_ID"
}

# Cleanup function
cleanup() {
    log_warn "🛑 Shutting down..."
    unregister_instance
    
    # Kill the signalling server process
    if [ ! -z "$SIGNALLING_PID" ]; then
        log_info "Stopping signalling server (PID: $SIGNALLING_PID)"
        kill $SIGNALLING_PID 2>/dev/null || true
        wait $SIGNALLING_PID 2>/dev/null || true
    fi
    
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM EXIT

# Main execution
main() {
    log "🚀 Starting Auto-Registering Pixel Streaming Instance"
    log_info "Player Port: $PLAYER_PORT"
    log_info "Streamer Port: $STREAMER_PORT"
    log_info "SFU Port: ${SFU_PORT:-'Not set'}"
    log_info "Server URL: $SERVER_URL"
    
    # Get public IP
    log_info "🌐 Getting public IP address..."
    PUBLIC_IP=$(get_public_ip)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    log "📍 Public IP: $PUBLIC_IP"
    
    # Generate unique instance ID
    INSTANCE_ID="ps-$(hostname)-${PLAYER_PORT}-$(date +%s)"
    log "🏷️  Instance ID: $INSTANCE_ID"
    
    # Register with main server
    log_info "📝 Registering instance..."
    register_instance
    if [ $? -ne 0 ]; then
        log_error "Failed to register instance. Exiting."
        exit 1
    fi
    
    # Start the signalling server in background
    log "🎬 Starting signalling server..."
    log_info "🔧 Passing arguments to start_with_turn.sh: ${PASSTHROUGH_ARGS[*]}"
    ./start_with_turn.sh "${PASSTHROUGH_ARGS[@]}" &
    SIGNALLING_PID=$!
    
    log "✅ Signalling server started (PID: $SIGNALLING_PID)"
    log_info "Instance URL: ws://${PUBLIC_IP}:${PLAYER_PORT}"
    
    # Health monitoring loop
    log "💓 Starting health monitoring (ping every ${PING_INTERVAL}s)..."
    
    while true; do
        sleep $PING_INTERVAL
        
        # Check if signalling server is still running
        if ! kill -0 $SIGNALLING_PID 2>/dev/null; then
            log_error "💀 Signalling server process died!"
            break
        fi
        
        # Send health ping
        send_ping
        
        # Check if we've missed too many pings
        if [ $MISSED_PINGS -ge $MAX_MISSED_PINGS ]; then
            log_error "💔 Too many missed pings (${MISSED_PINGS}). Main server might be down."
            log_warn "⏳ Continuing to run but will stop pinging..."
            
            # Continue running but stop health checks until server is back
            while ! send_ping; do
                sleep 30
                log_info "🔄 Attempting to reconnect to main server..."
            done
            
            log "🎉 Reconnected to main server! Resuming health checks..."
        fi
    done
}

# Run main function
main "$@"