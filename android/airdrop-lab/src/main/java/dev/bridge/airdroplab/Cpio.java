package dev.bridge.airdroplab;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.charset.*;
import java.util.*;
import java.util.zip.*;

/** Streaming gzip+CPIO, regular files only, with a transaction directory. */
public final class Cpio {
    private Cpio() {}
    public static String fileName(String name) throws IOException {
        if (name == null || name.isEmpty() || name.equals(".") || name.equals("..") || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || name.getBytes(StandardCharsets.UTF_8).length > 255 || name.chars().anyMatch(c -> c < 32 || c == 127)) throw new IOException("Unsafe/unsupported filename");
        return name;
    }
    public static void write(OutputStream destination, String name, long size, InputStream source) throws IOException {
        name = fileName(name); if (size < 0 || size > Http.FILE_LIMIT) throw new IOException("File exceeds 32 MiB lab limit");
        GZIPOutputStream gzip = new GZIPOutputStream(destination, 8192);
        odc(gzip, "./" + name, size, 0100644); copy(source, gzip, size);
        if (source.read() != -1) throw new IOException("Source grew while sending");
        odc(gzip, "TRAILER!!!", 0, 0); gzip.finish(); gzip.flush();
    }
    private static void odc(OutputStream out, String name, long size, int mode) throws IOException {
        byte[] n = name.getBytes(StandardCharsets.UTF_8);
        String h = String.format(Locale.ROOT, "070707%06o%06o%06o%06o%06o%06o%06o%011o%06o%011o", 0, 1, mode, 0, 0, 1, 0, 0L, n.length + 1, size);
        out.write(h.getBytes(StandardCharsets.US_ASCII)); out.write(n); out.write(0);
    }
    public static List<File> receive(InputStream compressed, File staging, Set<String> expected) throws IOException {
        if (expected.isEmpty() || expected.size() > 8) throw new IOException("Unsupported file count");
        for (String name : expected) fileName(name);
        CountingInput counted = new CountingInput(new GZIPInputStream(compressed, 8192));
        List<File> saved = new ArrayList<>(); Set<String> seen = new HashSet<>(); long total = 0; int entries = 0;
        try {
            for (;;) {
                if (++entries > 12) throw new IOException("Too many archive entries");
                String magic = ascii(exact(counted, 6)); long mode, size, names, links; boolean newc;
                if (magic.equals("070707")) {
                    String h = ascii(exact(counted, 70)); mode = numeric(h.substring(12, 18), 8); links = numeric(h.substring(30, 36), 8);
                    names = numeric(h.substring(53, 59), 8); size = numeric(h.substring(59, 70), 8); newc = false;
                } else if (magic.equals("070701")) {
                    String h = ascii(exact(counted, 104)); mode = numeric(h.substring(8, 16), 16); links = numeric(h.substring(32, 40), 16);
                    size = numeric(h.substring(48, 56), 16); names = numeric(h.substring(88, 96), 16); newc = true;
                } else throw new IOException("Unsupported CPIO format (expected odc/newc)");
                if (names < 1 || names > 1024 || size < 0 || size > Http.FILE_LIMIT) throw new IOException("Archive entry exceeds limit");
                byte[] nb = exact(counted, (int) names);
                if (nb[nb.length - 1] != 0) throw new IOException("Missing archive name terminator");
                String raw = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(nb, 0, nb.length - 1)).toString();
                if (newc) padding(counted, 110 + names);
                if (raw.equals("TRAILER!!!")) { if (size != 0) throw new IOException("Invalid CPIO trailer"); break; }
                if ((raw.equals(".") || raw.equals("./")) && (mode & 0170000) == 0040000 && size == 0) continue;
                String name = fileName(raw.startsWith("./") ? raw.substring(2) : raw);
                if ((mode & 0170000) != 0100000 || links != 1 || !expected.contains(name) || !seen.add(name)) throw new IOException("Unexpected, duplicate or linked archive entry");
                total += size; if (total > Http.FILE_LIMIT) throw new IOException("Archive exceeds 32 MiB lab limit");
                File file = new File(staging, name);
                if (!file.createNewFile()) throw new IOException("Archive destination already exists");
                try (FileOutputStream output = new FileOutputStream(file)) { copy(counted, output, size); }
                saved.add(file); if (newc) padding(counted, size);
            }
            // Consume footer/zero padding to verify gzip CRC and the HTTP chunk terminator.
            int c, padding = 0; while ((c = counted.read()) != -1) { if (c != 0 || ++padding > 65536) throw new IOException("Unexpected archive tail"); }
            if (compressed.read() != -1) throw new IOException("Unexpected compressed archive tail");
            if (!seen.equals(expected)) throw new IOException("Archive does not match accepted offer");
            return saved;
        } catch (IOException | RuntimeException error) { delete(staging); throw error; }
    }
    public static void delete(File directory) {
        File[] children = directory.listFiles(); if (children != null) for (File child : children) child.delete(); directory.delete();
    }
    private static long numeric(String value, int radix) throws IOException {
        if (!value.matches(radix == 8 ? "[0-7]+" : "[0-9a-fA-F]+")) throw new IOException("Invalid CPIO number");
        try { return Long.parseLong(value, radix); } catch (NumberFormatException e) { throw new IOException("Invalid CPIO number", e); }
    }
    private static String ascii(byte[] b) { return new String(b, StandardCharsets.US_ASCII); }
    private static void padding(InputStream in, long offset) throws IOException { int n = (int) ((4 - offset % 4) % 4); for (int i = 0; i < n; i++) if (in.read() != 0) throw new IOException("Invalid CPIO padding"); }
    private static byte[] exact(InputStream in, int count) throws IOException { byte[] b = new byte[count]; new DataInputStream(in).readFully(b); return b; }
    private static void copy(InputStream in, OutputStream out, long remaining) throws IOException {
        byte[] b = new byte[8192]; while (remaining > 0) { int n = in.read(b, 0, (int) Math.min(b.length, remaining)); if (n < 0) throw new EOFException("Truncated file/archive"); out.write(b, 0, n); remaining -= n; }
    }
    private static final class CountingInput extends FilterInputStream {
        long read;
        CountingInput(InputStream in) { super(in); }
        @Override public int read() throws IOException { int c = in.read(); if (c >= 0 && ++read > Http.FILE_LIMIT + 1048576) throw new IOException("Inflated archive exceeds limit"); return c; }
        @Override public int read(byte[] b, int off, int len) throws IOException { int n = in.read(b, off, len); if (n > 0 && (read += n) > Http.FILE_LIMIT + 1048576) throw new IOException("Inflated archive exceeds limit"); return n; }
    }
}
