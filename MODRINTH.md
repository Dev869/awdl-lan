# Modrinth submission

Everything below is paste-ready. Run `./package.sh` first; it leaves five jars in
`dist/`, one per Minecraft line, and each goes up as its own version. The script
prints the game-version range to tick for each one.

## Project settings

| Field | Value |
|---|---|
| Name | AWDL LAN |
| Slug | `awdl-lan` |
| Summary | Play together over Apple peer-to-peer Wi-Fi. No router, no network, no setup. macOS only. |
| Categories | Utility, Social (feature both; "Multiplayer" is not a Modrinth category) |
| Environment | **Client-side only** (tick "Works in singleplayer too") |
| License | MIT |

## Version settings

| Field | Value |
|---|---|
| Version number | the jar's filename after `awdl-lan-`, so `<mod_version>` or `<mod_version>+mc<version>` |
| Channel | Release |
| Loaders | Fabric |
| Game versions | the range `./package.sh` prints beside that jar |
| Dependencies | Fabric API — required |

The version changelog field is in [CHANGELOG.md](CHANGELOG.md).

## Description (paste as-is)

Two Macs. No router, no Wi-Fi network, no internet, no IP addresses. Open your
world to LAN and it shows up on your friend's machine.

This works by carrying Minecraft over **AWDL**, the peer-to-peer Wi-Fi radio Apple
built for AirDrop and Sidecar. It is the same link your Mac already uses to send a
photo to someone across the room, so there is nothing to configure and no network
to join. Turn Wi-Fi off entirely and it still works.

### How to use it

1. Install it on both Macs, along with Fabric API.
2. Host: open a world, pause, **Open to LAN**.
3. Joiner: open **Multiplayer**. The world appears in the LAN section within a few
   seconds, tagged `(nearby)` with a room code.
4. Click it and play.

A **Nearby** button on the multiplayer screen shows more detail: worlds still
connecting, the room code you are sharing under, and a clear message if anything
went wrong.

### Requirements

- **macOS only**, Intel or Apple Silicon. AWDL is Apple technology, so a Mac cannot link to a Windows or
  Linux machine this way. The mod installs harmlessly on other platforms and simply
  does nothing.
- Both players need the mod and Fabric API.
- Leave Bluetooth on. macOS uses it to bring up the peer-to-peer link.
- Best for 2 to 4 players. Apple's peer-to-peer protocol degrades sharply beyond
  a handful of devices.

### First run

macOS asks for Local Network permission the first time. If discovery stays empty,
check Settings › Privacy & Security › Local Network. The mod tells you on screen
when this is the problem, rather than showing an empty list.

### What it does not do

No internet play and no relay servers. Everything stays between the two machines.
Traffic is unencrypted, exactly like vanilla Open to LAN. The room code labels
worlds so you can tell them apart; it does not gate who joins.
