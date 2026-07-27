#!/bin/bash
# Two-Mac AWDL test, one command per machine.
#
#   Mac A (stands in for the Minecraft server):  ./twomac.sh host
#   Mac B (joins over AWDL and pushes a file):   ./twomac.sh join
#
# Wi-Fi must be ON on both Macs but joined to NO network, with Bluetooth on.
# AWDL is a virtual interface riding the Wi-Fi radio, so switching Wi-Fi off
# takes AWDL down with it, which is also why AirDrop needs Wi-Fi on. What the
# test needs is the absence of a shared LAN, not a powered-down radio.
#
# Success is the byte count Mac A reports with neither Mac on a network, which
# nothing but the peer-to-peer radio can explain.
#
# MB=5 ./twomac.sh join  for a quick smoke test instead of the full 50 MB.

set -u
cd "$(dirname "$0")"

PORT=19999
MB=${MB:-50}
GOT=/tmp/mcdirect-got.bin
LOG=$(mktemp -t mcdirect)
FIFO=""
DISCOVERY_TIMEOUT=60

trap 'kill $(jobs -p) 2>/dev/null; rm -f "$LOG" ${FIFO:+"$FIFO"}' EXIT INT TERM

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

# The radio has to be powered for AWDL to exist, and the two Macs must not share
# a LAN for a pass to mean anything. Those pull in opposite directions, so check
# both rather than repeating the earlier mistake of telling people to kill Wi-Fi.
#
# The Wi-Fi device is not always en0, so ask rather than assume: a hardcoded
# guess turns these checks into silence on the machines that need them.
WIFI_DEV=$(networksetup -listallhardwareports 2>/dev/null |
    awk '/Hardware Port: Wi-Fi/ { getline; print $2; exit }')

if [ -n "${WIFI_DEV:-}" ] &&
   [ "$(networksetup -getairportpower "$WIFI_DEV" 2>/dev/null | awk '{print $NF}')" = "Off" ]; then
    echo "Wi-Fi is off, so AWDL cannot run and discovery will never fire."
    echo "AWDL is a virtual interface on the Wi-Fi radio, which is why AirDrop"
    echo "needs Wi-Fi on too."
    echo
    echo "Turn Wi-Fi ON, then leave it joined to no network at all (Wi-Fi menu >"
    echo "disconnect, or just do not pick a network). No shared LAN is what this"
    echo "test needs, not a radio that is switched off."
    exit 1
fi

if ! ifconfig awdl0 2>/dev/null | grep -q RUNNING; then
    echo "WARNING: awdl0 is not running, so peer-to-peer Wi-Fi may be unavailable."
    echo "         Toggling Wi-Fi off and back on usually brings it up."
    echo
fi

if [ -n "${WIFI_DEV:-}" ] &&
   networksetup -getairportnetwork "$WIFI_DEV" 2>/dev/null | grep -q 'Current Wi-Fi Network'; then
    echo "NOTE: this Mac is on a Wi-Fi network. That is fine if the other Mac is on"
    echo "      a different one, but if they share it a pass proves nothing about"
    echo "      AWDL. Disconnect from Wi-Fi without powering it off to be sure."
    echo
fi

# macOS `date` has no sub-second format, and whole seconds are too coarse to
# judge a small transfer: a 5 MB smoke test over loopback lands inside one tick
# and reads as though it were slow. Use python3 when it is there, which on a Mac
# with the developer tools it always is, and fall back to whole seconds.
PYTHON=$(command -v python3 2>/dev/null || true)
now_ms() {
    if [ -n "$PYTHON" ]; then
        "$PYTHON" -c 'import time; print(int(time.time() * 1000))'
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

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
    echo "That crossed AWDL if neither Mac was on a network. Mac B printed the speed."
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
                echo "Nothing was advertised at all. In order of likelihood:"
                echo
                echo "  1. Wi-Fi is off on one of the Macs. It must be ON and joined to no"
                echo "     network. Off means no AWDL, so nothing can be discovered."
                echo "  2. macOS denied Local Network access silently, with no prompt and no"
                echo "     error. System Settings > Privacy & Security > Local Network:"
                echo "     toggle Terminal off and back on, then retry."
                echo "  3. ./twomac.sh host is not actually running on the other Mac, or its"
                echo "     binary is quarantined: xattr -d com.apple.quarantine mcdirect-helper"
                echo "  4. Bluetooth is off. macOS uses it to bootstrap AWDL."
                echo
                echo "To split a permission problem from an AWDL problem: put both Macs on"
                echo "the same Wi-Fi network and retry. If discovery works there, the"
                echo "permissions are fine and AWDL is the problem. If it still fails, the"
                echo "Local Network grant is being denied."
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

    # nc does not exit when it runs out of input: it half-closes and waits for the
    # far end to close, and the listener on Mac A is holding the connection open
    # too, so both sit there forever. Its exit is therefore useless as a stopwatch.
    #
    # Feed it through a fifo instead and time the producer, which returns once nc
    # has consumed every byte. That measures the transfer rather than nc's
    # lifetime, and it cannot hang waiting for a close that never comes.
    local start elapsed_ms sender
    FIFO=$(mktemp -u -t mcdirectpipe)
    mkfifo "$FIFO"
    nc 127.0.0.1 "$local_port" < "$FIFO" > /dev/null &
    sender=$!

    start=$(now_ms)
    head -c $((MB * 1000000)) /dev/urandom > "$FIFO"
    elapsed_ms=$(( $(now_ms) - start ))
    [ $elapsed_ms -lt 1 ] && elapsed_ms=1

    kill "$sender" 2>/dev/null
    rm -f "$FIFO"
    FIFO=""

    echo
    awk -v mb="$MB" -v ms="$elapsed_ms" 'BEGIN {
        s = ms / 1000
        rate = mb / s
        printf "  %d MB in %.2fs = %.1f MB/s\n\n", mb, s, rate
        if (rate > 5)       print "  Joining a world will feel instant. Ship it."
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
