package io.github.okiyashko1337.dragonrescue;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public final class RescueActivity extends Activity {
    private static final int PICK_APK = 41;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        startNavigationBar();
        new Handler().postDelayed(this::startNavigationBar, 750);
        showControlPanel();
    }

    private void startNavigationBar() {
        Intent navigation = new Intent(this, NavigationService.class)
                .setAction(NavigationService.ACTION_SHOW);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(navigation);
        else startService(navigation);
    }

    private void showControlPanel() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setPadding(dp(56), dp(32), dp(56), dp(32));
        root.setBackgroundColor(Color.rgb(7, 26, 24));

        TextView title = new TextView(this);
        title.setText("Dragon Rescue");
        title.setTextColor(Color.WHITE);
        title.setTextSize(32);
        title.setGravity(Gravity.CENTER);
        root.addView(title, matchWrap(dp(16)));

        TextView hint = new TextView(this);
        hint.setText("The floating Back / Home / Recents bar works over every app and starts automatically after reboot.");
        hint.setTextColor(Color.rgb(172, 205, 199));
        hint.setTextSize(18);
        hint.setGravity(Gravity.CENTER);
        root.addView(hint, matchWrap(dp(24)));

        addButton(root, "SHOW NAVIGATION BAR", v -> startNavigationBar());
        addButton(root, "OPEN ANDROID SETTINGS", v -> open(Settings.ACTION_SETTINGS));
        addButton(root, "INSTALL APK FROM USB", v -> pickApk());
        addButton(root, "CHOOSE HOME APP", v -> open(Settings.ACTION_HOME_SETTINGS));
        addButton(root, "OPEN FELICITY DASHBOARD", v -> launchPackage("io.github.okiyashko1337.felicitydashboard"));

        setContentView(root);
    }

    private void addButton(LinearLayout root, String text, View.OnClickListener action) {
        Button button = new Button(this);
        button.setText(text);
        button.setTextSize(18);
        button.setAllCaps(false);
        button.setOnClickListener(action);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(dp(520), dp(64));
        params.topMargin = dp(12);
        root.addView(button, params);
    }

    private void open(String action) {
        try {
            startActivity(new Intent(action));
        } catch (ActivityNotFoundException error) {
            Toast.makeText(this, "This settings screen is unavailable", Toast.LENGTH_LONG).show();
        }
    }

    private void pickApk() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("application/vnd.android.package-archive");
        startActivityForResult(intent, PICK_APK);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != PICK_APK || resultCode != RESULT_OK || data == null || data.getData() == null) return;
        Uri apk = data.getData();
        Intent install = new Intent(Intent.ACTION_VIEW);
        install.setDataAndType(apk, "application/vnd.android.package-archive");
        install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(install);
    }

    private void launchPackage(String packageName) {
        Intent launch = getPackageManager().getLaunchIntentForPackage(packageName);
        if (launch == null) {
            Toast.makeText(this, "Felicity Dashboard is not installed yet", Toast.LENGTH_LONG).show();
            return;
        }
        startActivity(launch);
    }

    private LinearLayout.LayoutParams matchWrap(int bottomMargin) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        params.bottomMargin = bottomMargin;
        return params;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
