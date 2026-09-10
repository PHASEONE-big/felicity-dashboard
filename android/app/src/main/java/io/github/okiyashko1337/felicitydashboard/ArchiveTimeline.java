package io.github.okiyashko1337.felicitydashboard;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Locale;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Pure timeline/time math shared by the archive UI and local unit tests. */
final class ArchiveTimeline {
    static final long HOUR=60L*60*1000,DAY=24*HOUR;
    private static final Pattern ISO=Pattern.compile("^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?:\\.(\\d{1,9}))?(Z|[+-]\\d{2}:?\\d{2})?.*$");
    private ArchiveTimeline(){}

    static long adaptiveSpan(int eventCount){if(eventCount<=6)return DAY;if(eventCount<=18)return 12*HOUR;if(eventCount<=48)return 6*HOUR;return 3*HOUR;}
    static long dayStart(long value){Calendar calendar=Calendar.getInstance();calendar.setTimeInMillis(value>0?value:System.currentTimeMillis());calendar.set(Calendar.HOUR_OF_DAY,0);calendar.set(Calendar.MINUTE,0);calendar.set(Calendar.SECOND,0);calendar.set(Calendar.MILLISECOND,0);return calendar.getTimeInMillis();}
    static long ceil(long value,long step){long remainder=Math.floorMod(value,step);return remainder==0?value:value+(step-remainder);}
    static boolean isMajor(long value,long step){return Math.floorMod(value,step)==0;}

    static long parseIso8601(String value){
        if(value==null)return 0;Matcher matcher=ISO.matcher(value.trim());if(!matcher.matches())return 0;
        try{
            SimpleDateFormat format=new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss",Locale.US);format.setLenient(false);format.setTimeZone(TimeZone.getTimeZone("UTC"));long result=format.parse(matcher.group(1)).getTime();
            String fraction=matcher.group(2);if(fraction!=null){String millis=(fraction+"000").substring(0,3);result+=Integer.parseInt(millis);}
            String zone=matcher.group(3);if(zone!=null&&!"Z".equalsIgnoreCase(zone)){int sign=zone.charAt(0)=='-'?-1:1,hours=Integer.parseInt(zone.substring(1,3)),minutes=Integer.parseInt(zone.substring(zone.length()-2));result-=sign*(hours*60L+minutes)*60_000L;}
            return result;
        }catch(Exception ignored){return 0;}
    }
}
