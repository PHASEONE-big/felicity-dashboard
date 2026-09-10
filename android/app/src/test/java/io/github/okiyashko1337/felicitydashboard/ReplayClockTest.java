package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public final class ReplayClockTest {
    @Test public void readsOnvifReplayNtpTimestamp(){
        long expected=1_787_990_400_500L,seconds=expected/1000+2_208_988_800L,fraction=2_147_483_648L;
        byte[] packet=new byte[28];packet[0]=(byte)0x90;put16(packet,12,0xabac);put16(packet,14,3);put32(packet,16,seconds);put32(packet,20,fraction);
        assertEquals(expected,ReplayClock.fromRtp(packet));
    }

    @Test public void ignoresOrdinaryRtpAndOtherExtensions(){
        byte[] packet=new byte[28];packet[0]=(byte)0x80;assertEquals(0,ReplayClock.fromRtp(packet));
        packet[0]=(byte)0x90;put16(packet,12,0xbede);put16(packet,14,3);assertEquals(0,ReplayClock.fromRtp(packet));
    }

    @Test public void readsRtspClockRangeAsFallback(){
        assertEquals(1_787_990_400_000L,ReplayClock.fromRange("clock=20260829T080000Z-"));
    }

    private static void put16(byte[] out,int offset,long value){out[offset]=(byte)(value>>8);out[offset+1]=(byte)value;}
    private static void put32(byte[] out,int offset,long value){out[offset]=(byte)(value>>24);out[offset+1]=(byte)(value>>16);out[offset+2]=(byte)(value>>8);out[offset+3]=(byte)value;}
}
