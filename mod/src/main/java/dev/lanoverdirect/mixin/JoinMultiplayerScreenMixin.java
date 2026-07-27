package dev.lanoverdirect.mixin;

import dev.lanoverdirect.LanOverDirectClient;
import net.minecraft.client.gui.screens.multiplayer.JoinMultiplayerScreen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Scopes discovery to the multiplayer screen.
 *
 * <p>Browsing holds the AWDL radio active, so it must not run for the whole session.
 */
@Mixin(JoinMultiplayerScreen.class)
public class JoinMultiplayerScreenMixin {

    @Inject(method = "init", at = @At("TAIL"))
    private void lanOverDirect$startBrowsing(CallbackInfo ci) {
        LanOverDirectClient.startBrowsing();
    }

    @Inject(method = "removed", at = @At("HEAD"))
    private void lanOverDirect$stopBrowsing(CallbackInfo ci) {
        LanOverDirectClient.stopBrowsing();
    }
}
