package io.github.okiyashko1337.felicitydashboard;

import android.app.Activity;
import android.content.res.Configuration;
import android.view.View;
import android.view.WindowManager;

/** Keeps the 5-inch appliance immersive while making tablet Android controls reachable. */
final class DeviceUi {
    private DeviceUi() {}

    static boolean isLargeDisplay(Activity activity) {
        return activity.getResources().getConfiguration().smallestScreenWidthDp >= 600;
    }

    static void apply(Activity activity) {
        View decor = activity.getWindow().getDecorView();
        if (isLargeDisplay(activity)) {
            // This vendor SystemUI exposes an empty status-bar window but no usable shade.
            // Keep the tablet clean; Android Settings is reachable from Felicity itself.
            activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
            decor.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        } else {
            decor.setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    | View.SYSTEM_UI_FLAG_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        }
    }
}
