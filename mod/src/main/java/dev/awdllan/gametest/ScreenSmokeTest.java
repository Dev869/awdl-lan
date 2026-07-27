package dev.awdllan.gametest;

import dev.awdllan.AwdlLanClient;
import dev.awdllan.NearbyWorldsScreen;
import net.fabricmc.fabric.api.client.gametest.v1.FabricClientGameTest;
import net.fabricmc.fabric.api.client.gametest.v1.context.ClientGameTestContext;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.client.gui.screens.multiplayer.JoinMultiplayerScreen;

/**
 * Opens the screens this mod touches so their mixins actually apply.
 *
 * <p>Booting to the title screen proves nothing about these injections:
 * {@code JoinMultiplayerScreen} and {@code ServerSelectionList} are not loaded until
 * the multiplayer screen opens, and mixins are applied at class load. With
 * {@code defaultRequire: 1} a stale target throws there, so simply reaching these
 * screens without an exception is the assertion.
 *
 * <p>This is the check that catches a Minecraft update moving the ground under the
 * mixins, which is the most version-fragile part of the mod.
 */
public class ScreenSmokeTest implements FabricClientGameTest {

    @Override
    public void runTest(ClientGameTestContext context) {
        // Loading JoinMultiplayerScreen applies both the button injection and,
        // through its server list, the updateNetworkServers ModifyVariable.
        context.setScreen(() -> new JoinMultiplayerScreen(new TitleScreen()));
        context.waitTicks(40);
        context.takeScreenshot("multiplayer-screen");

        // The mod's own screen, reached in play via the Nearby button.
        context.setScreen(() -> new NearbyWorldsScreen(new TitleScreen()));
        context.waitTicks(40);
        context.takeScreenshot("nearby-worlds-screen");

        context.runOnClient(client -> {
            // Discovery should be held by the open screen, and querying it must not throw.
            AwdlLanClient.nearbyWorlds();
            if (AwdlLanClient.lastError() != null) {
                // Not a failure: a machine with Local Network denied still exercises the
                // mixins. Record it so the run is not silently misread as a clean pass.
                AwdlLanClient.LOG.warn("Gametest saw discovery error: {}",
                        AwdlLanClient.lastError());
            }
        });

        context.setScreen(TitleScreen::new);
        context.waitTicks(20);
    }
}
