package dev.awdllan;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * Owns the awdl-lan-helper subprocess and translates its JSON line protocol
 * into callbacks.
 *
 * <p>Everything radio-related lives in the helper. This class only ever deals
 * with a process, some lines of text, and a loopback port number, which is why
 * it can be tested without Minecraft, without a network, and without a Mac.
 */
public final class HelperProcess implements AutoCloseable {

    public record Peer(String id, String name, String code) {}

    public interface Listener {
        default void onReady(String mode) {}

        default void onPeerFound(Peer peer) {}

        default void onPeerLost(String id) {}

        default void onTunnelReady(String id, int localPort) {}

        /** Helper stderr. The only evidence available when this misbehaves on someone else's machine. */
        default void onTrace(String line) {}

        /**
         * Codes worth handling by name: {@code local_network_denied} (macOS refused
         * local network access, and the grant cannot be reset with tccutil, so this
         * must reach the player as an actionable message rather than an empty list),
         * {@code helper_died}, {@code unknown_peer}, {@code listener_failed}.
         */
        void onError(String code, String message);
    }

    private final Process process;
    private final BufferedWriter commands;
    private final Listener listener;
    private volatile boolean closing;

    private HelperProcess(Process process, Listener listener) {
        this.process = process;
        this.listener = listener;
        this.commands = new BufferedWriter(
                new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8));

        startDaemon("awdl-lan-events", () -> readLines(process.getInputStream(), this::dispatch, true));
        // stderr must be drained or its pipe buffer fills and the helper blocks mid-relay.
        startDaemon("awdl-lan-trace", () -> readLines(process.getErrorStream(), listener::onTrace, false));
    }

    public static HelperProcess start(Path binary, List<String> args, Listener listener) throws IOException {
        List<String> command = new ArrayList<>();
        command.add(binary.toString());
        command.addAll(args);
        return new HelperProcess(new ProcessBuilder(command).start(), listener);
    }

    /** Ask the helper to dial a discovered peer. The port arrives via {@link Listener#onTunnelReady}. */
    public void connect(String id) {
        send("{\"cmd\":\"connect\",\"id\":\"" + escape(id) + "\"}");
    }

    public boolean isAlive() {
        return process.isAlive();
    }

    @Override
    public void close() {
        closing = true;
        try {
            commands.close();   // closing stdin is the helper's shutdown signal
        } catch (IOException ignored) {
            // already gone
        }
        try {
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            process.destroyForcibly();
        }
    }

    // MARK: - Plumbing

    private void startDaemon(String name, Runnable body) {
        Thread thread = new Thread(body, name);
        thread.setDaemon(true);
        thread.start();
    }

    private void readLines(InputStream stream, java.util.function.Consumer<String> sink, boolean reportDeath) {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                sink.accept(line);
            }
        } catch (IOException ignored) {
            // stream closed underneath us; handled below
        }
        if (reportDeath && !closing) {
            listener.onError("helper_died", "helper exited unexpectedly");
        }
    }

    private synchronized void send(String json) {
        try {
            commands.write(json);
            commands.newLine();
            commands.flush();
        } catch (IOException e) {
            listener.onError("helper_died", "could not write to helper: " + e.getMessage());
        }
    }

    private void dispatch(String line) {
        Map<String, String> fields = parseFlatJson(line);
        String event = fields.get("event");
        if (event == null) {
            return;   // trace noise or a malformed line; never fatal
        }
        switch (event) {
            case "ready" -> listener.onReady(fields.getOrDefault("mode", ""));
            case "found" -> {
                String id = fields.get("id");
                if (id != null) {
                    listener.onPeerFound(new Peer(id,
                            fields.getOrDefault("name", id),
                            fields.getOrDefault("code", "")));
                }
            }
            case "lost" -> {
                String id = fields.get("id");
                if (id != null) {
                    listener.onPeerLost(id);
                }
            }
            case "connected" -> {
                try {
                    listener.onTunnelReady(fields.get("id"), Integer.parseInt(fields.get("localPort")));
                } catch (NumberFormatException | NullPointerException e) {
                    listener.onError("bad_event", line);
                }
            }
            case "error" -> listener.onError(
                    fields.getOrDefault("code", "unknown"),
                    fields.getOrDefault("message", ""));
            default -> {
                // forward compatible: unknown events are ignored, not fatal
            }
        }
    }

    // MARK: - JSON
    //
    // The protocol is a flat object of strings and numbers on both ends, and this
    // side controls the other end. Parsing it directly keeps the class runnable
    // under plain javac, so the tests need no Minecraft classpath and no Gson.

    static Map<String, String> parseFlatJson(String line) {
        Map<String, String> fields = new LinkedHashMap<>();
        int i = line.indexOf('{');
        if (i < 0) {
            return fields;
        }
        i++;
        while (i < line.length()) {
            while (i < line.length() && (line.charAt(i) == ' ' || line.charAt(i) == ',')) {
                i++;
            }
            if (i >= line.length() || line.charAt(i) == '}' || line.charAt(i) != '"') {
                break;
            }

            StringBuilder key = new StringBuilder();
            i = readQuoted(line, i, key);
            if (i < 0) {
                break;
            }

            while (i < line.length() && (line.charAt(i) == ' ' || line.charAt(i) == ':')) {
                i++;
            }
            if (i >= line.length()) {
                break;
            }

            StringBuilder value = new StringBuilder();
            if (line.charAt(i) == '"') {
                i = readQuoted(line, i, value);
                if (i < 0) {
                    break;
                }
            } else {
                while (i < line.length() && line.charAt(i) != ',' && line.charAt(i) != '}') {
                    value.append(line.charAt(i));
                    i++;
                }
            }
            fields.put(key.toString(), value.toString().trim());
        }
        return fields;
    }

    /** Reads a quoted string starting at its opening quote. Returns the index after the close, or -1. */
    private static int readQuoted(String s, int i, StringBuilder out) {
        i++;
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c == '"') {
                return i + 1;
            }
            if (c == '\\' && i + 1 < s.length()) {
                char escaped = s.charAt(++i);
                switch (escaped) {
                    case 'n' -> out.append('\n');
                    case 't' -> out.append('\t');
                    case 'r' -> out.append('\r');
                    case 'b' -> out.append('\b');
                    case 'f' -> out.append('\f');
                    case 'u' -> {
                        if (i + 4 < s.length()) {
                            out.append((char) Integer.parseInt(s.substring(i + 1, i + 5), 16));
                            i += 4;
                        }
                    }
                    default -> out.append(escaped);   // \" \\ \/
                }
            } else {
                out.append(c);
            }
            i++;
        }
        return -1;
    }

    /**
     * Escapes a value for the one-line JSON command protocol.
     *
     * <p>Control characters matter as much as quotes here. This escapes an id that
     * came from a Bonjour service name advertised by whoever is in radio range, and
     * the protocol is newline-delimited, so a raw newline in that name would split one
     * command into two lines and hand the second to the helper's parser as a command
     * of the peer's choosing.
     */
    static String escape(String s) {
        StringBuilder out = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '\\' -> out.append("\\\\");
                case '"' -> out.append("\\\"");
                default -> {
                    if (c < 0x20 || c == 0x7f) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        return out.toString();
    }
}
