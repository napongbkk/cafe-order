package com.coconutpos.standalone;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintManager;
import android.view.View;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.TextView;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Shows the POS from this device's own server, and gives the page printing and file picking. */
public class MainActivity extends Activity {
  private static final int PICK_FILE = 41;
  private WebView web;
  private TextView status;
  private ValueCallback<Uri[]> fileCb;
  private final Handler ui = new Handler(Looper.getMainLooper());
  private WebView printView;

  @Override protected void onCreate(Bundle b) {
    super.onCreate(b);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
      requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 7);

    status = new TextView(this);
    status.setText("Coconut POS กำลังเริ่มระบบ…");
    status.setTextSize(18); status.setPadding(48, 48, 48, 48); status.setBackgroundColor(Color.parseColor("#F3F7FB"));
    setContentView(status);

    Intent svc = new Intent(this, ServerService.class);
    if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc); else startService(svc);
    waitForServer(0);
  }

  private void waitForServer(final int tries) {
    PosServer s = ServerService.server;
    if (s != null) { showWeb(s.port()); return; }
    if (ServerService.error != null || tries > 150) {
      status.setText("เริ่มระบบไม่สำเร็จ: " + (ServerService.error == null ? "หมดเวลา" : ServerService.error) + "\nปิดแอปแล้วเปิดใหม่");
      return;
    }
    ui.postDelayed(new Runnable() { public void run() { waitForServer(tries + 1); } }, 100);
  }

  private void showWeb(int port) {
    web = new WebView(this);
    WebSettings ws = web.getSettings();
    ws.setJavaScriptEnabled(true);
    ws.setDomStorageEnabled(true);
    ws.setDatabaseEnabled(true);
    ws.setMediaPlaybackRequiresUserGesture(false);
    ws.setAllowFileAccess(false);
    ws.setSupportMultipleWindows(false);
    ws.setTextZoom(100);
    if (Build.VERSION.SDK_INT >= 21) ws.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
    web.addJavascriptInterface(new Bridge(), "CoconutAndroid");
    final String local = "http://127.0.0.1:" + port;
    web.setWebViewClient(new WebViewClient() {
      @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) { return external(r.getUrl().toString(), local); }
      @SuppressWarnings("deprecation") @Override public boolean shouldOverrideUrlLoading(WebView v, String url) { return external(url, local); }
    });
    web.setWebChromeClient(new WebChromeClient() {
      @Override public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
        if (fileCb != null) fileCb.onReceiveValue(null);
        fileCb = cb;
        try { startActivityForResult(p.createIntent(), PICK_FILE); }
        catch (Exception e) { fileCb = null; return false; }
        return true;
      }
    });
    setContentView(web);
    Map<String, String> h = new HashMap<>();
    h.put("X-Coconut-Host", "android");
    web.loadUrl(local + "/", h);
  }

  private boolean external(String url, String local) {
    if (url.startsWith(local)) return false;
    try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))); } catch (Exception e) { /* no browser */ }
    return true;
  }

  @Override protected void onActivityResult(int req, int res, Intent data) {
    if (req == PICK_FILE && fileCb != null) {
      fileCb.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(res, data));
      fileCb = null;
      return;
    }
    super.onActivityResult(req, res, data);
  }

  @Override public void onBackPressed() {
    if (web != null && web.canGoBack()) { web.goBack(); return; }
    new AlertDialog.Builder(this)
        .setTitle("ออกจาก Coconut POS?")
        .setMessage("เครื่องนี้เป็นเครื่องหลักที่เก็บข้อมูล ระบบยังทำงานต่อเบื้องหลังเพื่อให้เครื่องอื่นในร้านใช้งานได้")
        .setPositiveButton("ย่อแอป", (d, w) -> moveTaskToBack(true))
        .setNeutralButton("ปิดระบบ", (d, w) -> { stopService(new Intent(this, ServerService.class)); finish(); })
        .setNegativeButton("ยกเลิก", null)
        .show();
  }

  /** Available to the page as CoconutAndroid. */
  final class Bridge {
    @JavascriptInterface public void print(final String html) {
      ui.post(new Runnable() { public void run() { printHtml(html); } });
    }
    @JavascriptInterface public String info() {
      List<String> lan = PosServer.lanAddresses();
      StringBuilder b = new StringBuilder("{\"platform\":\"android\",\"lan\":[");
      PosServer s = ServerService.server; int port = s == null ? 8080 : s.port();
      for (int i = 0; i < lan.size(); i++) { if (i > 0) b.append(','); b.append("\"http://").append(lan.get(i)).append(':').append(port).append('"'); }
      return b.append("]}").toString();
    }
  }

  private void printHtml(String html) {
    PosServer s = ServerService.server;
    String base = "http://127.0.0.1:" + (s == null ? 8080 : s.port()) + "/";
    // The receipt page prints itself when loaded; here Android's print service does it instead.
    String page = html.replace("window.print()", "void 0");
    final WebView pv = new WebView(this);
    pv.getSettings().setJavaScriptEnabled(true);
    pv.setWebViewClient(new WebViewClient() {
      @Override public void onPageFinished(final WebView v, String url) {
        ui.postDelayed(new Runnable() { public void run() {
          PrintManager pm = (PrintManager) getSystemService(Context.PRINT_SERVICE);
          PrintDocumentAdapter ad = v.createPrintDocumentAdapter("Coconut POS");
          PrintAttributes.Builder ab = new PrintAttributes.Builder().setMinMargins(PrintAttributes.Margins.NO_MARGINS);
          if (pm != null) pm.print("Coconut POS", ad, ab.build());
        } }, 600);
      }
    });
    printView = pv; // keep a reference until printing is done
    pv.loadDataWithBaseURL(base, page, "text/html", "utf-8", null);
  }

  @Override protected void onDestroy() {
    if (web != null) { web.setVisibility(View.GONE); web.destroy(); }
    super.onDestroy();
  }
}
