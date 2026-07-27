package dev.awdllan;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Runs {@link HelperProcess} against a fake helper that speaks the same JSON
 * protocol. No Minecraft, no network, no second Mac.
 *
 * <pre>javac -d out ... &amp;&amp; java -ea -cp out dev.awdllan.HelperProcessSelfCheck</pre>
 */
public final class HelperProcessSelfCheck {

    // A world name carrying an escaped quote, a unicode escape, and a malformed
    // line in the middle of the stream. All three have broken naive parsers before.
    private static final String FAKE_HELPER = """
            #!/bin/sh
            echo '{"event":"ready","mode":"browse"}'
            echo '{"event":"found","id":"world-a","name":"Dev\\"s \\u2603 World","code":"1234"}'
            echo 'not json at all'
            echo '{"event":"unheard_of","id":"x"}'
            echo '{"event":"error","code":"local_network_denied","message":"denied"}'
            echo '{"event":"lost","id":"world-a"}'
            echo 'trace: some diagnostic' >&2
            while read -r line; do
              case "$line" in
                *connect*) echo '{"localPort":49999,"event":"connected","id":"world-a"}';;
              esac
            done
            """;

    private static final Path REAL_HELPER =
            Path.of("../helper/.build/release/awdl-lan-helper");

    public static void main(String[] args) throws Exception {
        checkParser();
        checkProtocol();
        checkAgainstRealHelper();
        System.out.println("PASS: HelperProcess self-check");
    }

    /**
     * The fake helper proves this class parses what it expects. This proves the
     * Swift binary actually emits that. Protocol drift between the two halves is
     * otherwise invisible until someone launches the game.
     */
    private static void checkAgainstRealHelper() throws Exception {
        if (!Files.isExecutable(REAL_HELPER)) {
            System.out.println("SKIP: real helper not built (swift build -c release in helper/)");
            return;
        }

        var ready = new CountDownLatch(1);
        var mode = new String[1];
        var listener = new HelperProcess.Listener() {
            @Override public void onReady(String m) {
                mode[0] = m;
                ready.countDown();
            }
            @Override public void onError(String code, String message) {
                if (code.equals("local_network_denied")) {
                    System.out.println("NOTE: local network permission denied on this machine");
                    ready.countDown();
                }
            }
        };

        HelperProcess process = HelperProcess.start(REAL_HELPER, List.of("browse"), listener);
        try {
            assertTrue(ready.await(10, TimeUnit.SECONDS), "real helper reached a ready or error state");
            if (mode[0] != null) {
                assertEquals("browse", mode[0], "real helper reports its mode");
            }
        } finally {
            process.close();
        }
        assertTrue(!process.isAlive(), "real helper exited on stdin close");
    }

    private static void checkParser() {
        var flat = HelperProcess.parseFlatJson("{\"event\":\"connected\",\"localPort\":49999}");
        assertEquals("connected", flat.get("event"), "string value");
        assertEquals("49999", flat.get("localPort"), "numeric value");

        var escaped = HelperProcess.parseFlatJson("{\"name\":\"a\\\"b\\\\c\",\"k\":\"v\"}");
        assertEquals("a\"b\\c", escaped.get("name"), "escaped quote and backslash");
        assertEquals("v", escaped.get("k"), "field after an escaped value");

        var unicode = HelperProcess.parseFlatJson("{\"name\":\"\\u2603\"}");
        assertEquals("\u2603", unicode.get("name"), "unicode escape");

        // Malformed input must degrade to empty, never throw.
        assertTrue(HelperProcess.parseFlatJson("not json").isEmpty(), "non-json line");
        assertTrue(HelperProcess.parseFlatJson("{\"unterminated").isEmpty(), "unterminated string");
        assertTrue(HelperProcess.parseFlatJson("").isEmpty(), "empty line");

        // A comma inside a value must not split the field.
        var comma = HelperProcess.parseFlatJson("{\"message\":\"a, b\",\"code\":\"x\"}");
        assertEquals("a, b", comma.get("message"), "comma inside a quoted value");
        assertEquals("x", comma.get("code"), "field after a comma-bearing value");
    }

    private static void checkProtocol() throws Exception {
        Path helper = writeFakeHelper();
        var events = new ArrayList<String>();
        var sawConnected = new CountDownLatch(1);
        var sawLost = new CountDownLatch(1);

        var listener = new HelperProcess.Listener() {
            @Override public void onReady(String mode) {
                record("ready:" + mode);
            }
            @Override public void onPeerFound(HelperProcess.Peer peer) {
                record("found:" + peer.id() + "|" + peer.name() + "|" + peer.code());
            }
            @Override public void onPeerLost(String id) {
                record("lost:" + id);
                sawLost.countDown();
            }
            @Override public void onTunnelReady(String id, int localPort) {
                record("tunnel:" + id + ":" + localPort);
                sawConnected.countDown();
            }
            @Override public void onTrace(String line) {
                record("trace:" + line);
            }
            @Override public void onError(String code, String message) {
                record("error:" + code);
            }
            private void record(String e) {
                synchronized (events) { events.add(e); }
            }
        };

        List<String> snapshot;
        HelperProcess process = HelperProcess.start(helper, List.of("browse"), listener);
        try {
            assertTrue(sawLost.await(5, TimeUnit.SECONDS), "streamed events arrived");

            process.connect("world-a");
            assertTrue(sawConnected.await(5, TimeUnit.SECONDS), "connect command round-tripped");

            synchronized (events) { snapshot = List.copyOf(events); }
            assertTrue(process.isAlive(), "helper alive before close");
        } finally {
            process.close();
        }

        // Closing stdin must actually stop the helper. Orphaned helpers would hold
        // the radio open after Minecraft quits.
        assertTrue(!process.isAlive(), "helper exited on stdin close");

        assertTrue(snapshot.contains("ready:browse"), "ready event");
        assertTrue(snapshot.contains("found:world-a|Dev\"s \u2603 World|1234"),
                "found event with escapes decoded, got: " + snapshot);
        assertTrue(snapshot.contains("error:local_network_denied"),
                "the permission failure must surface, never go silent");
        assertTrue(snapshot.contains("lost:world-a"), "lost event");
        assertTrue(snapshot.contains("tunnel:world-a:49999"), "tunnel port parsed");
        assertTrue(snapshot.stream().anyMatch(e -> e.startsWith("trace:")), "stderr drained to onTrace");

        // A deliberately unknown event and a malformed line must not have produced errors.
        assertTrue(snapshot.stream().noneMatch(e -> e.equals("error:unknown")),
                "unknown events ignored, not reported as errors");

        Files.deleteIfExists(helper);
    }

    private static Path writeFakeHelper() throws IOException {
        Path path = Files.createTempFile("fake-helper", ".sh");
        Files.writeString(path, FAKE_HELPER, StandardCharsets.UTF_8);
        path.toFile().setExecutable(true);
        return path;
    }

    private static void assertEquals(String expected, String actual, String what) {
        if (!expected.equals(actual)) {
            throw new AssertionError("FAIL " + what + ": expected [" + expected + "] got [" + actual + "]");
        }
    }

    private static void assertTrue(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError("FAIL " + what);
        }
    }
}
