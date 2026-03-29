#!/usr/bin/env bash
#===============================================================================
# iperf3_server.sh — Multi-process iperf3 server for high-speed bandwidth testing
#
# Based on ESnet guidance: https://fasterdata.es.net/performance-testing/
#   network-troubleshooting-tools/iperf/multi-stream-iperf3/
#
# Each iperf3 process is single-threaded, so we launch one per CPU core
# on separate ports to allow the client to drive aggregate bandwidth.
#
# Usage:
#   ./iperf3_server.sh [--instances N] [--base-port PORT] [--bind IP] [--affinity] [--yes] [--debug]
#   ./iperf3_server.sh --stop [--base-port PORT]
#===============================================================================
set -euo pipefail

SCRIPT_VERSION="1.2.1"
SCRIPT_VERSION_DATE="2026-03-28"

#--- Defaults ------------------------------------------------------------------
INSTANCES=10          # 10 processes x ~25G each = 250G headroom
BASE_PORT=5200
BIND_ADDR=""          # empty = all interfaces
CPU_AFFINITY=false    # pin each process to a separate core
STOP_MODE=false
AUTO_YES=false        # skip confirmations
DEBUG=false

#--- Color output --------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; DIM='\033[2m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
err()   { echo -e "${RED}[ERROR]${RST} $*"; }

#--- Action log ----------------------------------------------------------------
ACTION_LOG="./iperf3_action.log"
log_action() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$ACTION_LOG"
    echo -e "  ${DIM}[LOG] $*${RST}"
}

#--- Confirm-before-execute (no eval) ------------------------------------------
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

#--- Collect server IPs once ---------------------------------------------------
get_server_ips() {
    ip -4 addr show up 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' || true
}

#--- PID file management -------------------------------------------------------
get_pidfile() {
    echo "/tmp/iperf3_server_suite_${BASE_PORT}.pids"
}

save_pid() {
    local pidfile
    pidfile=$(get_pidfile)
    if [[ -L "$pidfile" ]]; then
        err "PID file is a symlink — refusing to write: $pidfile"
        exit 1
    fi
    echo "$1" >> "$pidfile"
}

read_pids() {
    local pidfile
    pidfile=$(get_pidfile)
    if [[ -f "$pidfile" ]]; then
        cat "$pidfile"
    fi
}

cleanup_pidfile() {
    local pidfile
    pidfile=$(get_pidfile)
    rm -f "$pidfile"
}

is_iperf3_process() {
    local pid="$1"
    [[ -f "/proc/$pid/comm" ]] && [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == "iperf3" ]]
}

#--- Parse arguments -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instances)
            [[ $# -lt 2 ]] && { err "--instances requires an argument"; exit 1; }
            INSTANCES="$2"; shift 2 ;;
        --base-port)
            [[ $# -lt 2 ]] && { err "--base-port requires an argument"; exit 1; }
            BASE_PORT="$2"; shift 2 ;;
        --bind)
            [[ $# -lt 2 ]] && { err "--bind requires an argument"; exit 1; }
            BIND_ADDR="$2"; shift 2 ;;
        --affinity)     CPU_AFFINITY=true; shift ;;
        --stop)         STOP_MODE=true;   shift ;;
        --yes|-y)       AUTO_YES=true;    shift ;;
        --debug)        DEBUG=true;       shift ;;
        -h|--help)
            echo "iperf3_server.sh v${SCRIPT_VERSION} (${SCRIPT_VERSION_DATE})"
            echo "Usage: $0 [--instances N] [--base-port PORT] [--bind IP] [--affinity] [--yes] [--debug] [--stop]"
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

$DEBUG && set -x

#--- Input validation ----------------------------------------------------------
if ! [[ "$INSTANCES" =~ ^[0-9]+$ ]] || (( INSTANCES < 1 )); then
    err "--instances must be a positive integer, got '$INSTANCES'"
    exit 1
fi
if ! [[ "$BASE_PORT" =~ ^[0-9]+$ ]] || (( BASE_PORT < 1024 || BASE_PORT > 65535 )); then
    err "--base-port must be 1024-65535, got '$BASE_PORT'"
    exit 1
fi
if (( BASE_PORT + INSTANCES - 1 > 65535 )); then
    err "Port range ${BASE_PORT}-$(( BASE_PORT + INSTANCES - 1 )) exceeds 65535"
    exit 1
fi
if [[ -n "$BIND_ADDR" ]] && ! [[ "$BIND_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "--bind must be a valid IPv4 address, got '$BIND_ADDR'"
    exit 1
fi

#--- Stop mode -----------------------------------------------------------------
if $STOP_MODE; then
    info "Stopping iperf3 server processes (base-port $BASE_PORT)..."
    PIDFILE=$(get_pidfile)
    if [[ -f "$PIDFILE" ]]; then
        KILLED=0
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            if is_iperf3_process "$pid"; then
                if kill "$pid" 2>/dev/null; then
                    log_action "STOP: killed iperf3 server PID $pid"
                    ok "Killed iperf3 server PID $pid"
                    KILLED=$(( KILLED + 1 ))
                fi
            else
                warn "PID $pid is not an iperf3 process — skipping"
            fi
        done < "$PIDFILE"
        cleanup_pidfile
        if (( KILLED > 0 )); then
            ok "Stopped $KILLED iperf3 server(s)."
        else
            warn "No running iperf3 servers found from PID file."
        fi
    else
        warn "No PID file found at $PIDFILE. No servers to stop."
        warn "If servers are running from a different base-port, use: $0 --stop --base-port <PORT>"
    fi
    exit 0
fi

#--- Pre-flight checks ---------------------------------------------------------
if ! command -v iperf3 &>/dev/null; then
    err "iperf3 not found. Install with: sudo apt-get install -y iperf3"
    exit 1
fi

HAS_LSOF=true
if ! command -v lsof &>/dev/null; then
    warn "lsof not found — port conflict detection disabled."
    warn "Install with: sudo apt-get install -y lsof"
    HAS_LSOF=false
fi

IPERF_VERSION=$(iperf3 --version 2>&1 | head -1)
info "iperf3 version: $IPERF_VERSION"
info "Script version: v${SCRIPT_VERSION} (${SCRIPT_VERSION_DATE})"

AVAILABLE_CORES=$(nproc)
info "Available CPU cores: $AVAILABLE_CORES"
if (( INSTANCES > AVAILABLE_CORES )); then
    warn "Requested $INSTANCES instances but only $AVAILABLE_CORES cores available."
    warn "Processes will share cores — consider reducing --instances."
fi

#--- Display server IP addresses -----------------------------------------------
info "Server IP addresses:"
while IFS= read -r line; do
    iface=$(echo "$line" | awk '{print $NF}')
    addr=$(echo "$line" | awk '{print $2}' | cut -d/ -f1)
    echo -e "    ${GRN}${addr}${RST}  (${iface})"
done < <(get_server_ips)
echo ""

#--- Auto-detect default interface for system checks ---------------------------
SRV_INTERFACE="eth0"
if ! ip link show eth0 &>/dev/null; then
    SRV_INTERFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}') || true
    if [[ -z "$SRV_INTERFACE" ]]; then
        SRV_INTERFACE=$(ip -4 addr show up 2>/dev/null | grep -v '127.0.0.1' | grep 'inet ' | head -1 | awk '{print $NF}') || true
    fi
fi

#--- Host system checks --------------------------------------------------------
info "Host system checks:"
echo ""

# TCP buffer settings
info "TCP buffer settings:"
for param in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    printf "  %-30s %s\n" "$param" "$val"
done

# Congestion control
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
if [[ "$CC" == "bbr" ]]; then
    ok "Congestion control: $CC"
else
    warn "Congestion control: $CC (recommended: bbr)"
fi

# MTU
echo ""
if [[ -n "$SRV_INTERFACE" ]] && ip link show "$SRV_INTERFACE" &>/dev/null; then
    SRV_MTU=$(ip link show "$SRV_INTERFACE" | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
    SRV_MTU=${SRV_MTU:-0}
    [[ "$SRV_MTU" =~ ^[0-9]+$ ]] || SRV_MTU=0
    if (( SRV_MTU >= 9000 )); then
        ok "MTU ($SRV_INTERFACE): $SRV_MTU"
    else
        warn "MTU ($SRV_INTERFACE): $SRV_MTU (recommended: 9000)"
    fi
fi

# IRQ balance
if pgrep irqbalance &>/dev/null; then
    ok "irqbalance: running"
else
    warn "irqbalance: NOT running"
fi

# CPU governor
CPU_GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
if [[ -f "$CPU_GOV_PATH" ]]; then
    CURRENT_GOV=$(cat "$CPU_GOV_PATH" 2>/dev/null || echo "N/A")
    AVAIL_GOVS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "N/A")
    if [[ "$CURRENT_GOV" == "performance" ]]; then
        ok "CPU governor: $CURRENT_GOV"
    else
        warn "CPU governor: $CURRENT_GOV (should be 'performance' for up to 30% throughput gain)"
    fi
    info "  Available governors: $AVAIL_GOVS"
else
    warn "CPU governor: N/A (no cpufreq sysfs — hypervisor-controlled)"
fi

# NIC driver and firmware
echo ""
if [[ -n "$SRV_INTERFACE" ]] && ip link show "$SRV_INTERFACE" &>/dev/null; then
    info "NIC info ($SRV_INTERFACE):"
    if command -v ethtool &>/dev/null; then
        drv_info=$(ethtool -i "$SRV_INTERFACE" 2>/dev/null) || true
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
            warn "  ethtool -i not supported on $SRV_INTERFACE"
        fi

        # Link speed
        link_speed=$(ethtool "$SRV_INTERFACE" 2>/dev/null | awk '/Speed:/{print $2}') || true
        link_duplex=$(ethtool "$SRV_INTERFACE" 2>/dev/null | awk '/Duplex:/{print $2}') || true
        printf "  %-20s %s\n" "Link speed:" "${link_speed:-N/A}"
        printf "  %-20s %s\n" "Duplex:" "${link_duplex:-N/A}"
    else
        warn "  ethtool not installed — cannot query NIC driver/firmware"
    fi
fi

# Netdev budget
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

# TX queue length
if [[ -n "$SRV_INTERFACE" ]] && ip link show "$SRV_INTERFACE" &>/dev/null; then
    CURRENT_TXQLEN=$(ip link show "$SRV_INTERFACE" | awk '/qlen/{for(i=1;i<=NF;i++) if($i=="qlen") print $(i+1)}')
    CURRENT_TXQLEN=${CURRENT_TXQLEN:-1000}
    [[ "$CURRENT_TXQLEN" =~ ^[0-9]+$ ]] || CURRENT_TXQLEN=1000
    if (( CURRENT_TXQLEN >= 10000 )); then
        ok "txqueuelen ($SRV_INTERFACE): $CURRENT_TXQLEN (recommended: 10000)"
    else
        warn "txqueuelen ($SRV_INTERFACE): $CURRENT_TXQLEN (recommended: 10000)"
    fi
fi

# NIC offload settings
echo ""
if [[ -n "$SRV_INTERFACE" ]] && ip link show "$SRV_INTERFACE" &>/dev/null && command -v ethtool &>/dev/null; then
    info "NIC offload settings ($SRV_INTERFACE):"
    offload_info=$(ethtool -k "$SRV_INTERFACE" 2>/dev/null) || true
    if [[ -n "$offload_info" ]]; then
        for feat in tcp-segmentation-offload generic-receive-offload large-receive-offload tx-checksumming rx-checksumming; do
            val=$(echo "$offload_info" | grep "^${feat}:" | awk '{print $2}')
            case "$feat" in
                large-receive-offload)
                    if [[ "$val" == "off" ]]; then
                        ok "  $feat: $val (recommended: off)"
                    else
                        warn "  $feat: $val (recommended: off)"
                    fi
                    ;;
                generic-receive-offload)
                    if [[ "$val" == "on" ]]; then
                        ok "  $feat: $val (recommended: on)"
                    else
                        warn "  $feat: $val (recommended: on)"
                    fi
                    ;;
                *)
                    info "  $feat: ${val:-N/A}"
                    ;;
            esac
        done
    fi
fi

# NUMA topology
if command -v numactl &>/dev/null; then
    echo ""
    info "NUMA nodes: $(numactl --hardware 2>/dev/null | grep 'available' || echo 'unknown')"
    if [[ -n "$SRV_INTERFACE" && -f "/sys/class/net/${SRV_INTERFACE}/device/numa_node" ]]; then
        NIC_NUMA=$(cat "/sys/class/net/${SRV_INTERFACE}/device/numa_node" 2>/dev/null || echo "")
        if [[ -n "$NIC_NUMA" && "$NIC_NUMA" != "-1" ]]; then
            info "  $SRV_INTERFACE is on NUMA node $NIC_NUMA"
        fi
    fi
fi

echo ""

#--- Kill any existing iperf3 servers on our port range ------------------------
if $HAS_LSOF; then
    for (( i=0; i<INSTANCES; i++ )); do
        port=$(( BASE_PORT + i ))
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            warn "Port $port in use by PID $pid"
            confirm_exec "Kill PID $pid on port $port" kill -- "$pid" || true
            sleep 0.2
        done < <(lsof -ti "TCP:$port" -sTCP:LISTEN 2>/dev/null || true)
    done
fi

#--- Launch servers ------------------------------------------------------------
info "Launching $INSTANCES iperf3 server instances (ports ${BASE_PORT}-$(( BASE_PORT + INSTANCES - 1 )))..."
echo ""

BIND_OPTS=()
[[ -n "$BIND_ADDR" ]] && BIND_OPTS=(--bind "$BIND_ADDR")

# Preview all commands before executing
echo -e "  ${CYN}Commands to execute:${RST}"
for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))
    if $CPU_AFFINITY; then
        echo -e "    ${DIM}\$ taskset -c $core iperf3 -s -p $port ${BIND_OPTS[*]:-} -D${RST}"
    else
        echo -e "    ${DIM}\$ iperf3 -s -p $port ${BIND_OPTS[*]:-} -D${RST}"
    fi
done
echo ""

if ! $AUTO_YES; then
    read -rp "  Launch all $INSTANCES server processes? [y/N]: " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *)
            warn "Aborted. No servers launched."
            exit 0
            ;;
    esac
else
    echo -e "  ${DIM}(auto-confirmed via --yes)${RST}"
fi

# Clear any stale PID file
cleanup_pidfile

echo ""
LAUNCHED=0
for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))

    if $CPU_AFFINITY; then
        taskset -c "$core" iperf3 -s -p "$port" "${BIND_OPTS[@]+"${BIND_OPTS[@]}"}" -D
        log_action "START: taskset -c $core iperf3 -s -p $port ${BIND_OPTS[*]:-} -D"
    else
        iperf3 -s -p "$port" "${BIND_OPTS[@]+"${BIND_OPTS[@]}"}" -D
        log_action "START: iperf3 -s -p $port ${BIND_OPTS[*]:-} -D"
    fi

    # Verify it started and save PID
    sleep 0.1
    aff_msg=""
    $CPU_AFFINITY && aff_msg=" (pinned to core $core)"
    if $HAS_LSOF; then
        srv_pid=$(lsof -ti "TCP:$port" -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$srv_pid" ]]; then
            save_pid "$srv_pid"
            ok "Server #$(( i+1 ))  port=$port  PID=$srv_pid${aff_msg}"
            LAUNCHED=$(( LAUNCHED + 1 ))
        else
            err "Server #$(( i+1 ))  port=$port FAILED to start"
        fi
    else
        ok "Server #$(( i+1 ))  port=$port${aff_msg}  (lsof unavailable — cannot verify)"
        LAUNCHED=$(( LAUNCHED + 1 ))
    fi
done

echo ""
if (( LAUNCHED == INSTANCES )); then
    info "All $LAUNCHED servers launched. Listening on ports ${BASE_PORT}-$(( BASE_PORT + INSTANCES - 1 ))."
else
    warn "Only $LAUNCHED of $INSTANCES servers launched successfully."
fi
echo ""
echo "  Client command (use one of the IPs above):"
while IFS= read -r line; do
    addr=$(echo "$line" | awk '{print $2}' | cut -d/ -f1)
    iface=$(echo "$line" | awk '{print $NF}')
    echo "    ./iperf3_client.sh --server $addr --instances $INSTANCES --base-port $BASE_PORT   # $iface"
done < <(get_server_ips)
echo ""
echo "  To stop all servers:"
echo "    $0 --stop --base-port $BASE_PORT"
echo ""
info "PID file: $(get_pidfile)"
