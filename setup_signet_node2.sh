#!/bin/bash
set -x

# --- Configuration for the second Signet node ---

# Paths to executables (assuming they are in ./bin relative to the script)
BITCOIND_PATH="./bin/bitcoind"
BITCOIN_CLI_PATH="./bin/bitcoin-cli"

# Data directory for the second node
NODE2_DATADIR="./signet_data_node2"

# RPC and P2P ports for the second node (must be different from the first node)
NODE2_RPC_PORT="38334"
NODE2_P2P_PORT="38335"
NODE2_RPC_USER="signetuser2"
NODE2_RPC_PASSWORD="signetpassword2"

# Configuration of the first node (miner)
NODE1_DATADIR="./signet_data"
NODE1_RPC_PORT="38332" # As defined in miner2.sh
NODE1_P2P_PORT="38333" # Default signet P2P port, not explicitly set in miner2.sh conf

# --- 1. Read Signet Challenge from the first node's configuration ---

NODE1_CONF_PATH="$NODE1_DATADIR/bitcoin.conf"

if [ ! -f "$NODE1_CONF_PATH" ]; then
    echo "Error: First node's configuration file not found at $NODE1_CONF_PATH."
    echo "Please ensure miner2.sh has been run successfully."
    exit 1
fi

# Extract the signetchallenge value. Using grep and cut to parse the line.
SIGNET_CHALLENGE=$(grep "signetchallenge=" "$NODE1_CONF_PATH" | cut -d' -f2)

if [ -z "$SIGNET_CHALLENGE" ]; then
    echo "Error: Could not extract signetchallenge from $NODE1_CONF_PATH."
    exit 1
fi

echo "Successfully extracted Signet Challenge: $SIGNET_CHALLENGE"

# --- 2. Setup Data Directory for the Second Node ---

echo "Creating data directory for the second node: $NODE2_DATADIR"
mkdir -p "$NODE2_DATADIR"

# --- 3. Create bitcoin.conf for the Second Node ---

echo "Creating bitcoin.conf for the second node..."
# Mimicking the structure from miner2.sh for bitcoin.conf
cat <<EOF > "$NODE2_DATADIR/bitcoin.conf"
rpcuser=$NODE2_RPC_USER
rpcpassword=$NODE2_RPC_PASSWORD
signet=1
[signet]
rpcport=$NODE2_RPC_PORT
port=$NODE2_P2P_PORT
signetchallenge=$SIGNET_CHALLENGE
EOF

# Add the connect directive to link to the first node's P2P port
echo "connect=127.0.0.1:$NODE1_P2P_PORT" >> "$NODE2_DATADIR/bitcoin.conf"
echo "daemon=1" >> "$NODE2_DATADIR/bitcoin.conf"

echo "Configuration written to $NODE2_DATADIR/bitcoin.conf:"
cat "$NODE2_DATADIR/bitcoin.conf"

# --- 4. Start the Second Node Daemon ---

echo "Starting bitcoind for the second node in Signet mode..."
$BITCOIND_PATH -signet -datadir="$NODE2_DATADIR" -conf="$NODE2_DATADIR/bitcoin.conf" -daemon || { echo "Error: Failed to start bitcoind for the second node."; exit 1; }

echo "Second Signet node started. Waiting for it to sync..."

# --- 5. Verification (Optional but recommended) ---
# Wait for the daemon to be ready for RPC calls
MAX_RETRIES=20
RETRY_COUNT=0
while ! $BITCOIN_CLI_PATH -datadir="$NODE2_DATADIR" -rpcport="$NODE2_RPC_PORT" getblockchaininfo 2>/dev/null; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "Error: Second Signet node failed to start or become ready after $MAX_RETRIES attempts."
        exit 1
    fi
    echo "Waiting for second Signet node daemon... (Attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 3
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

echo "Second Signet node is running and ready."
echo "You can check its status with: $BITCOIN_CLI_PATH -datadir='$NODE2_DATADIR' -rpcport='$NODE2_RPC_PORT' getblockchaininfo"
echo "You can also connect to it using: $BITCOIN_CLI_PATH -datadir='$NODE2_DATADIR' -rpcport='$NODE2_RPC_PORT' <command>"

exit 0
