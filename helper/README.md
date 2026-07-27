# awdl-lan-helper

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

On both Macs, leave **Wi-Fi on but joined to no network** (disconnect in the
Wi-Fi menu; different networks also work, the point is no shared link) and leave
Bluetooth on, since macOS uses it to bootstrap AWDL.

Do not switch Wi-Fi off. AWDL is a virtual interface on the Wi-Fi radio, so
powering the radio down takes AWDL with it and discovery can never fire, which
is the same reason AirDrop needs Wi-Fi on.

AirDrop both `awdl-lan-helper` and `twomac.sh` into the same folder on Mac B,
then run one command per machine. Mac A first:

```sh
./twomac.sh host
```

Mac B, once Mac A says it is advertising:

```sh
./twomac.sh join
```

Mac B times the transfer and prints the throughput verdict; Mac A prints the
byte count that proves the payload arrived. `MB=5 ./twomac.sh join` pushes 5 MB
instead of 50 for a quick smoke test.

The script handles what used to be manual and easy to get wrong: clearing a
stale listener that would otherwise hold port 19999 and swallow the transfer,
carrying the tunnel port across without copying it by hand, refusing to run with
Wi-Fi powered off, flagging a shared network that would make a pass meaningless,
and naming a Local Network denial instead of showing an empty server list.

Success is bytes arriving on Mac A with neither machine on a network. The elapsed
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
