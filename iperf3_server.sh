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
#   ./iperf3_server.sh [--instances N] [--base-port PORT] [--bind IP] [--affinity] [--yes]
#   ./iperf3_server.sh --stop
#===============================================================================
set -euo pipefail

#--- Defaults ------------------------------------------------------------------
INSTANCES=10          # 10 processes × ~25G each ≈ 250G headroom
BASE_PORT=5200
BIND_ADDR=""          # empty = all interfaces
CPU_AFFINITY=false    # pin each process to a separate core
STOP_MODE=false
AUTO_YES=false        # skip confirmations

#--- Color output --------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; DIM='\033[2m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
err()   { echo -e "${RED}[ERROR]${RST} $*"; }

#--- Confirm-before-execute (no eval) ------------------------------------------
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

#--- Collect server IPs once ---------------------------------------------------
get_server_ips() {
    ip -4 addr show up 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' || true
}

#--- Parse arguments -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instances)    INSTANCES="$2";   shift 2 ;;
        --base-port)    BASE_PORT="$2";   shift 2 ;;
        --bind)         BIND_ADDR="$2";   shift 2 ;;
        --affinity)     CPU_AFFINITY=true; shift ;;
        --stop)         STOP_MODE=true;   shift ;;
        --yes|-y)       AUTO_YES=true;    shift ;;
        -h|--help)
            echo "Usage: $0 [--instances N] [--base-port PORT] [--bind IP] [--affinity] [--yes] [--stop]"
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

#--- Stop mode -----------------------------------------------------------------
if $STOP_MODE; then
    info "Stopping all iperf3 server processes..."
    confirm_exec "Kill all iperf3 server processes" pkill -f "iperf3 -s" && \
        ok "All iperf3 servers stopped." || warn "No iperf3 servers found or skipped."
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

#--- Kill any existing iperf3 servers on our port range ------------------------
if $HAS_LSOF; then
    for (( i=0; i<INSTANCES; i++ )); do
        port=$(( BASE_PORT + i ))
        # lsof can return multiple PIDs — handle each
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            warn "Port $port in use by PID $pid"
            confirm_exec "Kill PID $pid on port $port" kill "$pid" || true
            sleep 0.2
        done < <(lsof -ti :"$port" 2>/dev/null || true)
    done
fi

#--- Launch servers ------------------------------------------------------------
info "Launching $INSTANCES iperf3 server instances (ports ${BASE_PORT}–$(( BASE_PORT + INSTANCES - 1 )))..."
echo ""

BIND_OPT=""
[[ -n "$BIND_ADDR" ]] && BIND_OPT="--bind $BIND_ADDR"

# Preview all commands before executing
echo -e "  ${CYN}Commands to execute:${RST}"
for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))
    if $CPU_AFFINITY; then
        echo -e "    ${DIM}\$ taskset -c $core iperf3 -s -p $port $BIND_OPT -D${RST}"
    else
        echo -e "    ${DIM}\$ iperf3 -s -p $port $BIND_OPT -D${RST}"
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

echo ""
for (( i=0; i<INSTANCES; i++ )); do
    port=$(( BASE_PORT + i ))
    core=$(( i % AVAILABLE_CORES ))

    if $CPU_AFFINITY; then
        taskset -c "$core" iperf3 -s -p "$port" $BIND_OPT -D
    else
        iperf3 -s -p "$port" $BIND_OPT -D
    fi

    # Verify it started
    sleep 0.1
    aff_msg=""
    $CPU_AFFINITY && aff_msg=" (pinned to core $core)"
    if $HAS_LSOF && lsof -ti :"$port" &>/dev/null; then
        ok "Server #$(( i+1 ))  port=$port${aff_msg}"
    elif ! $HAS_LSOF; then
        ok "Server #$(( i+1 ))  port=$port${aff_msg}  (lsof unavailable — cannot verify)"
    else
        err "Server #$(( i+1 ))  port=$port FAILED to start"
    fi
done

echo ""
info "All servers launched. Listening on ports ${BASE_PORT}–$(( BASE_PORT + INSTANCES - 1 ))."
echo ""
echo "  Client command (use one of the IPs above):"
while IFS= read -r line; do
    addr=$(echo "$line" | awk '{print $2}' | cut -d/ -f1)
    iface=$(echo "$line" | awk '{print $NF}')
    echo "    ./iperf3_client.sh --server $addr --instances $INSTANCES --base-port $BASE_PORT   # $iface"
done < <(get_server_ips)
echo ""
echo "  To stop all servers:"
echo "    $0 --stop"
