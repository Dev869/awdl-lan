# LAN over Direct

Minecraft multiplayer between two Macs with no router, no network, and no
configuration, carried over **AWDL** — the peer-to-peer Wi-Fi radio behind AirDrop
and Sidecar.

Minecraft speaks plain TCP, so the whole problem reduces to a proxy:

```
[MC host] ──127.0.0.1:25565──> [helper] ≈≈AWDL≈≈> [helper] ──127.0.0.1:PORT──> [MC client]
```

A small Swift binary owns the radio via Network.framework. The Java mod never sees
anything but a loopback port, which is why it needs no JNI, no native bindings, and
no Bluetooth stack.

Minecraft 26.1–26.2, Fabric, client-side, macOS only.

## Build and package

```sh
./package.sh          # tests both halves, builds, verifies, writes dist/
```

That is the only command needed for a release. It runs both test suites, then
checks the packaged jar rather than trusting the build: required resources present,
embedded binary byte-identical to the one just compiled, signature still valid, and
the binary still executable after the jar round trip.

Upload `dist/lan-over-direct-<version>.jar`. Project page copy is in
[MODRINTH.md](MODRINTH.md).

## Layout

| Path | What |
|---|---|
| `helper/` | Swift binary. Owns AWDL, speaks JSON lines on stdio. |
| `mod/` | Fabric mod. Process management and UI. |
| `docs/superpowers/specs/` | Design spec, including revisions and what was measured. |
| `howto.html` | Two-Mac AWDL transport test. |

## Testing

```sh
helper/test.sh        # full relay path on one machine, no second Mac
mod/test.sh           # transport classes under plain javac, no Minecraft
cd mod && gradle runClient
```

`mod/test.sh` enforces that `HelperProcess` and `HelperBinary` never import
Minecraft or Fabric. That boundary is what keeps them testable in seconds, and it
broke silently once already.

A client gametest (`gradle runClientGametest`) opens the screens the mod mixes
into. Booting to the title screen proves nothing about them: those classes only
load when Multiplayer opens, and mixins apply at class load.

## Design notes

Peers are surfaced as ordinary `LanServer` entries pointing at a loopback tunnel,
so vanilla renders, pings, and joins them unaided. One `@ModifyVariable` is the
entire list integration.

They are dialled eagerly on discovery, because an entry's address must be real
before it can be clicked. This also hides AWDL's slow first association.

Discovery is hold-counted, not started and stopped. Screen handoff fires the old
screen's `removed()` before the new screen's `init()`, so a plain stop/start blanks
the list on every navigation.

Minecraft went unobfuscated at 26.1, which is why there is no `mappings` line in
`build.gradle` and why the mixins reference real names. It is also why 1.21.x is
out of reach without a separate mappings build.

## Limits

macOS only, by construction. Roughly 2–4 players before Apple's peer-to-peer
protocol degrades. Traffic is unencrypted, matching vanilla Open to LAN.
