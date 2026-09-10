package io.github.okiyashko1337.felicitydashboard;

import android.content.SharedPreferences;

final class ArchiveSession {
    static final long TTL_MS=30*60*1000L;
    private static final String TIME="archive_sync_time_ms",TOUCHED="archive_sync_touched_ms";
    private ArchiveSession(){}

    static long validTime(SharedPreferences prefs,long now){long touched=prefs.getLong(TOUCHED,0),time=prefs.getLong(TIME,0);if(!isValid(time,touched,now)){clear(prefs);return 0;}return time;}
    static boolean isValid(long time,long touched,long now){return time>0&&touched>0&&now>=touched&&now-touched<=TTL_MS;}
    static void set(SharedPreferences prefs,long archiveTime,long now){prefs.edit().putLong(TIME,archiveTime).putLong(TOUCHED,now).apply();}
    static void touch(SharedPreferences prefs,long now){if(validTime(prefs,now)>0)prefs.edit().putLong(TOUCHED,now).apply();}
    static void clear(SharedPreferences prefs){prefs.edit().remove(TIME).remove(TOUCHED).apply();}
}
