#!/bin/bash
# End-to-end relay test on a single machine.
#
# Stands up a fake "Minecraft server" (nc), fronts it with a host helper,
# discovers it with a browse helper, and pushes a payload through the tunnel.
# If the bytes come out the far end intact, the whole relay path works.
#
# Proves everything except AWDL itself: that needs two Macs sharing no network.

set -u
cd "$(dirname "$0")"

HELPER=.build/release/awdl-lan-helper
MC_PORT=19999
# Unique per run. A fixed name collides with a leftover advertisement (Bonjour
# renames the newcomer to "TestWorld (2)") and with any real world being shared
# nearby, and the test then dials the wrong host and receives nothing.
WORLD="LODTest-$$"
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

[ -x "$HELPER" ] || { echo "FAIL: build first (swift build -c release)"; exit 1; }

# 1. A payload big enough to cross several receive() chunks.
head -c 300000 /dev/urandom > "$WORK/payload.bin"

# 2. Fake Minecraft server: accept one connection, dump it to a file.
# Clear leftovers first. A stale listener from a previous run keeps the port and
# silently swallows the transfer, which reads as a payload mismatch rather than as
# the process collision it actually is.
pkill -f "nc -l $MC_PORT" 2>/dev/null || true
pkill -f "$HELPER" 2>/dev/null || true
sleep 0.5

nc -l $MC_PORT > "$WORK/received.bin" &
FAKE_SERVER=$!
sleep 1

# 3. Host helper fronts it. `sleep` holds stdin open — closing stdin is our kill switch.
sleep 120 | $HELPER host --port $MC_PORT --name "$WORLD" --code 1234 > "$WORK/host.log" 2>&1 &

# 4. Browse helper finds this run's world specifically and dials it.
sleep 120 | $HELPER browse --auto --match "$WORLD" > "$WORK/browse.log" 2>&1 &

# 5. Wait for the tunnel mouth to open.
LOCAL_PORT=""
for _ in $(seq 1 30); do
    LOCAL_PORT=$(grep -o '"localPort":[0-9]*' "$WORK/browse.log" 2>/dev/null | head -1 | cut -d: -f2)
    [ -n "$LOCAL_PORT" ] && break
    sleep 0.5
done

if [ -z "$LOCAL_PORT" ]; then
    echo "FAIL: no tunnel opened after 15s"
    echo "--- host.log ---";   cat "$WORK/host.log"
    echo "--- browse.log ---"; cat "$WORK/browse.log"
    grep -q local_network_denied "$WORK/browse.log" "$WORK/host.log" 2>/dev/null &&
        echo ">>> Local Network permission denied. Grant it in System Settings > Privacy & Security > Local Network."
    exit 1
fi

echo "tunnel open on 127.0.0.1:$LOCAL_PORT"

# 6. Push the payload through and let it drain. `-w` because nc does not exit when
# its stdin runs out — waiting on it here used to stall until the helpers' own stdin
# closed, which made the test pass on a timeout rather than on the transfer.
nc -w 3 127.0.0.1 "$LOCAL_PORT" < "$WORK/payload.bin" &
sleep 6

# 7. Did every byte survive the round trip?
if ! cmp -s "$WORK/payload.bin" "$WORK/received.bin"; then
    echo "FAIL: payload mismatch"
    echo "  sent:     $(wc -c < "$WORK/payload.bin" | tr -d ' ') bytes"
    echo "  received: $(wc -c < "$WORK/received.bin" 2>/dev/null | tr -d ' ') bytes"
    echo "--- browse.log ---"; cat "$WORK/browse.log"
    exit 1
fi

# 8. The radio must be in the dial chain. A world seen over awdl0 that is only ever
# dialled unpinned is the bug where two Macs joined to one Wi-Fi network discover each
# other, fail to connect over it, and never try the one path that would have worked.
if ! grep -q 'paths \[.*awdl0' "$WORK/browse.log"; then
    echo "FAIL: awdl0 was seen but is not in the dial chain"
    grep 'paths \[' "$WORK/browse.log" || echo "  (no dial chain logged at all)"
    exit 1
fi

# 9. Same tunnel, second connection. A player who disconnects and rejoins gets no
# new discovery event, so the mouth has to survive the first join or the entry in
# the list points at a closed port for the rest of the session.
# `nc -l` holds the port until its connection closes, and the relay only half-closes,
# so the first fake server has to be retired before a second can bind. By pid, not by
# pattern: a pattern kill here would also take out a developer's unrelated nc.
kill $FAKE_SERVER 2>/dev/null || true
sleep 1
# `-w` on both ends, because nc's exit on stdin EOF is not something to bet on.
nc -l -w 6 $MC_PORT > "$WORK/received2.bin" &
sleep 1
nc -w 3 127.0.0.1 "$LOCAL_PORT" < "$WORK/payload.bin" &
sleep 8

if ! cmp -s "$WORK/payload.bin" "$WORK/received2.bin"; then
    echo "FAIL: tunnel did not survive the first connection"
    echo "  received on reconnect: $(wc -c < "$WORK/received2.bin" 2>/dev/null | tr -d ' ') bytes"
    echo "--- browse.log ---"; cat "$WORK/browse.log"
    exit 1
fi

echo "PASS: $(wc -c < "$WORK/received.bin" | tr -d ' ') bytes relayed intact, tunnel reusable"
exit 0
