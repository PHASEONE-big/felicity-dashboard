package io.github.okiyashko1337.felicitydashboard;

import java.text.SimpleDateFormat;
import java.util.Locale;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Extracts the absolute recording time carried by ONVIF Profile G replay. */
final class ReplayClock {
    private static final long NTP_UNIX_EPOCH_SECONDS=2_208_988_800L;
    private static final long NTP_FRACTION_SCALE=4_294_967_296L;
    private static final Pattern CLOCK_RANGE=Pattern.compile("clock=(\\d{8}T\\d{6}Z)",Pattern.CASE_INSENSITIVE);
    private ReplayClock(){}

    static long fromRtp(byte[] packet){
        if(packet==null||packet.length<28||(packet[0]&0xc0)!=0x80||(packet[0]&0x10)==0)return 0;
        int csrcCount=packet[0]&0x0f,extension=12+csrcCount*4;
        if(extension+16>packet.length||unsigned16(packet,extension)!=0xabac||unsigned16(packet,extension+2)<3)return 0;
        long seconds=unsigned32(packet,extension+4),fraction=unsigned32(packet,extension+8);
        if(seconds<NTP_UNIX_EPOCH_SECONDS)return 0;
        return (seconds-NTP_UNIX_EPOCH_SECONDS)*1000L+(fraction*1000L)/NTP_FRACTION_SCALE;
    }

    static long fromRange(String range){
        if(range==null)return 0;Matcher matcher=CLOCK_RANGE.matcher(range);if(!matcher.find())return 0;
        try{SimpleDateFormat format=new SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'",Locale.US);format.setLenient(false);format.setTimeZone(TimeZone.getTimeZone("UTC"));return format.parse(matcher.group(1)).getTime();}catch(Exception ignored){return 0;}
    }

    private static int unsigned16(byte[] value,int offset){return ((value[offset]&255)<<8)|(value[offset+1]&255);}
    private static long unsigned32(byte[] value,int offset){return ((value[offset]&255L)<<24)|((value[offset+1]&255L)<<16)|((value[offset+2]&255L)<<8)|(value[offset+3]&255L);}
}
