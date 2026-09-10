package io.github.okiyashko1337.felicitydashboard.prototype;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public final class PrototypeActivity extends Activity {
    @Override protected void onCreate(Bundle state){super.onCreate(state);getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);getWindow().getDecorView().setSystemUiVisibility(5894);WebView web=new WebView(this);web.setBackgroundColor(0xff07110f);web.setWebViewClient(new WebViewClient());WebSettings settings=web.getSettings();settings.setJavaScriptEnabled(true);settings.setDomStorageEnabled(false);settings.setAllowFileAccess(false);setContentView(web);String device=getIntent().getStringExtra("device");if(!"fhd".equals(device))device="echo";web.loadUrl("http://10.0.2.2:8790/dual-dashboard-v2.html?device="+device);}
}
