package dev.awdllan.mixin;

import dev.awdllan.AwdlLanClient;
import dev.awdllan.NearbyWorldsScreen;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.multiplayer.JoinMultiplayerScreen;
import net.minecraft.network.chat.Component;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Adds the Nearby button and scopes discovery to this screen.
 *
 * <p>Browsing holds the AWDL radio active, so it must not run for the whole session.
 */
@Mixin(JoinMultiplayerScreen.class)
public abstract class JoinMultiplayerScreenMixin extends Screen {

    protected JoinMultiplayerScreenMixin(Component title) {
        super(title);
    }

    @Inject(method = "init", at = @At("TAIL"))
    private void awdlLan$addNearbyButton(CallbackInfo ci) {
        AwdlLanClient.acquireBrowse();
        if (!dev.awdllan.HelperBinary.isSupportedPlatform()) {
            return;
        }
        Screen self = (Screen) (Object) this;
        addRenderableWidget(Button.builder(
                        Component.translatable("awdl-lan.button.nearby"),
                        b -> Minecraft.getInstance().setScreenAndShow(new NearbyWorldsScreen(self)))
                .bounds(this.width - 84, 6, 78, 20)
                .build());
    }

    @Inject(method = "removed", at = @At("HEAD"))
    private void awdlLan$stopBrowsing(CallbackInfo ci) {
        AwdlLanClient.releaseBrowse();
    }
}
