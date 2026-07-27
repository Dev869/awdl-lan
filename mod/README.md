# lan-over-direct (Fabric mod)

Minecraft 26.2, Fabric, macOS only. Surfaces nearby Macs' open worlds in the
vanilla LAN list, tunnelled over Apple peer-to-peer Wi-Fi (AWDL).

```sh
cd ../helper && swift build -c release   # the mod jar embeds this binary
cd ../mod
./test.sh                                # transport self-check, no Gradle or Minecraft
gradle build                             # jar in build/libs/
gradle runClient                         # dev client
```

`JAVA_HOME` must be JDK 25 (`/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home`).

## Layout

`HelperProcess` and `HelperBinary` are the transport layer and import nothing from
Minecraft or Fabric, which is why `test.sh` can run them under plain `javac` in
seconds. `test.sh` enforces that boundary — it fails if either file grows a game
import.

`LanOverDirectClient` owns both helper processes. `mixin/` holds the two hooks.

## How it reaches the UI

`ServerSelectionList` builds its LAN section from
`updateNetworkServers(List<LanServer>)`, and `LanServer` is only `(motd, address)`.
So discovered peers are appended as ordinary LAN entries pointing at
`127.0.0.1:<tunnelPort>`, and vanilla renders, pings, and joins them unaided.

There is no custom UI in this mod. One `@ModifyVariable` is the whole integration.

Peers are dialled eagerly on discovery, because an entry's address has to be real
before it can be clicked.

## Verified

Builds clean; `selfCheck` runs as part of `gradle build`. The Swift binary survives
the jar round-trip, extracts executable, runs, and keeps a valid ad-hoc signature.
The dev client reaches the main menu with both mixins configured and no injection
errors, and the helper leaves no orphan process on exit.

## Not yet verified

`ServerSelectionList` and `JoinMultiplayerScreen` only class-load when the
Multiplayer screen opens, so reaching the main menu does not prove those injections
apply. Open Multiplayer once in the dev client: with `defaultRequire: 1` a bad
target fails loudly rather than silently doing nothing.

AWDL transport itself is proven only on one machine so far. See `../helper/README.md`
for the two-Mac test.
