# Changelog

## 1.0.1

Fixes joining while connected to a Wi-Fi network.

- A world advertised on both Wi-Fi and the peer-to-peer radio was treated as two
  different worlds. It could be dialled over the Wi-Fi side even when only the
  peer-to-peer side could reach it, and it flickered in and out of the list.
- Joining is no longer one-shot. The connection to a nearby world was torn down
  after the first attempt, so leaving a world and coming back, or retrying after
  a failed join, hit a dead port until the world was rediscovered.
- A world that stops responding mid-join now gets one retry on the path it was
  last seen on, then drops the connection instead of leaving Minecraft waiting
  on it.

## 1.0.0

First release.

Play Minecraft with someone on another Mac with no router, no Wi-Fi network,
and no internet. Open a world to LAN and it appears in their multiplayer list.

Traffic goes over AWDL, the peer-to-peer Wi-Fi radio behind AirDrop, so there
is nothing to configure and no network to join. Measured at ~8 MB/s with Wi-Fi
switched off on both machines, so joining is quick.

**Requirements**
- macOS on both machines. AWDL is Apple-only.
- Both players need this mod and Fabric API.
- Leave Bluetooth on. macOS uses it to bring up the link.

**Notes**
- macOS asks for Local Network permission on first run. If nothing shows up,
  check Settings › Privacy & Security › Local Network. The mod tells you on
  screen when this is the problem.
- Best with 2–4 players. Apple's peer-to-peer protocol degrades beyond that.
- Traffic is unencrypted, same as vanilla Open to LAN.
