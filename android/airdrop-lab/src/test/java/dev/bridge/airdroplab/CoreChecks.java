package dev.bridge.airdroplab;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import javax.net.ssl.*;

/** Executable offline checks against Python plistlib and libarchive fixtures. */
public final class CoreChecks {
    private static int checks;
    private interface Action { void run() throws Exception; }
    private static void check(boolean value, String name) { if (!value) throw new AssertionError(name); checks++; }
    private static void reject(String name, Action action) throws Exception {
        try { action.run(); throw new AssertionError("Accepted " + name); } catch (IOException expected) { checks++; }
    }
    private static InputStream ascii(String value) { return new ByteArrayInputStream(value.getBytes(StandardCharsets.US_ASCII)); }
    private static File stage(Path root) throws IOException { return Files.createTempDirectory(root, "stage-").toFile(); }
    public static void main(String[] args) throws Exception {
        Path root = Paths.get(args[0]);
        Map<String, Object> external = Plist.dictionary(Files.readAllBytes(root.resolve("python.plist")));
        check("Málaga 📁".equals(external.get("ReceiverComputerName")), "Python Unicode plist");
        check(Arrays.equals((byte[]) external.get("ReceiverMediaCapabilities"), new byte[] {0, 1, 2, 3}), "Python binary data");
        check(Boolean.FALSE.equals(external.get("Bool")), "Python boolean");
        check(((Number) external.get("Integer")).longValue() == 4294967296L, "Python 64-bit integer");
        check(((List<?>) external.get("Array")).size() == 20, "Python extended array length");
        Map<String, Object> output = Plist.map("ReceiverComputerName", "Málaga 📁", "ReceiverMediaCapabilities", new byte[] {0, 1, 2, 3}, "Bool", false,
            "Integer", 4294967296L, "Negative", -1L, "Array", new ArrayList<>(Collections.nCopies(20, "sample")));
        Files.write(root.resolve("java.plist"), Plist.encode(output));
        reject("truncated plist", () -> Plist.decode(new byte[8]));
        reject("cyclic plist", () -> Plist.decode(Files.readAllBytes(root.resolve("cycle.plist"))));
        reject("bad object offset", () -> Plist.decode(Files.readAllBytes(root.resolve("offset.plist"))));
        reject("oversized plist", () -> Plist.decode(new byte[Plist.LIMIT + 1]));
        List<Object> cyclic = new ArrayList<>(); cyclic.add(cyclic); reject("recursive encoder input", () -> Plist.encode(cyclic));
        reject("unsafe filename", () -> Cpio.fileName("../outside"));
        reject("NUL filename", () -> Cpio.fileName("a\u0000b"));
        reject("Windows path", () -> Cpio.fileName("a\\b"));
        String next = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nz";
        InputStream http = ascii("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n1;test=1\r\nc\r\n0\r\nX-Test: yes\r\n\r\n" + next);
        check(Arrays.equals(Http.bytes(Http.read(http, true).body, 64), "abc".getBytes(StandardCharsets.US_ASCII)), "Chunk extensions and trailers");
        check(Arrays.equals(Http.bytes(Http.read(http, true).body, 64), new byte[] {'z'}), "Persistent HTTP framing after chunked body");
        reject("CL/TE smuggling", () -> Http.read(ascii("POST /Upload HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n"), false));
        reject("duplicate length", () -> Http.read(ascii("POST /Upload HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n"), false));
        reject("truncated fixed body", () -> Http.bytes(Http.read(ascii("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nx"), true).body, 64));
        reject("truncated chunk", () -> Http.bytes(Http.read(ascii("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nx"), true).body, 64));
        reject("bad chunk terminator", () -> Http.bytes(Http.read(ascii("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx!!0\r\n\r\n"), true).body, 64));
        reject("huge chunk", () -> Http.bytes(Http.read(ascii("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffff\r\n"), true).body, 64));
        reject("huge body length", () -> Http.read(ascii("HTTP/1.1 200 OK\r\nContent-Length: 99999999999\r\n\r\n"), true));
        for (String format : Arrays.asList("odc", "newc")) {
            File staging = stage(root);
            try (InputStream input = Files.newInputStream(root.resolve(format + ".gz"))) {
                List<File> files = Cpio.receive(input, staging, Collections.singleton("hello.txt"));
                check(files.size() == 1 && Arrays.equals(Files.readAllBytes(files.get(0).toPath()), "hello\n".getBytes(StandardCharsets.UTF_8)), "libarchive " + format + " receive");
            } finally { Cpio.delete(staging); }
        }
        for (String fixture : Arrays.asList("traversal", "absolute", "symlink", "hardlink", "duplicate", "unexpected", "truncated", "crc", "missing")) {
            File staging = stage(root);
            reject(fixture + " archive", () -> { try (InputStream input = Files.newInputStream(root.resolve(fixture + ".gz"))) { Cpio.receive(input, staging, Collections.singleton("hello.txt")); } });
            check(!staging.exists(), fixture + " staging cleanup");
        }
        check(!Files.exists(root.resolve("outside")), "Traversal did not create outside file");
        try (OutputStream archive = Files.newOutputStream(root.resolve("java.cpio.gz"))) { Cpio.write(archive, "hello.txt", 6, ascii("hello\n")); }
        reject("source shrank", () -> Cpio.write(new ByteArrayOutputStream(), "hello.txt", 6, ascii("hello")));
        reject("source grew", () -> Cpio.write(new ByteArrayOutputStream(), "hello.txt", 4, ascii("hello")));
        Map<String, Object> offer = Plist.map("Files", Collections.singletonList(Plist.map("FileName", "hello.txt", "FileBomPath", "./hello.txt", "FileIsDirectory", false)));
        check(Engine.offeredNames(offer).equals(Collections.singleton("hello.txt")), "Regular-file offer accepted");
        reject("folder offer", () -> Engine.offeredNames(Plist.map("Files", Collections.singletonList(Plist.map("FileName", "folder", "FileBomPath", "./folder", "FileIsDirectory", true)))));
        reject("duplicate offer", () -> Engine.offeredNames(Plist.map("Files", Arrays.asList(((List<?>) offer.get("Files")).get(0), ((List<?>) offer.get("Files")).get(0)))));
        reject("offer BOM mismatch", () -> Engine.offeredNames(Plist.map("Files", Collections.singletonList(Plist.map("FileName", "hello.txt", "FileBomPath", "../hello.txt", "FileIsDirectory", false)))));
        byte[] ask = Files.readAllBytes(root.resolve("ask.plist")), archive = Files.readAllBytes(root.resolve("odc.gz"));
        Session unapproved = session(root, request("/Upload", archive), true);
        check(unapproved.accepts == 0 && unapproved.saved == 0 && unapproved.output().startsWith("HTTP/1.1 403"), "Upload cannot precede accepted offer");
        Session declined = session(root, concat(request("/Ask", ask), request("/Upload", archive)), false);
        check(declined.accepts == 1 && declined.saved == 0 && declined.output().startsWith("HTTP/1.1 403"), "Declined offer cannot upload");
        Session accepted = session(root, concat(request("/Ask", ask), request("/Upload", archive)), true);
        check(accepted.accepts == 1 && accepted.saved == 1 && accepted.output().contains("HTTP/1.1 200"), "Accepted offer commits archive");
        check(Arrays.equals(Files.readAllBytes(accepted.file.toPath()), "hello\n".getBytes(StandardCharsets.US_ASCII)), "Committed file matches external archive");
        Session old = session(root, request("/Ask", ask), true);
        Session separate = session(root, request("/Upload", archive), true);
        check(old.accepts == 1 && separate.saved == 0 && separate.output().startsWith("HTTP/1.1 403"), "Acceptance is bound to original connection");
        Session corrupt = session(root, concat(request("/Ask", ask), request("/Upload", Files.readAllBytes(root.resolve("crc.gz")))), true);
        check(corrupt.saved == 0 && !corrupt.output().endsWith("Content-Length: 0\r\n\r\n"), "Corrupt archive cannot report completed upload");
        check(corrupt.directory.listFiles() != null && corrupt.directory.listFiles().length == 0, "Rejected upload removes transaction directory");
        System.out.println("Passed " + checks + " AirDrop lab codec, framing, archive and offer checks");
    }
    private static byte[] request(String path, byte[] body) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(("POST " + path + " HTTP/1.1\r\nHost: fixture\r\nContent-Type: application/x-cpio\r\nContent-Length: " + body.length + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII)); out.write(body); return out.toByteArray();
    }
    private static byte[] concat(byte[] a, byte[] b) throws IOException { ByteArrayOutputStream out = new ByteArrayOutputStream(); out.write(a); out.write(b); return out.toByteArray(); }
    private static Session session(Path root, byte[] request, boolean accept) throws Exception {
        Session ui = new Session(); ui.directory = stage(root); ui.approve = accept;
        Engine engine = new Engine(ui, "Fixture", ui.directory); MemorySocket socket = new MemorySocket(request);
        try {
            java.lang.reflect.Method receive = Engine.class.getDeclaredMethod("receive", SSLSocket.class); receive.setAccessible(true); receive.invoke(engine, socket);
            ui.response = socket.out.toByteArray(); return ui;
        } finally { engine.close(); }
    }
    private static final class Session implements Engine.UI {
        boolean approve; int accepts, saved; File file, directory; byte[] response;
        public void log(String ignored) {}
        public boolean accept(String sender, Set<String> names) { accepts++; return approve; }
        public void received(File directory, List<File> files) { saved += files.size(); file = files.get(0); }
        String output() { return new String(response, StandardCharsets.ISO_8859_1); }
    }
    /** Only TLS transport is mocked; requests run through the real receiver state machine. */
    private static final class MemorySocket extends SSLSocket {
        final InputStream in; final ByteArrayOutputStream out = new ByteArrayOutputStream();
        MemorySocket(byte[] request) { in = new ByteArrayInputStream(request); }
        public InputStream getInputStream() { return in; }
        public OutputStream getOutputStream() { return out; }
        public void setSoTimeout(int timeout) {}
        public void close() {}
        public String[] getSupportedCipherSuites() { return new String[0]; }
        public String[] getEnabledCipherSuites() { return new String[0]; }
        public void setEnabledCipherSuites(String[] s) {}
        public String[] getSupportedProtocols() { return new String[0]; }
        public String[] getEnabledProtocols() { return new String[0]; }
        public void setEnabledProtocols(String[] s) {}
        public SSLSession getSession() { return null; }
        public void addHandshakeCompletedListener(HandshakeCompletedListener l) {}
        public void removeHandshakeCompletedListener(HandshakeCompletedListener l) {}
        public void startHandshake() {}
        public void setUseClientMode(boolean b) {}
        public boolean getUseClientMode() { return false; }
        public void setNeedClientAuth(boolean b) {}
        public boolean getNeedClientAuth() { return false; }
        public void setWantClientAuth(boolean b) {}
        public boolean getWantClientAuth() { return false; }
        public void setEnableSessionCreation(boolean b) {}
        public boolean getEnableSessionCreation() { return false; }
    }
}
