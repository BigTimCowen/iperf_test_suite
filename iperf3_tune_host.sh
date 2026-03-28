#!/usr/bin/env bash
#===============================================================================
# iperf3_tune_host.sh — Apply host tuning for high-speed network testing
#
# Run this on BOTH client and server before testing.
# Based on ESnet host tuning guidance: https://fasterdata.es.net/host-tuning/linux/
#
# NOTE: Backup is stored in /tmp and will be lost on reboot. For persistent
# tuning, add values to /etc/sysctl.d/99-network-tuning.conf instead.
#
# Usage:
#   sudo ./iperf3_tune_host.sh [--interface NAME] [--apply] [--revert]
#
# Without --apply, just shows current values and recommendations.
#===============================================================================
set -euo pipefail

INTERFACE="eth0"
APPLY=false
REVERT=false

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
err()   { echo -e "${RED}[ERROR]${RST} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interface|-I)  INTERFACE="$2"; shift 2 ;;
        --apply)         APPLY=true;     shift ;;
        --revert)        REVERT=true;    shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--interface NAME] [--apply] [--revert]"
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

BACKUP_FILE="/tmp/sysctl_backup_iperf3.conf"

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

#--- Revert mode ---------------------------------------------------------------
if $REVERT; then
    if [[ -f "$BACKUP_FILE" ]]; then
        info "Reverting sysctl settings from $BACKUP_FILE..."
        sysctl -p "$BACKUP_FILE" 2>/dev/null
        ok "Settings reverted."
        rm -f "$BACKUP_FILE"
    else
        warn "No backup file found at $BACKUP_FILE. Nothing to revert."
    fi
    exit 0
fi

#--- Display current values ----------------------------------------------------
echo -e "\n${BLD}═══════════════════════════════════════════════════════════${RST}"
echo -e "${BLD}  Host Tuning for High-Speed Network Testing${RST}"
echo -e "${BLD}═══════════════════════════════════════════════════════════${RST}\n"

info "Interface: $INTERFACE"
info "Mode: $( $APPLY && echo 'APPLY changes' || echo 'DRY RUN (use --apply to make changes)' )"
echo ""

# Define desired values
declare -A DESIRED=(
    [net.core.rmem_max]=268435456          # 256 MB
    [net.core.wmem_max]=268435456          # 256 MB
    [net.core.rmem_default]=16777216       # 16 MB
    [net.core.wmem_default]=16777216       # 16 MB
    [net.ipv4.tcp_rmem]="4096 131072 268435456"
    [net.ipv4.tcp_wmem]="4096 16384 268435456"
    [net.ipv4.tcp_congestion_control]=bbr
    [net.ipv4.tcp_mtu_probing]=1
    [net.ipv4.tcp_no_metrics_save]=1
    [net.core.netdev_max_backlog]=250000
    [net.core.optmem_max]=67108864
    [net.ipv4.tcp_timestamps]=1
    [net.ipv4.tcp_sack]=1
    [net.ipv4.tcp_window_scaling]=1
)

printf "  %-40s %-24s %-24s %s\n" "Parameter" "Current" "Recommended" "Status"
printf "  %-40s %-24s %-24s %s\n" "$(printf '%.0s-' {1..39})" "$(printf '%.0s-' {1..23})" "$(printf '%.0s-' {1..23})" "------"

CHANGES_NEEDED=0
BACKUP_ENTRIES=""

for param in "${!DESIRED[@]}"; do
    current=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    desired="${DESIRED[$param]}"

    # Normalize whitespace for comparison
    current_norm=$(echo "$current" | tr -s '[:space:]' ' ' | xargs)
    desired_norm=$(echo "$desired" | tr -s '[:space:]' ' ' | xargs)

    if [[ "$current_norm" == "$desired_norm" ]]; then
        status="${GRN}OK${RST}"
    else
        status="${YEL}CHANGE${RST}"
        CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
        BACKUP_ENTRIES+="${param}=${current_norm}\n"
    fi

    printf "  %-40s %-24s %-24s %b\n" "$param" "$current_norm" "$desired_norm" "$status"
done

# Interface-level checks
echo ""
if ip link show "$INTERFACE" &>/dev/null; then
    CURRENT_MTU=$(ip link show "$INTERFACE" | grep -oP 'mtu \K[0-9]+')
    if (( CURRENT_MTU >= 9000 )); then
        printf "  %-40s %-24s %-24s %b\n" "$INTERFACE MTU" "$CURRENT_MTU" "9000" "${GRN}OK${RST}"
    else
        printf "  %-40s %-24s %-24s %b\n" "$INTERFACE MTU" "$CURRENT_MTU" "9000" "${YEL}CHANGE${RST}"
        CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
    fi

    # Ring buffer sizes
    if command -v ethtool &>/dev/null; then
        echo ""
        info "Ring buffer settings ($INTERFACE):"
        ethtool -g "$INTERFACE" 2>/dev/null | head -10 || warn "ethtool -g not supported on this interface."
    fi

    # Offload settings
    echo ""
    info "Offload settings ($INTERFACE):"
    if command -v ethtool &>/dev/null; then
        for feat in tx-checksumming rx-checksumming tcp-segmentation-offload generic-receive-offload; do
            val=$(ethtool -k "$INTERFACE" 2>/dev/null | grep "^${feat}:" | awk '{print $2}' || echo "N/A")
            printf "  %-40s %s\n" "$feat" "$val"
        done
    fi
else
    warn "Interface $INTERFACE not found — skipping interface checks."
fi

# BBR module check
echo ""
if lsmod 2>/dev/null | grep -q tcp_bbr; then
    ok "tcp_bbr module is loaded."
else
    warn "tcp_bbr module not loaded. Loading it is needed for BBR congestion control."
    CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
fi

echo ""

#--- Apply mode ----------------------------------------------------------------
if $APPLY; then
    if (( CHANGES_NEEDED == 0 )); then
        ok "All settings already at recommended values. Nothing to change."
        exit 0
    fi

    if [[ $EUID -ne 0 ]]; then
        err "Must run with sudo to apply changes."
        exit 1
    fi

    # Save backup
    echo -e "$BACKUP_ENTRIES" > "$BACKUP_FILE"
    info "Current values backed up to $BACKUP_FILE"
    info "Revert with: sudo $0 --revert"
    warn "NOTE: Backup is in /tmp — it will be lost on reboot."
    echo ""

    # Load BBR module
    modprobe tcp_bbr 2>/dev/null || warn "Could not load tcp_bbr module."

    # Apply sysctl values
    for param in "${!DESIRED[@]}"; do
        desired="${DESIRED[$param]}"
        sysctl -w "${param}=${desired}" 2>/dev/null && \
            ok "Set $param = $desired" || \
            warn "Failed to set $param"
    done

    # Set MTU
    if ip link show "$INTERFACE" &>/dev/null; then
        CURRENT_MTU=$(ip link show "$INTERFACE" | grep -oP 'mtu \K[0-9]+')
        if (( CURRENT_MTU < 9000 )); then
            ip link set "$INTERFACE" mtu 9000 2>/dev/null && \
                ok "Set $INTERFACE MTU to 9000" || \
                warn "Failed to set MTU (may need VCN-level jumbo frame support)"
        fi
    fi

    echo ""
    ok "Host tuning applied. Run the test now, then revert with: sudo $0 --revert"
else
    if (( CHANGES_NEEDED > 0 )); then
        echo ""
        warn "$CHANGES_NEEDED settings differ from recommended values."
        info "To apply: sudo $0 --interface $INTERFACE --apply"
    else
        ok "All settings already at recommended values."
    fi
fi
