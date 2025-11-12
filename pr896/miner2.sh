#!/bin/bash
set -x
#
# Script to set up a custom Signet network, generate a challenge, 
# start the daemon, create a wallet, and start a local miner.
#

# --- 1. Setup and Cleanup ---

# Define the data directory path
SIGNET_DATADIR="./signet_data"
export SIGNET_DATADIR

# Ensure the data directory exists
mkdir -p "$SIGNET_DATADIR"

# Define executable paths relative to the current working directory
btcd="./bin/bitcoind -datadir=$SIGNET_DATADIR"
bcli="./bin/bitcoin-cli -datadir=$SIGNET_DATADIR"
miner="../contrib/signet/miner"
grinder="./bin/bitcoin-util grind"

# Cleanup old configuration/data files for a fresh start (Crucial for debugging)
echo "Archiving old configuration and data files..."
TIMESTAMP=$(date +%s)
# Note: Renaming files ensures you don't lose previous configurations.
mv "$SIGNET_DATADIR/bitcoin.conf" "$SIGNET_DATADIR/bitcoin-$TIMESTAMP.conf" 2>/dev/null
mv "$SIGNET_DATADIR/signet/peers.dat" "$SIGNET_DATADIR/signet/peers-$TIMESTAMP.dat" 2>/dev/null
mv "$SIGNET_DATADIR/regtest" "$SIGNET_DATADIR/regtest-$TIMESTAMP" 2>/dev/null

# Explicitly remove wallet directories to ensure a clean start
echo "Removing existing wallet directories if they exist..."
rm -rf "$SIGNET_DATADIR/regtest/wallets/signer" 2>/dev/null
rm -rf "$SIGNET_DATADIR/signet/wallets/miner" 2>/dev/null


# --- 2. Phase 1: Regtest Setup (Generate Signet Challenge) ---

echo "--- Phase 1: Generating Signet Challenge using Regtest ---"

# 1. Stop any potentially running bitcoind processes (using the default regtest port 18443)
echo "Checking for and stopping any residual bitcoind processes..."
pids=$(lsof -t -i :18443)
if [ -n "$pids" ]; then
    echo "Found processes on port 18443. Killing them now: $pids"
    kill -9 $pids
fi
pids=$(lsof -t -i :18444)
if [ -n "$pids" ]; then
    echo "Found processes on port 18443. Killing them now: $pids"
    kill -9 $pids
fi
pids=$(lsof -t -i :18332)
if [ -n "$pids" ]; then
    echo "Found processes on port 18443. Killing them now: $pids"
    kill -9 $pids
fi
pids=$(lsof -t -i :38333)
if [ -n "$pids" ]; then
    echo "Found processes on port 18443. Killing them now: $pids"
    kill -9 $pids
fi
pids=$(lsof -t -i :38334)
if [ -n "$pids" ]; then
    echo "Found processes on port 18443. Killing them now: $pids"
    kill -9 $pids
fi


# 2. Check for the lock file in your Regtest directory (which is temporarily the main data directory)
LOCK_FILE="$SIGNET_DATADIR/.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "Lock file found: $LOCK_FILE. Removing it now."
    rm "$LOCK_FILE"
else
    echo "No lock file found."
fi

# Start bitcoind in Regtest mode as a daemon
echo "Starting bitcoind in regtest mode..."
$btcd -regtest -daemon || { echo "Error: Failed to start bitcoind in regtest mode."; exit 1; }
sleep 5

# Wait until the daemon is ready for RPC calls
MAX_RETRIES=10
RETRY_COUNT=0
while ! $bcli -regtest getblockchaininfo 2>/dev/null; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "Error: bitcoind failed to start after $MAX_RETRIES attempts."
        exit 1
    fi
    echo "Waiting for regtest daemon... (Attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

# Create a temporary 'signer' wallet
echo "Creating temporary 'signer' wallet..."
$bcli -regtest createwallet "signer"

# Extract descriptors for later import
echo "Extracting descriptors..."
DESCRIPTORS=$($bcli -regtest listdescriptors true | jq -r .descriptors)
echo "Descriptors: $DESCRIPTORS"

# Generate a new address and get its scriptPubKey for the challenge
ADDR=$($bcli -regtest -named getnewaddress address_type="bech32")
echo "Temporary Regtest Address: $ADDR"

SIGNET_CHALLENGE=$($bcli -regtest -named getaddressinfo "$ADDR" | jq -r .scriptPubKey)
echo "Generated SIGNET_CHALLENGE (scriptPubKey): $SIGNET_CHALLENGE"

# Stop the regtest daemon gracefully
echo "Stopping regtest daemon..."
$bcli -regtest stop
sleep 5 # Wait for shutdown

# --- 3. Write Custom Signet Configuration ---

echo "Writing new bitcoin.conf for custom Signet..."
cat <<EOF > "$SIGNET_DATADIR/bitcoin.conf"
rpcuser=signetuser
rpcpassword=signetpassword
signet=1
[signet]
rpcport=38332
add-node=8080
daemon=1
signetchallenge=$SIGNET_CHALLENGE
EOF

cat "$SIGNET_DATADIR/bitcoin.conf"

# --- 4. Phase 2: Signet Execution and Mining Setup ---

echo "--- Phase 2: Starting Custom Signet and Miner Setup ---"

# Start bitcoind in Signet mode as a daemon
echo "Starting bitcoind in Signet mode as a daemon..."
$btcd -signet -daemon || { echo "Error: Failed to start bitcoind in Signet mode."; exit 1; }
sleep 5

# Robust check for Signet daemon readiness
MAX_RETRIES=10
RETRY_COUNT=0
while ! $bcli -signet getblockchaininfo 2>/dev/null; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "Error: Signet bitcoind failed to start after $MAX_RETRIES attempts."
        exit 1
    fi
    echo "Waiting for Signet daemon... (Attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

# Create and load the 'miner' wallet
echo "Creating and loading 'miner' wallet..."
# Use -signet and the RPC is already configured via the config file
$bcli -signet createwallet "miner"

# Import the descriptors (keys) from the regtest wallet into the new miner wallet
echo "Importing descriptors into 'miner' wallet..."
$bcli -signet -rpcwallet=miner importdescriptors "$DESCRIPTORS"

# Generate a mining address from the 'miner' wallet
MINER_ADDR=$($bcli -signet -rpcwallet=miner -named getnewaddress address_type="bech32")
echo "Miner Block Reward Address: $MINER_ADDR"

# --- 5. Start Mining ---

echo "Generating initial block with custom nBits..."
$miner --cli "$bcli" generate --address "$MINER_ADDR" --grind-cmd "$grinder" --min-nbits --set-block-time $(date +%s) && sleep 10

# Start ongoing mining loop
echo "Starting ongoing mining loop..."
$miner --cli "$bcli" generate --address "$MINER_ADDR" --grind-cmd "$grinder" --min-nbits --ongoing
