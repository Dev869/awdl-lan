package dev.lanoverdirect;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.StringWidget;
import net.minecraft.client.gui.screens.ConnectScreen;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.resolver.ServerAddress;
import net.minecraft.network.chat.Component;

import java.util.List;

/**
 * Shows worlds found over peer-to-peer Wi-Fi, including the states the vanilla LAN
 * list cannot express: a peer still being dialled, and why discovery failed.
 *
 * <p>Surfacing failure is the reason this screen exists. macOS can refuse local
 * network access with no prompt, and the grant cannot be reset with {@code tccutil},
 * so a silent empty list would leave a player with no way to know what went wrong.
 */
public class NearbyWorldsScreen extends Screen {

    private static final int ROW_HEIGHT = 24;
    private static final int BUTTON_WIDTH = 240;

    private final Screen parent;
    private List<LanOverDirectClient.NearbyWorld> shown = List.of();
    private int ticks;

    public NearbyWorldsScreen(Screen parent) {
        super(Component.translatable("lan-over-direct.nearby.title"));
        this.parent = parent;
    }

    @Override
    protected void init() {
        LanOverDirectClient.acquireBrowse();
        shown = LanOverDirectClient.nearbyWorlds();

        int left = this.width / 2 - BUTTON_WIDTH / 2;
        int y = 40;

        String error = LanOverDirectClient.lastError();
        if (error != null) {
            for (Component line : describeError(error)) {
                addRenderableWidget(new StringWidget(left, y, BUTTON_WIDTH, 18, line, this.font));
                y += 18;
            }
            y += 8;
        }

        String hostingWorld = LanOverDirectClient.hostingWorld();
        if (hostingWorld != null) {
            addRenderableWidget(new StringWidget(left, y, BUTTON_WIDTH, 18,
                    Component.translatable("lan-over-direct.nearby.sharing",
                            hostingWorld, LanOverDirectClient.hostingCode()),
                    this.font));
            y += 26;
        }

        if (shown.isEmpty() && error == null) {
            addRenderableWidget(new StringWidget(left, y, BUTTON_WIDTH, 18,
                    Component.translatable("lan-over-direct.nearby.searching"), this.font));
            y += 26;
        }

        for (LanOverDirectClient.NearbyWorld world : shown) {
            Button button = Button.builder(label(world), b -> join(world))
                    .bounds(left, y, BUTTON_WIDTH, 20)
                    .build();
            // A peer without a tunnel yet has no address to connect to.
            button.active = world.ready();
            addRenderableWidget(button);
            y += ROW_HEIGHT;
        }

        addRenderableWidget(Button.builder(Component.translatable("gui.back"), b -> onClose())
                .bounds(left, Math.max(y + 12, this.height - 32), BUTTON_WIDTH, 20)
                .build());
    }

    private Component label(LanOverDirectClient.NearbyWorld world) {
        if (!world.ready()) {
            return Component.translatable("lan-over-direct.nearby.connecting", world.name());
        }
        return world.code().isEmpty()
                ? Component.literal(world.name())
                : Component.translatable("lan-over-direct.nearby.entry", world.name(), world.code());
    }

    private static List<Component> describeError(String code) {
        return switch (code) {
            case "local_network_denied" -> List.of(
                    Component.translatable("lan-over-direct.error.denied.1"),
                    Component.translatable("lan-over-direct.error.denied.2"));
            case "helper_died", "helper_start_failed" -> List.of(
                    Component.translatable("lan-over-direct.error.helper"));
            default -> List.of(Component.translatable("lan-over-direct.error.generic", code));
        };
    }

    private void join(LanOverDirectClient.NearbyWorld world) {
        String address = "127.0.0.1:" + world.port();
        ConnectScreen.startConnecting(this, Minecraft.getInstance(),
                ServerAddress.parseString(address),
                new ServerData(world.name(), address, ServerData.Type.LAN),
                false, null);
    }

    @Override
    public void tick() {
        // Peers appear, finish dialling, and leave while this screen is open.
        if (++ticks % 20 == 0 && !LanOverDirectClient.nearbyWorlds().equals(shown)) {
            rebuildWidgets();
        }
    }

    @Override
    public void removed() {
        LanOverDirectClient.releaseBrowse();
    }

    @Override
    public void onClose() {
        Minecraft.getInstance().setScreenAndShow(parent);
    }
}
