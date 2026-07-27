# Changelog

## 1.0.2

Fixes joining. If 1.0.0 showed you a nearby world that would not let you in, this
is the release that fixes it.

**Joining works from the Multiplayer list.** Picking a nearby world from the
vanilla LAN section closed the connection at the moment it opened, so the join
failed every time. Joining from the Nearby screen usually worked, which is why
this looked intermittent rather than broken.

**Joining works on a Wi-Fi network.** A world seen over both Wi-Fi and the
peer-to-peer radio was treated as two worlds, and the mod could try to reach it
over the side that had no route to it. Worlds also flickered in and out of the
list. Both are fixed, so you no longer have to leave your network to play.

**Retrying works.** Leaving a world and coming back, or trying again after a
failed join, used to hit a dead end until the world was rediscovered.

**A join that cannot succeed now fails instead of hanging.** It tries the other
routes to the world first, then gives up rather than leaving you on a loading
screen.

Also: a world whose name started or ended with a space could never be joined.
Nearby machines can no longer use colour codes in a world name to make it look
like something the mod said. Discovery no longer keeps the radio warm for the
rest of your session after you have opened the Nearby screen once.

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
