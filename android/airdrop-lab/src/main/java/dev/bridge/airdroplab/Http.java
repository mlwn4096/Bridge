package dev.bridge.airdroplab;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** HTTP/1.1 framing shared by the lab client and receiver. */
public final class Http {
    public static final long FILE_LIMIT = 32L * 1024 * 1024;
    private Http() {}
    public static final class Message {
        public final String start;
        public final Map<String, String> headers;
        public final InputStream body;
        Message(String start, Map<String, String> headers, InputStream body) { this.start = start; this.headers = headers; this.body = body; }
        public int status() throws IOException {
            String[] parts = start.split(" ", 3);
            if (parts.length < 2 || !parts[0].equals("HTTP/1.1")) throw new IOException("Invalid HTTP response");
            try { return Integer.parseInt(parts[1]); } catch (NumberFormatException e) { throw new IOException("Invalid HTTP status", e); }
        }
    }
    public static Message read(InputStream in, boolean response) throws IOException {
        String start = line(in, 2048); Map<String, String> headers = new LinkedHashMap<>(); int size = start.length();
        for (;;) {
            String line = line(in, 2048); size += line.length() + 2;
            if (size > 16384 || headers.size() > 64) throw new IOException("HTTP headers too large");
            if (line.isEmpty()) break;
            int colon = line.indexOf(':'); if (colon <= 0) throw new IOException("Invalid HTTP header");
            String key = line.substring(0, colon).toLowerCase(Locale.ROOT), value = line.substring(colon + 1).trim();
            if (!key.matches("[a-z0-9-]+") || headers.put(key, value) != null) throw new IOException("Duplicate/invalid HTTP header");
        }
        String cl = headers.get("content-length"), te = headers.get("transfer-encoding");
        if (cl != null && te != null) throw new IOException("Ambiguous HTTP framing");
        InputStream body;
        if (te != null) {
            if (!te.equalsIgnoreCase("chunked")) throw new IOException("Unsupported HTTP transfer encoding");
            body = new ChunkInput(in);
        } else if (cl != null) {
            long length;
            try { if (!cl.matches("[0-9]+")) throw new NumberFormatException(); length = Long.parseLong(cl); }
            catch (NumberFormatException e) { throw new IOException("Invalid content length", e); }
            if (length > FILE_LIMIT + 1048576) throw new IOException("HTTP body too large");
            body = new ExactInput(in, length);
        } else if (response && (start.startsWith("HTTP/1.1 100 ") || start.startsWith("HTTP/1.1 204 "))) body = new ByteArrayInputStream(new byte[0]);
        else throw new IOException("Missing HTTP body framing");
        return new Message(start, headers, body);
    }
    public static byte[] bytes(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] b = new byte[8192]; int n;
        while ((n = in.read(b)) != -1) { if (out.size() > limit - n) throw new IOException("Response body exceeds limit"); out.write(b, 0, n); }
        return out.toByteArray();
    }
    public static void request(OutputStream out, String host, String path, byte[] body) throws IOException {
        header(out, "POST " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUser-Agent: AirDrop/1.0\r\nContent-Type: application/octet-stream\r\nContent-Length: " + body.length + "\r\nConnection: keep-alive\r\n\r\n");
        out.write(body); out.flush();
    }
    public static void response(OutputStream out, int status, byte[] bytes) throws IOException {
        String reason = status == 200 ? "OK" : status == 403 ? "Forbidden" : status == 406 ? "Not Acceptable" : "Bad Request";
        header(out, "HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: application/octet-stream\r\nContent-Length: " + bytes.length + "\r\n\r\n"); out.write(bytes); out.flush();
    }
    public static void header(OutputStream out, String header) throws IOException { out.write(header.getBytes(StandardCharsets.US_ASCII)); out.flush(); }
    private static String line(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        for (;;) {
            int c = in.read(); if (c < 0) throw new EOFException("Truncated HTTP headers/chunk framing");
            if (c == '\r') { if (in.read() != '\n') throw new IOException("Invalid HTTP line ending"); return bytes.toString("US-ASCII"); }
            if (c < 32 || c > 126 || bytes.size() >= limit) throw new IOException("Invalid/oversized HTTP line"); bytes.write(c);
        }
    }
    private static final class ExactInput extends InputStream {
        final InputStream in; long remaining;
        ExactInput(InputStream in, long length) { this.in = in; remaining = length; }
        @Override public int read() throws IOException { byte[] b = new byte[1]; return read(b) < 0 ? -1 : b[0] & 255; }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            if (len == 0) return 0; if (remaining == 0) return -1;
            int n = in.read(b, off, (int) Math.min(len, remaining)); if (n < 0) throw new EOFException("Truncated HTTP body"); remaining -= n; return n;
        }
    }
    private static final class ChunkInput extends InputStream {
        final InputStream in; long remaining, total; boolean done, needCRLF;
        ChunkInput(InputStream in) { this.in = in; }
        void next() throws IOException {
            if (needCRLF) { if (in.read() != '\r' || in.read() != '\n') throw new IOException("Invalid chunk terminator"); needCRLF = false; }
            String value = line(in, 256).split(";", 2)[0];
            try { if (!value.matches("[0-9a-fA-F]{1,8}")) throw new NumberFormatException(); remaining = Long.parseLong(value, 16); }
            catch (NumberFormatException e) { throw new IOException("Invalid HTTP chunk length", e); }
            if (remaining > FILE_LIMIT + 1048576 - total) throw new IOException("Chunked body exceeds limit");
            if (remaining == 0) {
                int length = 0; String trailer;
                while (!(trailer = line(in, 2048)).isEmpty()) { length += trailer.length() + 2; if (length > 8192) throw new IOException("Oversized chunk trailers"); }
                done = true;
            }
        }
        @Override public int read() throws IOException { byte[] b = new byte[1]; return read(b) < 0 ? -1 : b[0] & 255; }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            if (len == 0) return 0; if (done) return -1; if (remaining == 0) next(); if (done) return -1;
            int n = in.read(b, off, (int) Math.min(len, remaining)); if (n < 0) throw new EOFException("Truncated chunk");
            total += n; remaining -= n; if (remaining == 0) needCRLF = true; return n;
        }
    }
    public static final class ChunkOutput extends OutputStream {
        final OutputStream out; boolean finished;
        public ChunkOutput(OutputStream out) { this.out = out; }
        @Override public void write(int value) throws IOException { write(new byte[] {(byte) value}); }
        @Override public void write(byte[] b, int off, int len) throws IOException {
            if (finished) throw new IOException("Chunk stream finished"); if (len == 0) return;
            header(out, Integer.toHexString(len) + "\r\n"); out.write(b, off, len); header(out, "\r\n");
        }
        public void finish() throws IOException { if (!finished) { header(out, "0\r\n\r\n"); finished = true; } }
        @Override public void flush() throws IOException { out.flush(); }
    }
}
