# mcdirect-helper

Owns the radio so the JVM doesn't have to. Advertises and discovers Minecraft
worlds over AWDL (Apple peer-to-peer Wi-Fi) and exposes each peer as a plain
loopback TCP port. Speaks newline-delimited JSON on stdin/stdout.

```sh
swift build -c release
./test.sh                 # end-to-end relay test, single machine
```

## Two-Mac AWDL test

The remaining Phase 0 gate. `test.sh` proves the relay but not that traffic
actually crosses AWDL, because on one machine Bonjour resolves over loopback.

Copy `.build/release/mcdirect-helper` to a second Mac, then **turn Wi-Fi off on
both** (or join different networks — the point is no shared link) and leave
Bluetooth on, since macOS uses it to bootstrap AWDL.

Mac A, standing in for a Minecraft server, timing a 50 MB transfer:

```sh
time nc -l 19999 > /dev/null &
sleep 60 | ./mcdirect-helper host --port 19999 --name "TestWorld" --code 1234
```

Mac B:

```sh
sleep 60 | ./mcdirect-helper browse --auto
# note the "localPort" in the connected event, then in another shell:
head -c 50000000 /dev/urandom | nc 127.0.0.1 <localPort>
```

Success is bytes arriving on Mac A with Wi-Fi off on both machines. The elapsed
time is the throughput number that decides whether initial chunk sync is
tolerable — Minecraft's world sync is measured in megabytes, so anything above
roughly 5 MB/s makes joining feel instant and anything under 1 MB/s will be
noticeable.

If discovery never fires, check System Settings → Privacy & Security → Local
Network. That grant cannot be reset with `tccutil`, so a denial is sticky.

## Protocol

Commands in: `{"cmd":"connect","id":"..."}`, `{"cmd":"quit"}`
Events out: `ready`, `found{id,name,code}`, `lost{id}`, `connected{id,localPort}`,
`error{code,message}`

Closing stdin terminates the helper, so it can never outlive Minecraft.
