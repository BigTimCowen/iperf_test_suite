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
#                      [--yes]
#===============================================================================
set -euo pipefail

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

#--- Color output --------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
err()   { echo -e "${RED}[ERROR]${RST} $*"; }
hdr()   { echo -e "\n${BLD}$*${RST}"; }

#--- Confirm-before-execute (no eval) ------------------------------------------
# Usage: confirm_exec "description" command arg1 arg2 ...
confirm_exec() {
    local desc="$1"; shift
    echo -e "  ${CYN}▶ ${desc}${RST}"
    echo -e "    ${DIM}\$ $*${RST}"
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
        --server|-s)        SERVER="$2";          shift 2 ;;
        --instances)        INSTANCES="$2";       shift 2 ;;
        --base-port)        BASE_PORT="$2";       shift 2 ;;
        --duration|-t)      DURATION="$2";        shift 2 ;;
        --streams-per|-P)   STREAMS_PER="$2";     shift 2 ;;
        --window|-w)        WINDOW="$2";          shift 2 ;;
        --target)           TARGET_GBPS="$2";     shift 2 ;;
        --bind)             BIND_ADDR="$2";       shift 2 ;;
        --interface|-I)     INTERFACE="$2";       shift 2 ;;
        --affinity)         CPU_AFFINITY=true;    shift ;;
        --mtu-check)        MTU_CHECK=true;       shift ;;
        --raw)              SHOW_RAW=true;        shift ;;
        --json-dir)         JSON_DIR="$2";        shift 2 ;;
        --yes|-y)           AUTO_YES=true;        shift ;;
        -h|--help)
            cat <<'EOF'
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
  -h, --help            Show this help
EOF
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$SERVER" ]] && { err "Missing --server <IP>. Use -h for help."; exit 1; }

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
        d = d[k]
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

TMPDIR=$(mktemp -d /tmp/iperf3_test.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

AVAILABLE_CORES=$(nproc)
TOTAL_STREAMS=$(( INSTANCES * STREAMS_PER ))

hdr "╔══════════════════════════════════════════════════════════════╗"
hdr "║          iperf3 Multi-Process Bandwidth Test                ║"
hdr "╚══════════════════════════════════════════════════════════════╝"
echo ""
info "Server:           $SERVER"
info "Processes:        $INSTANCES"
info "Streams/process:  $STREAMS_PER"
info "Total streams:    $TOTAL_STREAMS"
info "Duration:         ${DURATION}s"
info "TCP window:       ${WINDOW:-auto (kernel default)}"
info "Target:           ${TARGET_GBPS} Gbps"
info "Port range:       ${BASE_PORT}–$(( BASE_PORT + INSTANCES - 1 ))"
info "CPU affinity:     $CPU_AFFINITY"
info "Monitor iface:    $INTERFACE"
info "Available cores:  $AVAILABLE_CORES"
info "Show raw output:  $SHOW_RAW"

#--- System checks -------------------------------------------------------------
hdr "── Pre-Test System Checks ──"

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
        *M) req_bytes=$(( ${WINDOW%M} * 1024 * 1024 )) ;;
        *K) req_bytes=$(( ${WINDOW%K} * 1024 )) ;;
        *G) req_bytes=$(( ${WINDOW%G} * 1024 * 1024 * 1024 )) ;;
        *)  req_bytes=$WINDOW ;;
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
    CURRENT_MTU=$(ip link show "$INTERFACE" | grep -oP 'mtu \K[0-9]+')
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
        # Note: confirm_exec runs the command directly, so we wrap ping
        # in a subshell to suppress its output without swallowing the prompt
        if confirm_exec "MTU probe (payload=$sz)" bash -c "ping -M do -s $sz -c 1 -W 2 $SERVER &>/dev/null"; then
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
if pgrep irqbalance &>/dev/null; then
    info "irqbalance is running (OK for general use, may want manual IRQ pinning for ${TARGET_GBPS}G)."
else
    info "irqbalance is NOT running."
fi

#--- Capture baseline NIC counters ---------------------------------------------
TX_BEFORE=$(get_iface_bytes tx_bytes)
RX_BEFORE=$(get_iface_bytes rx_bytes)

#--- Build command options -----------------------------------------------------
BIND_OPT=""
[[ -n "$BIND_ADDR" ]] && BIND_OPT="--bind $BIND_ADDR"
WINDOW_OPT=""
[[ -n "$WINDOW" ]] && WINDOW_OPT="-w $WINDOW"

#--- Launch clients ------------------------------------------------------------
hdr "── Running Test ──"
echo ""

# Preview all commands
echo -e "  ${CYN}Commands to execute:${RST}"
for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))
    label="s$(( i+1 ))"
    outfile="\${TMPDIR}/iperf3_${label}.json"
    base_cmd="iperf3 -c $SERVER -p $port -P $STREAMS_PER -t $DURATION $WINDOW_OPT -J $BIND_OPT"
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

declare -a CLIENT_PIDS=()
for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))
    label="s$(( i+1 ))"
    outfile="${TMPDIR}/iperf3_${label}.json"

    if $CPU_AFFINITY; then
        taskset -c "$core" iperf3 -c "$SERVER" -p "$port" -P "$STREAMS_PER" \
            -t "$DURATION" $WINDOW_OPT -J $BIND_OPT > "$outfile" 2>&1 &
    else
        iperf3 -c "$SERVER" -p "$port" -P "$STREAMS_PER" \
            -t "$DURATION" $WINDOW_OPT -J $BIND_OPT > "$outfile" 2>&1 &
    fi
    CLIENT_PIDS+=($!)

    aff_msg=""
    $CPU_AFFINITY && aff_msg=" → core $core"
    info "  Process $label  port=$port  PID=${CLIENT_PIDS[-1]}${aff_msg}"
done

echo ""
info "All $INSTANCES processes launched. Waiting ${DURATION}s for completion..."

#--- Progress indicator --------------------------------------------------------
ELAPSED=0
while (( ELAPSED < DURATION + 5 )); do
    ALL_DONE=true
    for pid in "${CLIENT_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            ALL_DONE=false
            break
        fi
    done
    $ALL_DONE && break

    printf "\r  [%3ds / %ds]  " "$ELAPSED" "$DURATION"
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
done
echo ""

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
    hdr "── Raw iperf3 Output (per-process) ──"
    for (( i=0; i<INSTANCES; i++ )); do
        label="s$(( i+1 ))"
        outfile="${TMPDIR}/iperf3_${label}.json"
        echo ""
        echo -e "  ${BLD}── Process $label (port $(( BASE_PORT + i ))) ──${RST}"
        if [[ -s "$outfile" ]]; then
            json_pretty "$outfile"
        else
            echo "  (no output)"
        fi
    done
fi

#--- Parse results -------------------------------------------------------------
hdr "── Results ──"
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
        printf "  %-8s %15s %15s %12s %8s\n" "$label" "—" "—" "—" "NO DATA"
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

    sent_gbps=$(echo "scale=2; $sent_bps / 1000000000" | bc)
    recv_gbps=$(echo "scale=2; $recv_bps / 1000000000" | bc)

    sent_bytes=$(json_val "$outfile" "end.sum_sent.bytes" 0)
    recv_bytes=$(json_val "$outfile" "end.sum_received.bytes" 0)

    # Sanitize to integers
    sent_bytes=$(printf '%.0f' "$sent_bytes" 2>/dev/null || echo 0)
    recv_bytes=$(printf '%.0f' "$recv_bytes" 2>/dev/null || echo 0)
    retrans=$(printf '%.0f' "$retrans" 2>/dev/null || echo 0)

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
if (( PROCESS_COUNT > 0 )); then
    AGG_SENT_GBPS=$(echo "scale=2; $TOTAL_SENT_BYTES * 8 / $DURATION / 1000000000" | bc)
    AGG_RECV_GBPS=$(echo "scale=2; $TOTAL_RECV_BYTES * 8 / $DURATION / 1000000000" | bc)
    AGG_SENT_GB=$(echo "scale=2; $TOTAL_SENT_BYTES / 1073741824" | bc)
    AGG_RECV_GB=$(echo "scale=2; $TOTAL_RECV_BYTES / 1073741824" | bc)

    printf "  ${BLD}%-8s %12.2f    %12.2f    %12d${RST}\n" "TOTAL" "$AGG_SENT_GBPS" "$AGG_RECV_GBPS" "$TOTAL_RETRANSMITS"
    echo ""
    info "Aggregate sent:     ${AGG_SENT_GB} GB  →  ${AGG_SENT_GBPS} Gbps"
    info "Aggregate received: ${AGG_RECV_GB} GB  →  ${AGG_RECV_GBPS} Gbps"
    info "Total retransmits:  $TOTAL_RETRANSMITS"

    # NIC-level sanity check (only if interface exists)
    if ip link show "$INTERFACE" &>/dev/null; then
        TX_DELTA=$(( TX_AFTER - TX_BEFORE ))
        RX_DELTA=$(( RX_AFTER - RX_BEFORE ))
        NIC_TX_GBPS=$(echo "scale=2; $TX_DELTA * 8 / $DURATION / 1000000000" | bc)
        NIC_RX_GBPS=$(echo "scale=2; $RX_DELTA * 8 / $DURATION / 1000000000" | bc)
        echo ""
        info "NIC-level TX delta ($INTERFACE): $(echo "scale=2; $TX_DELTA / 1073741824" | bc) GB → ${NIC_TX_GBPS} Gbps"
        info "NIC-level RX delta ($INTERFACE): $(echo "scale=2; $RX_DELTA / 1073741824" | bc) GB → ${NIC_RX_GBPS} Gbps"
    fi
else
    err "No successful iperf3 processes. Check server connectivity."
fi

if (( FAILED_COUNT > 0 )); then
    warn "$FAILED_COUNT of $INSTANCES processes failed. Check server is running on all ports."
fi

#--- Throughput assessment -----------------------------------------------------
hdr "── Assessment ──"
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
    else
        err "Throughput ${AGG_SENT_GBPS} Gbps — only ${PCT}% of ${TARGET_GBPS}G target."
        err "Likely hitting per-VNIC bandwidth cap. See remediation below."
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
hdr "── Remediation Checklist (if below target) ──"
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
       sudo ip link set $INTERFACE mtu 9000

  4. IRQ AFFINITY: Distribute NIC interrupts across cores:
       sudo apt-get install -y irqbalance
       # Or manually pin with: /proc/irq/N/smp_affinity_list

  5. NUMA PINNING: Run iperf3 on the NUMA node that owns the NIC:
       numactl --cpunodebind=<NIC_NUMA> --membind=<NIC_NUMA> iperf3 ...

  6. MULTI-VNIC TESTING: To test aggregate across VNICs, run separate
     iperf3 processes bound to each VNIC IP (--bind flag).
GUIDANCE
echo ""
