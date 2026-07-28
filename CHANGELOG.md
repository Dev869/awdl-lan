# Changelog

## 1.1.0

Adds Minecraft 1.19.4 through 1.21, and Intel Macs.

**Five downloads, one mod.** Pick the jar for the version you play — 1.19.4, 1.20
to 1.20.1, 1.20.2 to 1.20.4, 1.20.5 to 1.21.11, or 26.1 to 26.2. The download page
lists the versions each one covers. Everything works the same on all of them: the
same nearby worlds in the same multiplayer list, over the same radio. Both players
still need the mod and the same Minecraft version, as they always did — the game
itself will not join a 1.20 client to a 26.2 world.

**Intel Macs work now.** The helper the mod runs was built for Apple Silicon only,
so on an Intel Mac nothing ever appeared. It now ships for both, back to macOS
10.15. Only current macOS has been tested, so if you are on something older and it
does not work, please report it.

Nothing changed in how any of it works.

## 1.0.3

Fixes joining while both Macs are on the same Wi-Fi network. If a nearby world
left you on "Connecting to the server…" for twenty seconds and then failed with
an internal exception, this is the release that fixes it.

**The peer-to-peer radio is used when the network cannot carry the game.** Being
on the same Wi-Fi as someone is not the same as being able to reach them through
it, and plenty of home routers, guest networks and hotel or campus Wi-Fi keep
devices from talking to each other at all. The mod took the network's word for it
and never tried the radio. Now, when the network route does not answer, it goes
over the radio instead — the same way it already worked with Wi-Fi switched off.

**A join that fails leaves an explanation.** If it still does not work, the log
says which routes were tried and how each one ended, which is what to attach if
you report it.

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
