use anyhow::Result;
use bitcoincore_rpc::{Auth, Client, Error};
use url::Url; // Import Url from the url crate
// use regex::Regex; // Not used, removing
use std::fs::{self, DirEntry}; // Keep fs, DirEntry might be useful later
use std::io::{self, prelude::*, BufReader}; // Keep io, prelude, BufReader
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio, Child};
use std::time::Duration;

// Constants for file paths and configurations
const SIGNET_DATADIR: &str = "./signet_data";

// Tool paths (relative to project root)
const BITCOIND_PATH: &str = "./bin/bitcoind";
const BITCOIN_CLI_PATH: &str = "./bin/bitcoin-cli";
const MINER_PATH: &str = "../contrib/signet/miner"; // Miner is in contrib/signet relative to project root
const GRINDER_PATH: &str = "./bin/bitcoin-util";

// RPC credentials
const RPC_USER: &str = "signetuser";
const RPC_PASSWORD: &str = "signetpassword";

// Default ports
const REGTEST_RPC_PORT: u16 = 18443;
const SIGNET_RPC_PORT: u16 = 38332;

// Helper to get the absolute path for executables
fn get_executable_path(cmd_name: &str) -> Result<PathBuf> {
    let current_dir = std::env::current_dir()?;
    let mut path_candidates = vec![];

    // 1. Check in the current directory (e.g., ./bin/bitcoind)
    path_candidates.push(current_dir.join(cmd_name));

    // 2. Check in parent directories (e.g., ../contrib/signet/miner)
    let mut parent = current_dir.clone();
    for _ in 0..5 { // Check up to 5 parent levels
        // Ensure we get a PathBuf from parent().ok_or() to satisfy the ? operator
        parent = parent.parent().ok_or(anyhow::anyhow!("Could not find parent directory for {}", cmd_name))?.to_path_buf();
        path_candidates.push(parent.join(cmd_name));
    }

    // 3. Check in a common 'bin' directory if it exists in the root
    if let Some(root_bin) = current_dir.join("bin").join(cmd_name).canonicalize().ok() {
        if root_bin.exists() {
            path_candidates.push(root_bin);
        }
    }

    for path in path_candidates {
        if path.exists() && path.is_file() {
            return Ok(path.canonicalize()?);
        }
    }

    Err(anyhow::anyhow!("Executable not found: {}. Searched paths: {:?}", cmd_name, path_candidates.iter().map(|p| p.display()).collect::<Vec<_>>()))
}

// Function to run a command and capture its output
async fn run_command_capture(
    mut cmd: Command,
    description: &'static str,
) -> Result<String> {
    println!("Executing: {} (capture output)", description);
    
    let mut child = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let stdout = child.stdout.take().expect("Failed to capture stdout");
    let stderr = child.stderr.take().expect("Failed to capture stderr");

    let stdout_handle = tokio::task::spawn_blocking(move || {
        let mut reader = BufReader::new(stdout);
        let mut buffer = String::new();
        reader.read_to_string(&mut buffer).map(|_| buffer)
    });

    let stderr_handle = tokio::task::spawn_blocking(move || {
        let mut reader = BufReader::new(stderr);
        let mut buffer = String::new();
        reader.read_to_string(&mut buffer).map(|_| buffer)
    });

    let status = child.wait()?; // Removed .await here
    let stdout_str = stdout_handle.await??;
    let stderr_str = stderr_handle.await??;

    if status.success() {
        Ok(stdout_str)
    } else {
        Err(anyhow::anyhow!(
            "Command failed: {}. Stderr: {}{}",
            description,
            stderr_str,
            if stdout_str.is_empty() { "".to_string() } else { format!(" Stdout: {}", stdout_str) }
        ))
    }
}

// Function to run a command in the background (daemonize)
async fn run_command_background(mut cmd: Command, description: &'static str) -> Result<Child> {
    println!("Starting command in background: {}", description);
    // Ensure stdout/stderr are not captured if we want it to run truly in background
    // For simplicity, we'll let them go to the terminal or be managed by the OS.
    // If we need to capture them later, we can use pipes and detach manually.
    let child = cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit()).spawn()?;
    println!("Background process started with PID: {:?}", child.id());
    Ok(child)
}

// Function to stop processes listening on specific ports
async fn stop_processes_on_ports(ports: &[u16]) -> Result<()> {
    println!("Checking for and stopping processes on ports: {:?}", ports);
    for port in ports {
        let mut lsof_cmd = Command::new("lsof");
        lsof_cmd.arg("-t").arg("-i").arg(format!(":{}", port));
        
        let mut child = lsof_cmd.stdout(Stdio::piped()).spawn()?;
        let stdout = child.stdout.take().expect("Failed to capture stdout");
        let status = child.wait()?; // Removed .await here

        if status.success() {
            let mut pids_str = String::new();
            io::BufReader::new(stdout).read_to_string(&mut pids_str)?;
            let pids: Vec<&str> = pids_str.trim().lines().collect();

            if !pids.is_empty() {
                println!("Found processes on port {}: {:?}. Killing them now.", port, pids);
                for pid_str in pids {
                    let pid = pid_str.parse::<u32>()?;
                    let mut kill_cmd = Command::new("kill");
                    kill_cmd.arg("-9").arg(pid.to_string());
                    // Use run_command_capture for kill command as it should complete
                    run_command_capture(kill_cmd, &format!("kill process {} on port {}", pid, port)).await.ok(); // Ignore errors if kill fails for some reason
                }
            }
        } else {
            // lsof might fail if not installed or if no processes are running on the port.
            // This is not necessarily a critical error for our script.
            eprintln!("Warning: 'lsof' command failed or returned no PIDs for port {}. It might not be available or no processes are running.", port);
        }
    }
    Ok(())
}

// Function to wait until bitcoind is ready for RPC calls
async fn wait_for_rpc(client: &Client, network: &str, retries: u32, delay_ms: u64) -> Result<()> {
    let mut attempt = 0;
    loop {
        match client.get_blockchain_info(network).await { // Use get_blockchain_info from bitcoincore-rpc
            Ok(_) => return Ok(()),
            Err(e) => {
                if attempt >= retries {
                    return Err(anyhow::anyhow!("bitcoind failed to start after {} attempts. Last error: {}", retries, e));
                }
                println!("Waiting for {} daemon... (Attempt {}/{})", network, attempt + 1, retries);
                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                attempt += 1;
            }
        }
    }
}

// Helper to build bitcoin-cli command arguments
fn build_cli_args(network: &str, datadir: &str) -> Vec<String> {
    let mut args = vec![];
    args.push(format!("-datadir={}", datadir));
    if !network.is_empty() {
        args.push(format!("-{}", network));
    }
    args
}

// Helper to construct the full bitcoin-cli command string for external tools like miner
fn get_bitcoin_cli_command_string(network: &str, datadir: &str) -> String {
    let mut cmd_parts = vec![get_executable_path(BITCOIN_CLI_PATH).unwrap().to_string_lossy().to_string()];
    cmd_parts.extend(build_cli_args(network, datadir));
    cmd_parts.join(" ")
}

// Helper to construct the full bitcoin-util command string
// Removed duplicate definition
fn get_bitcoin_util_command_string(subcommand: &str) -> String {
    format!("{}", get_executable_path(GRINDER_PATH).unwrap().to_string_lossy())
}

// Helper to construct the full miner command string
fn get_miner_command_string(network: &str, datadir: &str) -> String {
    let bcli_cmd = get_bitcoin_cli_command_string(network, datadir);
    let grinder_cmd = get_bitcoin_util_command_string("grind"); // Assuming grind is the subcommand
    format!("{} --cli \"{}\" --grind-cmd \"{}\" --min-nbits", get_executable_path(MINER_PATH).unwrap().to_string_lossy(), bcli_cmd, grinder_cmd)
}

#[tokio::main] async fn main() -> Result<()> {
    let datadir_path = PathBuf::from(SIGNET_DATADIR);
    fs::create_dir_all(&datadir_path)?;

    // --- Cleanup Old Data ---
    println!("--- Cleaning up old data ---");
    let timestamp = chrono::Local::now().format("%Y%m%d%H%M%S").to_string();

    // Archive bitcoin.conf
    let old_conf_path = datadir_path.join("bitcoin.conf");
    if old_conf_path.exists() {
        fs::rename(&old_conf_path, datadir_path.join(format!("bitcoin-{}.conf", timestamp)))?;
    }
    // Archive signet/peers.dat
    let signet_dir = datadir_path.join("signet");
    if signet_dir.exists() {
        let old_peers_path = signet_dir.join("peers.dat");
        if old_peers_path.exists() {
            fs::rename(&old_peers_path, signet_dir.join(format!("peers-{}.dat", timestamp)))?;
        }
    }
    // Archive regtest directory
    let regtest_path = datadir_path.join("regtest");
    if regtest_path.exists() {
        fs::rename(&regtest_path, datadir_path.join(format!("regtest-{}", timestamp)))?;
    }
    // Remove existing wallet directories
    println!("Removing existing wallet directories if they exist...");
    fs::remove_dir_all(datadir_path.join("regtest/wallets/signer")).ok();
    fs::remove_dir_all(datadir_path.join("signet/wallets/miner")).ok();

    // --- Phase 1: Regtest Setup ---
    println!("--- Phase 1: Generating Signet Challenge using Regtest ---");
    
    // Stop and clean up potential previous processes on relevant ports
    stop_processes_on_ports(&[REGTEST_RPC_PORT, SIGNET_RPC_PORT, 18332, 38333, 38334]).await?;

    // Check for lock file and remove if it exists
    let lock_file_path = datadir_path.join(".lock");
    if lock_file_path.exists() {
        println!("Lock file found: {:?}. Removing it now.", lock_file_path);
        fs::remove_file(&lock_file_path)?;
    }

    // Start bitcoind in Regtest mode as a daemon
    let mut btcd_regtest_cmd = Command::new(get_executable_path(BITCOIND_PATH)?);
    btcd_regtest_cmd.arg("-regtest").arg("-daemon").arg(format!("-datadir={}", datadir_path.to_string_lossy())); 
    run_command_background(btcd_regtest_cmd, "Start bitcoind in regtest mode").await?;
    tokio::time::sleep(Duration::from_secs(5)).await; // Give it time to start

    // Wait for RPC to be ready
    let regtest_url = Url::parse(&format!("http://127.0.0.1:{}", REGTEST_RPC_PORT))?;
    // Create client with explicit credentials. The config file will be used by bitcoind itself.
    let regtest_client = Client::new(&regtest_url, Auth::UserPass(RPC_USER.to_string(), RPC_PASSWORD.to_string()))?; // Handle Result from Client::new
    wait_for_rpc(&regtest_client, "regtest", 10, 2000).await?;

    // Create 'signer' wallet
    let mut create_signer_wallet_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    create_signer_wallet_cmd.args(build_cli_args("regtest", &datadir_path.to_string_lossy()));
    create_signer_wallet_cmd.arg("createwallet").arg("signer");
    run_command_capture(create_signer_wallet_cmd, "Create signer wallet").await?;

    // Extract descriptors
    let mut list_descriptors_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    list_descriptors_cmd.args(build_cli_args("regtest", &datadir_path.to_string_lossy()));
    list_descriptors_cmd.arg("listdescriptors").arg("true");
    list_descriptors_cmd.arg("--rpcwallet=signer"); // Specify wallet
    
    let descriptors_json_str = run_command_capture(list_descriptors_cmd, "List descriptors for signer wallet").await?;
    let descriptors_json: serde_json::Value = serde_json::from_str(&descriptors_json_str)?;
    // Serialize the descriptors array back to a JSON string for import
    let descriptors = serde_json::to_string(descriptors_json.get("descriptors").ok_or(anyhow::anyhow!("Failed to get descriptors array"))?)?;

    // Generate new address and get scriptPubKey
    let mut get_new_address_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    get_new_address_cmd.args(build_cli_args("regtest", &datadir_path.to_string_lossy()));
    get_new_address_cmd.arg("getnewaddress").arg("address_type=bech32");
    get_new_address_cmd.arg("--rpcwallet=signer");
    let addr = run_command_capture(get_new_address_cmd, "Get new address for signer wallet/challenge").await?;

    let mut get_address_info_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    get_address_info_cmd.args(build_cli_args("regtest", &datadir_path.to_string_lossy()));
    get_address_info_cmd.arg("getaddressinfo").arg(&addr);
    get_address_info_cmd.arg("--rpcwallet=signer");
    let address_info_json_str = run_command_capture(get_address_info_cmd, "Get address info for challenge").await?;
    let address_info_json: serde_json::Value = serde_json::from_str(&address_info_json_str)?;
    let signet_challenge = address_info_json["scriptPubKey"]
        .as_str()
        .ok_or(anyhow::anyhow!("scriptPubKey not found in address info"))?
        .to_string();

    // Stop regtest daemon
    let mut stop_regtest_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    stop_regtest_cmd.args(build_cli_args("regtest", &datadir_path.to_string_lossy()));
    stop_regtest_cmd.arg("stop");
    run_command_capture(stop_regtest_cmd, "Stop regtest daemon").await?;
    tokio::time::sleep(Duration::from_secs(5)).await; // Give it time to shut down

    // --- 3. Write Custom Signet Configuration ---
    println!("Writing new bitcoin.conf for custom Signet...");
    let mut bitcoin_conf_content = String::new();
    bitcoin_conf_content.push_str(&format!("rpcuser={}\n", RPC_USER));
    bitcoin_conf_content.push_str(&format!("rpcpassword={}\n", RPC_PASSWORD));
    bitcoin_conf_content.push_str("signet=1\n");
    bitcoin_conf_content.push_str(&format!("[signet]\n"));
    bitcoin_conf_content.push_str(&format!("rpcport={}\n", SIGNET_RPC_PORT)); // Signet default RPC port
    bitcoin_conf_content.push_str("daemon=1\n");
    bitcoin_conf_content.push_str(&format!("signetchallenge={}\n", signet_challenge));

    let conf_file_path = datadir_path.join("bitcoin.conf");
    fs::write(&conf_file_path, bitcoin_conf_content)?;
    println!("Created configuration file: {:?}", conf_file_path);

    // --- 4. Phase 2: Signet Execution and Mining Setup ---
    println!("--- Phase 2: Starting Custom Signet and Miner Setup ---");

    // Start bitcoind in Signet mode as a daemon
    let mut btcd_signet_cmd = Command::new(get_executable_path(BITCOIND_PATH)?);
    btcd_signet_cmd.arg("-signet").arg("-daemon").arg(format!("-datadir={}", datadir_path.to_string_lossy())); 
    run_command_background(btcd_signet_cmd, "Start bitcoind in Signet mode").await?;
    tokio::time::sleep(Duration::from_secs(5)).await; // Give it time to start

    // Wait for RPC to be ready
    let signet_url = Url::parse(&format!("http://127.0.0.1:{}", SIGNET_RPC_PORT))?;
    // Create client with explicit credentials. The config file will be used by bitcoind itself.
    let signet_client = Client::new(&signet_url, Auth::UserPass(RPC_USER.to_string(), RPC_PASSWORD.to_string()))?; // Handle Result from Client::new
    wait_for_rpc(&signet_client, "signet", 10, 2000).await?;

    // Create 'miner' wallet
    let mut create_miner_wallet_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    create_miner_wallet_cmd.args(build_cli_args("signet", &datadir_path.to_string_lossy()));
    create_miner_wallet_cmd.arg("createwallet").arg("miner");
    run_command_capture(create_miner_wallet_cmd, "Create miner wallet").await?;

    // Import descriptors into 'miner' wallet
    let mut import_descriptors_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    import_descriptors_cmd.args(build_cli_args("signet", &datadir_path.to_string_lossy()));
    import_descriptors_cmd.arg("importdescriptors").arg(&descriptors);
    import_descriptors_cmd.arg("--rpcwallet=miner"); // Specify wallet
    run_command_capture(import_descriptors_cmd, "Import descriptors into miner wallet").await?;

    // Generate mining address from 'miner' wallet
    let mut get_miner_address_cmd = Command::new(get_executable_path(BITCOIN_CLI_PATH)?);
    get_miner_address_cmd.args(build_cli_args("signet", &datadir_path.to_string_lossy()));
    get_miner_address_cmd.arg("getnewaddress").arg("address_type=bech32");
    get_miner_address_cmd.arg("--rpcwallet=miner");
    let miner_addr = run_command_capture(get_miner_address_cmd, "Get miner address").await?;
    println!("Miner Block Reward Address: {}", miner_addr.trim()); // Trim to remove potential newline

    // --- 5. Start Mining ---
    println!("Starting mining...");

    // Generate initial block
    let timestamp = chrono::Local::now().format("%s").to_string();
    let miner_cli_cmd_str = get_bitcoin_cli_command_string("signet", &datadir_path.to_string_lossy());
    let grinder_cmd_str = get_bitcoin_util_command_string("grind"); // Assuming grind is the subcommand

    let mut miner_generate_cmd = Command::new(get_executable_path(MINER_PATH)?);
    miner_generate_cmd
        .arg("--cli").arg(&miner_cli_cmd_str)
        .arg("generate")
        .arg("--address").arg(&miner_addr.trim()); 
        // .arg("--grind-cmd").arg(&grinder_cmd_str) // This might be handled internally by miner if path is correct
        // .arg("--min-nbits") // This flag might not be directly supported by the miner executable, check its usage
        .arg("--set-block-time").arg(&timestamp);

    // The original script runs `miner generate --ongoing` in the background. 
    // We need to ensure this happens. The `miner` executable might handle this internally.
    // For now, let's try running it and see if it blocks or runs in background.
    // If it blocks, we'll need to adjust.
    run_command_capture(miner_generate_cmd, "Generate initial block").await?;
    tokio::time::sleep(Duration::from_secs(10)).await; // Give it time to mine the first block

    // Start ongoing mining loop
    let mut miner_ongoing_cmd = Command::new(get_executable_path(MINER_PATH)?);
    miner_ongoing_cmd
        .arg("--cli").arg(&miner_cli_cmd_str)
        .arg("generate")
        .arg("--address").arg(&miner_addr.trim()); 
        // .arg("--grind-cmd").arg(&grinder_cmd_str)
        // .arg("--min-nbits") // This flag might not be directly supported by the miner executable, check its usage
        .arg("--ongoing");
    
    // The original script runs this in the foreground, but it's meant to be ongoing.
    // We should run this in the background to allow the main program to exit or continue.
    run_command_background(miner_ongoing_cmd, "Start ongoing mining loop").await?;

    println!("Signet setup complete. Mining is ongoing.");

    // Keep the main thread alive to allow background processes to run, or exit if desired.
    // For this script, it seems intended to run mining indefinitely until interrupted.
    // We can add a loop or a signal handler here if needed.
    // For now, we'll let it exit, but the background miner process might continue.
    // A more robust solution would manage the lifecycle of all child processes.
    println!("Main process exiting. Background miner should continue. Press Ctrl+C to stop.");
    Ok(())
}
