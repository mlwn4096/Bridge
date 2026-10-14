package dev.bridge.airdroplab;

import java.io.*;
import java.nio.*;
import java.nio.charset.*;
import java.util.*;

/** Bounded binary plist subset for the observed AirDrop dictionary exchange. */
public final class Plist {
    public static final int LIMIT = 1_048_576;
    private static final int OBJECT_LIMIT = 4096, DEPTH_LIMIT = 32;
    private Plist() {}
    public static byte[] encode(Object root) throws IOException {
        Encoder e = new Encoder(); int top = e.add(root, 0);
        int refs = width(e.nodes.size());
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write("bplist00".getBytes(StandardCharsets.US_ASCII));
        long[] offsets = new long[e.nodes.size()];
        for (int i = 0; i < offsets.length; i++) {
            offsets[i] = out.size(); e.write(out, e.nodes.get(i), refs);
            if (out.size() > LIMIT - 32 - offsets.length * 8) throw new IOException("Plist too large");
        }
        int table = out.size(), ow = width(table);
        for (long offset : offsets) number(out, offset, ow);
        out.write(new byte[6]); out.write(ow); out.write(refs);
        number(out, offsets.length, 8); number(out, top, 8); number(out, table, 8);
        return out.toByteArray();
    }
    public static Object decode(byte[] bytes) throws IOException { return new Decoder(bytes).root(); }
    public static Map<String, Object> dictionary(byte[] bytes) throws IOException {
        Object root = decode(bytes);
        if (!(root instanceof Map)) throw new IOException("Expected plist dictionary");
        @SuppressWarnings("unchecked") Map<String, Object> value = (Map<String, Object>) root;
        return value;
    }
    public static Map<String, Object> map(Object... pairs) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (int i = 0; i < pairs.length; i += 2) out.put((String) pairs[i], pairs[i + 1]);
        return out;
    }
    private static int width(long n) { return n < 256 ? 1 : n < 65536 ? 2 : n <= 0xffffffffL ? 4 : 8; }
    private static void number(OutputStream out, long n, int width) throws IOException {
        for (int i = width - 1; i >= 0; i--) out.write((int) (n >>> (i * 8)) & 255);
    }
    private static void length(OutputStream out, int marker, int size) throws IOException {
        out.write(marker | Math.min(size, 15));
        if (size >= 15) { int w = width(size); out.write(0x10 | Integer.numberOfTrailingZeros(w)); number(out, size, w); }
    }
    private static class Node {
        Object value; int[] refs;
        Node(Object value) { this.value = value; }
    }
    private static class Encoder {
        final List<Node> nodes = new ArrayList<>();
        int add(Object value, int depth) throws IOException {
            if (depth > DEPTH_LIMIT || nodes.size() >= OBJECT_LIMIT) throw new IOException("Plist complexity limit");
            Node n = new Node(value); int id = nodes.size(); nodes.add(n);
            if (value instanceof Map) {
                Map<?, ?> map = (Map<?, ?>) value;
                if (map.size() > OBJECT_LIMIT / 2) throw new IOException("Dictionary too large");
                n.refs = new int[map.size() * 2]; int index = 0;
                for (Object key : map.keySet()) { if (!(key instanceof String)) throw new IOException("Non-string plist key"); n.refs[index++] = add(key, depth + 1); }
                for (Object child : map.values()) n.refs[index++] = add(child, depth + 1);
            } else if (value instanceof List) {
                List<?> list = (List<?>) value;
                if (list.size() > OBJECT_LIMIT) throw new IOException("Array too large");
                n.refs = new int[list.size()];
                for (int i = 0; i < list.size(); i++) n.refs[i] = add(list.get(i), depth + 1);
            } else if (value instanceof String) {
                if (((String) value).length() > 65536) throw new IOException("String too long");
            } else if (value instanceof byte[]) {
                if (((byte[]) value).length > LIMIT / 2) throw new IOException("Data too large");
            } else if (!(value instanceof Boolean) && !(value instanceof Long) && !(value instanceof Integer)) {
                throw new IOException("Unsupported plist value");
            }
            return id;
        }
        void write(OutputStream out, Node n, int refs) throws IOException {
            Object v = n.value;
            if (v instanceof Map || v instanceof List) {
                length(out, v instanceof Map ? 0xd0 : 0xa0, v instanceof Map ? n.refs.length / 2 : n.refs.length);
                for (int ref : n.refs) number(out, ref, refs);
            } else if (v instanceof Boolean) out.write((Boolean) v ? 9 : 8);
            else if (v instanceof Number) { long x = ((Number) v).longValue(); int w = x < 0 ? 8 : width(x); out.write(0x10 | Integer.numberOfTrailingZeros(w)); number(out, x, w); }
            else if (v instanceof byte[]) { byte[] b = (byte[]) v; length(out, 0x40, b.length); out.write(b); }
            else {
                String s = (String) v; boolean ascii = s.chars().allMatch(c -> c < 128);
                byte[] b = s.getBytes(ascii ? StandardCharsets.US_ASCII : StandardCharsets.UTF_16BE);
                length(out, ascii ? 0x50 : 0x60, s.length()); out.write(b);
            }
        }
    }
    private static class Decoder {
        final byte[] data; final int count, refs, table, top; final int[] offsets;
        final Object[] cache; final boolean[] active;
        Decoder(byte[] b) throws IOException {
            data = b;
            if (b.length < 40 || b.length > LIMIT || !Arrays.equals(Arrays.copyOf(b, 8), "bplist00".getBytes(StandardCharsets.US_ASCII))) throw new IOException("Invalid binary plist");
            int trailer = b.length - 32, ow = b[trailer + 6] & 255; refs = b[trailer + 7] & 255;
            if (!validWidth(ow) || !validWidth(refs)) throw new IOException("Invalid plist integer width");
            count = limited(read(trailer + 8, 8), OBJECT_LIMIT);
            top = limited(read(trailer + 16, 8), Math.max(0, count - 1));
            table = limited(read(trailer + 24, 8), trailer);
            if (count == 0 || table < 8 || (long) table + (long) count * ow != trailer) throw new IOException("Invalid plist offset table");
            offsets = new int[count]; cache = new Object[count]; active = new boolean[count];
            for (int i = 0; i < count; i++) { offsets[i] = limited(read(table + i * ow, ow), table - 1); if (offsets[i] < 8) throw new IOException("Invalid object offset"); }
        }
        boolean validWidth(int w) { return w == 1 || w == 2 || w == 4 || w == 8; }
        int limited(long n, int max) throws IOException { if (n < 0 || n > max) throw new IOException("Plist bounds exceeded"); return (int) n; }
        long read(int at, int width) throws IOException {
            if (at < 0 || width < 1 || width > 8 || at > data.length - width) throw new IOException("Truncated plist");
            long n = 0; for (int i = 0; i < width; i++) n = n << 8 | (data[at + i] & 255L); return n;
        }
        Object root() throws IOException { return object(top, 0); }
        Object object(int id, int depth) throws IOException {
            if (depth > DEPTH_LIMIT || id < 0 || id >= count || active[id]) throw new IOException("Invalid/cyclic plist reference");
            if (cache[id] != null) return cache[id];
            active[id] = true;
            int at = offsets[id], marker = data[at++] & 255, type = marker >>> 4, size = marker & 15;
            if (type >= 4 && size == 15) {
                if (at >= table) throw new IOException("Truncated plist length");
                int m = data[at++] & 255, w = 1 << (m & 15);
                if ((m >>> 4) != 1 || !validWidth(w) || at > table - w) throw new IOException("Invalid plist length");
                size = limited(read(at, w), LIMIT); at += w;
            }
            Object result;
            if (marker == 8 || marker == 9) result = marker == 9;
            else if (type == 1) {
                int w = 1 << size; if (!validWidth(w) || at > table - w) throw new IOException("Invalid plist integer"); result = read(at, w);
            } else if (type == 4 || type == 5 || type == 6) {
                int bytes = type == 6 ? Math.multiplyExact(size, 2) : size;
                if (bytes > (type == 4 ? LIMIT / 2 : 131072) || at > table - bytes) throw new IOException("Invalid plist data bounds");
                if (type == 4) result = Arrays.copyOfRange(data, at, at + bytes);
                else {
                    Charset charset = type == 5 ? StandardCharsets.US_ASCII : StandardCharsets.UTF_16BE;
                    result = charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data, at, bytes)).toString();
                }
            } else if (type == 10 || type == 13) {
                if (size > OBJECT_LIMIT || (long) at + (long) size * refs * (type == 13 ? 2 : 1) > table) throw new IOException("Invalid plist container");
                if (type == 10) {
                    List<Object> list = new ArrayList<>();
                    for (int i = 0; i < size; i++) list.add(object(limited(read(at + i * refs, refs), count - 1), depth + 1)); result = list;
                } else {
                    Map<String, Object> map = new LinkedHashMap<>();
                    for (int i = 0; i < size; i++) {
                        Object key = object(limited(read(at + i * refs, refs), count - 1), depth + 1);
                        if (!(key instanceof String) || map.containsKey(key)) throw new IOException("Invalid/duplicate plist key");
                        map.put((String) key, object(limited(read(at + (i + size) * refs, refs), count - 1), depth + 1));
                    } result = map;
                }
            } else throw new IOException("Unsupported plist marker: " + marker);
            active[id] = false; cache[id] = result; return result;
        }
    }
}
