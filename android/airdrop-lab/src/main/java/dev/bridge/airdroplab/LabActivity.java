package dev.bridge.airdroplab;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.*;
import android.net.nsd.*;
import android.net.wifi.WifiManager;
import android.os.*;
import android.provider.OpenableColumns;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/** Foreground-only experimental app; installs alongside the production companion. */
public final class LabActivity extends Activity implements Engine.UI {
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final AtomicBoolean busy = new AtomicBoolean();
    private final List<File> saved = new ArrayList<>();
    private final ArrayDeque<NsdServiceInfo> resolveQueue = new ArrayDeque<>();
    private volatile boolean alive;
    private boolean resolving;
    private int networkEpoch;
    private final StringBuilder report = new StringBuilder();
    private TextView logView, chosenFile; private EditText host, port; private LinearLayout receivers;
    private NsdManager nsd; private NsdManager.DiscoveryListener discovery; private NsdManager.RegistrationListener registration;
    private WifiManager.MulticastLock multicast; private volatile Engine engine; private Engine.Peer peer;
    private Uri selection; private String selectionName; private File exportFile; private AlertDialog incomingDialog;
    private File receiveRoot;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); alive = true;
        getWindow().setDecorFitsSystemWindows(false);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        receiveRoot = new File(getFilesDir(), "AirDropLabReceived"); receiveRoot.mkdirs();
        File[] batches = receiveRoot.listFiles(); if (batches != null) for (File batch : batches) {
            if (batch.getName().startsWith(".partial-")) Cpio.delete(batch);
            else if (batch.isDirectory()) { File[] files = batch.listFiles(); if (files != null) for (File f : files) if (f.isFile()) saved.add(f); }
        }
        nsd = (NsdManager) getSystemService(NSD_SERVICE);
        ScrollView scroll = new ScrollView(this); LinearLayout column = new LinearLayout(this); column.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20); column.setPadding(pad, pad, pad, pad); scroll.addView(column); setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom); return insets;
        });
        scroll.post(() -> {
            scroll.requestApplyInsets(); WindowInsetsController controller = scroll.getWindowInsetsController();
            if (controller != null) controller.setSystemBarsAppearance(WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
        });
        text(column, "Bridge AirDrop Lab", 24);
        text(column, "Experimental direct transfer · Android 12+\nKeep this screen open. Native AirDrop compatibility is unverified. No Mac relay or cloud upload is used.", 14);
        text(column, "On the Apple device: turn on Wi-Fi and Bluetooth, open AirDrop, and select Everyone. For this first experiment, also connect both devices to the same Wi-Fi.", 14);
        text(column, "1. Choose a file, then discover", 18);
        chosenFile = text(column, "No file selected · up to 32 MiB", 14);
        button(column, "Choose file", () -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE), 1));
        button(column, "Inspect phone interfaces", this::inspect);
        button(column, "Scan for AirDrop services", this::scan);
        receivers = new LinearLayout(this); receivers.setOrientation(LinearLayout.VERTICAL); column.addView(receivers);
        host = new EditText(this); host.setSingleLine(true); host.setHint("Receiver IP or scoped IPv6 (manual fallback)"); column.addView(host);
        port = new EditText(this); port.setSingleLine(true); port.setHint("Receiver port"); port.setInputType(android.text.InputType.TYPE_CLASS_NUMBER); column.addView(port);
        button(column, "Probe selected endpoint (/Discover)", this::probe);
        text(column, "2. Send one file (up to 32 MiB)", 18);
        button(column, "Send to probed receiver", this::send);
        text(column, "3. Receive files", 18);
        text(column, "The lab advertises on an existing interface. This does not create an AWDL wireless link. Each offer needs your acceptance. Files remain private until you export them.", 14);
        button(column, "Start experimental receiver", this::startReceiver);
        button(column, "Save a received file…", this::export);
        button(column, "Stop networking", this::stopNetworking);
        button(column, "Copy diagnostic report", () -> {
            ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Bridge AirDrop Lab", report.toString()));
            Toast.makeText(this, "Diagnostic report copied", Toast.LENGTH_SHORT).show();
        });
        logView = text(column, "", 12); logView.setTextIsSelectable(true);
        inspect();
    }
    @Override public void onStart() { super.onStart(); alive = true; }
    @Override public void onStop() { alive = false; stopNetworking(); super.onStop(); }
    @Override public void onDestroy() { io.shutdownNow(); super.onDestroy(); }
    private int dp(int n) { return (int) (getResources().getDisplayMetrics().density * n); }
    private TextView text(LinearLayout parent, String value, int size) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setPadding(0, dp(8), 0, dp(8)); parent.addView(view); return view;
    }
    private void button(LinearLayout parent, String title, Runnable action) {
        Button button = new Button(this); button.setText(title); button.setAllCaps(false); parent.addView(button, new LinearLayout.LayoutParams(-1, -2)); button.setOnClickListener(v -> action.run());
    }
    @Override public void log(String message) {
        runOnUiThread(() -> {
            if (isDestroyed()) return;
            report.append(message).append('\n'); if (report.length() > 24000) report.delete(0, report.length() - 20000);
            if (logView != null) logView.setText(report.toString());
        });
    }
    private boolean permitted() {
        if (Build.VERSION.SDK_INT >= 37 && checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.ACCESS_LOCAL_NETWORK}, 4);
            log("Local network permission requested. After allowing it, retry the action."); return false;
        }
        return true;
    }
    private synchronized Engine engine() throws IOException {
        if (!alive) throw new IOException("Experiment stopped; return to the lab screen");
        if (engine == null || engine.closed) engine = new Engine(this, Build.MODEL, receiveRoot);
        return engine;
    }
    private void task(String stage, Work work) {
        if (!alive || !busy.compareAndSet(false, true)) { log("Finish the current operation first."); return; }
        io.execute(() -> { try { work.run(); } catch (Exception e) { log(stage + " failed: " + e.getClass().getSimpleName() + ": " + e.getMessage()); } finally { busy.set(false); } });
    }
    interface Work { void run() throws Exception; }
    private Network wifi() {
        ConnectivityManager manager = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        for (Network network : manager.getAllNetworks()) {
            NetworkCapabilities c = manager.getNetworkCapabilities(network); if (c != null && c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return network;
        }
        return null;
    }
    private void inspect() {
        log("Device: " + Build.MANUFACTURER + " " + Build.MODEL + "; Android " + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ")");
        log("Wi-Fi Direct feature: " + getPackageManager().hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
            + "; Wi-Fi Aware feature: " + getPackageManager().hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
            + ". These features alone do not establish AirDrop compatibility.");
        task("Interface inspection", () -> {
            boolean awdl = false; Enumeration<NetworkInterface> all = NetworkInterface.getNetworkInterfaces();
            while (all != null && all.hasMoreElements()) {
                NetworkInterface ni = all.nextElement(); if (!ni.isUp() || ni.isLoopback()) continue;
                if (ni.getName().startsWith("awdl")) awdl = true;
                List<String> addresses = new ArrayList<>(); Enumeration<InetAddress> ips = ni.getInetAddresses();
                while (ips.hasMoreElements()) addresses.add(ips.nextElement().getHostAddress());
                log("Interface " + ni.getName() + ": " + String.join(", ", addresses));
            }
            log(awdl ? "An AWDL-named interface exists. Routing still needs testing." : "No AWDL-named interface is exposed. Trying existing-network discovery is a separate hypothesis.");
        });
    }
    private void multicast() {
        if (multicast == null) {
            WifiManager manager = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
            multicast = manager.createMulticastLock("BridgeAirDropLab"); multicast.setReferenceCounted(false);
        }
        if (!multicast.isHeld()) multicast.acquire();
    }
    private void scan() {
        if (!permitted()) return;
        if (discovery != null) { log("Discovery already running. Open the Apple device's AirDrop screen."); return; }
        receivers.removeAllViews(); resolveQueue.clear();
        AtomicInteger found = new AtomicInteger();
        NsdManager.DiscoveryListener candidate = new NsdManager.DiscoveryListener() {
            public void onDiscoveryStarted(String type) { log("Bonjour scan started on OS-visible networks (_airdrop._tcp). Zero results do not establish device incompatibility."); }
            public void onServiceFound(NsdServiceInfo service) { runOnUiThread(() -> {
                if (!alive || discovery != this || service.getServiceName().equals(engine == null ? "" : engine.id)) return;
                found.incrementAndGet();
                if (resolveQueue.size() < 32) { resolveQueue.add(service); resolveNext(); }
            }); }
            public void onServiceLost(NsdServiceInfo service) { log("Service left: " + service.getServiceName()); }
            public void onDiscoveryStopped(String type) { log("Bonjour scan stopped."); }
            public void onStartDiscoveryFailed(String type, int code) { runOnUiThread(() -> { if (discovery == this) discovery = null; }); log("Bonjour start failed: " + code); }
            public void onStopDiscoveryFailed(String type, int code) { log("Bonjour stop failed: " + code); }
        };
        try {
            multicast(); discovery = candidate; nsd.discoverServices("_airdrop._tcp.", NsdManager.PROTOCOL_DNS_SD, candidate);
            new Handler(Looper.getMainLooper()).postDelayed(() -> {
                if (alive && discovery == candidate) log(found.get() == 0
                    ? "No AirDrop services found after 20 seconds on exposed networks. Discovery continues. Record this as a link/discovery result."
                    : "AirDrop service announcements observed: " + found.get() + ". Select a resolved endpoint to probe it.");
            }, 20000L);
        }
        catch (Exception e) { discovery = null; log("Discovery failed: " + e.getMessage()); }
    }
    @SuppressWarnings("deprecation") private void resolveNext() {
        if (!alive || discovery == null || resolving || resolveQueue.isEmpty()) return;
        resolving = true; NsdServiceInfo service = resolveQueue.remove();
        final int epoch = networkEpoch;
        try { nsd.resolveService(service, new NsdManager.ResolveListener() {
            public void onResolveFailed(NsdServiceInfo info, int code) { runOnUiThread(() -> { if (epoch != networkEpoch) return; resolving = false; log("Service resolution failed: " + code); resolveNext(); }); }
            public void onServiceResolved(NsdServiceInfo info) { runOnUiThread(() -> {
                if (epoch != networkEpoch) return; resolving = false;
                if (alive && discovery != null && info.getHost() != null) {
                    String address = info.getHost().getHostAddress(); int p = info.getPort();
                    if (receivers.getChildCount() < 32) button(receivers, info.getServiceName() + " · " + address + ":" + p, () -> {
                        host.setText(address); port.setText(Integer.toString(p)); peer = null;
                        log("Selected discovered endpoint. Probe before sending.");
                    });
                    log("Resolved service on an existing network: " + address + ":" + p);
                }
                resolveNext();
            }); }
        }); } catch (Exception e) { resolving = false; log("Resolve failed: " + e.getMessage()); resolveNext(); }
    }
    private void probe() {
        if (!permitted()) return;
        final String h = host.getText().toString().trim(); final int p;
        try { p = Integer.parseInt(port.getText().toString()); } catch (Exception e) { log("Select a discovered endpoint or enter its IP and port."); return; }
        peer = null;
        task("/Discover", () -> {
            Engine.Peer found = engine().probe(h, p, wifi());
            runOnUiThread(() -> { if (alive) { peer = found; log("Endpoint ready for a send attempt. Claimed identity is unverified."); } });
        });
    }
    private void send() {
        if (!permitted()) return;
        final Engine.Peer receiver = peer; final Uri uri = selection; final String name = selectionName;
        if (receiver == null || uri == null) { log("Probe a receiver and choose a file first."); return; }
        new AlertDialog.Builder(this).setTitle("Send selected file?")
            .setMessage(name + " → " + receiver.name + "\n" + receiver.host + ":" + receiver.port + "\nThis device name is unverified. Confirm the nearby recipient yourself. The lab pins the certificate seen during your probe.")
            .setNegativeButton("Cancel", null).setPositiveButton("Send", (dialog, which) -> task("Send", () -> {
                File snapshot = File.createTempFile("airdrop-send-", ".tmp", getCacheDir());
                try {
                    try (InputStream input = getContentResolver().openInputStream(uri); OutputStream output = new FileOutputStream(snapshot)) {
                        if (input == null) throw new IOException("Selected source is unavailable");
                        byte[] b = new byte[8192]; long total = 0; int n;
                        while ((n = input.read(b)) != -1) { if (!alive || (total += n) > Http.FILE_LIMIT) throw new IOException("Cancelled or source exceeds 32 MiB"); output.write(b, 0, n); }
                    }
                    engine().send(receiver, snapshot, name);
                } finally { snapshot.delete(); }
            })).show();
    }
    private InetAddress receiveAddress(Network network) throws Exception {
        Enumeration<NetworkInterface> all = NetworkInterface.getNetworkInterfaces();
        while (all != null && all.hasMoreElements()) {
            NetworkInterface ni = all.nextElement();
            if (ni.getName().startsWith("awdl") && ni.isUp()) { Enumeration<InetAddress> ips = ni.getInetAddresses(); while (ips.hasMoreElements()) { InetAddress address = ips.nextElement(); if (address instanceof Inet6Address && !address.isLoopbackAddress()) return address; } }
        }
        if (network == null) throw new IOException("Connect to Wi-Fi first; no AWDL interface is exposed");
        LinkProperties links = ((ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE)).getLinkProperties(network);
        if (links != null) for (LinkAddress link : links.getLinkAddresses()) if (link.getAddress() instanceof Inet4Address) return link.getAddress();
        throw new IOException("No usable Wi-Fi IPv4 or AWDL IPv6 address");
    }
    private void startReceiver() {
        if (!permitted()) return;
        if (registration != null) { log("Receiver already registered. Stop networking to reset it."); return; }
        final Network network = wifi();
        task("Receive setup", () -> {
            Engine current = engine(); InetAddress address = receiveAddress(network); int p = current.listen(address);
            runOnUiThread(() -> {
                if (!alive || current.closed || engine != current) return;
                try {
                    multicast(); NsdServiceInfo info = new NsdServiceInfo(); info.setServiceName(current.id); info.setServiceType("_airdrop._tcp."); info.setPort(p); info.setAttribute("flags", "136");
                    if (Build.VERSION.SDK_INT >= 33 && network != null && address instanceof Inet4Address) info.setNetwork(network);
                    NsdManager.RegistrationListener candidate = new NsdManager.RegistrationListener() {
                        public void onServiceRegistered(NsdServiceInfo service) { log("Receiver advertised at " + address.getHostAddress() + ":" + p + ". Select Bridge AirDrop Lab on the Apple device if it appears."); }
                        public void onRegistrationFailed(NsdServiceInfo info, int code) { log("Receiver advertisement failed: " + code); runOnUiThread(() -> { if (registration == this) { registration = null; current.close(); } }); }
                        public void onServiceUnregistered(NsdServiceInfo info) { log("Receiver advertisement stopped."); }
                        public void onUnregistrationFailed(NsdServiceInfo info, int code) { log("Receiver unregistration failed: " + code); }
                    };
                    registration = candidate; nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, candidate);
                } catch (Exception e) { registration = null; current.close(); log("Receiver advertisement failed: " + e.getMessage()); }
            });
        });
    }
    @Override public boolean accept(String sender, Set<String> names) throws InterruptedException {
        CountDownLatch answer = new CountDownLatch(1); AtomicBoolean accepted = new AtomicBoolean();
        runOnUiThread(() -> {
            if (!alive || isFinishing()) { answer.countDown(); return; }
            incomingDialog = new AlertDialog.Builder(this).setTitle("Accept incoming files?")
                .setMessage("Claimed sender: " + sender + " (unverified)\n" + String.join("\n", names) + "\nUp to 32 MiB total. Accept only the transfer you just started.")
                .setNegativeButton("Decline", (d, w) -> answer.countDown())
                .setPositiveButton("Accept", (d, w) -> { accepted.set(true); answer.countDown(); })
                .setOnCancelListener(d -> answer.countDown()).create(); incomingDialog.show();
        });
        try { return answer.await(25, TimeUnit.SECONDS) && accepted.get() && alive; }
        finally { runOnUiThread(() -> { if (incomingDialog != null) { incomingDialog.dismiss(); incomingDialog = null; } }); }
    }
    @Override public void received(File directory, List<File> files) {
        runOnUiThread(() -> { saved.addAll(files); log("Received and committed " + files.size() + " file(s) privately. Use Save a received file to export."); });
    }
    private void export() {
        if (saved.isEmpty()) { log("No received files yet."); return; }
        String[] names = new String[saved.size()]; for (int i = 0; i < names.length; i++) names[i] = saved.get(i).getName();
        new AlertDialog.Builder(this).setTitle("Save received file").setItems(names, (d, index) -> {
            exportFile = saved.get(index);
            startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/octet-stream").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, exportFile.getName()), 2);
        }).show();
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) return; Uri uri = data.getData();
        if (request == 1) {
            try {
                String name = null;
                try (Cursor cursor = getContentResolver().query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) { if (cursor != null && cursor.moveToFirst()) name = cursor.getString(0); }
                selectionName = Cpio.fileName(name); selection = uri; chosenFile.setText(selectionName); log("Selected source: " + selectionName);
            } catch (Exception e) { selection = null; selectionName = null; chosenFile.setText("No file selected"); log("Selection failed: " + e.getMessage()); }
        } else if (request == 2 && exportFile != null) {
            File source = exportFile; exportFile = null;
            task("Export", () -> {
                try (InputStream input = new FileInputStream(source); OutputStream output = getContentResolver().openOutputStream(uri, "w")) {
                    if (output == null) throw new IOException("Cannot open save destination");
                    byte[] b = new byte[8192]; int n; while ((n = input.read(b)) != -1) output.write(b, 0, n);
                }
                log("Exported " + source.getName());
            });
        }
    }
    private synchronized void stopNetworking() {
        if (incomingDialog != null) { incomingDialog.dismiss(); incomingDialog = null; }
        if (engine != null) { engine.close(); engine = null; }
        peer = null;
        if (discovery != null) { NsdManager.DiscoveryListener current = discovery; discovery = null; try { nsd.stopServiceDiscovery(current); } catch (Exception ignored) {} }
        if (registration != null) { NsdManager.RegistrationListener current = registration; registration = null; try { nsd.unregisterService(current); } catch (Exception ignored) {} }
        networkEpoch++; resolving = false; resolveQueue.clear(); if (multicast != null && multicast.isHeld()) multicast.release();
        log("Networking stopped. Probe again before sending.");
    }
}
