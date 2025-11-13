rsync -r ./signet_data/* ./signet_data-0/
cat ./signet_data-0/bitcoin.conf
 ./bin/bitcoin-cli --signet -netinfo -rpcpassword=signetpassword -rpcuser=signetuser --datadir=./signet_data-0
./bin/bitcoind --datadir=./signet_data-0 -port=8080 -server & sleep 3;
./bin/bitcoin-cli --signet -netinfo -rpcpassword=signetpassword -rpcuser=signetuser --datadir=./signet_data-0
cat ./signet_data/bitcoin.conf
./bin/bitcoin-cli --signet -netinfo -rpcpassword=signetpassword -rpcuser=signetuser --datadir=./signet_data
count=0
while ((count < 101));do
../contrib/signet/miner --cli './bin/bitcoin-cli -datadir=./signet_data' generate --address tb1quj2f4cdeczgsuqcuse0aehc8alp2zyqknfs8zg --grind-cmd './bin/bitcoin-util grind' --min-nbits #--ongoing
 ./bin/bitcoin-cli --signet -netinfo -rpcpassword=signetpassword -rpcuser=signetuser --datadir=./signet_data
 ./bin/bitcoin-cli --signet -netinfo -rpcpassword=signetpassword -rpcuser=signetuser --datadir=./signet_data-0
done
exit;
