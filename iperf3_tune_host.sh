#!/usr/bin/env bash
#===============================================================================
# iperf3_tune_host.sh — Apply host tuning for high-speed network testing
#
# Run this on BOTH client and server before testing.
# Based on ESnet host tuning guidance: https://fasterdata.es.net/host-tuning/linux/
#
# Usage:
#   sudo ./iperf3_tune_host.sh [--interface NAME] [--apply] [--revert] [--debug]
#
# Without --apply, just shows current values and recommendations.
#===============================================================================
set -euo pipefail

SCRIPT_VERSION="1.2.1"
SCRIPT_VERSION_DATE="2026-03-28"

INTERFACE="eth0"
APPLY=false
REVERT=false
DEBUG=false

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interface|-I)
            [[ $# -lt 2 ]] && { err "--interface requires an argument"; exit 1; }
            INTERFACE="$2"; shift 2 ;;
        --apply)         APPLY=true;     shift ;;
        --revert)        REVERT=true;    shift ;;
        --debug)         DEBUG=true;     shift ;;
        -h|--help)
            echo "iperf3_tune_host.sh v${SCRIPT_VERSION} (${SCRIPT_VERSION_DATE})"
            echo "Usage: sudo $0 [--interface NAME] [--apply] [--revert] [--debug]"
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

$DEBUG && set -x

#--- Input validation ----------------------------------------------------------
if ! [[ "$INTERFACE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    err "Invalid interface name: '$INTERFACE'"
    exit 1
fi

#--- Root check for apply/revert early -----------------------------------------
if $APPLY || $REVERT; then
    if [[ $EUID -ne 0 ]]; then
        err "Must run with sudo to apply/revert changes."
        exit 1
    fi
fi

#--- Backup file in a safe location --------------------------------------------
BACKUP_DIR="/var/lib/iperf3_tune"
BACKUP_FILE="${BACKUP_DIR}/sysctl_backup.conf"
MTU_BACKUP_FILE="${BACKUP_DIR}/mtu_backup.conf"
GOV_BACKUP_FILE="${BACKUP_DIR}/governor_backup.conf"
TXQLEN_BACKUP_FILE="${BACKUP_DIR}/txqueuelen_backup.conf"
OFFLOAD_BACKUP_FILE="${BACKUP_DIR}/offload_backup.conf"

ensure_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
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

#--- Revert mode ---------------------------------------------------------------
if $REVERT; then
    if [[ -f "$BACKUP_FILE" ]]; then
        # Symlink check
        if [[ -L "$BACKUP_FILE" ]]; then
            err "Backup file is a symlink — refusing to load. Investigate: $BACKUP_FILE"
            exit 1
        fi
        info "Reverting sysctl settings from $BACKUP_FILE..."
        sysctl -p "$BACKUP_FILE" 2>/dev/null
        log_action "REVERT: sysctl -p $BACKUP_FILE"
        ok "Sysctl settings reverted."
        rm -f "$BACKUP_FILE"
    else
        warn "No sysctl backup file found at $BACKUP_FILE. Nothing to revert."
    fi
    # Restore CPU governor if backup exists
    if [[ -f "$GOV_BACKUP_FILE" ]]; then
        if [[ -L "$GOV_BACKUP_FILE" ]]; then
            err "Governor backup file is a symlink — refusing to load."
            exit 1
        fi
        old_gov=$(cat "$GOV_BACKUP_FILE")
        if [[ -n "$old_gov" ]]; then
            gov_reverted=0
            for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [[ -f "$cpu_gov" ]] || continue
                echo "$old_gov" > "$cpu_gov" 2>/dev/null && gov_reverted=$(( gov_reverted + 1 ))
            done
            if (( gov_reverted > 0 )); then
                ok "Restored CPU governor to '$old_gov' on $gov_reverted CPUs"
                log_action "REVERT: CPU governor -> $old_gov ($gov_reverted CPUs)"
            else
                warn "Failed to restore CPU governor to '$old_gov'"
            fi
        fi
        rm -f "$GOV_BACKUP_FILE"
    fi
    # Restore MTU if backup exists
    if [[ -f "$MTU_BACKUP_FILE" ]]; then
        if [[ -L "$MTU_BACKUP_FILE" ]]; then
            err "MTU backup file is a symlink — refusing to load."
            exit 1
        fi
        while IFS='=' read -r iface_name old_mtu; do
            [[ -z "$iface_name" || -z "$old_mtu" ]] && continue
            if ip link show "$iface_name" &>/dev/null; then
                if ip link set "$iface_name" mtu "$old_mtu" 2>/dev/null; then
                    ok "Restored $iface_name MTU to $old_mtu"
                else
                    warn "Failed to restore MTU on $iface_name"
                fi
                log_action "REVERT: ip link set $iface_name mtu $old_mtu"
            fi
        done < "$MTU_BACKUP_FILE"
        rm -f "$MTU_BACKUP_FILE"
    fi
    # Restore txqueuelen if backup exists
    if [[ -f "$TXQLEN_BACKUP_FILE" ]]; then
        if [[ -L "$TXQLEN_BACKUP_FILE" ]]; then
            err "txqueuelen backup file is a symlink — refusing to load."
            exit 1
        fi
        while IFS='=' read -r iface_name old_txqlen; do
            [[ -z "$iface_name" || -z "$old_txqlen" ]] && continue
            if ip link show "$iface_name" &>/dev/null; then
                if ip link set "$iface_name" txqueuelen "$old_txqlen" 2>/dev/null; then
                    ok "Restored $iface_name txqueuelen to $old_txqlen"
                else
                    warn "Failed to restore txqueuelen on $iface_name"
                fi
                log_action "REVERT: ip link set $iface_name txqueuelen $old_txqlen"
            fi
        done < "$TXQLEN_BACKUP_FILE"
        rm -f "$TXQLEN_BACKUP_FILE"
    fi
    # Restore NIC offloads if backup exists
    if [[ -f "$OFFLOAD_BACKUP_FILE" ]]; then
        if [[ -L "$OFFLOAD_BACKUP_FILE" ]]; then
            err "Offload backup file is a symlink — refusing to load."
            exit 1
        fi
        while IFS='=' read -r key val; do
            [[ -z "$key" || -z "$val" ]] && continue
            iface="${key%%:*}"
            feat="${key#*:}"
            if ip link show "$iface" &>/dev/null && command -v ethtool &>/dev/null; then
                if ethtool -K "$iface" "$feat" "$val" 2>/dev/null; then
                    ok "Restored $iface $feat to $val"
                else
                    warn "Failed to restore $feat on $iface"
                fi
                log_action "REVERT: ethtool -K $iface $feat $val"
            fi
        done < "$OFFLOAD_BACKUP_FILE"
        rm -f "$OFFLOAD_BACKUP_FILE"
    fi
    exit 0
fi

#--- Display current values ----------------------------------------------------
echo -e "\n${BLD}=======================================================${RST}"
echo -e "${BLD}  Host Tuning for High-Speed Network Testing v${SCRIPT_VERSION}${RST}"
echo -e "${BLD}=======================================================${RST}\n"

info "Interface: $INTERFACE"
info "Mode: $( $APPLY && echo 'APPLY changes' || echo 'DRY RUN (use --apply to make changes)' )"
echo ""

# Define desired values and ordered key list for deterministic iteration
PARAM_ORDER=(
    net.core.rmem_max
    net.core.wmem_max
    net.core.rmem_default
    net.core.wmem_default
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_no_metrics_save
    net.core.netdev_max_backlog
    net.core.netdev_budget
    net.core.netdev_budget_usecs
    net.core.optmem_max
    net.ipv4.tcp_timestamps
    net.ipv4.tcp_sack
    net.ipv4.tcp_window_scaling
)

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
    [net.core.netdev_budget]=600               # ESnet 100G: default 300, WAN 600
    [net.core.netdev_budget_usecs]=4000        # ESnet 100G: default 2000, WAN 4000
    [net.core.optmem_max]=67108864
    [net.ipv4.tcp_timestamps]=1
    [net.ipv4.tcp_sack]=1
    [net.ipv4.tcp_window_scaling]=1
)

printf "  %-40s %-24s %-24s %s\n" "Parameter" "Current" "Recommended" "Status"
printf "  %-40s %-24s %-24s %s\n" "$(printf '%.0s-' {1..39})" "$(printf '%.0s-' {1..23})" "$(printf '%.0s-' {1..23})" "------"

CHANGES_NEEDED=0
declare -a BACKUP_LINES=()

for param in "${PARAM_ORDER[@]}"; do
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
        BACKUP_LINES+=("${param}=${current_norm}")
    fi

    printf "  %-40s %-24s %-24s %b\n" "$param" "$current_norm" "$desired_norm" "$status"
done

# Interface-level checks
echo ""
if ip link show "$INTERFACE" &>/dev/null; then
    CURRENT_MTU=$(ip link show "$INTERFACE" | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
    CURRENT_MTU=${CURRENT_MTU:-0}
    [[ "$CURRENT_MTU" =~ ^[0-9]+$ ]] || CURRENT_MTU=0
    if (( CURRENT_MTU >= 9000 )); then
        printf "  %-40s %-24s %-24s %b\n" "$INTERFACE MTU" "$CURRENT_MTU" "9000" "${GRN}OK${RST}"
    else
        printf "  %-40s %-24s %-24s %b\n" "$INTERFACE MTU" "$CURRENT_MTU" "9000" "${YEL}CHANGE${RST}"
        CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
    fi

    # TX queue length (ESnet: 10000 recommended for WAN, default 1000 OK for LAN)
    CURRENT_TXQLEN=$(ip link show "$INTERFACE" | awk '/qlen/{for(i=1;i<=NF;i++) if($i=="qlen") print $(i+1)}')
    CURRENT_TXQLEN=${CURRENT_TXQLEN:-1000}
    [[ "$CURRENT_TXQLEN" =~ ^[0-9]+$ ]] || CURRENT_TXQLEN=1000
    if (( CURRENT_TXQLEN >= 10000 )); then
        printf "  %-40s %-24s %-24s %b\n" "$INTERFACE txqueuelen" "$CURRENT_TXQLEN" "10000" "${GRN}OK${RST}"
    else
        printf "  %-40s %-24s %-24s %b\n" "$INTERFACE txqueuelen" "$CURRENT_TXQLEN" "10000" "${YEL}CHANGE${RST}"
        CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
    fi

    # Ring buffer sizes
    if command -v ethtool &>/dev/null; then
        echo ""
        info "Ring buffer settings ($INTERFACE):"
        ethtool -g "$INTERFACE" 2>/dev/null | head -10 || warn "ethtool -g not supported on this interface."
    fi

    # Offload settings (ESnet: LRO off, GRO on for 100G+)
    echo ""
    info "Offload settings ($INTERFACE):"
    if command -v ethtool &>/dev/null; then
        for feat in tx-checksumming rx-checksumming tcp-segmentation-offload generic-receive-offload large-receive-offload; do
            val=$(ethtool -k "$INTERFACE" 2>/dev/null | grep "^${feat}:" | awk '{print $2}' || echo "N/A")
            case "$feat" in
                large-receive-offload)
                    if [[ "$val" == "off" ]]; then
                        printf "  %-40s %-24s %-24s %b\n" "$feat" "$val" "off" "${GRN}OK${RST}"
                    elif [[ "$val" == "on" ]]; then
                        printf "  %-40s %-24s %-24s %b\n" "$feat" "$val" "off" "${YEL}CHANGE${RST}"
                        warn "LRO is on. ESnet recommends LRO off, GRO on for 100G+."
                        warn "  Set with: sudo ethtool -K $INTERFACE lro off"
                        CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
                    else
                        printf "  %-40s %s\n" "$feat" "$val"
                    fi
                    ;;
                generic-receive-offload)
                    if [[ "$val" == "on" ]]; then
                        printf "  %-40s %-24s %-24s %b\n" "$feat" "$val" "on" "${GRN}OK${RST}"
                    elif [[ "$val" == "off" ]]; then
                        printf "  %-40s %-24s %-24s %b\n" "$feat" "$val" "on" "${YEL}CHANGE${RST}"
                        warn "GRO is off. ESnet recommends GRO on for 100G+."
                        warn "  Set with: sudo ethtool -K $INTERFACE gro on"
                        CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
                    else
                        printf "  %-40s %s\n" "$feat" "$val"
                    fi
                    ;;
                *)
                    printf "  %-40s %s\n" "$feat" "$val"
                    ;;
            esac
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

# CPU governor check (ESnet: "performance" governor can increase throughput by ~30%)
echo ""
CPU_GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
if [[ -f "$CPU_GOV_PATH" ]]; then
    CURRENT_GOV=$(cat "$CPU_GOV_PATH" 2>/dev/null || echo "N/A")
    if [[ "$CURRENT_GOV" == "performance" ]]; then
        printf "  %-40s %-24s %-24s %b\n" "CPU governor" "$CURRENT_GOV" "performance" "${GRN}OK${RST}"
    else
        printf "  %-40s %-24s %-24s %b\n" "CPU governor" "$CURRENT_GOV" "performance" "${YEL}CHANGE${RST}"
        CHANGES_NEEDED=$(( CHANGES_NEEDED + 1 ))
        warn "CPU governor is '$CURRENT_GOV'. ESnet recommends 'performance' for up to 30% throughput gain."
        warn "  Set with: cpupower frequency-set -g performance"
    fi
    # Show available governors
    AVAIL_GOVS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "N/A")
    info "Available governors: $AVAIL_GOVS"
else
    info "CPU frequency scaling not available (no cpufreq sysfs). Governor check skipped."
fi

# NIC driver and firmware info
echo ""
if ip link show "$INTERFACE" &>/dev/null && command -v ethtool &>/dev/null; then
    info "NIC driver/firmware ($INTERFACE):"
    drv_info=$(ethtool -i "$INTERFACE" 2>/dev/null) || true
    if [[ -n "$drv_info" ]]; then
        while IFS=': ' read -r key val; do
            case "$key" in
                driver|version|firmware-version|bus-info)
                    printf "  %-40s %s\n" "$key" "$val"
                    ;;
            esac
        done <<< "$drv_info"
    else
        warn "ethtool -i not supported on $INTERFACE"
    fi
fi

echo ""

#--- Apply mode ----------------------------------------------------------------
if $APPLY; then
    if (( CHANGES_NEEDED == 0 )); then
        ok "All settings already at recommended values. Nothing to change."
        exit 0
    fi

    # Save backup (root check already done above)
    ensure_backup_dir

    # Symlink check before writing
    if [[ -L "$BACKUP_FILE" ]]; then
        err "Backup path is a symlink — refusing to write. Investigate: $BACKUP_FILE"
        exit 1
    fi

    # Write backup entries safely
    printf '%s\n' "${BACKUP_LINES[@]}" > "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    log_action "BACKUP: saved sysctl backup to $BACKUP_FILE"
    info "Current values backed up to $BACKUP_FILE"
    info "Revert with: sudo $0 --revert"
    echo ""

    # Load BBR module
    modprobe tcp_bbr 2>/dev/null || warn "Could not load tcp_bbr module."
    log_action "APPLY: modprobe tcp_bbr"

    # Apply sysctl values
    for param in "${PARAM_ORDER[@]}"; do
        desired="${DESIRED[$param]}"
        if sysctl -w "${param}=${desired}" 2>/dev/null; then
            ok "Set $param = $desired"
            log_action "APPLY: sysctl -w ${param}=${desired}"
        else
            warn "Failed to set $param"
        fi
    done

    # Set MTU
    if ip link show "$INTERFACE" &>/dev/null; then
        CURRENT_MTU=$(ip link show "$INTERFACE" | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
        CURRENT_MTU=${CURRENT_MTU:-0}
        [[ "$CURRENT_MTU" =~ ^[0-9]+$ ]] || CURRENT_MTU=0
        if (( CURRENT_MTU < 9000 )); then
            # Save original MTU for revert
            if [[ -L "$MTU_BACKUP_FILE" ]]; then
                err "MTU backup path is a symlink — refusing to write."
                exit 1
            fi
            echo "${INTERFACE}=${CURRENT_MTU}" > "$MTU_BACKUP_FILE"
            chmod 600 "$MTU_BACKUP_FILE"

            if ip link set "$INTERFACE" mtu 9000 2>/dev/null; then
                ok "Set $INTERFACE MTU to 9000"
                log_action "APPLY: ip link set $INTERFACE mtu 9000 (was $CURRENT_MTU)"
            else
                warn "Failed to set MTU (may need VCN-level jumbo frame support)"
            fi
        fi
    fi

    # Set txqueuelen (ESnet: 10000 for WAN/100G+)
    if ip link show "$INTERFACE" &>/dev/null; then
        CURRENT_TXQLEN=$(ip link show "$INTERFACE" | awk '/qlen/{for(i=1;i<=NF;i++) if($i=="qlen") print $(i+1)}')
        CURRENT_TXQLEN=${CURRENT_TXQLEN:-1000}
        if (( CURRENT_TXQLEN < 10000 )); then
            # Save original txqueuelen for revert
            if [[ -L "$TXQLEN_BACKUP_FILE" ]]; then
                err "txqueuelen backup path is a symlink — refusing to write."
                exit 1
            fi
            echo "${INTERFACE}=${CURRENT_TXQLEN}" > "$TXQLEN_BACKUP_FILE"
            chmod 600 "$TXQLEN_BACKUP_FILE"

            if ip link set "$INTERFACE" txqueuelen 10000 2>/dev/null; then
                ok "Set $INTERFACE txqueuelen to 10000 (was $CURRENT_TXQLEN)"
                log_action "APPLY: ip link set $INTERFACE txqueuelen 10000 (was $CURRENT_TXQLEN)"
            else
                warn "Failed to set txqueuelen on $INTERFACE"
            fi
        fi

        # Set LRO off / GRO on (ESnet recommendation) with backup
        if command -v ethtool &>/dev/null; then
            if [[ -L "$OFFLOAD_BACKUP_FILE" ]]; then
                err "Offload backup path is a symlink — refusing to write."
                exit 1
            fi
            lro_val=$(ethtool -k "$INTERFACE" 2>/dev/null | grep "^large-receive-offload:" | awk '{print $2}' || echo "")
            if [[ "$lro_val" == "on" ]]; then
                echo "${INTERFACE}:lro=${lro_val}" >> "$OFFLOAD_BACKUP_FILE"
                if ethtool -K "$INTERFACE" lro off 2>/dev/null; then
                    ok "Set $INTERFACE LRO off (was $lro_val)"
                    log_action "APPLY: ethtool -K $INTERFACE lro off (was $lro_val)"
                else
                    warn "Failed to disable LRO on $INTERFACE (may not be supported)"
                fi
            fi
            gro_val=$(ethtool -k "$INTERFACE" 2>/dev/null | grep "^generic-receive-offload:" | awk '{print $2}' || echo "")
            if [[ "$gro_val" == "off" ]]; then
                echo "${INTERFACE}:gro=${gro_val}" >> "$OFFLOAD_BACKUP_FILE"
                if ethtool -K "$INTERFACE" gro on 2>/dev/null; then
                    ok "Set $INTERFACE GRO on (was $gro_val)"
                    log_action "APPLY: ethtool -K $INTERFACE gro on (was $gro_val)"
                else
                    warn "Failed to enable GRO on $INTERFACE"
                fi
            fi
            if [[ -f "$OFFLOAD_BACKUP_FILE" ]]; then
                chmod 600 "$OFFLOAD_BACKUP_FILE"
            fi
        fi
    fi

    # Set CPU governor to performance
    CPU_GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    if [[ -f "$CPU_GOV_PATH" ]]; then
        CURRENT_GOV=$(cat "$CPU_GOV_PATH" 2>/dev/null || echo "")
        if [[ "$CURRENT_GOV" != "performance" ]]; then
            # Save original governor for revert
            if [[ -L "$GOV_BACKUP_FILE" ]]; then
                err "Governor backup path is a symlink — refusing to write."
                exit 1
            fi
            echo "$CURRENT_GOV" > "$GOV_BACKUP_FILE"
            chmod 600 "$GOV_BACKUP_FILE"

            gov_set=0
            for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                [[ -f "$cpu_gov" ]] || continue
                echo "performance" > "$cpu_gov" 2>/dev/null && gov_set=$(( gov_set + 1 ))
            done
            if (( gov_set > 0 )); then
                ok "Set CPU governor to 'performance' on $gov_set CPUs (was '$CURRENT_GOV')"
                log_action "APPLY: CPU governor -> performance on $gov_set CPUs (was $CURRENT_GOV)"
            else
                warn "Failed to set CPU governor. Try: cpupower frequency-set -g performance"
            fi
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
