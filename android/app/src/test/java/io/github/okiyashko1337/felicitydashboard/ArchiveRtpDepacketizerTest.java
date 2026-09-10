package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.*;
import java.util.*;
import org.junit.Test;

public final class ArchiveRtpDepacketizerTest {
    @Test public void joinsH264FuAIntoAnnexBIdr(){List<byte[]> units=new ArrayList<>();ArchiveRtpDepacketizer d=new ArchiveRtpDepacketizer(false,(data,time,ts,key)->{assertTrue(key);units.add(data);});d.accept(rtp(7,99,false,new byte[]{0x7c,(byte)0x85,1,2}));d.accept(rtp(8,99,true,new byte[]{0x7c,0x45,3,4}));assertEquals(1,units.size());assertArrayEquals(new byte[]{0,0,0,1,0x65,1,2,3,4},units.get(0));}
    @Test public void joinsH265FuIntoAnnexBIrap(){List<byte[]> units=new ArrayList<>();ArchiveRtpDepacketizer d=new ArchiveRtpDepacketizer(true,(data,time,ts,key)->{assertTrue(key);units.add(data);});d.accept(rtp(1,101,false,new byte[]{0x62,1,(byte)(0x80|19),7}));d.accept(rtp(2,101,true,new byte[]{0x62,1,(byte)(0x40|19),8}));assertEquals(1,units.size());assertArrayEquals(new byte[]{0,0,0,1,0x26,1,7,8},units.get(0));}
    private static byte[] rtp(int seq,int ts,boolean marker,byte[] payload){byte[] p=new byte[12+payload.length];p[0]=(byte)0x80;p[1]=(byte)(96|(marker?0x80:0));p[2]=(byte)(seq>>>8);p[3]=(byte)seq;p[4]=(byte)(ts>>>24);p[5]=(byte)(ts>>>16);p[6]=(byte)(ts>>>8);p[7]=(byte)ts;System.arraycopy(payload,0,p,12,payload.length);return p;}
}
