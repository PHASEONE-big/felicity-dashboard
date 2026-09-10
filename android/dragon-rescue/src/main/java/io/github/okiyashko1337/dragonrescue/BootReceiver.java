package io.github.okiyashko1337.dragonrescue;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public final class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context,Intent intent){Intent service=new Intent(context,NavigationService.class).setAction(NavigationService.ACTION_SHOW);if(Build.VERSION.SDK_INT>=26)context.startForegroundService(service);else context.startService(service);}
}
