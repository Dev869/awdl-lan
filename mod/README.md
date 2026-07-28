# awdl-lan (Fabric mod)

Minecraft 1.19.4 through 26.x, Fabric, macOS only. Surfaces nearby Macs' open worlds
in the vanilla LAN list, tunnelled over Apple peer-to-peer Wi-Fi (AWDL).

`gradle build` produces the 26.x jar. `gradle build -Pmc=<id>` produces any other
line — `gradle targets` lists them. `../package.sh` builds and verifies all five.

```sh
cd ../helper && ./build.sh   # the jar embeds this binary
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

`AwdlLanClient` owns both helper processes. `mixin/` holds the two hooks.

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

End to end on two Macs with Wi-Fi disabled on both: a world shared with Open to
LAN appeared in the other machine's list and was joined and played. That exercises
the whole chain, including the `ServerSelectionList` and `JoinMultiplayerScreen`
injections, which only class-load when the Multiplayer screen opens.

Raw AWDL throughput measured separately at 50 MB in about 6 seconds (~8 MB/s),
well clear of the point where chunk sync would be felt.
