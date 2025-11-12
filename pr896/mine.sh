ln -sf /Users/git/Library/Application\ Support /Users/git/Library/Application_Support
#ls /Users/git/Library/Application_Support/Bitcoin/
ls /Users/git/Library/Application_Support/Signet/
#ls /Users/git/Library/Application_Support/Bitcoin/signet/
#cat /Users/git/Library/Application_Support/Bitcoin/bitcoin.conf
cat /Users/git/Library/Application_Support/Signet/bitcoin.conf
mv /Users/git/Library/Application_Support/Signet/bitcoin.conf /Users/git/Library/Application_Support/Signet/bitcoin-$(date +%s).conf
mv /Users/git/Library/Application_Support/Signet/signet/peers.dat /Users/git/Library/Application_Support/Signet/signet/peers-$(date +%s).dat
mv /Users/git/Library/Application_Support/Signet/regtest /Users/git/Library/Application_Support/Signet/regtest-$(date +%s)
# Bitcoin client
SIGNET_DATADIR="/Users/git/Library/Application_Support/Signet/"
export SIGNET_DATADIR
mkdir -p $SIGNET_DATADIR
btcd="./bin/bitcoind -datadir=$SIGNET_DATADIR"

ls /Users/git/Library/Application_Support/Signet

# Bitcoin CLI
bcli="./bin/bitcoin-cli -datadir=$SIGNET_DATADIR"

# Mining script
miner="../contrib/signet/miner"

# Bitcoin-util, a tool that computes proof of work
grinder="./bin/bitcoin-util grind"

# datadir cleanup, in case we need to start the network from scratch
miner_datadir_cleanup="rm $SIGNET_DATADIR; mkdir $SIGNET_DATADIR"

$btcd -regtest -daemon && echo "sleep 10" && sleep 10
$bcli -regtest createwallet "signer"
DESCRIPTORS=$($bcli -regtest listdescriptors true | jq -r .descriptors)
echo $DESCRIPTORS
ADDR=$($bcli -regtest -named getnewaddress address_type="bech32")
echo $ADDR
SIGNET_CHALLENGE=$($bcli -regtest -named getaddressinfo $ADDR | jq -r .scriptPubKey)
echo $SIGNET_CHALLENGE
$bcli -regtest stop

#exit;

echo "
rpcuser=signetuser
rpcpassword=signetpassword
signet=1
[signet]
rpcport=38332
daemon=1
signetchallenge=$SIGNET_CHALLENGE" > $SIGNET_DATADIR/bitcoin.conf

cat /Users/git/Library/Application_Support/Signet/bitcoin.conf

#exit;

(\
$btcd -signet; sleep 5;
#./bin/bitcoin-qt --datadir="/Users/git/Library/Application_Support/Signet/"; sleep 10;
)

$bcli createwallet "miner"
$bcli importdescriptors "$DESCRIPTORS"

echo "Checking for remaining bitcoind processes..."
pids=$(lsof -t -i :38332)
if [ -n "$pids" ]; then
    echo "Found processes using port 38332. Killing them now: $pids"
    kill -9 $pids
else
    echo "No bitcoind process found on port 38332."
fi

(\
$btcd; sleep 5;
##./bin/bitcoin-qt --datadir="/Users/git/Library/Application_Support/Signet/"; sleep 1;
)
$bcli loadwallet "miner"

#$bcli -signet stop
#exit;

#$bcli --signet --datadir=/Users/git/Library/Application_Support/Signet/ loadwallet "miner"

#./bin/bitcoin-qt --datadir=/Users/git/Library/Application_Support/Signet --signet 

MINER_ADDR=$($bcli -rpcwallet=miner -named getnewaddress address_type="bech32")
$miner --cli "$bcli" generate --address $MINER_ADDR --grind-cmd "grinder" --min-nbits --set-block-time $(date +%s) && sleep 10
$miner --cli "$bcli" generate --address $MINER_ADDR --grind-cmd "grinder" --min-nbits --ongoing

