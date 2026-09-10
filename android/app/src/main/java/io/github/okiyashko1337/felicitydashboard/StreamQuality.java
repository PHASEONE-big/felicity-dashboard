package io.github.okiyashko1337.felicitydashboard;

import android.content.Context;
import android.content.SharedPreferences;

final class StreamQuality {
    static final String KEY="stream_quality";
    static final String AUTO="auto";
    static final String MAIN="main";
    static final String SUB="sub";

    private StreamQuality(){}

    static boolean useSubstream(Context context,SharedPreferences prefs,CameraCatalog.Camera camera){
        String preference=prefs.getString(key(camera),AUTO);
        if(SUB.equals(preference))return true;
        if(MAIN.equals(preference))return false;
        return context.getResources().getDisplayMetrics().widthPixels<=1200;
    }

    static void select(SharedPreferences prefs,CameraCatalog.Camera camera,boolean substream){
        prefs.edit().putString(key(camera),substream?SUB:MAIN).apply();
    }

    private static String key(CameraCatalog.Camera camera){return KEY+"."+(camera==null?"default":camera.id);}
}
