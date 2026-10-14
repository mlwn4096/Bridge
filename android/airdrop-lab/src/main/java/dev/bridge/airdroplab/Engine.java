package dev.bridge.airdroplab;

import android.net.Network;
import java.io.*;
import java.net.*;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.concurrent.*;
import javax.net.ssl.*;

/** Direct socket experiment: requires a routable link already exposed by the OS. */
final class Engine implements AutoCloseable {
    interface UI {
        void log(String text);
        boolean accept(String claimedSender, Set<String> names) throws InterruptedException;
        void received(File directory, List<File> files);
    }
    static final class Peer {
        final String host, name, fingerprint; final int port; final Network network;
        Peer(String h, int p, String n, String f, Network net) { host = h; port = p; name = n; fingerprint = f; network = net; }
    }
    final UI ui; final String model, id = UUID.randomUUID().toString().replace("-", "").substring(0, 12);
    final File root; final Set<Socket> sockets = ConcurrentHashMap.newKeySet();
    volatile boolean closed; SSLServerSocket listener;
    final ExecutorService workers = Executors.newFixedThreadPool(2);
    Engine(UI ui, String model, File root) { this.ui = ui; this.model = model; this.root = root; }
    private SSLSocket connect(String host, int port, Network network, String pin) throws Exception {
        if (closed || host.isEmpty() || host.length() > 253 || host.chars().anyMatch(c -> c <= 32 || c == 127) || host.indexOf('/') >= 0 || port < 1 || port > 65535) throw new IOException("Invalid endpoint or stopped experiment");
        Socket plain = network == null ? new Socket() : network.getSocketFactory().createSocket(); sockets.add(plain);
        try {
            plain.connect(new InetSocketAddress(host, port), 10000);
            SSLSocket tls = (SSLSocket) Tls.context(pin, false).getSocketFactory().createSocket(plain, host, port, true);
            sockets.add(tls); tls.setSoTimeout(30000); tls.setEnabledProtocols(new String[] {"TLSv1.2", "TLSv1.3"}); tls.startHandshake(); return tls;
        } catch (Exception e) { sockets.remove(plain); plain.close(); throw e; }
    }
    Peer probe(String host, int port, Network network) throws Exception {
        ui.log("TCP/TLS: connecting to selected endpoint…");
        try (SSLSocket socket = connect(host, port, network, null)) {
            String pin = Tls.fingerprint((X509Certificate) socket.getSession().getPeerCertificates()[0]);
            ui.log("TLS ready. This lab does not validate Apple account identity.");
            Http.request(socket.getOutputStream(), authority(host, port), "/Discover", Plist.encode(Plist.map()));
            Http.Message reply = Http.read(new BufferedInputStream(socket.getInputStream()), true);
            if (reply.status() != 200) throw new IOException("/Discover returned HTTP " + reply.status());
            Map<String, Object> plist = Plist.dictionary(Http.bytes(reply.body, Plist.LIMIT));
            Object name = plist.get("ReceiverComputerName"); if (!(name instanceof String) || ((String) name).length() > 256) throw new IOException("/Discover did not return a receiver name");
            ui.log("/Discover succeeded. Claimed receiver: " + name + "\nCertificate SHA-256: " + pin);
            return new Peer(host, port, (String) name, pin, network);
        } finally { prune(); }
    }
    void send(Peer peer, File file, String name) throws Exception {
        name = Cpio.fileName(name); if (!file.isFile() || file.length() > Http.FILE_LIMIT) throw new IOException("Select a regular file up to 32 MiB");
        try (SSLSocket socket = connect(peer.host, peer.port, peer.network, peer.fingerprint); FileInputStream source = new FileInputStream(file)) {
            BufferedInputStream input = new BufferedInputStream(socket.getInputStream()); OutputStream out = socket.getOutputStream();
            Http.request(out, authority(peer.host, peer.port), "/Discover", Plist.encode(Plist.map()));
            Http.Message discovery = Http.read(input, true);
            if (discovery.status() != 200) throw new IOException("/Discover on send connection returned HTTP " + discovery.status());
            Plist.dictionary(Http.bytes(discovery.body, Plist.LIMIT));
            Map<String, Object> ask = Plist.map("SenderComputerName", "Bridge AirDrop Lab", "SenderModelName", model,
                "SenderID", id, "BundleID", "dev.bridge.airdroplab", "ConvertMediaFormats", false,
                "Files", Collections.singletonList(Plist.map("FileName", name, "FileType", "public.data", "FileBomPath", "./" + name, "FileIsDirectory", false, "ConvertMediaFormats", 0)));
            ui.log("/Ask: waiting for receiver acceptance…");
            Http.request(out, authority(peer.host, peer.port), "/Ask", Plist.encode(ask));
            Http.Message accepted = Http.read(input, true); Http.bytes(accepted.body, Plist.LIMIT);
            if (accepted.status() != 200) throw new IOException("Receiver did not accept: HTTP " + accepted.status());
            ui.log("/Ask accepted. /Upload: streaming selected file…");
            Http.header(out, "POST /Upload HTTP/1.1\r\nHost: " + authority(peer.host, peer.port) + "\r\nUser-Agent: AirDrop/1.0\r\nContent-Type: application/x-cpio\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
            Http.ChunkOutput chunks = new Http.ChunkOutput(out); Cpio.write(chunks, name, file.length(), source); chunks.finish();
            Http.Message done = Http.read(input, true); Http.bytes(done.body, Plist.LIMIT);
            if (done.status() != 200) throw new IOException("/Upload returned HTTP " + done.status());
            ui.log("Receiver returned HTTP 200 for /Upload. Confirm the saved file on the receiving device.");
        } finally { prune(); }
    }
    synchronized int listen(InetAddress address) throws Exception {
        if (closed || listener != null) throw new IOException("Receiver already running or stopped");
        SSLServerSocket server = (SSLServerSocket) Tls.context(null, true).getServerSocketFactory().createServerSocket();
        server.setEnabledProtocols(new String[] {"TLSv1.2", "TLSv1.3"}); server.bind(new InetSocketAddress(address, 0), 2); listener = server;
        Semaphore slot = new Semaphore(1);
        workers.execute(() -> {
            while (!closed) {
                try {
                    SSLSocket socket = (SSLSocket) server.accept(); sockets.add(socket);
                    if (!slot.tryAcquire()) { sockets.remove(socket); socket.close(); continue; }
                    workers.execute(() -> { try { receive(socket); } finally { sockets.remove(socket); slot.release(); } });
                } catch (Exception e) { if (!closed) ui.log("Receiver socket failed: " + e.getMessage()); break; }
            }
        });
        return server.getLocalPort();
    }
    private void receive(SSLSocket socket) {
        File staging = null;
        try (SSLSocket incoming = socket) {
            socket.setSoTimeout(30000); socket.startHandshake(); ui.log("Incoming TLS connection ready.");
            BufferedInputStream input = new BufferedInputStream(socket.getInputStream()); OutputStream out = socket.getOutputStream();
            Set<String> approved = null;
            for (int requests = 0; requests < 6 && !closed; requests++) {
                Http.Message request = Http.read(input, false); String[] line = request.start.split(" ");
                if (line.length != 3 || !line[0].equals("POST") || !line[2].equals("HTTP/1.1")) throw new IOException("Unsupported request");
                ui.log("Incoming " + line[1]);
                if (line[1].equals("/Discover")) {
                    Plist.dictionary(Http.bytes(request.body, Plist.LIMIT));
                    Http.response(out, 200, Plist.encode(Plist.map("ReceiverComputerName", "Bridge AirDrop Lab", "ReceiverModelName", model,
                        "ReceiverMediaCapabilities", "{\"Version\":1}".getBytes(java.nio.charset.StandardCharsets.UTF_8))));
                } else if (line[1].equals("/Ask")) {
                    if (approved != null) throw new IOException("Offer already accepted on this connection");
                    Map<String, Object> ask = Plist.dictionary(Http.bytes(request.body, Plist.LIMIT));
                    Set<String> names = offeredNames(ask);
                    String sender = ask.get("SenderComputerName") instanceof String ? (String) ask.get("SenderComputerName") : "Unknown device";
                    if (sender.length() > 256) throw new IOException("Sender name too long");
                    if (!ui.accept(sender, names) || closed) { Http.response(out, 403, new byte[0]); return; }
                    approved = names; Http.response(out, 200, Plist.encode(Plist.map("ReceiverComputerName", "Bridge AirDrop Lab", "ReceiverModelName", model)));
                } else if (line[1].equals("/Upload")) {
                    if (approved == null) { Http.response(out, 403, new byte[0]); return; }
                    if (!"application/x-cpio".equalsIgnoreCase(request.headers.get("content-type"))) { Http.response(out, 406, new byte[0]); return; }
                    if ("100-continue".equalsIgnoreCase(request.headers.get("expect"))) Http.header(out, "HTTP/1.1 100 Continue\r\n\r\n");
                    staging = new File(root, ".partial-" + UUID.randomUUID());
                    if (!root.isDirectory() && !root.mkdirs() || !staging.mkdir()) throw new IOException("Cannot create private receive directory");
                    List<File> files = Cpio.receive(request.body, staging, approved);
                    if (closed) throw new IOException("Receive cancelled");
                    File completed = new File(root, "received-" + UUID.randomUUID());
                    if (!staging.renameTo(completed)) throw new IOException("Cannot commit received files");
                    staging = null; List<File> saved = new ArrayList<>(); for (File file : files) saved.add(new File(completed, file.getName()));
                    ui.received(completed, saved); Http.response(out, 200, new byte[0]); return;
                } else { Http.response(out, 400, new byte[0]); return; }
            }
        } catch (Exception e) { if (!closed) ui.log("Incoming transfer failed: " + e.getClass().getSimpleName() + ": " + e.getMessage()); }
        finally { if (staging != null) Cpio.delete(staging); }
    }
    static Set<String> offeredNames(Map<String, Object> ask) throws IOException {
        Object files = ask.get("Files"); if (!(files instanceof List) || ((List<?>) files).isEmpty() || ((List<?>) files).size() > 8) throw new IOException("Lab accepts 1–8 regular files");
        Set<String> names = new LinkedHashSet<>();
        for (Object entry : (List<?>) files) {
            if (!(entry instanceof Map)) throw new IOException("Invalid file offer"); Map<?, ?> file = (Map<?, ?>) entry;
            if (!(file.get("FileName") instanceof String) || !Boolean.FALSE.equals(file.get("FileIsDirectory"))) throw new IOException("Only regular-file offers are supported");
            String name = Cpio.fileName((String) file.get("FileName"));
            if (!Objects.equals(file.get("FileBomPath"), "./" + name) || !names.add(name)) throw new IOException("Invalid/duplicate offered path");
        }
        return names;
    }
    private static String authority(String host, int port) { return (host.indexOf(':') >= 0 ? "[" + host + "]" : host) + ":" + port; }
    private void prune() { sockets.removeIf(Socket::isClosed); }
    @Override public synchronized void close() {
        closed = true; try { if (listener != null) listener.close(); } catch (IOException ignored) {}
        for (Socket socket : sockets) try { socket.close(); } catch (IOException ignored) {} sockets.clear(); workers.shutdownNow();
    }
}
