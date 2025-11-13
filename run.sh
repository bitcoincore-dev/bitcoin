ln -sf /Users/git/Library/Application\ Support /Users/git/Library/Application_Support
#ls /Users/git/Library/Application_Support/Bitcoin/
ls /Users/git/Library/Application_Support/Signet/
#ls /Users/git/Library/Application_Support/Bitcoin/signet/
#cat /Users/git/Library/Application_Support/Bitcoin/bitcoin.conf
cat /Users/git/Library/Application_Support/Signet/bitcoin.conf
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

cat /Users/git/Library/Application_Support/Signet/bitcoin.conf

(\
./bin/bitcoin-qt --datadir="/Users/git/Library/Application_Support/Signet/";
)

MINER_ADDR=$($bcli -named getnewaddress address_type="bech32")
$miner --cli "bcli" generate --address $MINER_ADDR --grind-cmd "grinder" --min-nbits --set-block-time $(date +%s)
$miner --cli "bcli" generate --address $MINER_ADDR --grind-cmd "grinder" --min-nbits --ongoing
