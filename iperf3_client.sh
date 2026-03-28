#!/usr/bin/env bash
#===============================================================================
# iperf3_client.sh — Multi-process iperf3 client for high-speed bandwidth testing
#
# Launches N parallel iperf3 client processes, each on its own port/core,
# collects JSON results, and reports aggregate throughput.
#
# Usage:
#   ./iperf3_client.sh --server <IP> [--instances N] [--base-port PORT]
#                      [--duration SEC] [--streams-per N] [--window SIZE]
#                      [--target GBPS] [--bind IP] [--interface NAME]
#                      [--affinity] [--mtu-check] [--raw] [--json-dir DIR]
#                      [--yes] [--debug]
#===============================================================================
set -euo pipefail

SCRIPT_VERSION="1.2.1"
SCRIPT_VERSION_DATE="2026-03-28"

#--- Defaults ------------------------------------------------------------------
SERVER=""
INSTANCES=10          # match server count
BASE_PORT=5200
DURATION=30           # seconds per test
STREAMS_PER=4         # -P streams per iperf3 process
WINDOW="128M"         # TCP window size (ESnet recommends 128M for 100G+)
TARGET_GBPS=200       # throughput target for pass/fail assessment
BIND_ADDR=""
CPU_AFFINITY=false
MTU_CHECK=false
SHOW_RAW=false        # show raw iperf3 output per process
JSON_DIR=""
INTERFACE="eth0"      # interface to monitor
AUTO_YES=false        # skip confirmations
DEBUG=false

#--- Color output --------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
err()   { echo -e "${RED}[ERROR]${RST} $*"; }
hdr()   { echo -e "\n${BLD}$*${RST}"; }

#--- Action log ----------------------------------------------------------------
ACTION_LOG="./iperf3_action.log"
log_action() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$ACTION_LOG"
    echo -e "  ${DIM}[LOG] $*${RST}"
}

#--- Confirm-before-execute (no eval) ------------------------------------------
# Usage: confirm_exec "description" command arg1 arg2 ...
confirm_exec() {
    local desc="$1"; shift
    local cmd_display
    cmd_display=$(printf '%q ' "$@")
    echo -e "  ${CYN}> ${desc}${RST}"
    echo -e "    ${DIM}\$ ${cmd_display}${RST}"
    if $AUTO_YES; then
        echo -e "    ${DIM}(auto-confirmed via --yes)${RST}"
    else
        read -rp "    Execute? [y/N]: " answer
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *)
                warn "Skipped: $desc"
                return 1
                ;;
        esac
    fi
    "$@"
}

#--- Parse arguments -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server|-s)
            [[ $# -lt 2 ]] && { err "--server requires an argument"; exit 1; }
            SERVER="$2"; shift 2 ;;
        --instances)
            [[ $# -lt 2 ]] && { err "--instances requires an argument"; exit 1; }
            INSTANCES="$2"; shift 2 ;;
        --base-port)
            [[ $# -lt 2 ]] && { err "--base-port requires an argument"; exit 1; }
            BASE_PORT="$2"; shift 2 ;;
        --duration|-t)
            [[ $# -lt 2 ]] && { err "--duration requires an argument"; exit 1; }
            DURATION="$2"; shift 2 ;;
        --streams-per|-P)
            [[ $# -lt 2 ]] && { err "--streams-per requires an argument"; exit 1; }
            STREAMS_PER="$2"; shift 2 ;;
        --window|-w)
            [[ $# -lt 2 ]] && { err "--window requires an argument"; exit 1; }
            WINDOW="$2"; shift 2 ;;
        --target)
            [[ $# -lt 2 ]] && { err "--target requires an argument"; exit 1; }
            TARGET_GBPS="$2"; shift 2 ;;
        --bind)
            [[ $# -lt 2 ]] && { err "--bind requires an argument"; exit 1; }
            BIND_ADDR="$2"; shift 2 ;;
        --interface|-I)
            [[ $# -lt 2 ]] && { err "--interface requires an argument"; exit 1; }
            INTERFACE="$2"; shift 2 ;;
        --affinity)         CPU_AFFINITY=true;    shift ;;
        --mtu-check)        MTU_CHECK=true;       shift ;;
        --raw)              SHOW_RAW=true;        shift ;;
        --json-dir)
            [[ $# -lt 2 ]] && { err "--json-dir requires an argument"; exit 1; }
            JSON_DIR="$2"; shift 2 ;;
        --yes|-y)           AUTO_YES=true;        shift ;;
        --debug)            DEBUG=true;           shift ;;
        -h|--help)
            cat <<EOF
iperf3_client.sh v${SCRIPT_VERSION} (${SCRIPT_VERSION_DATE})

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
  --debug               Enable debug output (set -x)
  -h, --help            Show this help
EOF
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

$DEBUG && set -x

#--- Input validation ----------------------------------------------------------
[[ -z "$SERVER" ]] && { err "Missing --server <IP>. Use -h for help."; exit 1; }

# Validate server as IPv4 or resolvable hostname
if ! [[ "$SERVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! [[ "$SERVER" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    err "Invalid server address: '$SERVER'"
    exit 1
fi

# Validate numeric arguments
for var_check in INSTANCES BASE_PORT DURATION STREAMS_PER TARGET_GBPS; do
    val="${!var_check}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        err "--${var_check,,} must be a positive integer, got '$val'"
        exit 1
    fi
done

if (( INSTANCES < 1 )); then
    err "--instances must be >= 1, got '$INSTANCES'"
    exit 1
fi
if (( BASE_PORT < 1024 || BASE_PORT > 65535 )); then
    err "--base-port must be 1024-65535, got '$BASE_PORT'"
    exit 1
fi
if (( BASE_PORT + INSTANCES - 1 > 65535 )); then
    err "Port range ${BASE_PORT}-$(( BASE_PORT + INSTANCES - 1 )) exceeds 65535"
    exit 1
fi
if (( DURATION < 1 )); then
    err "--duration must be >= 1, got '$DURATION'"
    exit 1
fi
if (( STREAMS_PER < 1 )); then
    err "--streams-per must be >= 1, got '$STREAMS_PER'"
    exit 1
fi
if (( TARGET_GBPS < 1 )); then
    err "--target must be >= 1, got '$TARGET_GBPS'"
    exit 1
fi

# Validate --window format (e.g., 128M, 64K, 1G, or bare bytes)
if [[ -n "$WINDOW" ]] && ! [[ "$WINDOW" =~ ^[0-9]+[KkMmGg]?$ ]]; then
    err "Invalid window size: '$WINDOW' (expected format: 128M, 64K, 1G, or bare bytes)"
    exit 1
fi

# Validate interface name (prevent path traversal into /sys)
if ! [[ "$INTERFACE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    err "Invalid interface name: '$INTERFACE'"
    exit 1
fi

# Validate bind address if provided
if [[ -n "$BIND_ADDR" ]] && ! [[ "$BIND_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "--bind must be a valid IPv4 address, got '$BIND_ADDR'"
    exit 1
fi

#--- Pre-flight: dependency checks ---------------------------------------------
missing_deps=()
command -v iperf3  &>/dev/null || missing_deps+=(iperf3)
command -v python3 &>/dev/null || missing_deps+=(python3)
command -v bc      &>/dev/null || missing_deps+=(bc)

if (( ${#missing_deps[@]} > 0 )); then
    err "Missing required tools: ${missing_deps[*]}"
    err "Install with: sudo apt-get install -y ${missing_deps[*]}"
    exit 1
fi

#--- JSON helpers using python3 (no jq dependency) -----------------------------
json_val() {
    local file="$1" path="$2" default="${3:-0}"
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'):
        d = d[int(k)] if isinstance(d, list) else d[k]
    print(d)
except Exception:
    print(sys.argv[3])
" "$file" "$path" "$default" 2>/dev/null
}

json_error() {
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    e = d.get('error', '')
    print(e)
except Exception:
    print('JSON parse error')
" "$1" 2>/dev/null
}

# Pretty-print iperf3 JSON for --raw output
json_pretty() {
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    start = d.get('start', {})
    end = d.get('end', {})
    intervals = d.get('intervals', [])

    # Connection info
    for c in start.get('connected', []):
        print(f\"  [{c.get('socket','')}] {c.get('local_host','')}:{c.get('local_port','')} -> {c.get('remote_host','')}:{c.get('remote_port','')}\")

    # Per-interval summary
    print()
    print(f\"  {'Interval':>16s}  {'Transfer':>12s}  {'Bitrate':>14s}  {'Retr':>6s}  {'Cwnd':>8s}\")
    print(f\"  {'-'*16:>16s}  {'-'*12:>12s}  {'-'*14:>14s}  {'-'*6:>6s}  {'-'*8:>8s}\")
    for iv in intervals:
        s = iv.get('sum', {})
        st = s.get('start', 0)
        en = s.get('end', 0)
        xfer_gb = s.get('bytes', 0) / (1024**3)
        bps_g = s.get('bits_per_second', 0) / 1e9
        retr = s.get('retransmits', '-')
        streams = iv.get('streams', [])
        cwnd_mb = streams[0].get('snd_cwnd', 0) / (1024**2) if streams else 0
        print(f\"  {st:6.2f}-{en:<6.2f} sec  {xfer_gb:9.2f} GB  {bps_g:11.2f} Gbps  {retr!s:>6}  {cwnd_mb:5.2f} MB\")

    # Final summary
    ss = end.get('sum_sent', {})
    sr = end.get('sum_received', {})
    cpu = end.get('cpu_utilization_percent', {})
    print()
    print(f\"  Sender:    {ss.get('bytes',0)/(1024**3):8.2f} GB  {ss.get('bits_per_second',0)/1e9:8.2f} Gbps  retransmits: {ss.get('retransmits',0)}\")
    print(f\"  Receiver:  {sr.get('bytes',0)/(1024**3):8.2f} GB  {sr.get('bits_per_second',0)/1e9:8.2f} Gbps\")
    if cpu:
        print(f\"  CPU: host={cpu.get('host_total',0):.1f}%  remote={cpu.get('remote_total',0):.1f}%\")
except Exception as e:
    print(f'  (could not parse: {e})')
" "$1" 2>/dev/null
}

#--- Numeric validation helper for bc inputs -----------------------------------
safe_number() {
    local val="$1" default="${2:-0}"
    if [[ "$val" =~ ^-?[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?$ ]]; then
        echo "$val"
    else
        echo "$default"
    fi
}

#--- Auto-detect default interface if eth0 doesn't exist -----------------------
if [[ "$INTERFACE" == "eth0" ]] && ! ip link show eth0 &>/dev/null; then
    INTERFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}') || true
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip -4 addr show up 2>/dev/null | grep -v '127.0.0.1' | grep 'inet ' | head -1 | awk '{print $NF}') || true
    fi
    if [[ -n "$INTERFACE" ]]; then
        info "Auto-detected interface: $INTERFACE"
    else
        warn "Could not auto-detect network interface. Use --interface to specify."
    fi
fi

#--- NIC counter helper --------------------------------------------------------
get_iface_bytes() {
    local dir=$1  # tx_bytes or rx_bytes
    cat "/sys/class/net/${INTERFACE}/statistics/${dir}" 2>/dev/null || echo 0
}

#--- Setup ---------------------------------------------------------------------
if [[ -n "$JSON_DIR" ]]; then
    mkdir -p "$JSON_DIR"
fi

TMPDIR=$(mktemp -d /tmp/iperf3_test.XXXXXXXXXX)

# Cleanup trap: kill background iperf3 clients + remove temp dir
declare -a CLIENT_PIDS=()
cleanup() {
    for pid in "${CLIENT_PIDS[@]:-}"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM HUP

AVAILABLE_CORES=$(nproc)
TOTAL_STREAMS=$(( INSTANCES * STREAMS_PER ))

hdr "======================================================================"
hdr "          iperf3 Multi-Process Bandwidth Test v${SCRIPT_VERSION}"
hdr "======================================================================"
echo ""
info "Server:           $SERVER"
info "Processes:        $INSTANCES"
info "Streams/process:  $STREAMS_PER"
info "Total streams:    $TOTAL_STREAMS"
info "Duration:         ${DURATION}s"
info "TCP window:       ${WINDOW:-auto (kernel default)}"
info "Target:           ${TARGET_GBPS} Gbps"
info "Port range:       ${BASE_PORT}-$(( BASE_PORT + INSTANCES - 1 ))"
info "CPU affinity:     $CPU_AFFINITY"
info "Monitor iface:    $INTERFACE"
info "Available cores:  $AVAILABLE_CORES"
info "Show raw output:  $SHOW_RAW"

#--- Connectivity pre-check ----------------------------------------------------
info "Checking connectivity to $SERVER:$BASE_PORT..."
if ! timeout 3 bash -c "echo >/dev/tcp/$SERVER/$BASE_PORT" 2>/dev/null; then
    err "Cannot connect to $SERVER:$BASE_PORT — is the server running?"
    err "Start the server with: ./iperf3_server.sh --instances $INSTANCES --base-port $BASE_PORT"
    exit 1
fi
ok "Server reachable at $SERVER:$BASE_PORT"

#--- System checks -------------------------------------------------------------
hdr "-- Pre-Test System Checks --"

# 1. Kernel TCP tuning
echo ""
info "TCP buffer settings:"
for param in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    printf "  %-30s %s\n" "$param" "$val"
done

CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
info "Congestion control: $CC"

# Warn on small buffers and auto-adjust window
RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
MIN_BUF=$((128 * 1024 * 1024))  # 128 MB
if (( RMEM_MAX < MIN_BUF || WMEM_MAX < MIN_BUF )); then
    warn "Buffer max < 128MB. For ${TARGET_GBPS}G, recommend running:"
    warn "  sudo sysctl -w net.core.rmem_max=268435456"
    warn "  sudo sysctl -w net.core.wmem_max=268435456"
    warn "  sudo sysctl -w net.ipv4.tcp_rmem='4096 131072 268435456'"
    warn "  sudo sysctl -w net.ipv4.tcp_wmem='4096 16384 268435456'"
    warn "Or run: sudo ./iperf3_tune_host.sh --apply"

    WINDOW_REQUESTED="$WINDOW"
    req_bytes=0
    case "$WINDOW" in
        *[Mm]) req_bytes=$(( ${WINDOW%[Mm]} * 1024 * 1024 )) ;;
        *[Kk]) req_bytes=$(( ${WINDOW%[Kk]} * 1024 )) ;;
        *[Gg]) req_bytes=$(( ${WINDOW%[Gg]} * 1024 * 1024 * 1024 )) ;;
        *)     req_bytes=${WINDOW:-0} ;;
    esac
    KERN_MAX=$(( RMEM_MAX < WMEM_MAX ? RMEM_MAX : WMEM_MAX ))
    if (( req_bytes > KERN_MAX )); then
        WINDOW=""
        warn "Requested window ($WINDOW_REQUESTED) exceeds kernel max ($(( KERN_MAX / 1024 ))K)."
        warn "Dropping -w flag — TCP autotuning will be used instead."
    fi
fi

if [[ "$CC" != "bbr" ]]; then
    warn "Congestion control is '$CC'. BBR is recommended for high-throughput:"
    warn "  sudo sysctl -w net.ipv4.tcp_congestion_control=bbr"
fi

# 2. MTU check
echo ""
if ip link show "$INTERFACE" &>/dev/null; then
    CURRENT_MTU=$(ip link show "$INTERFACE" | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
    CURRENT_MTU=${CURRENT_MTU:-0}
    [[ "$CURRENT_MTU" =~ ^[0-9]+$ ]] || CURRENT_MTU=0
    info "Interface $INTERFACE MTU: $CURRENT_MTU"
    if (( CURRENT_MTU < 9000 )); then
        warn "MTU is $CURRENT_MTU. Jumbo frames (9000) recommended for ${TARGET_GBPS}G."
    else
        ok "Jumbo frames enabled (MTU $CURRENT_MTU)."
    fi
else
    warn "Interface $INTERFACE not found — skipping MTU check."
fi

# 3. MTU path discovery (optional)
if $MTU_CHECK; then
    info "Running MTU path discovery to $SERVER..."
    for sz in 8972 4472 1472; do
        if confirm_exec "MTU probe (payload=$sz)" ping -M "do" -s "$sz" -c 1 -W 2 -- "$SERVER"; then
            ok "Path MTU supports payload size $sz (MTU ~$(( sz + 28 )))"
            break
        else
            warn "Payload $sz (MTU ~$(( sz + 28 ))) — PMTU exceeded, unreachable, or skipped."
        fi
    done
fi

# 4. NUMA topology
echo ""
if command -v numactl &>/dev/null; then
    info "NUMA nodes: $(numactl --hardware 2>/dev/null | grep 'available' || echo 'unknown')"
    NIC_NUMA=""
    if [[ -f "/sys/class/net/${INTERFACE}/device/numa_node" ]]; then
        NIC_NUMA=$(cat "/sys/class/net/${INTERFACE}/device/numa_node" 2>/dev/null || echo "")
    fi
    if [[ -n "$NIC_NUMA" && "$NIC_NUMA" != "-1" ]]; then
        info "Interface $INTERFACE is on NUMA node $NIC_NUMA"
    fi
fi

# 5. IRQ balance check
echo ""
if pgrep irqbalance &>/dev/null; then
    ok "irqbalance: running"
else
    warn "irqbalance: NOT running"
    warn "  Install with: sudo apt-get install -y irqbalance"
fi

# 6. CPU governor (ESnet: "performance" governor can increase throughput by ~30%)
CPU_GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
if [[ -f "$CPU_GOV_PATH" ]]; then
    CURRENT_GOV=$(cat "$CPU_GOV_PATH" 2>/dev/null || echo "N/A")
    AVAIL_GOVS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "N/A")
    if [[ "$CURRENT_GOV" == "performance" ]]; then
        ok "CPU governor: $CURRENT_GOV"
    else
        warn "CPU governor: $CURRENT_GOV (should be 'performance' for up to 30% throughput gain)"
        warn "  Set with: sudo cpupower frequency-set -g performance"
        warn "  Or run: sudo ./iperf3_tune_host.sh --apply"
    fi
    info "  Available governors: $AVAIL_GOVS"
else
    warn "CPU governor: N/A (no cpufreq sysfs — hypervisor-controlled)"
fi

# 7. NIC driver and firmware
echo ""
info "NIC info ($INTERFACE):"
if ip link show "$INTERFACE" &>/dev/null; then
    if command -v ethtool &>/dev/null; then
        drv_info=$(ethtool -i "$INTERFACE" 2>/dev/null) || true
        if [[ -n "$drv_info" ]]; then
            drv=$(echo "$drv_info" | awk -F': ' '/^driver:/{print $2}')
            drv_ver=$(echo "$drv_info" | awk -F': ' '/^version:/{print $2}')
            fw=$(echo "$drv_info" | awk -F': ' '/^firmware-version:/{print $2}')
            bus=$(echo "$drv_info" | awk -F': ' '/^bus-info:/{print $2}')
            printf "  %-20s %s\n" "Driver:" "${drv:-N/A}"
            printf "  %-20s %s\n" "Driver version:" "${drv_ver:-N/A}"
            printf "  %-20s %s\n" "Firmware:" "${fw:-N/A}"
            printf "  %-20s %s\n" "Bus info:" "${bus:-N/A}"
        else
            warn "  ethtool -i not supported on $INTERFACE"
        fi
    else
        warn "  ethtool not installed — cannot query NIC driver/firmware"
        warn "  Install with: sudo apt-get install -y ethtool"
    fi

    # Link speed
    if command -v ethtool &>/dev/null; then
        link_speed=$(ethtool "$INTERFACE" 2>/dev/null | awk '/Speed:/{print $2}') || true
        link_duplex=$(ethtool "$INTERFACE" 2>/dev/null | awk '/Duplex:/{print $2}') || true
        printf "  %-20s %s\n" "Link speed:" "${link_speed:-N/A}"
        printf "  %-20s %s\n" "Duplex:" "${link_duplex:-N/A}"
    fi
else
    warn "  Interface $INTERFACE not found"
fi

# 8. Netdev budget (ESnet 100G "other tuning")
echo ""
info "Netdev budget settings:"
NETDEV_BUDGET=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo "N/A")
NETDEV_BUDGET_USECS=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo "N/A")
if [[ "$NETDEV_BUDGET" =~ ^[0-9]+$ ]] && (( NETDEV_BUDGET >= 600 )); then
    ok "netdev_budget: $NETDEV_BUDGET (recommended: >= 600)"
else
    warn "netdev_budget: $NETDEV_BUDGET (recommended: 600, default: 300)"
fi
if [[ "$NETDEV_BUDGET_USECS" =~ ^[0-9]+$ ]] && (( NETDEV_BUDGET_USECS >= 4000 )); then
    ok "netdev_budget_usecs: $NETDEV_BUDGET_USECS (recommended: >= 4000)"
else
    warn "netdev_budget_usecs: $NETDEV_BUDGET_USECS (recommended: 4000, default: 2000)"
fi

# 9. TX queue length (ESnet: 10000 for WAN, default 1000 OK for LAN)
if ip link show "$INTERFACE" &>/dev/null; then
    CURRENT_TXQLEN=$(ip link show "$INTERFACE" | awk '/qlen/{for(i=1;i<=NF;i++) if($i=="qlen") print $(i+1)}')
    CURRENT_TXQLEN=${CURRENT_TXQLEN:-1000}
    [[ "$CURRENT_TXQLEN" =~ ^[0-9]+$ ]] || CURRENT_TXQLEN=1000
    if (( CURRENT_TXQLEN >= 10000 )); then
        ok "txqueuelen ($INTERFACE): $CURRENT_TXQLEN (recommended: 10000)"
    else
        warn "txqueuelen ($INTERFACE): $CURRENT_TXQLEN (recommended: 10000)"
        warn "  Set with: sudo ip link set $INTERFACE txqueuelen 10000"
    fi
fi

# 10. NIC offload settings (ESnet: LRO off, GRO on)
echo ""
info "NIC offload settings ($INTERFACE):"
if ip link show "$INTERFACE" &>/dev/null && command -v ethtool &>/dev/null; then
    offload_info=$(ethtool -k "$INTERFACE" 2>/dev/null) || true
    if [[ -n "$offload_info" ]]; then
        for feat in tcp-segmentation-offload generic-receive-offload large-receive-offload tx-checksumming rx-checksumming; do
            val=$(echo "$offload_info" | grep "^${feat}:" | awk '{print $2}')
            case "$feat" in
                large-receive-offload)
                    if [[ "$val" == "off" ]]; then
                        ok "  $feat: $val (recommended: off)"
                    else
                        warn "  $feat: $val (recommended: off)"
                        warn "    Set with: sudo ethtool -K $INTERFACE lro off"
                    fi
                    ;;
                generic-receive-offload)
                    if [[ "$val" == "on" ]]; then
                        ok "  $feat: $val (recommended: on)"
                    else
                        warn "  $feat: $val (recommended: on)"
                        warn "    Set with: sudo ethtool -K $INTERFACE gro on"
                    fi
                    ;;
                *)
                    info "  $feat: ${val:-N/A}"
                    ;;
            esac
        done
    fi
elif ! command -v ethtool &>/dev/null; then
    warn "  ethtool not installed — cannot check offloads"
fi

#--- Capture baseline NIC counters ---------------------------------------------
TX_BEFORE=$(get_iface_bytes tx_bytes)
RX_BEFORE=$(get_iface_bytes rx_bytes)

#--- Build command options (arrays for safe quoting) ---------------------------
BIND_OPTS=()
[[ -n "$BIND_ADDR" ]] && BIND_OPTS=(--bind "$BIND_ADDR")
WINDOW_OPTS=()
[[ -n "$WINDOW" ]] && WINDOW_OPTS=(-w "$WINDOW")

#--- Launch clients ------------------------------------------------------------
hdr "-- Running Test --"
echo ""

# Preview all commands
echo -e "  ${CYN}Commands to execute:${RST}"
for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))
    label="s$(( i+1 ))"
    outfile="\${TMPDIR}/iperf3_${label}.json"
    base_cmd="iperf3 -c $SERVER -p $port -P $STREAMS_PER -t $DURATION ${WINDOW_OPTS[*]:-} -J ${BIND_OPTS[*]:-}"
    if $CPU_AFFINITY; then
        echo -e "    ${DIM}\$ taskset -c $core $base_cmd > $outfile &${RST}"
    else
        echo -e "    ${DIM}\$ $base_cmd > $outfile &${RST}"
    fi
done
echo ""

if ! $AUTO_YES; then
    read -rp "  Launch all $INSTANCES client processes (${DURATION}s test)? [y/N]: " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *)
            warn "Aborted. No test launched."
            exit 0
            ;;
    esac
else
    echo -e "  ${DIM}(auto-confirmed via --yes)${RST}"
fi

echo ""
info "Launching $INSTANCES iperf3 client processes..."
echo ""

for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))
    label="s$(( i+1 ))"
    outfile="${TMPDIR}/iperf3_${label}.json"

    if $CPU_AFFINITY; then
        taskset -c "$core" iperf3 -c "$SERVER" -p "$port" -P "$STREAMS_PER" \
            -t "$DURATION" "${WINDOW_OPTS[@]+"${WINDOW_OPTS[@]}"}" -J "${BIND_OPTS[@]+"${BIND_OPTS[@]}"}" > "$outfile" 2>&1 &
    else
        iperf3 -c "$SERVER" -p "$port" -P "$STREAMS_PER" \
            -t "$DURATION" "${WINDOW_OPTS[@]+"${WINDOW_OPTS[@]}"}" -J "${BIND_OPTS[@]+"${BIND_OPTS[@]}"}" > "$outfile" 2>&1 &
    fi
    CLIENT_PIDS+=($!)

    aff_msg=""
    $CPU_AFFINITY && aff_msg=" -> core $core"
    log_action "CLIENT: iperf3 -c $SERVER -p $port -P $STREAMS_PER -t $DURATION ${WINDOW_OPTS[*]:-} -J ${BIND_OPTS[*]:-} (PID ${CLIENT_PIDS[-1]})"
    info "  Process $label  port=$port  PID=${CLIENT_PIDS[-1]}${aff_msg}"
done

echo ""
info "All $INSTANCES processes launched. Waiting ${DURATION}s for completion..."

#--- Progress indicator with spinner -------------------------------------------
SPINNER_CHARS=$'|/-\\'
SPIN_IDX=0
ELAPSED=0
START_TS=$(date +%s)
while (( ELAPSED < DURATION + 5 )); do
    ALL_DONE=true
    for pid in "${CLIENT_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            ALL_DONE=false
            break
        fi
    done
    $ALL_DONE && break

    NOW_TS=$(date +%s)
    ELAPSED=$(( NOW_TS - START_TS ))
    SPIN_CHAR="${SPINNER_CHARS:SPIN_IDX%4:1}"
    SPIN_IDX=$(( SPIN_IDX + 1 ))
    printf "\r  %s [%3ds / %ds]  " "$SPIN_CHAR" "$ELAPSED" "$DURATION"
    sleep 1
done
printf "\r  done.                          \n"

#--- Wait for all processes and collect exit codes -----------------------------
declare -a EXIT_CODES=()
for pid in "${CLIENT_PIDS[@]}"; do
    wait "$pid" 2>/dev/null && EXIT_CODES+=(0) || EXIT_CODES+=($?)
done

#--- Capture post-test NIC counters --------------------------------------------
TX_AFTER=$(get_iface_bytes tx_bytes)
RX_AFTER=$(get_iface_bytes rx_bytes)

#--- Show raw output if requested ----------------------------------------------
if $SHOW_RAW; then
    hdr "-- Raw iperf3 Output (per-process) --"
    for (( i=0; i<INSTANCES; i++ )); do
        label="s$(( i+1 ))"
        outfile="${TMPDIR}/iperf3_${label}.json"
        echo ""
        echo -e "  ${BLD}-- Process $label (port $(( BASE_PORT + i ))) --${RST}"
        if [[ -s "$outfile" ]]; then
            json_pretty "$outfile"
        else
            echo "  (no output)"
        fi
    done
fi

#--- Parse results -------------------------------------------------------------
hdr "-- Results --"
echo ""

TOTAL_SENT_BYTES=0
TOTAL_RECV_BYTES=0
TOTAL_RETRANSMITS=0
PROCESS_COUNT=0
FAILED_COUNT=0

printf "  %-8s %15s %15s %12s %8s\n" "Process" "Sent (Gbps)" "Recv (Gbps)" "Retransmits" "Status"
printf "  %-8s %15s %15s %12s %8s\n" "-------" "-----------" "-----------" "-----------" "------"

for (( i=0; i<INSTANCES; i++ )); do
    label="s$(( i+1 ))"
    outfile="${TMPDIR}/iperf3_${label}.json"

    if [[ ! -s "$outfile" ]]; then
        printf "  %-8s %15s %15s %12s %8s\n" "$label" "---" "---" "---" "NO DATA"
        FAILED_COUNT=$(( FAILED_COUNT + 1 ))
        continue
    fi

    # Check for iperf3 error in JSON
    iperf_error=$(json_error "$outfile")
    if [[ -n "$iperf_error" ]]; then
        printf "  %-8s  %-50s %8s\n" "$label" "$iperf_error" "ERROR"
        FAILED_COUNT=$(( FAILED_COUNT + 1 ))
        continue
    fi

    # Extract sender/receiver summary
    sent_bps=$(json_val "$outfile" "end.sum_sent.bits_per_second" 0)
    recv_bps=$(json_val "$outfile" "end.sum_received.bits_per_second" 0)
    retrans=$(json_val "$outfile" "end.sum_sent.retransmits" 0)

    # Validate bc inputs
    sent_bps=$(safe_number "$sent_bps" 0)
    recv_bps=$(safe_number "$recv_bps" 0)

    sent_gbps=$(echo "scale=2; $sent_bps / 1000000000" | bc)
    recv_gbps=$(echo "scale=2; $recv_bps / 1000000000" | bc)

    sent_bytes=$(json_val "$outfile" "end.sum_sent.bytes" 0)
    recv_bytes=$(json_val "$outfile" "end.sum_received.bytes" 0)

    # Sanitize to integers
    sent_bytes=$(printf '%.0f' "$(safe_number "$sent_bytes" 0)" 2>/dev/null || echo 0)
    recv_bytes=$(printf '%.0f' "$(safe_number "$recv_bytes" 0)" 2>/dev/null || echo 0)
    retrans=$(printf '%.0f' "$(safe_number "$retrans" 0)" 2>/dev/null || echo 0)

    TOTAL_SENT_BYTES=$(( TOTAL_SENT_BYTES + sent_bytes ))
    TOTAL_RECV_BYTES=$(( TOTAL_RECV_BYTES + recv_bytes ))
    TOTAL_RETRANSMITS=$(( TOTAL_RETRANSMITS + retrans ))
    PROCESS_COUNT=$(( PROCESS_COUNT + 1 ))

    status="OK"
    [[ "${EXIT_CODES[$i]}" -ne 0 ]] && status="WARN"

    printf "  %-8s %12.2f    %12.2f    %12d %8s\n" "$label" "$sent_gbps" "$recv_gbps" "$retrans" "$status"
done

echo ""

# Aggregate
EXIT_RC=0
if (( PROCESS_COUNT > 0 )); then
    AGG_SENT_GBPS=$(echo "scale=2; $TOTAL_SENT_BYTES * 8 / $DURATION / 1000000000" | bc)
    AGG_RECV_GBPS=$(echo "scale=2; $TOTAL_RECV_BYTES * 8 / $DURATION / 1000000000" | bc)
    AGG_SENT_GB=$(echo "scale=2; $TOTAL_SENT_BYTES / 1073741824" | bc)
    AGG_RECV_GB=$(echo "scale=2; $TOTAL_RECV_BYTES / 1073741824" | bc)

    # Print TOTAL row with BLD outside printf field widths for alignment
    echo -ne "  ${BLD}"
    printf "%-8s %12.2f    %12.2f    %12d" "TOTAL" "$AGG_SENT_GBPS" "$AGG_RECV_GBPS" "$TOTAL_RETRANSMITS"
    echo -e "${RST}"
    echo ""
    info "Aggregate sent:     ${AGG_SENT_GB} GB  ->  ${AGG_SENT_GBPS} Gbps"
    info "Aggregate received: ${AGG_RECV_GB} GB  ->  ${AGG_RECV_GBPS} Gbps"
    info "Total retransmits:  $TOTAL_RETRANSMITS"

    # NIC-level sanity check (only if interface exists)
    if ip link show "$INTERFACE" &>/dev/null; then
        TX_DELTA=$(( TX_AFTER - TX_BEFORE ))
        RX_DELTA=$(( RX_AFTER - RX_BEFORE ))
        NIC_TX_GBPS=$(echo "scale=2; $TX_DELTA * 8 / $DURATION / 1000000000" | bc)
        NIC_RX_GBPS=$(echo "scale=2; $RX_DELTA * 8 / $DURATION / 1000000000" | bc)
        echo ""
        info "NIC-level TX delta ($INTERFACE): $(echo "scale=2; $TX_DELTA / 1073741824" | bc) GB -> ${NIC_TX_GBPS} Gbps"
        info "NIC-level RX delta ($INTERFACE): $(echo "scale=2; $RX_DELTA / 1073741824" | bc) GB -> ${NIC_RX_GBPS} Gbps"
    fi
else
    err "No successful iperf3 processes. Check server connectivity."
    EXIT_RC=1
fi

if (( FAILED_COUNT > 0 )); then
    warn "$FAILED_COUNT of $INSTANCES processes failed. Check server is running on all ports."
fi

#--- Throughput assessment -----------------------------------------------------
hdr "-- Assessment --"
echo ""
if (( PROCESS_COUNT > 0 )); then
    PASS_THRESHOLD=$(echo "scale=0; $TARGET_GBPS * 95 / 100" | bc)
    WARN_THRESHOLD=$(echo "scale=0; $TARGET_GBPS * 75 / 100" | bc)
    PCT=$(echo "scale=1; $AGG_SENT_GBPS * 100 / $TARGET_GBPS" | bc)
    if (( $(echo "$AGG_SENT_GBPS >= $PASS_THRESHOLD" | bc -l) )); then
        ok "Throughput ${AGG_SENT_GBPS} Gbps — ${PCT}% of ${TARGET_GBPS}G target. PASS"
    elif (( $(echo "$AGG_SENT_GBPS >= $WARN_THRESHOLD" | bc -l) )); then
        warn "Throughput ${AGG_SENT_GBPS} Gbps — ${PCT}% of ${TARGET_GBPS}G target."
        warn "Possible bottlenecks: VNIC caps, TCP tuning, NUMA locality, or IRQ affinity."
        EXIT_RC=2
    else
        err "Throughput ${AGG_SENT_GBPS} Gbps — only ${PCT}% of ${TARGET_GBPS}G target."
        err "Likely hitting per-VNIC bandwidth cap. See remediation below."
        EXIT_RC=2
    fi
fi

#--- Copy JSON results if requested --------------------------------------------
if [[ -n "$JSON_DIR" ]]; then
    shopt -s nullglob
    json_files=("${TMPDIR}"/iperf3_*.json)
    shopt -u nullglob
    if (( ${#json_files[@]} > 0 )); then
        cp "${json_files[@]}" "$JSON_DIR/"
        info "JSON results saved to $JSON_DIR/"
    else
        warn "No JSON result files to save."
    fi
fi

#--- Remediation guidance ------------------------------------------------------
hdr "-- Remediation Checklist (if below target) --"
iface_display="$INTERFACE"
cat <<GUIDANCE

  1. VNIC CAPS: Each OCI VNIC is capped at ~25 Gbps. To reach ${TARGET_GBPS}G aggregate,
     you need multiple VNICs bound to separate physical NICs. Verify with:
       oci compute instance list-vnics --instance-id <OCID>

  2. TCP BUFFER TUNING: For ${TARGET_GBPS}G, set on BOTH client and server:
       sudo sysctl -w net.core.rmem_max=268435456
       sudo sysctl -w net.core.wmem_max=268435456
       sudo sysctl -w net.ipv4.tcp_rmem='4096 131072 268435456'
       sudo sysctl -w net.ipv4.tcp_wmem='4096 16384 268435456'
       sudo sysctl -w net.ipv4.tcp_congestion_control=bbr

  3. JUMBO FRAMES: Set MTU 9000 on both ends and all intermediate hops:
       sudo ip link set ${iface_display} mtu 9000

  4. IRQ AFFINITY: Distribute NIC interrupts across cores:
       sudo apt-get install -y irqbalance
       # Or manually pin with: /proc/irq/N/smp_affinity_list

  5. NUMA PINNING: Run iperf3 on the NUMA node that owns the NIC:
       numactl --cpunodebind=<NIC_NUMA> --membind=<NIC_NUMA> iperf3 ...

  6. CPU GOVERNOR: Set governor to 'performance' for up to 30% throughput gain:
       sudo cpupower frequency-set -g performance
     Verify with: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

  7. NETDEV BUDGET & TX QUEUE: Increase for WAN/100G+ paths:
       sudo sysctl -w net.core.netdev_budget=600
       sudo sysctl -w net.core.netdev_budget_usecs=4000
       sudo ip link set ${iface_display} txqueuelen 10000

  8. NIC OFFLOADS: LRO off, GRO on (ESnet recommendation for 100G+):
       sudo ethtool -K ${iface_display} lro off
       sudo ethtool -K ${iface_display} gro on

  9. MULTI-VNIC TESTING: To test aggregate across VNICs, run separate
     iperf3 processes bound to each VNIC IP (--bind flag).
GUIDANCE
echo ""

exit $EXIT_RC
