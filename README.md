# iperf3 Multi-Process Bandwidth Test Suite

Multi-process iperf3 test harness for validating high-speed network throughput (100G–200G+) on OCI bare metal GPU infrastructure. Based on [ESnet's guidance](https://fasterdata.es.net/performance-testing/network-troubleshooting-tools/iperf/multi-stream-iperf3/) for testing at 100 Gbps and above.

## Why Multi-Process?

A single iperf3 process is single-threaded — all parallel streams (`-P`) share one CPU core. On 100G+ hosts, you hit CPU saturation long before you hit the network limit. This suite launches **N separate iperf3 processes** across separate cores and ports, then aggregates the results to measure true aggregate bandwidth.

Additionally, on OCI bare metal shapes, each VNIC is capped at ~25 Gbps. Reaching 200G requires multiple VNICs across multiple physical NICs — these scripts help you prove the per-VNIC cap and validate aggregate throughput.

## Scripts

| Script | Purpose |
|---|---|
| `iperf3_server.sh` | Launch N iperf3 server processes on separate ports |
| `iperf3_client.sh` | Launch N parallel client processes, aggregate results, assess throughput |
| `iperf3_tune_host.sh` | Display/apply TCP buffer, MTU, and BBR tuning for high-speed testing |
| `test_iperf3_scripts.sh` | 89-test validation suite covering JSON parsing, math, edge cases |

## Quick Start

### 1. Copy scripts to both hosts

```bash
chmod +x iperf3_server.sh iperf3_client.sh iperf3_tune_host.sh
```

### 2. (Optional) Tune both hosts

```bash
# Dry run — shows current vs. recommended values
sudo ./iperf3_tune_host.sh

# Apply tuning (backs up current values to /tmp)
sudo ./iperf3_tune_host.sh --apply

# Revert when done
sudo ./iperf3_tune_host.sh --revert
```

### 3. Start servers on the remote host

```bash
./iperf3_server.sh --instances 10
```

The script displays all server IPs and provides ready-to-copy client commands.

### 4. Run the client test

```bash
./iperf3_client.sh --server 10.140.0.13 --instances 10
```

Both scripts preview every command before execution and ask for confirmation. Use `--yes` to skip prompts for scripted/repeat runs.

## Client Options

```
Usage: iperf3_client.sh --server <IP> [OPTIONS]

Required:
  --server, -s IP       Target server IP

Options:
  --instances N         Number of parallel iperf3 processes (default: 10)
  --base-port PORT      Starting port number (default: 5200)
  --duration, -t SEC    Test duration in seconds (default: 30)
  --streams-per, -P N   Parallel streams per process (default: 4)
  --window, -w SIZE     TCP window size (default: 128M, auto-adjusted if needed)
  --target GBPS         Throughput target for pass/fail (default: 200)
  --bind IP             Bind client to specific IP
  --interface, -I NAME  Interface to monitor counters (default: eth0, auto-detected)
  --affinity            Pin each process to a separate CPU core
  --mtu-check           Run MTU path discovery before test
  --raw                 Show raw iperf3 per-second output for each process
  --json-dir DIR        Save per-process JSON results to DIR
  --yes, -y             Skip all confirmations (auto-approve)
```

## Server Options

```
Usage: iperf3_server.sh [--instances N] [--base-port PORT] [--bind IP]
                        [--affinity] [--yes] [--stop]
```

Stop all servers with:

```bash
./iperf3_server.sh --stop
```

## Example Output

```
╔══════════════════════════════════════════════════════════════╗
║          iperf3 Multi-Process Bandwidth Test                ║
╚══════════════════════════════════════════════════════════════╝

[INFO]  Server:           10.140.0.13
[INFO]  Processes:        3
[INFO]  Total streams:    12
[INFO]  Target:           100 Gbps

── Results ──

  Process      Sent (Gbps)     Recv (Gbps)  Retransmits   Status
  -------      -----------     -----------  -----------   ------
  s1             25.60           25.50               0       OK
  s2             25.80           25.70               0       OK
  s3             25.40           25.30               2       OK
  TOTAL          76.80           76.50               2

── Assessment ──

[WARN]  Throughput 76.80 Gbps — 76.8% of 100G target.
[WARN]  Possible bottlenecks: VNIC caps, TCP tuning, NUMA locality, or IRQ affinity.
```

## Raw Output Mode

Use `--raw` to see per-second, per-process detail — useful for spotting throughput drops, retransmit bursts, or congestion window issues:

```bash
./iperf3_client.sh --server 10.140.0.13 --instances 1 --raw
```

```
── Raw iperf3 Output (per-process) ──

  ── Process s1 (port 5200) ──
  [5] 10.140.0.13:44206 -> 10.140.0.13:5200

          Interval      Transfer       Bitrate    Retr      Cwnd
  ----------------  ------------  --------------  ------  --------
    0.00-1.00  sec      3.25 GB       26.00 Gbps       0  2.00 MB
    1.00-2.00  sec      3.25 GB       26.00 Gbps       0  2.00 MB
    ...

  Sender:       97.50 GB     26.00 Gbps  retransmits: 0
  Receiver:     97.40 GB     25.90 Gbps
  CPU: host=15.2%  remote=12.1%
```

## Pre-Test Checks

The client automatically validates before running:

- **TCP buffer sizes** — warns if `rmem_max`/`wmem_max` are below 128MB and auto-adjusts the `-w` flag to avoid iperf3 socket buffer errors
- **Congestion control** — recommends BBR over CUBIC for high-throughput
- **MTU / jumbo frames** — checks for 9000 MTU on the monitored interface
- **NUMA topology** — reports which NUMA node owns the NIC
- **IRQ balance** — reports irqbalance status
- **NIC counters** — captures TX/RX byte deltas at the kernel level for cross-validation

## Dependencies

All standard on Ubuntu — no `jq` required:

| Tool | Used for | Install |
|---|---|---|
| `iperf3` | Bandwidth testing | `sudo apt-get install -y iperf3` |
| `python3` | JSON result parsing | Pre-installed on Ubuntu |
| `bc` | Floating-point math | `sudo apt-get install -y bc` |
| `lsof` | Port conflict detection (server, optional) | `sudo apt-get install -y lsof` |

## Tuning Script

The tuning script manages 14 kernel parameters based on [ESnet's host tuning guide](https://fasterdata.es.net/host-tuning/linux/):

```bash
# Show current vs. recommended (safe, no changes)
sudo ./iperf3_tune_host.sh

# Apply all recommended values
sudo ./iperf3_tune_host.sh --apply

# Revert to original values
sudo ./iperf3_tune_host.sh --revert
```

Parameters managed: `rmem_max`, `wmem_max`, `rmem_default`, `wmem_default`, `tcp_rmem`, `tcp_wmem`, `tcp_congestion_control` (BBR), `tcp_mtu_probing`, `tcp_no_metrics_save`, `netdev_max_backlog`, `optmem_max`, `tcp_timestamps`, `tcp_sack`, `tcp_window_scaling`, plus interface MTU.

> **Note:** Backup is stored in `/tmp/sysctl_backup_iperf3.conf` and will be lost on reboot. For persistent tuning, add values to `/etc/sysctl.d/99-network-tuning.conf`.

## Testing OCI Multi-VNIC Bandwidth

To test aggregate throughput across multiple VNICs (required to exceed the ~25 Gbps per-VNIC cap):

```bash
# List VNICs on the instance
oci compute instance list-vnics --instance-id <OCID>

# Run separate client instances bound to each VNIC IP
./iperf3_client.sh --server 10.0.1.10 --instances 5 --bind 10.0.0.100 --base-port 5200 --yes &
./iperf3_client.sh --server 10.0.1.10 --instances 5 --bind 10.0.0.101 --base-port 5210 --yes &
wait
```

## Running the Test Suite

```bash
bash test_iperf3_scripts.sh
```

Validates JSON parsing, bc calculations, integer sanitization, window size parsing, edge cases (scientific notation, 3TB values, zero throughput), safety patterns (no `eval`, no `(( X++ ))`, no `jq`), and end-to-end mock pipelines. Network-dependent tests (NIC counters, interface detection) run automatically when a suitable interface is available.

## Safety Features

- **Confirm-before-execute** — every command is previewed and requires `y` before running (bypass with `--yes`)
- **No modifications** — server and client scripts are read-only; only the tuning script modifies system state, and only with `--apply`
- **No `eval`** — commands execute via direct `"$@"` invocation
- **No `jq` dependency** — JSON parsed via python3's built-in `json` module
- **Auto-adjusted TCP window** — detects when `-w 128M` exceeds `rmem_max` and drops the flag to prevent iperf3 errors
- **Graceful interface detection** — auto-detects `enp0s5`, `ens3`, etc. when `eth0` doesn't exist
