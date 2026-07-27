# awdl-lan — Design

Date: 2026-07-27
Status: Implemented and verified end to end on two Macs (v0.1.0)

## Summary

A Minecraft Java Edition mod that lets two Macs play together with no router,
no access point, no internet, and no configuration. The host opens a world to
LAN; nearby Macs see it appear in their multiplayer list and join.

The transport is Apple Wireless Direct Link (AWDL) — the peer-to-peer Wi-Fi
radio behind AirDrop and Sidecar — reached through Network.framework's
`includePeerToPeer` flag. Minecraft's protocol is unmodified; it travels
through a localhost TCP tunnel and never learns the link is unusual.

Scope is Mac ↔ Mac only. AWDL is an Apple technology; a Mac cannot peer-to-peer
to a Windows or Linux machine.

## Why this shape

Java has no route to AWDL or Bluetooth on macOS without native bindings, and
Bluetooth is the wrong pipe regardless: BLE tops out near 1 Mbps and BT Classic
near 2 Mbps, while Minecraft's initial chunk sync is measured in megabytes.
AWDL runs at Wi-Fi speed with no AP.

Because Minecraft speaks plain TCP, the entire problem reduces to a proxy. A
native helper process owns the radio; the mod owns a socket. No JNI, no
native bindings inside the JVM, no Bluetooth stack.

```
[MC host] ──127.0.0.1:25565──> [helper] ≈≈AWDL≈≈> [helper] ──127.0.0.1:PORT──> [MC client]
```

One further property earns this design its keep: Network.framework uses
infrastructure Wi-Fi when a shared network is present and falls back to AWDL
when it is not. Same-network play and no-network play are a single code path,
not two.

## Prior art

Nothing occupies this space. e4mc tunnels Open to LAN over the public internet
via a relay. SinglePlayerServerSettings [OfflineLAN] only removes the online-auth
requirement from LAN worlds. Vanilla LAN discovery broadcasts on UDP multicast
224.0.2.60:4445 and dies on client-isolated networks and across subnets. No
existing mod uses AWDL.

## Components

### `awdl-lan-helper` (Swift, macOS 13+)

A command-line binary, roughly 300 lines, shipped inside the mod jar. It speaks
newline-delimited JSON on stdin/stdout and does all networking.

*Host mode*: opens an `NWListener` with `parameters.includePeerToPeer = true`,
advertising the Bonjour service `_awdllan._tcp`. Each inbound `NWConnection`
is paired with a fresh TCP socket to `127.0.0.1:<mcPort>`, and bytes are pumped
in both directions until either side closes.

*Browse mode*: runs an `NWBrowser` for `_awdllan._tcp`, reporting peers as they
appear and disappear. On a connect command it dials the peer's endpoint and
binds a local listener on `127.0.0.1:0`, reporting the assigned port back to
the mod.

### `awdl-lan` (Fabric mod, Java)

Deliberately thin: a process manager and a list renderer, containing no
networking logic of its own.

On startup it extracts the helper from the jar to a cache directory, marks it
executable, and spawns it. Host side, it hooks Open to LAN and forwards the
resulting port and world name. Client side, it runs a browse helper while the
multiplayer screen is open and injects discovered peers into the server list as
real entries; selecting one requests a dial and points the vanilla client at the
returned localhost port.

## Wire protocol

Mod → helper:

| Command | Fields |
|---|---|
| `host` | `port`, `name`, `code` |
| `browse` | — |
| `connect` | `id` |

Helper → mod:

| Event | Fields |
|---|---|
| `ready` | — |
| `found` | `id`, `name` |
| `lost` | `id` |
| `connected` | `id`, `localPort` |
| `error` | `code`, `message` |

This is the whole interface between the two halves. It is also the seam that
would let a Windows helper drop in later without the Java side changing.

## Room code

The host generates a four-digit code, carried in the Bonjour TXT record.

**Revised during Phase 1.** The original plan was to filter the client's list to
matching codes only. That would require a text-entry screen before a player can
see anything, which is worse friction than the problem it solves. The code is
now displayed in the list entry rather than enforced, so it disambiguates two
worlds sharing a name in one room without gating the join. Vanilla Open to LAN
gates nothing either, so this is parity rather than a regression, and the
security posture below is unchanged.

## UI approach

**Revised during Phase 1, and it removed most of the planned work.**

Inspecting the unobfuscated 26.2 jar showed `ServerSelectionList` populates its
LAN section from `updateNetworkServers(List<LanServer>)`, and that `LanServer` is
nothing but `(motd, address)`. Discovered peers can therefore be appended as
ordinary LAN entries pointing at `127.0.0.1:<tunnelPort>`, and vanilla renders,
pings, and joins them unaided.

The mod ships no custom UI, no custom list entry, and no click handling. One
`@ModifyVariable` on that method is the entire integration.

Peers are dialled eagerly on discovery rather than on click, since an entry's
address must be real before it can be selected. This also hides AWDL's slow
first association behind the time a player spends reading the list.

Hosting needs no mixin at all: polling the integrated server's published state
each client tick covers both `publishServer` overloads and `unpublishServer` in
one place.

Discovery is scoped to the multiplayer screen via `init`/`removed`, because
browsing holds the AWDL radio active and would otherwise cost battery for the
whole session.

Dropped: showing the room code in chat. `ChatComponent` is no longer reachable
from `Gui` or `Minecraft` in 26.2, and the list entry already carries the code.

## Failure handling

**Local network denial is the critical case.** macOS 15 and later gate local
network access, and a bare command-line binary with no app bundle is precisely
the case that receives `PolicyDenied` with no user-visible prompt. The
permission also cannot be reset with `tccutil`, so a bad first run is sticky.
The helper must emit `error{code:"local_network_denied"}` explicitly and the mod
must surface an actionable in-game message pointing at System Settings. A silent
empty server list is the single worst outcome and is not acceptable.

A missing, crashed, or unsigned helper disables the feature and logs. It must
never break vanilla multiplayer.

A peer leaving radio range closes the tunnel socket, which Minecraft already
handles as an ordinary disconnect. No special handling.

## Security posture

Data travels as plain TCP, matching vanilla Open to LAN, which is likewise
plaintext over the air. The room code gates casual access, not a determined
listener. PSK-derived TLS via `NWParameters` is the noted upgrade path and is
explicitly not in v1.

## Known limits

Apple documents that AWDL's on-the-wire protocol degrades exponentially as peer
count rises; it is not built to scale. This design promises nothing beyond
roughly four players. Apple also notes that peer-to-peer transmission can be
choppy until the OS elevates the link to realtime mode — whether Minecraft's
traffic pattern triggers that elevation is unknown and is a Phase 0 measurement.

Apple Silicon requires at least an ad-hoc code signature. **Resolved in Phase 0:**
the Swift linker applies one automatically (`flags=0x20002(adhoc,linker-signed)`),
so no signing step is needed.

## Phase 0 results (2026-07-27, macOS 26.5.1, Swift 6.3.3, arm64)

Single-machine end-to-end run via `helper/test.sh`: 300,000 bytes relayed
byte-identical through loopback client → Bonjour-discovered peer connection →
host helper → destination socket.

Confirmed working: service advertisement, `NWBrowser` discovery, TXT record
carrying the room code and world name, loopback tunnel binding, bidirectional
relay.

**Local network permission did not block a bare CLI binary.** No
`local_network_denied`, no prompt, no `PolicyDenied`. This was the primary
design risk and it did not materialise on macOS 26.5.1. The error path stays in
place regardless, since the grant is per-machine and other systems may differ.

Two bugs found and fixed, both worth recording:

1. `NWListener` and `NWBrowser` are not retained by the framework. Started
   instances must be held or they die when the creating function returns.
2. The relay originally cancelled both connections on `isComplete`. A half-close
   on one direction would therefore tear down a peer connection still in
   `preparing`, discarding all queued data. Each direction must close
   independently, propagating the FIN via `send(content: nil, isComplete: true)`.

**Phase 0 and Phase 2 both cleared (two Macs, Wi-Fi off both).** The mod was run
in game: a world shared with Open to LAN appeared on the second machine and was
joined and played, which exercises every layer including the two screen mixins.

On raw throughput: The 50 MB transfer completed
in roughly 6 seconds, about 8 MB/s. That is above the 5 MB/s mark set for "joining
feels instant", so Minecraft's initial chunk sync is a non-issue and AWDL's
realtime-mode elevation is evidently reached under this traffic pattern.

The timing was counted by hand rather than reported by the script, which hung
before printing, so treat 8 MB/s as approximate. It clears the threshold with
enough margin that a more precise figure would not change any decision.

## Build order

**Phase 0 — de-risk.** `awdl-lan-helper` alone. Two Macs, Wi-Fi disabled, piping
a file between them. This proves the local-network permission story and measures
real AWDL throughput before any mod code exists. It is a go/no-go gate: if the
permission model blocks a jar-extracted binary and a minimal `.app` bundle with
`NSLocalNetworkUsageDescription` does not rescue it, the design changes here
rather than after the mod is written.

**Phase 1 — mod.** The Java half, tested against a fake helper script speaking
the same JSON protocol. Most of the mod is therefore testable with no Minecraft
and no network.

**Phase 2 — integration.** Two Macs on no shared network, join a world.

## Out of scope for v1

Hotspot or Internet Sharing automation. Windows and Linux helpers. Bluetooth in
any role, including discovery. Any guarantee beyond ~4 players. Encryption
beyond plain TCP.

## References

- [Network framework peer-to-peer limitations](https://developer.apple.com/forums/thread/785308)
- [NWListener, P2P and awdl interfaces](https://developer.apple.com/forums/thread/718461)
- [NWBrowser PolicyDenied (-65570)](https://developer.apple.com/forums/thread/780655)
- [Resetting macOS local network permissions](https://zachbr.io/posts/2025-11-29-reset-macos-local-network-permissions/)
- [e4mc](https://www.curseforge.com/minecraft/mc-mods/e4mc)
- [SinglePlayerServerSettings [OfflineLAN]](https://www.curseforge.com/minecraft/mc-mods/singleplayerserversettings-offlinelan)
