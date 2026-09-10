package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public final class OnvifReplayProxyTest {
    @Test public void rtcpSenderReportCarriesTransportClockWithoutMedia(){
        byte[] value=OnvifReplayProxy.rtcpSenderReport(0x12345678,0x23456789,42,9001,1000);
        assertEquals(28,value.length);
        assertEquals(0x80,value[0]&255);
        assertEquals(200,value[1]&255);
        assertEquals(6,read16(value,2));
        assertEquals(0x12345678,read32(value,4));
        assertEquals(2208988801L,read32(value,8)&0xffffffffL);
        assertEquals(0x23456789,read32(value,16));
        assertEquals(42,read32(value,20));
        assertEquals(9001,read32(value,24));
    }

    @Test public void rtpKeepaliveContainsH264FillerButNoPicture(){
        byte[] value=OnvifReplayProxy.rtpFillerKeepalive(0x12345678,0x23456789,456,96,false);
        assertEquals(15,value.length);
        assertEquals(0x80,value[0]&255);
        assertEquals(96,value[1]&255);
        assertEquals(456,read16(value,2));
        assertEquals(0x23456789,read32(value,4));
        assertEquals(0x12345678,read32(value,8));
        assertEquals(12,value[12]&31);
    }

    @Test public void rtpKeepaliveContainsH265FillerButNoPicture(){
        byte[] value=OnvifReplayProxy.rtpFillerKeepalive(1,2,3,98,true);
        assertEquals(16,value.length);
        assertEquals(38,(value[12]>>1)&63);
    }

    private static int read16(byte[] value,int offset){return ((value[offset]&255)<<8)|(value[offset+1]&255);}
    private static int read32(byte[] value,int offset){return ((value[offset]&255)<<24)|((value[offset+1]&255)<<16)|((value[offset+2]&255)<<8)|(value[offset+3]&255);}
}
