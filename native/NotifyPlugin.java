package com.banaagjade.circle;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import androidx.core.app.NotificationManagerCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

@CapacitorPlugin(name = "Notify", permissions = {
    @Permission(alias = "notifications", strings = { "android.permission.POST_NOTIFICATIONS" })
})
public class NotifyPlugin extends Plugin {
    static final String CH = "circle_messages";

    private boolean granted() {
        if (Build.VERSION.SDK_INT >= 33) {
            return getPermissionState("notifications") == PermissionState.GRANTED;
        }
        return NotificationManagerCompat.from(getContext()).areNotificationsEnabled();
    }

    private void ensureChannel(Context c) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel ch = new NotificationChannel(CH, "Messages and activity", NotificationManager.IMPORTANCE_HIGH);
            ch.enableVibration(true);
            nm.createNotificationChannel(ch);
        }
    }

    @PluginMethod
    public void check(PluginCall call) {
        JSObject r = new JSObject();
        r.put("granted", granted());
        r.put("asked", Build.VERSION.SDK_INT < 33 || getContext().getSharedPreferences("circle", 0).getBoolean("asked", false));
        call.resolve(r);
    }

    @PluginMethod
    public void request(PluginCall call) {
        ensureChannel(getContext());
        getContext().getSharedPreferences("circle", 0).edit().putBoolean("asked", true).apply();
        if (granted()) { check(call); return; }
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissionForAlias("notifications", call, "permDone");
        } else {
            check(call);
        }
    }

    @PermissionCallback
    private void permDone(PluginCall call) { check(call); }

    @PluginMethod
    public void show(PluginCall call) {
        Context c = getContext();
        if (!granted()) { call.reject("no permission"); return; }
        ensureChannel(c);
        String title = call.getString("title", "Circle");
        String body = call.getString("body", "");
        String tag = call.getString("tag", "");
        Intent open = new Intent(c, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        int id = tag.isEmpty() ? (int) (System.currentTimeMillis() & 0x7fffffff) : tag.hashCode();
        PendingIntent pi = PendingIntent.getActivity(c, id, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(c, CH) : new Notification.Builder(c);
        b.setContentTitle(title).setContentText(body).setStyle(new Notification.BigTextStyle().bigText(body))
            .setSmallIcon(c.getApplicationInfo().icon).setAutoCancel(true).setContentIntent(pi)
            .setWhen(System.currentTimeMillis());
        if (Build.VERSION.SDK_INT < 26) b.setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL);
        ((NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE)).notify(id, b.build());
        call.resolve();
    }

    @PluginMethod
    public void keepAlive(PluginCall call) {
        Context c = getContext();
        Intent i = new Intent(c, KeepAliveService.class);
        try {
            if (Boolean.TRUE.equals(call.getBoolean("on", true))) {
                if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
            } else {
                c.stopService(i);
            }
            call.resolve();
        } catch (Exception e) {
            call.reject(String.valueOf(e.getMessage()));
        }
    }
}
