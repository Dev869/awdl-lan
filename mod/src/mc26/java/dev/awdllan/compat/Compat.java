package dev.awdllan.compat;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.ConnectScreen;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.resolver.ServerAddress;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.network.chat.Component;

/**
 * The vanilla calls that were renamed or resignatured between Minecraft lines.
 *
 * <p>{@literal Minecraft 26.x}. One copy of this class exists per line, under {@code src/mc*}, and the
 * build puts exactly one of them on the source path — see TARGETS in build.gradle.
 * Keep it to renames: a real behavioural difference belongs in the shared code where
 * it can be read.
 */
public final class Compat {
    private Compat() {}

    public static void show(Screen screen) {
        Minecraft.getInstance().setScreenAndShow(screen);
    }

    public static void tell(LocalPlayer player, Component message) {
        player.sendSystemMessage(message);
    }

    public static void connect(Screen parent, String address, String name) {
        ConnectScreen.startConnecting(parent, Minecraft.getInstance(),
                ServerAddress.parseString(address),
                new ServerData(name, address, ServerData.Type.LAN), false, null);
    }
}
