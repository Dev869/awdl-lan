# AWDL LAN

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

## Why not just use a hotspot

A hotspot does work, so this is a question of what it costs rather than whether
it is possible.

A hotspot makes someone leave their network. AWDL runs alongside an existing
Wi-Fi connection on the same radio, so both machines keep the network they were
already on — no dropped internet, no voice chat cutting out mid-game. Making that
true while joined to a network is most of what 1.0.2 was about.

Two laptops with only Wi-Fi also cannot do this natively. macOS Internet Sharing
cannot share a Wi-Fi connection *over* Wi-Fi; the uplink and the shared interface
have to be different, so you need Ethernet or a second adapter. The old ad-hoc
"Create Network" item is gone from the Wi-Fi menu on recent macOS. What is left in
practice is someone's iPhone hotspot, which means cellular data, a charged phone
in the room, and both Macs joining it.

And there is nothing to set up here. No SSID, no password read out loud, no one
changing network settings. AWDL is already running for AirDrop.

Use a hotspot instead when your friend is not on a Mac — AWDL is Apple-only and
no amount of work on this mod changes that. Or for more than about four players,
where Apple's peer-to-peer link degrades and a hotspot scales better. Or when you
would rather not have both people install a mod, since vanilla LAN over a hotspot
just works.

This is for two to four Macs somewhere with no usable network, who would rather
not burn cellular or give up the connections they already have.

## Build and package

```sh
./package.sh          # tests both halves, builds, verifies, writes dist/
```

That is the only command needed for a release. It runs both test suites, then
checks the packaged jar rather than trusting the build: required resources present,
embedded binary byte-identical to the one just compiled, signature still valid, and
the binary still executable after the jar round trip.

Upload `dist/awdl-lan-<version>.jar`. Project page copy is in
[MODRINTH.md](MODRINTH.md).

## Layout

| Path | What |
|---|---|
| `helper/` | Swift binary. Owns AWDL, speaks JSON lines on stdio. |
| `mod/` | Fabric mod. Process management and UI. |
| `docs/DESIGN.md` | Design, including revisions and what was measured. |

## Testing

```sh
helper/test.sh        # full relay path on one machine, no second Mac
mod/test.sh           # transport classes under plain javac, no Minecraft
cd mod && gradle runClient
```

`helper/twomac.sh` runs the two-Mac transport test. `mod/test.sh` enforces that `HelperProcess` and `HelperBinary` never import
Minecraft or Fabric. That boundary is what keeps them testable in seconds, and it
broke silently once already.

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

A shared world is open to anyone in radio range. The room code is advertised in
the clear and is shown to disambiguate two worlds with the same name, not checked
on join — same as vanilla Open to LAN, which gates nothing either. The difference
worth knowing is reach: vanilla LAN needs an attacker on your network, and this
needs only proximity, since AWDL carries no network to join. Treat sharing a world
the way you would treat sharing it on open Wi-Fi.
