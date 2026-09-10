package io.github.okiyashko1337.felicitydashboard;

import android.content.SharedPreferences;

final class EventFilters {
    static final int PERSON=1,ANIMAL=2,VEHICLE=4,FACE=8,ALL=PERSON|ANIMAL|VEHICLE|FACE;
    private EventFilters(){}
    static int get(SharedPreferences prefs,CameraCatalog.Camera camera){return prefs.getInt(key(camera),defaultMask(camera));}
    static void set(SharedPreferences prefs,CameraCatalog.Camera camera,int mask){prefs.edit().putInt(key(camera),mask&ALL).apply();}
    static void apply(ThreeEyeState state,int mask){state.allowPerson=(mask&PERSON)!=0;state.allowAnimal=(mask&ANIMAL)!=0;state.allowVehicle=(mask&VEHICLE)!=0;state.allowFace=(mask&FACE)!=0;}
    static String summary(int mask){return Integer.bitCount(mask&ALL)+"/4";}
    static int defaultMask(CameraCatalog.Camera camera){String name=camera.name==null?"":camera.name.toLowerCase(java.util.Locale.US);return "street".equals(camera.id)||name.contains("улиц")||name.contains("street")?PERSON|ANIMAL:ALL;}
    private static String key(CameraCatalog.Camera camera){return "event_filter_"+camera.id;}
}
