package dev.bridge.notificationtest;

import android.app.NotificationManager;
import android.app.RemoteInput;
import android.os.Bundle;
import android.content.*;

public class ActionReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        Bundle replies = RemoteInput.getResultsFromIntent(intent);
        if (replies != null && replies.containsKey("reply-text")) {
            context.getSharedPreferences("test", Context.MODE_PRIVATE).edit()
                .putString("reply", replies.getCharSequence("reply-text").toString()).apply();
        } else context.getSharedPreferences("test", Context.MODE_PRIVATE).edit().putBoolean("received", true).apply();
        context.getSystemService(NotificationManager.class).cancel(100);
    }
}
