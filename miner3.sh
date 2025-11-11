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
mkdir -p "$SIGNET_DATADIR-$TIMESTAMP"
rsync -r "$SIGNET_DATADIR/bitcoin.conf" "$SIGNET_DATADIR-$TIMESTAMP/" 2>/dev/null
rsync -r "$SIGNET_DATADIR/*" "$SIGNET_DATADIR-$TIMESTAMP/" 2>/dev/null
rsync -r "$SIGNET_DATADIR/signet" "$SIGNET_DATADIR-$TIMESTAMP/signet" 2>/dev/null
cat "$SIGNET_DATADIR-$TIMESTAMP/bitcoin.conf"

# --- 4. Phase 2: Signet Execution and Mining Setup ---

echo "--- Phase 2: Starting Custom Signet and Miner Setup ---"

# Start bitcoind in Signet mode as a daemon
echo "Starting bitcoind in Signet mode as a daemon..."
./bin/bitcoin-qt -port=8080 -signet -daemon -datadir=$SIGNET_DATADIR-$TIMESTAMP || { echo "Error: Failed to start bitcoind in Signet mode."; exit 1; }
sleep 5
