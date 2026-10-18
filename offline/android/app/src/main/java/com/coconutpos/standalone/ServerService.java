package com.coconutpos.standalone;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.content.res.AssetManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.List;

/** Keeps the shop's local server running (as a foreground service) so other devices stay connected. */
public class ServerService extends Service {
  static final String CHANNEL = "server";
  static volatile PosServer server;
  static volatile String error;
  private PowerManager.WakeLock wake;

  static final String HOST_SCRIPT =
      "window.COCONUT_HOST={platform:'android',print:function(h){try{CoconutAndroid.print(String(h));return true}catch(e){return false}},"
      + "info:function(){try{return Promise.resolve(JSON.parse(CoconutAndroid.info()))}catch(e){return Promise.resolve({})}}};";

  @Override public IBinder onBind(Intent intent) { return null; }

  @Override public void onCreate() {
    super.onCreate();
    startForegroundNow("กำลังเริ่มระบบ…");
    new Thread(new Runnable() { public void run() { startServer(); } }, "coconut-start").start();
    try {
      PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
      wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CoconutPOS:server");
      wake.setReferenceCounted(false);
      wake.acquire();
    } catch (Exception e) { /* optional */ }
  }

  private void startServer() {
    if (server != null) { updateNotification(); return; }
    final AssetManager am = getAssets();
    PosServer.Files files = new PosServer.Files() {
      public InputStream open(String path) throws IOException { return am.open("www/" + path); }
    };
    File data = new File(getFilesDir(), "data");
    String name = Build.MANUFACTURER + " " + Build.MODEL;
    IOException last = null;
    for (int port = 8080; port <= 8090; port++) {
      try {
        PosServer s = new PosServer(data, files, port, "android", name, HOST_SCRIPT);
        s.start();
        server = s; error = null; updateNotification(); return;
      } catch (IOException e) { last = e; }
    }
    error = last == null ? "start failed" : last.getMessage();
  }

  static String address() {
    PosServer s = server;
    if (s == null) return null;
    List<String> lan = PosServer.lanAddresses();
    return "http://" + (lan.isEmpty() ? "127.0.0.1" : lan.get(0)) + ":" + s.port();
  }

  private void updateNotification() {
    String a = address();
    NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
    if (nm != null) nm.notify(1, build(a == null ? "กำลังเริ่มระบบ…" : "เครื่องอื่นในร้านเปิด " + a));
  }

  private Notification build(String text) {
    NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
    if (Build.VERSION.SDK_INT >= 26 && nm != null && nm.getNotificationChannel(CHANNEL) == null) {
      NotificationChannel ch = new NotificationChannel(CHANNEL, "Coconut POS เครื่องหลัก", NotificationManager.IMPORTANCE_LOW);
      ch.setShowBadge(false);
      nm.createNotificationChannel(ch);
    }
    Intent open = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
    PendingIntent pi = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0));
    Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
    return b.setSmallIcon(android.R.drawable.stat_sys_upload_done)
        .setContentTitle("Coconut POS เปิดอยู่ (เครื่องหลัก)")
        .setContentText(text)
        .setContentIntent(pi)
        .setOngoing(true)
        .build();
  }

  private void startForegroundNow(String text) {
    Notification n = build(text);
    if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
    else startForeground(1, n);
  }

  @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }

  @Override public void onDestroy() {
    PosServer s = server; server = null;
    if (s != null) s.stop();
    try { if (wake != null && wake.isHeld()) wake.release(); } catch (Exception e) { /* ignore */ }
    super.onDestroy();
  }
}
