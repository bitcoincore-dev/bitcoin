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

SIGNET_CHALLENGE=$(cat ./signetchallenge)
export SIGNET_CHALLENGE

# Ensure the data directory exists
mkdir -p "$SIGNET_DATADIR"

# Define executable paths relative to the current working directory
btcd="./bin/bitcoind -datadir=$SIGNET_DATADIR -chain=signet"
bcli="./bin/bitcoin-cli -datadir=$SIGNET_DATADIR"
miner="../contrib/signet/miner"
grinder="./bin/bitcoin-util grind"

##TIMESTAMP=0
### Note: Renaming files ensures you don't lose previous configurations.
##mkdir -p "$SIGNET_DATADIR-$TIMESTAMP"
##rsync -r "$SIGNET_DATADIR-0/bitcoin.conf" "$SIGNET_DATADIR-$TIMESTAMP/" 2>/dev/null
##rsync -r "$SIGNET_DATADIR-0/*" "$SIGNET_DATADIR-$TIMESTAMP/" 2>/dev/null
##rsync -r "$SIGNET_DATADIR-0/signet" "$SIGNET_DATADIR-$TIMESTAMP/signet" 2>/dev/null
##cat "$SIGNET_DATADIR-$TIMESTAMP/bitcoin.conf"

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


# 1. Execute the external tool and capture its output
weeble_raw=$(gnostr-weeble)

# 2. Declare 'weeble' as an integer variable.
# This forces the value to be treated as an integer for math operations.
# It's safer than using 'eval'.
declare -i weeble

# 3. Assign the raw output to the integer variable.
# Bash will attempt to convert the string to an integer during this assignment.
weeble=$weeble_raw

# Optional: Export the variable if needed by subprocesses
export weeble



echo "--- Phase 2: Starting Custom Signet and Miner Setup ---"

## pids=$(lsof -t -i :$((weeble+1))  )
## if [ -n "$pids" ]; then
##     echo "Found processes on port $((weeble+10)). Killing them now: $pids"
##    kill -9 $pids
## fi

#cp ./signet_data/signet/wallet $

for datadir in $(ls -d signet_data-*);do
pids=$(lsof -t -i :$((weeble+2))  )
if [ -n "$pids" ]; then
    echo "Found processes on port $((weeble+10)). Killing them now: $pids"
   kill -9 $pids
fi
./bin/bitcoin-qt \
-debug \
-min \
-listen=$((weeble -1)) \
-addnode=127.0.0.1:8080 \
-addnode=127.0.0.1:$((weeble-1)) \
-addnode=127.0.0.1:$((weeble-2)) \
-addnode=127.0.0.1:$((weeble)) \
-addnode=127.0.0.1:38332 \
-addnode=127.0.0.1:38333 \
-addnode=127.0.0.1:38334 \
-port=$((weeble +1 )) \
-signet \
-datadir=$datadir || { echo "Error: Failed to start bitcoind in Signet mode."; exit 1; } & sleep 3 &
weeble=$(( weeble + 1 ))
done
sleep 1
#exit;
##
./bin/bitcoin-qt \
-listen=$((weeble -1)) \
-addnode=127.0.0.1:8080 \
-addnode=127.0.0.1:$((weeble-1)) \
-addnode=127.0.0.1:$((weeble-2)) \
-addnode=127.0.0.1:$((weeble)) \
-addnode=127.0.0.1:$((weeble+1)) \
-addnode=127.0.0.1:$((weeble+2)) \
-addnode=127.0.0.1:$((weeble+3)) \
-addnode=127.0.0.1:38332 \
-addnode=127.0.0.1:38333 \
-addnode=127.0.0.1:38334 \
-port=$((weeble +1 )) \
-signet \
-daemon \
-signetchallenge=$SIGNET_CHALLENGE
#-datadir=$datadir || { echo "Error: Failed to start bitcoind in Signet mode."; exit 1; } & sleep 5

