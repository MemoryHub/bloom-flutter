package com.bloom.widget_bridge;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.channels.FileLock;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;

/** Identity fallback when Android supplies no usable hardware-scoped ID. */
public final class BloomInstallIdentity {
    private BloomInstallIdentity() {}

    public static boolean usableAndroidId(String value) {
        return value != null && value.matches("(?i)[0-9a-f]{16}")
                && !value.equalsIgnoreCase("0000000000000000")
                && !value.equalsIgnoreCase("ffffffffffffffff")
                && !value.equalsIgnoreCase("9774d56d682e549c");
    }

    /** Call with Context.noBackupFilesDir; independent phones never share this file. */
    public static synchronized Map<String, String> credentials(File directory) throws IOException {
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("identity directory unavailable");
        File path = new File(directory, "bloom-install-identity-v3.properties");
        try (RandomAccessFile file = new RandomAccessFile(path, "rw");
             FileLock ignored = file.getChannel().lock()) {
            Properties properties = new Properties();
            if (file.length() > 0) {
                if (file.length() > 4096) throw new IOException("invalid identity file");
                byte[] bytes = new byte[(int) file.length()];
                file.readFully(bytes);
                properties.load(new ByteArrayInputStream(bytes));
                if (!properties.getProperty("deviceId", "").matches("bloom-mobile-[0-9a-f-]{36}")
                        || !properties.getProperty("deviceToken", "").matches("[0-9a-f]{64}")) {
                    throw new IOException("incomplete identity file");
                }
            } else {
                properties.setProperty("deviceId", "bloom-mobile-" + UUID.randomUUID());
                byte[] bytes = new byte[32];
                new SecureRandom().nextBytes(bytes);
                StringBuilder token = new StringBuilder();
                for (byte value : bytes) token.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
                properties.setProperty("deviceToken", token.toString());
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                properties.store(output, "Bloom installation identity v3");
                file.write(output.toByteArray());
                file.getChannel().force(true);
            }
            Map<String, String> result = new HashMap<>();
            result.put("deviceId", properties.getProperty("deviceId"));
            result.put("deviceToken", properties.getProperty("deviceToken"));
            return result;
        }
    }
}
