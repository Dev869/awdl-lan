package dev.awdllan;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.HexFormat;

/**
 * Unpacks the bundled awdl-lan-helper to a stable on-disk location.
 *
 * <p>The binary cannot run from inside the jar, so it is written to a cache
 * directory named by content hash. Hashing means an updated mod ships an
 * updated helper without a stale copy shadowing it, and an unchanged mod skips
 * the write entirely.
 */
public final class HelperBinary {

    /** Path inside the jar. Populated by the build from helper/.build/apple/Products/Release/. */
    private static final String RESOURCE = "/native/awdl-lan-helper";

    private HelperBinary() {}

    public static boolean isSupportedPlatform() {
        String os = System.getProperty("os.name", "").toLowerCase();
        return os.contains("mac") || os.contains("darwin");
    }

    /**
     * @param cacheDir typically the mod's own config or cache directory
     * @return the executable helper path
     * @throws IOException if the binary is missing from the jar or cannot be written
     */
    public static Path extract(Path cacheDir) throws IOException {
        byte[] binary = readResource();
        String hash = sha256(binary).substring(0, 16);
        Path target = cacheDir.resolve("awdl-lan-helper-" + hash);

        if (Files.isExecutable(target) && Files.size(target) == binary.length) {
            return target;   // already unpacked and unchanged
        }

        Files.createDirectories(cacheDir);

        // Write to a temp name and move into place, so a crash midway cannot leave
        // a truncated binary that looks valid to the size check above.
        Path staging = Files.createTempFile(cacheDir, "awdllan-", ".tmp");
        try {
            Files.write(staging, binary);
            if (!staging.toFile().setExecutable(true, true)) {
                throw new IOException("could not mark helper executable: " + staging);
            }
            Files.move(staging, target, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(staging);
        }
        return target;
    }

    private static byte[] readResource() throws IOException {
        try (InputStream in = HelperBinary.class.getResourceAsStream(RESOURCE)) {
            if (in == null) {
                throw new IOException("helper binary missing from jar at " + RESOURCE
                        + " (build the Swift helper first)");
            }
            return in.readAllBytes();
        }
    }

    private static String sha256(byte[] data) throws IOException {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException("SHA-256 unavailable", e);
        }
    }
}
