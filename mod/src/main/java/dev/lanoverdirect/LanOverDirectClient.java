package dev.lanoverdirect;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.client.server.LanServer;
import net.minecraft.network.chat.Component;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Mod entry point. Owns the two helper processes and the peers currently in range.
 *
 * <p>Discovered peers are surfaced as ordinary {@link LanServer} entries pointing at
 * a loopback tunnel, so they render in the vanilla LAN section and join through the
 * vanilla flow. There is no custom UI anywhere in this mod.
 *
 * <p>Every failure path is non-fatal: a missing, blocked, or dead helper leaves
 * vanilla multiplayer untouched.
 */
public final class LanOverDirectClient implements ClientModInitializer {

    public static final Logger LOG = LoggerFactory.getLogger("lan-over-direct");

    private static final Map<String, HelperProcess.Peer> PEERS = new ConcurrentHashMap<>();
    private static final Map<String, Integer> TUNNELS = new ConcurrentHashMap<>();

    private static volatile Path helperPath;
    private static volatile HelperProcess browser;
    private static volatile HelperProcess host;
    private static volatile String lastError;
    private static volatile String hostingWorld;
    private static volatile String hostingCode;

    /** Port the integrated server was last seen published on, or -1. */
    private static int publishedPort = -1;

    /** Screens currently wanting discovery. Zero means the radio can be released. */
    private static int browseHolders;

    @Override
    public void onInitializeClient() {
        if (!HelperBinary.isSupportedPlatform()) {
            LOG.info("Peer-to-peer discovery needs macOS; disabled on this platform.");
            return;
        }
        try {
            helperPath = HelperBinary.extract(
                    FabricLoader.getInstance().getConfigDir().resolve("lan-over-direct"));
        } catch (Exception e) {
            LOG.warn("Could not unpack the helper, peer-to-peer play disabled: {}", e.toString());
            return;
        }

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            stopBrowsing();
            stopHosting();
        }));

        // Watching the integrated server's published state covers both publishServer
        // overloads and unpublishServer in one place, with no mixin.
        ClientTickEvents.END_CLIENT_TICK.register(LanOverDirectClient::tick);
    }

    // MARK: - Hosting

    private static void tick(Minecraft client) {
        checkHostState(client);
        if (browseHolders == 0 && browser != null) {
            stopBrowsing();
        }
    }

    private static void checkHostState(Minecraft client) {
        IntegratedServer server = client.getSingleplayerServer();
        int port = (server != null && server.isPublished()) ? server.getPort() : -1;
        if (port == publishedPort) {
            return;
        }
        publishedPort = port;
        stopHosting();
        if (port > 0) {
            startHosting(port, server.getWorldData().getLevelName());
        }
    }

    private static synchronized void startHosting(int port, String worldName) {
        if (helperPath == null) {
            return;
        }
        String code = String.format("%04d", ThreadLocalRandom.current().nextInt(10000));
        try {
            host = HelperProcess.start(helperPath,
                    List.of("host", "--port", String.valueOf(port), "--name", worldName, "--code", code),
                    new Events());
            // Joiners see this code in the server list entry; the host sees it in chat,
            // next to vanilla's own "Local game hosted on port" line.
            hostingWorld = worldName;
            hostingCode = code;
            LOG.info("Sharing '{}' over peer-to-peer Wi-Fi. Room code: {}", worldName, code);
            var player = Minecraft.getInstance().player;
            if (player != null) {
                player.sendSystemMessage(
                        Component.translatable("lan-over-direct.chat.hosting", code));
            }
        } catch (Exception e) {
            LOG.warn("Could not start hosting: {}", e.toString());
        }
    }

    private static synchronized void stopHosting() {
        if (host != null) {
            host.close();
            host = null;
        }
        hostingWorld = null;
        hostingCode = null;
    }

    // MARK: - Discovery
    //
    // Scoped to the screens that need it. Browsing keeps the AWDL radio warm, so it
    // must not run for the whole session.

    /**
     * Screens that want discovery running call this on open and {@link #releaseBrowse()}
     * on close.
     *
     * <p>It is a count rather than a start/stop pair because moving between the
     * multiplayer screen and the nearby screen fires the old screen's {@code removed}
     * before the new screen's {@code init}. A plain stop/start there would restart the
     * helper and blank the list on every navigation. The count only reaches zero when
     * the player has genuinely left, and it is checked on tick, by which point any
     * handoff has already re-acquired.
     */
    public static synchronized void acquireBrowse() {
        browseHolders++;
        if (helperPath == null || (browser != null && browser.isAlive())) {
            return;
        }
        PEERS.clear();
        TUNNELS.clear();
        lastError = null;
        try {
            browser = HelperProcess.start(helperPath, List.of("browse"), new Events());
        } catch (Exception e) {
            lastError = "helper_start_failed";
            LOG.warn("Could not start discovery: {}", e.toString());
        }
    }

    public static synchronized void releaseBrowse() {
        browseHolders = Math.max(0, browseHolders - 1);
    }

    private static synchronized void stopBrowsing() {
        if (browser != null) {
            browser.close();
            browser = null;
        }
        PEERS.clear();
        TUNNELS.clear();
    }

    /**
     * Peers with an open tunnel, as vanilla LAN entries.
     *
     * <p>Only peers that already have a tunnel appear, because the address has to be
     * real before the player can click it. Dialling happens eagerly on discovery,
     * which also hides AWDL's slow first association behind the time spent reading
     * the server list.
     */
    public static List<LanServer> nearbyLanServers() {
        List<LanServer> entries = new ArrayList<>();
        for (Map.Entry<String, Integer> tunnel : TUNNELS.entrySet()) {
            HelperProcess.Peer peer = PEERS.get(tunnel.getKey());
            if (peer != null) {
                // The code disambiguates two worlds with the same name in one room.
                // It is shown, not enforced: gating the join would mean a text-entry
                // screen, and vanilla Open to LAN gates nothing either.
                String label = peer.code().isEmpty()
                        ? peer.name() + " (nearby)"
                        : peer.name() + " (nearby · " + peer.code() + ")";
                entries.add(new LanServer(label, "127.0.0.1:" + tunnel.getValue()));
            }
        }
        return entries;
    }

    /** Last error code, or null. {@code local_network_denied} is the one players must be told about. */
    public static String lastError() {
        return lastError;
    }

    /**
     * A peer as the UI sees it. {@code port} is -1 while the tunnel is still being
     * dialled, which is the state the vanilla LAN list cannot express.
     */
    public record NearbyWorld(String id, String name, String code, int port) {
        public boolean ready() {
            return port > 0;
        }
    }

    /** Every peer in range, dialled or not, sorted for a stable list. */
    public static List<NearbyWorld> nearbyWorlds() {
        List<NearbyWorld> worlds = new ArrayList<>();
        for (HelperProcess.Peer peer : PEERS.values()) {
            Integer port = TUNNELS.get(peer.id());
            worlds.add(new NearbyWorld(peer.id(), peer.name(), peer.code(), port == null ? -1 : port));
        }
        worlds.sort(Comparator.comparing(NearbyWorld::name).thenComparing(NearbyWorld::id));
        return worlds;
    }

    /** Name of the world being shared, or null. */
    public static String hostingWorld() {
        return hostingWorld;
    }

    /** Room code being advertised, or null. */
    public static String hostingCode() {
        return hostingCode;
    }

    // MARK: - Helper events

    private static final class Events implements HelperProcess.Listener {
        @Override
        public void onReady(String mode) {
            LOG.info("Helper ready ({}).", mode);
        }

        @Override
        public void onPeerFound(HelperProcess.Peer peer) {
            PEERS.put(peer.id(), peer);
            LOG.info("Found nearby world '{}' (code {}).", peer.name(), peer.code());
            HelperProcess current = browser;
            if (current != null) {
                current.connect(peer.id());   // dial now so the entry is clickable when shown
            }
        }

        @Override
        public void onPeerLost(String id) {
            HelperProcess.Peer gone = PEERS.remove(id);
            TUNNELS.remove(id);
            if (gone != null) {
                LOG.info("Lost nearby world '{}'.", gone.name());
            }
        }

        @Override
        public void onTunnelReady(String id, int localPort) {
            TUNNELS.put(id, localPort);
            LOG.info("Tunnel to '{}' open on 127.0.0.1:{}.", id, localPort);
        }

        @Override
        public void onTrace(String line) {
            LOG.debug("helper: {}", line);
        }

        @Override
        public void onError(String code, String message) {
            lastError = code;
            if (code.equals("local_network_denied")) {
                LOG.error("macOS denied local network access. Grant it in System Settings > "
                        + "Privacy & Security > Local Network, then restart the game.");
            } else {
                LOG.warn("Helper error [{}]: {}", code, message);
            }
        }
    }
}
