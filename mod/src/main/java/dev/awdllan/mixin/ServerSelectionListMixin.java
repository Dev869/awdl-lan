package dev.awdllan.mixin;

import dev.awdllan.AwdlLanClient;
import net.minecraft.client.gui.screens.multiplayer.ServerSelectionList;
import net.minecraft.client.server.LanServer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyVariable;

import java.util.ArrayList;
import java.util.List;

/**
 * Appends peers found over AWDL to the LAN section of the multiplayer screen.
 *
 * <p>They are ordinary {@link LanServer} entries pointing at a loopback tunnel, so
 * vanilla renders and joins them with no help from us. That is the whole UI.
 */
@Mixin(ServerSelectionList.class)
public class ServerSelectionListMixin {

    @ModifyVariable(method = "updateNetworkServers", at = @At("HEAD"), argsOnly = true)
    private List<LanServer> awdlLan$addNearbyWorlds(List<LanServer> servers) {
        List<LanServer> nearby = AwdlLanClient.nearbyLanServers();
        if (nearby.isEmpty()) {
            return servers;
        }
        // Copy rather than mutate: the caller's list is vanilla's to own.
        List<LanServer> combined = new ArrayList<>(servers);
        combined.addAll(nearby);
        return combined;
    }
}
