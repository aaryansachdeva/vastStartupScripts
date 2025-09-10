#!/bin/bash

# Simple test script to verify port mapping
echo "Testing Vast.ai port mapping..."

# Test function - clean, no logging
get_external_port_clean() {
    local internal_port=$1
    local vast_port_var="VAST_TCP_PORT_${internal_port}"
    local external_port=${!vast_port_var}
    
    if [ -n "$external_port" ]; then
        echo "$external_port"
    else
        echo "$internal_port" 
    fi
}

PLAYER_PORT=80
STREAMER_PORT=8888
SFU_PORT=9888

echo "Environment variables:"
echo "PUBLIC_IPADDR: ${PUBLIC_IPADDR:-'not set'}"
echo "VAST_TCP_PORT_80: ${VAST_TCP_PORT_80:-'not set'}"
echo "VAST_TCP_PORT_8888: ${VAST_TCP_PORT_8888:-'not set'}"

echo ""
echo "Port mapping test:"
EXTERNAL_PLAYER_PORT=$(get_external_port_clean $PLAYER_PORT)
echo "Player: $PLAYER_PORT → $EXTERNAL_PLAYER_PORT"

echo ""
echo "JSON test:"
cat << EOF
{
    "instanceId": "test-instance",
    "publicIP": "${PUBLIC_IPADDR:-127.0.0.1}",
    "playerPort": $EXTERNAL_PLAYER_PORT,
    "streamerPort": $STREAMER_PORT,
    "sfuPort": $SFU_PORT,
    "timestamp": $(date +%s)
}
EOF