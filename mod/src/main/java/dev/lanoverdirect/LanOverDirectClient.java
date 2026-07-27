package dev.lanoverdirect;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.loader.api.FabricLoader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.file.Path;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Mod entry point. Owns the discovery helper and the set of peers currently in range.
 *
 * <p>Every failure here is non-fatal by design: if the helper is missing, blocked,
 * or crashes, the mod goes quiet and vanilla multiplayer keeps working.
 */
public final class LanOverDirectClient implements ClientModInitializer {

    public static final Logger LOG = LoggerFactory.getLogger("lan-over-direct");

    private static final Map<String, HelperProcess.Peer> PEERS = new ConcurrentHashMap<>();
    private static volatile HelperProcess browser;
    private static volatile Path helperPath;
    private static volatile String lastError;

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
            LOG.warn("Could not unpack the helper, peer-to-peer discovery disabled: {}", e.toString());
            return;
        }
        Runtime.getRuntime().addShutdownHook(new Thread(LanOverDirectClient::stopBrowsing));

        // ponytail: browsing for the whole session keeps the AWDL radio warm and costs
        // battery. Once the multiplayer screen mixin lands, scope this to that screen.
        startBrowsing();
    }

    // MARK: - Discovery lifecycle

    public static synchronized void startBrowsing() {
        if (helperPath == null || (browser != null && browser.isAlive())) {
            return;
        }
        PEERS.clear();
        lastError = null;
        try {
            browser = HelperProcess.start(helperPath, List.of("browse"), new Events());
        } catch (Exception e) {
            lastError = "helper_start_failed";
            LOG.warn("Could not start discovery: {}", e.toString());
        }
    }

    public static synchronized void stopBrowsing() {
        if (browser != null) {
            browser.close();
            browser = null;
        }
        PEERS.clear();
    }

    /** Peers currently in radio range. */
    public static Collection<HelperProcess.Peer> peers() {
        return List.copyOf(PEERS.values());
    }

    /**
     * Last error code, or null. {@code local_network_denied} is the one that needs
     * to reach the player as text, since macOS gives no prompt and the grant cannot
     * be reset with tccutil.
     */
    public static String lastError() {
        return lastError;
    }

    /** Ask for a tunnel to a peer. The port arrives asynchronously via {@link Events}. */
    public static void requestTunnel(String peerId) {
        HelperProcess current = browser;
        if (current != null) {
            current.connect(peerId);
        }
    }

    // MARK: - Helper events

    private static final class Events implements HelperProcess.Listener {
        @Override
        public void onReady(String mode) {
            LOG.info("Discovery ready ({}).", mode);
        }

        @Override
        public void onPeerFound(HelperProcess.Peer peer) {
            PEERS.put(peer.id(), peer);
            LOG.info("Found nearby world '{}' (code {}).", peer.name(), peer.code());
        }

        @Override
        public void onPeerLost(String id) {
            HelperProcess.Peer gone = PEERS.remove(id);
            if (gone != null) {
                LOG.info("Lost nearby world '{}'.", gone.name());
            }
        }

        @Override
        public void onTunnelReady(String id, int localPort) {
            LOG.info("Tunnel to '{}' open on 127.0.0.1:{}.", id, localPort);
            // The screen mixin will hand this port to the vanilla connect flow.
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
