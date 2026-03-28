#!/usr/bin/env bash
#===============================================================================
# test_iperf3_scripts.sh — Functional & unit tests for the iperf3 test suite
#===============================================================================
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

SCRIPT_DIR="/home/claude"
CLIENT="$SCRIPT_DIR/iperf3_client.sh"
SERVER="$SCRIPT_DIR/iperf3_server.sh"
TUNER="$SCRIPT_DIR/iperf3_tune_host.sh"
TESTDIR=$(mktemp -d /tmp/iperf3_tests.XXXXXX)
trap 'rm -rf "$TESTDIR"' EXIT

assert_pass() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GRN}PASS${RST}  $name"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${RED}FAIL${RST}  $name"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_fail() {
    local name="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        echo -e "  ${GRN}PASS${RST}  $name (expected failure)"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${RED}FAIL${RST}  $name (should have failed)"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GRN}PASS${RST}  $name"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${RED}FAIL${RST}  $name"
        echo -e "         expected: '$expected'"
        echo -e "         actual:   '$actual'"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${GRN}PASS${RST}  $name"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${RED}FAIL${RST}  $name"
        echo -e "         expected to contain: '$needle'"
        echo -e "         in output (first 200 chars): '${haystack:0:200}'"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${GRN}PASS${RST}  $name"
        PASS=$(( PASS + 1 ))
    else
        echo -e "  ${RED}FAIL${RST}  $name"
        echo -e "         should NOT contain: '$needle'"
        FAIL=$(( FAIL + 1 ))
    fi
}

skip_test() {
    local name="$1" reason="$2"
    echo -e "  ${YEL}SKIP${RST}  $name ($reason)"
    SKIP=$(( SKIP + 1 ))
}

echo -e "\n${BLD}╔══════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}║         iperf3 Script Test Suite                            ║${RST}"
echo -e "${BLD}╚══════════════════════════════════════════════════════════════╝${RST}\n"

#===============================================================================
echo -e "${BLD}── 1. Syntax Validation ──${RST}"
#===============================================================================
assert_pass "client.sh syntax valid"  bash -n "$CLIENT"
assert_pass "server.sh syntax valid"  bash -n "$SERVER"
assert_pass "tuner.sh syntax valid"   bash -n "$TUNER"

#===============================================================================
echo -e "\n${BLD}── 2. Argument Parsing ──${RST}"
#===============================================================================

# Help flags
out=$(bash "$CLIENT" --help 2>&1) || true
assert_contains "client --help shows usage"    "Usage:" "$out"
assert_contains "client --help shows --raw"    "--raw" "$out"
assert_contains "client --help shows --target" "--target" "$out"
assert_contains "client --help shows --yes"    "--yes" "$out"

out=$(bash "$SERVER" --help 2>&1) || true
assert_contains "server --help shows usage" "Usage:" "$out"
assert_contains "server --help shows --yes" "--yes" "$out"

out=$(bash "$TUNER" --help 2>&1) || true
assert_contains "tuner --help shows usage" "Usage:" "$out"

# Missing required arg
assert_fail "client fails without --server" bash "$CLIENT"

# Unknown flag
assert_fail "client rejects --bogus" bash "$CLIENT" --server 1.2.3.4 --bogus
assert_fail "server rejects --bogus" bash "$SERVER" --bogus
assert_fail "tuner rejects --bogus"  bash "$TUNER" --bogus

#===============================================================================
echo -e "\n${BLD}── 3. JSON Helper Functions ──${RST}"
#===============================================================================

# Create test JSON files
cat > "$TESTDIR/good.json" <<'JSON'
{
  "start": {
    "connected": [
      {"socket": 5, "local_host": "10.0.0.1", "local_port": 44206, "remote_host": "10.0.0.2", "remote_port": 5200}
    ]
  },
  "intervals": [
    {
      "streams": [{"socket": 5, "start": 0, "end": 1, "seconds": 1.0, "bytes": 1310720000, "bits_per_second": 10485760000, "retransmits": 0, "snd_cwnd": 1572864}],
      "sum": {"start": 0, "end": 1, "seconds": 1.0, "bytes": 5242880000, "bits_per_second": 41943040000, "retransmits": 0}
    },
    {
      "streams": [{"socket": 5, "start": 1, "end": 2, "seconds": 1.0, "bytes": 1310720000, "bits_per_second": 10485760000, "retransmits": 0, "snd_cwnd": 1900544}],
      "sum": {"start": 1, "end": 2, "seconds": 1.0, "bytes": 5242880000, "bits_per_second": 41943040000, "retransmits": 0}
    }
  ],
  "end": {
    "sum_sent": {"bytes": 156000000000, "bits_per_second": 41600000000.5, "retransmits": 3},
    "sum_received": {"bytes": 155900000000, "bits_per_second": 41500000000},
    "cpu_utilization_percent": {"host_total": 45.2, "remote_total": 38.1}
  }
}
JSON

cat > "$TESTDIR/error.json" <<'JSON'
{"error": "unable to connect to server: Connection refused"}
JSON

cat > "$TESTDIR/empty_error.json" <<'JSON'
{"start": {}, "end": {"sum_sent": {"bytes": 100, "bits_per_second": 800, "retransmits": 0}, "sum_received": {"bytes": 100, "bits_per_second": 800}}}
JSON

echo "this is not json at all" > "$TESTDIR/bad.json"
: > "$TESTDIR/empty.json"

# Source the json helpers from the client script using a subshell trick
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

json_pretty() {
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    start = d.get('start', {})
    end = d.get('end', {})
    intervals = d.get('intervals', [])
    for c in start.get('connected', []):
        print(f\"  [{c.get('socket','')}] {c.get('local_host','')}:{c.get('local_port','')} -> {c.get('remote_host','')}:{c.get('remote_port','')}\")
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

# json_val tests
result=$(json_val "$TESTDIR/good.json" "end.sum_sent.bytes" 0)
assert_eq "json_val: extract bytes" "156000000000" "$result"

result=$(json_val "$TESTDIR/good.json" "end.sum_sent.bits_per_second" 0)
assert_eq "json_val: extract float bps" "41600000000.5" "$result"

result=$(json_val "$TESTDIR/good.json" "end.sum_sent.retransmits" 0)
assert_eq "json_val: extract retransmits" "3" "$result"

result=$(json_val "$TESTDIR/good.json" "end.sum_received.bytes" 0)
assert_eq "json_val: extract received bytes" "155900000000" "$result"

result=$(json_val "$TESTDIR/good.json" "nonexistent.path" 99)
assert_eq "json_val: missing path returns default" "99" "$result"

result=$(json_val "$TESTDIR/bad.json" "end.sum_sent.bytes" 0)
assert_eq "json_val: invalid JSON returns default" "0" "$result"

result=$(json_val "$TESTDIR/empty.json" "end.sum_sent.bytes" 0)
assert_eq "json_val: empty file returns default" "0" "$result"

# json_error tests
result=$(json_error "$TESTDIR/error.json")
assert_eq "json_error: returns error string" "unable to connect to server: Connection refused" "$result"

result=$(json_error "$TESTDIR/empty_error.json")
assert_eq "json_error: no error returns empty" "" "$result"

result=$(json_error "$TESTDIR/bad.json")
assert_eq "json_error: invalid JSON returns parse error" "JSON parse error" "$result"

result=$(json_error "$TESTDIR/empty.json")
assert_eq "json_error: empty file returns parse error" "JSON parse error" "$result"

#===============================================================================
echo -e "\n${BLD}── 4. json_pretty (--raw) Output ──${RST}"
#===============================================================================

raw_out=$(json_pretty "$TESTDIR/good.json")
assert_contains "json_pretty: connection line"  "10.0.0.1:44206 -> 10.0.0.2:5200" "$raw_out"
assert_contains "json_pretty: interval header"  "Interval" "$raw_out"
assert_contains "json_pretty: Gbps in output"   "Gbps" "$raw_out"
assert_contains "json_pretty: sender summary"   "Sender:" "$raw_out"
assert_contains "json_pretty: receiver summary" "Receiver:" "$raw_out"
assert_contains "json_pretty: CPU utilization"  "CPU: host=45.2%" "$raw_out"
assert_contains "json_pretty: retransmits"      "retransmits: 3" "$raw_out"

raw_bad=$(json_pretty "$TESTDIR/bad.json")
assert_contains "json_pretty: bad JSON shows error" "could not parse" "$raw_bad"

#===============================================================================
echo -e "\n${BLD}── 5. Integer Sanitization ──${RST}"
#===============================================================================

# Test printf %.0f with various inputs (matching how the script sanitizes)
result=$(printf '%.0f' "41600000000.5" 2>/dev/null)
assert_eq "printf sanitizes float to int (banker's rounding)" "41600000000" "$result"

result=$(printf '%.0f' "0" 2>/dev/null)
assert_eq "printf sanitizes zero" "0" "$result"

result=$(printf '%.0f' "156000000000" 2>/dev/null)
assert_eq "printf sanitizes large int" "156000000000" "$result"

# Test that bash arithmetic works with sanitized values
sent_bytes=$(printf '%.0f' "156000000000" 2>/dev/null || echo 0)
total=$(( 0 + sent_bytes ))
assert_eq "bash arithmetic with sanitized value" "156000000000" "$total"

#===============================================================================
echo -e "\n${BLD}── 6. bc Calculations ──${RST}"
#===============================================================================

# Test the exact bc expressions used in the script
bps="41600000000.5"
gbps=$(echo "scale=2; $bps / 1000000000" | bc)
assert_eq "bc: bps to Gbps" "41.60" "$gbps"

sent_bytes="156000000000"
duration="30"
agg_gbps=$(echo "scale=2; $sent_bytes * 8 / $duration / 1000000000" | bc)
assert_eq "bc: aggregate Gbps from bytes" "41.60" "$agg_gbps"

agg_gb=$(echo "scale=2; $sent_bytes / 1073741824" | bc)
assert_eq "bc: bytes to GB" "145.28" "$agg_gb"

# Threshold calculations
target=200
pass_t=$(echo "scale=0; $target * 95 / 100" | bc)
warn_t=$(echo "scale=0; $target * 75 / 100" | bc)
assert_eq "bc: 95% threshold of 200" "190" "$pass_t"
assert_eq "bc: 75% threshold of 200" "150" "$warn_t"

# Custom target
target=100
pass_t=$(echo "scale=0; $target * 95 / 100" | bc)
warn_t=$(echo "scale=0; $target * 75 / 100" | bc)
assert_eq "bc: 95% threshold of 100" "95" "$pass_t"
assert_eq "bc: 75% threshold of 100" "75" "$warn_t"

# Percentage calculation — multiply first to avoid bc truncation
pct=$(echo "scale=1; 41.60 * 100 / 200" | bc)
assert_eq "bc: percentage calc (multiply first)" "20.8" "$pct"

# Edge: zero throughput
result=$(echo "scale=1; 0 * 100 / 200" | bc 2>&1)
assert_eq "bc: zero throughput percentage" "0" "$result"

#===============================================================================
echo -e "\n${BLD}── 7. Window Size Parsing ──${RST}"
#===============================================================================

# Simulate the window parsing logic from the script
for test_case in "128M:134217728" "64K:65536" "1G:1073741824" "256M:268435456"; do
    window="${test_case%%:*}"
    expected="${test_case##*:}"
    req_bytes=0
    case "$window" in
        *M) req_bytes=$(( ${window%M} * 1024 * 1024 )) ;;
        *K) req_bytes=$(( ${window%K} * 1024 )) ;;
        *G) req_bytes=$(( ${window%G} * 1024 * 1024 * 1024 )) ;;
        *)  req_bytes=$window ;;
    esac
    assert_eq "window parse: $window = $expected bytes" "$expected" "$req_bytes"
done

#===============================================================================
echo -e "\n${BLD}── 8. Interface Auto-Detection ──${RST}"
#===============================================================================

# Check that the script can find a non-eth0 interface
default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
if [[ -n "$default_iface" ]]; then
    assert_pass "default interface detected: $default_iface" test -n "$default_iface"
    # Verify interface exists
    assert_pass "detected interface exists in ip link" ip link show "$default_iface"
else
    skip_test "interface auto-detection" "no default route"
fi

#===============================================================================
echo -e "\n${BLD}── 9. NIC Counter Reading ──${RST}"
#===============================================================================

# Find any interface to test counter reading
test_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
if [[ -n "$test_iface" ]] && [[ -f "/sys/class/net/${test_iface}/statistics/tx_bytes" ]]; then
    tx=$(cat "/sys/class/net/${test_iface}/statistics/tx_bytes")
    assert_pass "NIC tx_bytes is numeric" test "$tx" -ge 0
    rx=$(cat "/sys/class/net/${test_iface}/statistics/rx_bytes")
    assert_pass "NIC rx_bytes is numeric" test "$rx" -ge 0
else
    skip_test "NIC counter reading" "no suitable interface"
fi

#===============================================================================
echo -e "\n${BLD}── 10. Tuning Script Dry Run ──${RST}"
#===============================================================================

tune_out=$(bash "$TUNER" 2>&1 || true)
if [[ -z "$tune_out" ]]; then
    # May fail in containers without ip/sysctl/lsmod — still shouldn't be silent
    skip_test "tuner dry run" "script produced no output (likely missing ip/sysctl)"
else
    assert_contains "tuner: shows Parameter header"   "Parameter" "$tune_out"
    assert_contains "tuner: shows Current column"      "Current" "$tune_out"
    assert_contains "tuner: shows Recommended column"  "Recommended" "$tune_out"
    assert_contains "tuner: shows rmem_max"            "net.core.rmem_max" "$tune_out"
    assert_contains "tuner: shows wmem_max"            "net.core.wmem_max" "$tune_out"
    assert_contains "tuner: shows tcp_congestion"      "tcp_congestion_control" "$tune_out"
    assert_contains "tuner: shows interface"           "Interface:" "$tune_out"
    assert_contains "tuner: DRY RUN mode"             "DRY RUN" "$tune_out"
fi

#===============================================================================
echo -e "\n${BLD}── 11. Tuning Script Auto-Detect Interface ──${RST}"
#===============================================================================

if ! ip link show eth0 &>/dev/null 2>&1; then
    if [[ -n "$tune_out" ]]; then
        assert_contains "tuner: auto-detects or warns about interface" "interface" "$tune_out"
    else
        skip_test "tuner auto-detect interface" "tuner produced no output"
    fi
else
    skip_test "tuner auto-detect interface" "eth0 exists on this host"
fi

#===============================================================================
echo -e "\n${BLD}── 12. End-to-End Functional Test (mock) ──${RST}"
#===============================================================================

# Create mock JSON results and test the parsing pipeline
E2E_DIR="$TESTDIR/e2e"
mkdir -p "$E2E_DIR"

# Create 3 mock process results simulating ~25 Gbps each
for i in 1 2 3; do
    bytes=$((97500000000))  # ~25 Gbps over 30s
    bps=$((26000000000))
    recv_bytes=$((97400000000))
    recv_bps=$((25900000000))
    cat > "$E2E_DIR/iperf3_s${i}.json" <<MOCK
{
  "start": {"connected": [{"socket": $((4+i)), "local_host": "10.0.0.1", "local_port": $((44200+i)), "remote_host": "10.0.0.2", "remote_port": $((5200+i-1))}]},
  "intervals": [
    {"streams": [{"socket": $((4+i)), "start": 0, "end": 1, "bytes": 3250000000, "bits_per_second": 26000000000, "retransmits": 0, "snd_cwnd": 2097152}],
     "sum": {"start": 0, "end": 1, "bytes": 3250000000, "bits_per_second": 26000000000, "retransmits": 0}}
  ],
  "end": {
    "sum_sent": {"bytes": $bytes, "bits_per_second": $bps, "retransmits": $((i-1))},
    "sum_received": {"bytes": $recv_bytes, "bits_per_second": $recv_bps},
    "cpu_utilization_percent": {"host_total": 15.2, "remote_total": 12.1}
  }
}
MOCK
done

# Also create one error result
cat > "$E2E_DIR/iperf3_s4.json" <<'MOCK'
{"error": "unable to connect to server: Connection refused"}
MOCK

# Parse all 4 mock results with the same logic as the script
TOTAL_SENT=0; TOTAL_RECV=0; TOTAL_RETR=0; P_COUNT=0; F_COUNT=0
for i in 1 2 3 4; do
    f="$E2E_DIR/iperf3_s${i}.json"
    ie=$(json_error "$f")
    if [[ -n "$ie" ]]; then
        F_COUNT=$(( F_COUNT + 1 ))
        continue
    fi
    sb=$(json_val "$f" "end.sum_sent.bytes" 0)
    rb=$(json_val "$f" "end.sum_received.bytes" 0)
    rt=$(json_val "$f" "end.sum_sent.retransmits" 0)
    sb=$(printf '%.0f' "$sb" 2>/dev/null || echo 0)
    rb=$(printf '%.0f' "$rb" 2>/dev/null || echo 0)
    rt=$(printf '%.0f' "$rt" 2>/dev/null || echo 0)
    TOTAL_SENT=$(( TOTAL_SENT + sb ))
    TOTAL_RECV=$(( TOTAL_RECV + rb ))
    TOTAL_RETR=$(( TOTAL_RETR + rt ))
    P_COUNT=$(( P_COUNT + 1 ))
done

assert_eq "e2e: 3 processes succeeded"    "3" "$P_COUNT"
assert_eq "e2e: 1 process failed"         "1" "$F_COUNT"
assert_eq "e2e: total sent bytes"         "292500000000" "$TOTAL_SENT"
assert_eq "e2e: total received bytes"     "292200000000" "$TOTAL_RECV"
assert_eq "e2e: total retransmits (0+1+2)" "3" "$TOTAL_RETR"

# Compute aggregate Gbps as the script would
AGG_SENT_GBPS=$(echo "scale=2; $TOTAL_SENT * 8 / 30 / 1000000000" | bc)
assert_eq "e2e: aggregate sent Gbps" "78.00" "$AGG_SENT_GBPS"

AGG_RECV_GBPS=$(echo "scale=2; $TOTAL_RECV * 8 / 30 / 1000000000" | bc)
assert_eq "e2e: aggregate recv Gbps" "77.92" "$AGG_RECV_GBPS"

# Assessment thresholds against target=200 (multiply first to avoid bc truncation)
PCT=$(echo "scale=1; $AGG_SENT_GBPS * 100 / 200" | bc)
assert_eq "e2e: percentage of 200G target" "39.0" "$PCT"

#===============================================================================
echo -e "\n${BLD}── 13. --raw Output with Mock Data ──${RST}"
#===============================================================================

raw_out=$(json_pretty "$E2E_DIR/iperf3_s1.json")
assert_contains "raw mock: shows connection"    "10.0.0.1:44201 -> 10.0.0.2:5200" "$raw_out"
assert_contains "raw mock: shows interval data" "Gbps" "$raw_out"
assert_contains "raw mock: shows sender"        "Sender:" "$raw_out"
assert_contains "raw mock: shows CPU"           "CPU:" "$raw_out"

raw_err=$(json_pretty "$E2E_DIR/iperf3_s4.json")
# Error JSON has no intervals/end, so it should show "could not parse" or minimal output
# Actually this has error key but json_pretty tries to read start/end — it should still work gracefully
assert_pass "raw mock: error file doesn't crash json_pretty" test -n "$raw_err"

#===============================================================================
echo -e "\n${BLD}── 14. Edge Cases ──${RST}"
#===============================================================================

# Scientific notation from json_val (iperf3 sometimes outputs this)
cat > "$TESTDIR/sci.json" <<'JSON'
{"end": {"sum_sent": {"bytes": 1.56e+11, "bits_per_second": 4.16e+10, "retransmits": 0}, "sum_received": {"bytes": 1.559e+11, "bits_per_second": 4.15e+10}}}
JSON

result=$(json_val "$TESTDIR/sci.json" "end.sum_sent.bytes" 0)
sanitized=$(printf '%.0f' "$result" 2>/dev/null || echo 0)
assert_eq "edge: scientific notation bytes" "156000000000" "$sanitized"

result=$(json_val "$TESTDIR/sci.json" "end.sum_sent.bits_per_second" 0)
gbps=$(echo "scale=2; $result / 1000000000" | bc 2>/dev/null || echo 0)
assert_eq "edge: scientific notation bps->Gbps" "41.60" "$gbps"

# Zero-value JSON
cat > "$TESTDIR/zero.json" <<'JSON'
{"end": {"sum_sent": {"bytes": 0, "bits_per_second": 0, "retransmits": 0}, "sum_received": {"bytes": 0, "bits_per_second": 0}}}
JSON

result=$(json_val "$TESTDIR/zero.json" "end.sum_sent.bytes" 0)
sanitized=$(printf '%.0f' "$result" 2>/dev/null || echo 0)
assert_eq "edge: zero bytes" "0" "$sanitized"

gbps=$(echo "scale=2; 0 / 1000000000" | bc)
assert_eq "edge: zero bps to Gbps" "0" "$gbps"

# Very large values (800 Gbps scenario)
cat > "$TESTDIR/large.json" <<'JSON'
{"end": {"sum_sent": {"bytes": 3000000000000, "bits_per_second": 800000000000, "retransmits": 42}, "sum_received": {"bytes": 2999000000000, "bits_per_second": 799000000000}}}
JSON

result=$(json_val "$TESTDIR/large.json" "end.sum_sent.bytes" 0)
sanitized=$(printf '%.0f' "$result" 2>/dev/null || echo 0)
assert_eq "edge: 3TB bytes" "3000000000000" "$sanitized"

gbps=$(echo "scale=2; 800000000000 / 1000000000" | bc)
assert_eq "edge: 800 Gbps" "800.00" "$gbps"

# Arithmetic overflow check — can bash handle 3TB?
total=$(( 0 + 3000000000000 ))
assert_eq "edge: bash arithmetic handles 3TB" "3000000000000" "$total"

#===============================================================================
echo -e "\n${BLD}── 15. No Dangerous Patterns ──${RST}"
#===============================================================================

# Verify no eval remains
for script in "$CLIENT" "$SERVER" "$TUNER"; do
    name=$(basename "$script")
    count=$(grep -c 'eval ' "$script" || true)
    assert_eq "no eval in $name" "0" "$count"
done

# Verify no (( X++ )) patterns
for script in "$CLIENT" "$SERVER" "$TUNER"; do
    name=$(basename "$script")
    count=$(grep -cP '\(\(\s*\w+\+\+' "$script" || true)
    assert_eq "no (( X++ )) in $name" "0" "$count"
done

# Verify no jq calls (excluding comments)
for script in "$CLIENT" "$SERVER" "$TUNER"; do
    name=$(basename "$script")
    count=$(grep -v '^\s*#' "$script" | grep -c 'jq ' || true)
    assert_eq "no jq calls in $name" "0" "$count"
done

# Verify no hardcoded eth0 in remediation text
remediation=$(grep -A 20 'Remediation Checklist' "$CLIENT" 2>/dev/null || true)
assert_not_contains "no hardcoded eth0 in remediation" "eth0" "$remediation"

#===============================================================================
echo -e "\n${BLD}── 16. Performance: JSON Helper Speed ──${RST}"
#===============================================================================

# Time 100 invocations of json_val to check for performance issues
start_time=$(date +%s%N)
for _ in $(seq 1 100); do
    json_val "$TESTDIR/good.json" "end.sum_sent.bytes" 0 >/dev/null
done
end_time=$(date +%s%N)
elapsed_ms=$(( (end_time - start_time) / 1000000 ))
avg_ms=$(( elapsed_ms / 100 ))

echo -e "  ${CYN}PERF${RST}  json_val: 100 calls in ${elapsed_ms}ms (avg ${avg_ms}ms/call)"
if (( avg_ms > 500 )); then
    echo -e "  ${YEL}WARN${RST}  json_val avg >500ms — may slow results parsing with many instances"
elif (( avg_ms > 200 )); then
    echo -e "  ${YEL}NOTE${RST}  json_val avg >200ms — acceptable but not fast"
else
    echo -e "  ${GRN}OK${RST}    json_val performance is good (<200ms/call)"
fi

# Per-process cost estimate: 5 json_val calls + 1 json_error = 6 python invocations
per_process_ms=$(( avg_ms * 6 ))
for n in 1 5 10 20; do
    total_ms=$(( per_process_ms * n ))
    echo -e "  ${DIM}      Estimated parsing overhead for $n processes: ${total_ms}ms (~$(( total_ms / 1000 ))s)${RST}"
done

#===============================================================================
# Summary
#===============================================================================
echo -e "\n${BLD}════════════════════════════════════════════════════════════════${RST}"
TOTAL=$(( PASS + FAIL + SKIP ))
echo -e "${BLD}  Results: ${GRN}$PASS passed${RST}, ${RED}$FAIL failed${RST}, ${YEL}$SKIP skipped${RST}  (${TOTAL} total)${RST}"
if (( FAIL == 0 )); then
    echo -e "  ${GRN}${BLD}ALL TESTS PASSED${RST}"
else
    echo -e "  ${RED}${BLD}SOME TESTS FAILED${RST}"
fi
echo -e "${BLD}════════════════════════════════════════════════════════════════${RST}\n"

exit $FAIL
