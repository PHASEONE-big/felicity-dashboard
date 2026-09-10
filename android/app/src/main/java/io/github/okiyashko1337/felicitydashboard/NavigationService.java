package io.github.okiyashko1337.felicitydashboard;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Build;
import android.os.IBinder;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;

public final class NavigationService extends Service {
    static final String ACTION_SHOW="io.github.okiyashko1337.felicitydashboard.NAV_SHOW";
    static final String ACTION_HIDE="io.github.okiyashko1337.felicitydashboard.NAV_HIDE";
    private WindowManager windowManager;
    private View overlay;
    private static NavigationService running;
    private final BroadcastReceiver visibilityReceiver=new BroadcastReceiver(){@Override public void onReceive(Context context,Intent intent){setVisible(ACTION_SHOW.equals(intent.getAction()));}};

    @Override public void onCreate(){super.onCreate();running=this;startForeground(72,notification());registerReceiver(visibilityReceiver,new IntentFilter(ACTION_SHOW));registerReceiver(visibilityReceiver,new IntentFilter(ACTION_HIDE));showOverlay();}
    @Override public int onStartCommand(Intent intent,int flags,int startId){setVisible(intent==null||!ACTION_HIDE.equals(intent.getAction()));return START_STICKY;}
    @Override public IBinder onBind(Intent intent){return null;}

    private void showOverlay(){if(overlay!=null)return;try{windowManager=(WindowManager)getSystemService(WINDOW_SERVICE);LinearLayout bar=new LinearLayout(this);bar.setOrientation(LinearLayout.HORIZONTAL);bar.setPadding(dp(4),dp(4),dp(4),dp(4));GradientDrawable background=new GradientDrawable();background.setColor(Color.argb(220,7,26,24));background.setCornerRadius(dp(14));background.setStroke(dp(1),Color.rgb(0,205,183));bar.setBackground(background);addAction(bar,"‹","Back",4);addAction(bar,"⌂","Home",3);addAction(bar,"▢","Recent apps",187);WindowManager.LayoutParams params=new WindowManager.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT,WindowManager.LayoutParams.WRAP_CONTENT,Build.VERSION.SDK_INT>=26?WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY:WindowManager.LayoutParams.TYPE_PHONE,WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,PixelFormat.TRANSLUCENT);params.gravity=Gravity.BOTTOM|Gravity.RIGHT;params.x=dp(18);params.y=dp(18);overlay=bar;windowManager.addView(overlay,params);}catch(Exception ignored){overlay=null;}}
    private void addAction(LinearLayout bar,String label,String description,int keyCode){Button button=new Button(this);button.setText(label);button.setContentDescription(description);button.setTextSize(22);button.setTextColor(Color.WHITE);button.setAllCaps(false);button.setMinWidth(0);button.setMinHeight(0);button.setPadding(0,0,0,dp(2));StateListDrawable states=new StateListDrawable();states.addState(new int[]{android.R.attr.state_pressed},buttonShape(Color.rgb(27,111,100)));states.addState(new int[]{},buttonShape(Color.TRANSPARENT));button.setBackground(states);button.setOnClickListener(v->sendKey(keyCode));LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(dp(52),dp(48));params.setMargins(dp(2),0,dp(2),0);bar.addView(button,params);}
    private void sendKey(int keyCode){try{new ProcessBuilder("/system/xbin/su","0","input","keyevent",Integer.toString(keyCode)).start();}catch(Exception ignored){}}
    private void setVisible(boolean visible){if(overlay==null)showOverlay();if(overlay!=null)overlay.setVisibility(visible?View.VISIBLE:View.GONE);}
    static boolean setVisibleNow(boolean visible){NavigationService service=running;if(service==null)return false;service.setVisible(visible);return true;}
    private Notification notification(){String channel="felicity_navigation";NotificationManager manager=(NotificationManager)getSystemService(NOTIFICATION_SERVICE);if(Build.VERSION.SDK_INT>=26)manager.createNotificationChannel(new NotificationChannel(channel,"Felicity navigation",NotificationManager.IMPORTANCE_MIN));Notification.Builder builder=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,channel):new Notification.Builder(this);return builder.setSmallIcon(android.R.drawable.ic_media_previous).setContentTitle("Felicity navigation").setContentText("Back, Home and Recent apps are available").setOngoing(true).build();}
    private GradientDrawable buttonShape(int color){GradientDrawable shape=new GradientDrawable();shape.setColor(color);shape.setCornerRadius(dp(10));return shape;}
    @Override public void onDestroy(){running=null;try{unregisterReceiver(visibilityReceiver);}catch(Exception ignored){}if(windowManager!=null&&overlay!=null)windowManager.removeView(overlay);overlay=null;super.onDestroy();}
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
}
