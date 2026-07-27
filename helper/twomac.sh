#!/bin/bash
# Two-Mac AWDL test, one command per machine.
#
#   Mac A (stands in for the Minecraft server):  ./twomac.sh host
#   Mac B (joins over AWDL and pushes a file):   ./twomac.sh join
#
# Turn Wi-Fi off on both Macs first, and leave Bluetooth on: macOS uses it to
# bootstrap AWDL. Success is the byte count Mac A reports while neither machine
# has a network, which nothing but AWDL can explain.
#
# MB=5 ./twomac.sh join  for a quick smoke test instead of the full 50 MB.

set -u
cd "$(dirname "$0")"

PORT=19999
MB=${MB:-50}
GOT=/tmp/mcdirect-got.bin
LOG=$(mktemp -t mcdirect)
DISCOVERY_TIMEOUT=60

trap 'kill $(jobs -p) 2>/dev/null; rm -f "$LOG"' EXIT INT TERM

HELPER=""
for candidate in ./mcdirect-helper .build/release/mcdirect-helper; do
    [ -x "$candidate" ] && HELPER=$candidate && break
done
if [ -z "$HELPER" ]; then
    echo "No mcdirect-helper found next to this script or in .build/release."
    echo "On Mac A: swift build -c release"
    echo "On Mac B: AirDrop both mcdirect-helper and twomac.sh into the same folder."
    exit 1
fi

# Wi-Fi left on is the one mistake that makes a passing test meaningless, since
# the bytes may cross a router instead of the peer-to-peer radio. The Wi-Fi
# device is not always en0, so ask rather than assume: a hardcoded guess turns
# this warning into silence on the machines that need it.
WIFI_DEV=$(networksetup -listallhardwareports 2>/dev/null |
    awk '/Hardware Port: Wi-Fi/ { getline; print $2; exit }')
if [ -n "${WIFI_DEV:-}" ] &&
   [ "$(networksetup -getairportpower "$WIFI_DEV" 2>/dev/null | awk '{print $NF}')" = "On" ]; then
    echo "WARNING: Wi-Fi is on. If both Macs can reach the same network this"
    echo "         test proves nothing about AWDL. Turn Wi-Fi off on both."
    echo
fi

# Wait for a JSON event to show up in the helper's log.
# 0 = found it, 1 = timed out, 2 = macOS denied Local Network access.
await() {
    local pattern=$1 seconds=$2 ticks=0
    while [ $ticks -lt $((seconds * 2)) ]; do
        grep -q local_network_denied "$LOG" && return 2
        grep -q "$pattern" "$LOG" && return 0
        sleep 0.5
        ticks=$((ticks + 1))
    done
    return 1
}

permission_help() {
    echo
    echo "macOS denied Local Network access, so discovery can never fire."
    echo "System Settings > Privacy & Security > Local Network, enable Terminal."
    echo "This grant is sticky and tccutil cannot reset it, so if Terminal is"
    echo "already listed as enabled, toggle it off and on."
}

dump_log() {
    echo
    echo "--- helper log ---"
    cat "$LOG"
}

run_host() {
    # A listener left over from an earlier attempt keeps the port and silently
    # eats the transfer, which looks exactly like a working tunnel moving zero
    # bytes. Clear it before binding.
    # -x so this matches only a bare `nc -l 19999`. Without it, -f matches any
    # command line merely containing that string, including a shell or editor.
    pkill -x -f "nc -l $PORT" 2>/dev/null && sleep 0.3
    : > "$GOT"
    nc -l $PORT > "$GOT" &
    local listener=$!
    sleep 0.5

    # nc exits immediately if it cannot bind. Without this the helper would
    # advertise happily, the tunnel would open, and the bytes would vanish into
    # whatever else owns the port.
    if ! kill -0 "$listener" 2>/dev/null; then
        echo "Could not listen on port $PORT: something else already has it."
        echo "Find it with:  lsof -nP -iTCP:$PORT"
        exit 1
    fi

    # `sleep` holds the helper's stdin open. Closing stdin is the kill switch,
    # so the helper can never outlive this script.
    sleep 900 | "$HELPER" host --port $PORT --name "TestWorld" --code 1234 > "$LOG" 2>&1 &

    printf 'Starting up... '
    case $(await '"event":"ready"' 15; echo $?) in
        2) permission_help; exit 1 ;;
        1) echo "helper never reported ready."; dump_log; exit 1 ;;
    esac
    echo "advertising TestWorld on port $PORT."
    echo
    echo "Now run  ./twomac.sh join  on the other Mac. Leave this running."
    echo

    # Report progress off the file size, so what gets printed is what actually
    # landed on disk rather than what the tunnel claims it sent.
    local received=0 last=0 idle=0
    while :; do
        received=$(wc -c < "$GOT" | tr -d ' ')
        if [ "$received" -gt "$last" ]; then
            # Only redraw in place on a terminal, so a redirected log stays readable.
            [ -t 1 ] && printf '\r  receiving... %s MB   ' "$((received / 1000000))"
            last=$received
            idle=0
        elif [ "$received" -gt 0 ]; then
            # Three quiet seconds after bytes started means the sender is done.
            idle=$((idle + 1))
            [ $idle -ge 6 ] && break
        fi
        sleep 0.5
    done

    [ -t 1 ] && printf '\r'
    printf '  received %s bytes (%s MB).            \n' "$received" "$((received / 1000000))"
    echo
    echo "That crossed AWDL if both Macs had Wi-Fi off. Mac B printed the speed."
}

run_join() {
    sleep 900 | "$HELPER" browse --auto > "$LOG" 2>&1 &

    printf 'Looking for a host... '
    case $(await '"localPort"' $DISCOVERY_TIMEOUT; echo $?) in
        2) permission_help; exit 1 ;;
        1)
            echo "nothing found in ${DISCOVERY_TIMEOUT}s."
            echo
            if grep -q '"event":"found"' "$LOG"; then
                echo "A host was discovered but the tunnel never opened, which points at"
                echo "AWDL failing to carry the connection rather than at discovery."
            else
                echo "Nothing was even advertised. Check that ./twomac.sh host is running"
                echo "on the other Mac, that Bluetooth is on for both, and that the binary"
                echo "is not quarantined: xattr -d com.apple.quarantine mcdirect-helper"
            fi
            dump_log
            exit 1
            ;;
    esac

    local local_port
    local_port=$(grep -o '"localPort":[0-9]*' "$LOG" | head -1 | cut -d: -f2)
    echo "connected, tunnel on 127.0.0.1:$local_port."
    echo
    echo "Pushing $MB MB..."

    local start elapsed
    start=$(date +%s)
    head -c $((MB * 1000000)) /dev/urandom | nc 127.0.0.1 "$local_port"
    elapsed=$(( $(date +%s) - start ))
    [ $elapsed -lt 1 ] && elapsed=1

    echo
    awk -v mb="$MB" -v s="$elapsed" 'BEGIN {
        rate = mb / s
        printf "  %d MB in %ds = %.1f MB/s\n\n", mb, s, rate
        if (rate > 5)      print "  Joining a world will feel instant. Ship it."
        else if (rate >= 1) print "  Workable. Initial chunk sync will be noticeable but fine."
        else                print "  Too slow. Likely stuck below realtime-mode elevation."
    }'
    echo
    echo "Check the byte count on Mac A to confirm every byte arrived."
}

case "${1:-}" in
    host|a|A) run_host ;;
    join|b|B) run_join ;;
    *)
        echo "usage: ./twomac.sh host    # Mac A, start this first"
        echo "       ./twomac.sh join    # Mac B, once Mac A says it is advertising"
        exit 1
        ;;
esac
