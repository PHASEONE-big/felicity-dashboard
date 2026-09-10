package io.github.okiyashko1337.felicitydashboard;

import android.app.Activity;
import android.app.Application;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Build;

public final class DashboardApplication extends Application implements Application.ActivityLifecycleCallbacks {
    private final Handler main = new Handler(Looper.getMainLooper());
    private int resumedActivities;
    private boolean navigationStarted;
    private final Runnable showNavigation = () -> { if (resumedActivities == 0) setNavigationVisible(true); };

    @Override public void onCreate() { super.onCreate(); registerActivityLifecycleCallbacks(this); }
    @Override public void onActivityResumed(Activity activity) { resumedActivities++; main.removeCallbacks(showNavigation); startNavigationIfNeeded(); setNavigationVisible(false); }
    @Override public void onActivityPaused(Activity activity) { resumedActivities = Math.max(0, resumedActivities - 1); main.removeCallbacks(showNavigation); main.postDelayed(showNavigation, 300); }

    private void setNavigationVisible(boolean visible) {
        if (!navigationStarted) return;
        if (NavigationService.setVisibleNow(visible)) return;
        try {
            Intent intent = new Intent(visible
                    ? NavigationService.ACTION_SHOW
                    : NavigationService.ACTION_HIDE);
            intent.setPackage(getPackageName());
            sendBroadcast(intent);
        } catch (Exception ignored) { }
    }

    private void startNavigationIfNeeded() {
        if (navigationStarted || getResources().getConfiguration().smallestScreenWidthDp < 600) return;
        navigationStarted = true;
        try {
            Intent intent = new Intent(this, NavigationService.class).setAction(NavigationService.ACTION_HIDE);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent); else startService(intent);
        } catch (Exception ignored) { navigationStarted = false; }
    }

    @Override public void onActivityCreated(Activity activity, Bundle state) { }
    @Override public void onActivityStarted(Activity activity) { }
    @Override public void onActivityStopped(Activity activity) { }
    @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) { }
    @Override public void onActivityDestroyed(Activity activity) { }
}
