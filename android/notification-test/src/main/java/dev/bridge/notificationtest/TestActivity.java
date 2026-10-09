package dev.bridge.notificationtest;

import android.Manifest;
import android.app.*;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.*;
import android.widget.*;

/** Separate diagnostic APK; never bundled in Bridge's production app. */
public class TestActivity extends Activity {
    private TextView status;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        int inset = (int)(24 * getResources().getDisplayMetrics().density);
        layout.setPadding(inset, inset, inset, inset);
        TextView title = new TextView(this); title.setText("Bridge notification action test"); title.setTextSize(22);
        layout.addView(title);
        status = new TextView(this); layout.addView(status);
        Button post = new Button(this); post.setText("Create test notification"); layout.addView(post);
        post.setOnClickListener(view -> {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
            else postNotification();
        });
        setContentView(layout);
    }
    @Override public void onResume() { super.onResume(); updateStatus(); }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == 1 && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) postNotification();
    }
    private void updateStatus() {
        String reply = getSharedPreferences("test", MODE_PRIVATE).getString("reply", "");
        if (!reply.isEmpty()) { status.setText("Reply received locally: " + reply); return; }
        status.setText(getSharedPreferences("test", MODE_PRIVATE).getBoolean("received", false)
            ? "Mark read action received successfully."
            : "Create a notification, then click Mark read in Mac Bridge. Keep the phone unlocked for this test.");
    }
    private void postNotification() {
        getSharedPreferences("test", MODE_PRIVATE).edit().putBoolean("received", false).remove("reply").apply(); updateStatus();
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("test", "Bridge action tests", NotificationManager.IMPORTANCE_DEFAULT));
        PendingIntent action = PendingIntent.getBroadcast(this, 1, new Intent(this, ActionReceiver.class), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Action read = new Notification.Action.Builder(android.R.drawable.ic_menu_view, "Mark read", action)
            .setSemanticAction(Notification.Action.SEMANTIC_ACTION_MARK_AS_READ).build();
        PendingIntent replyIntent = PendingIntent.getBroadcast(this, 2, new Intent(this, ActionReceiver.class).setAction("reply"),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
        RemoteInput input = new RemoteInput.Builder("reply-text").setLabel("Test reply").build();
        Notification.Action reply = new Notification.Action.Builder(android.R.drawable.ic_menu_send, "Reply", replyIntent)
            .addRemoteInput(input).setSemanticAction(Notification.Action.SEMANTIC_ACTION_REPLY).build();
        manager.notify(100, new Notification.Builder(this, "test").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Bridge action test").setContentText("Reply or click Mark read on your Mac.").addAction(read).addAction(reply).build());
    }
}
