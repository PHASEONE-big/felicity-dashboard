package io.github.okiyashko1337.felicitydashboard;

import org.junit.Test;
import static org.junit.Assert.*;

public final class RtpKeyframeDetectorTest {
    @Test public void detectsH264IdrAndFuStart(){
        assertTrue(RtpKeyframeDetector.isKeyframe(packet((byte)0x65)));
        assertTrue(RtpKeyframeDetector.isKeyframe(packet((byte)0x7c,(byte)0x85)));
        assertFalse(RtpKeyframeDetector.isKeyframe(packet((byte)0x41)));
    }

    @Test public void detectsH265IrapAndFuStart(){
        assertTrue(RtpKeyframeDetector.isKeyframe(packet((byte)(19<<1),(byte)1)));
        assertTrue(RtpKeyframeDetector.isKeyframe(packet((byte)(49<<1),(byte)1,(byte)(0x80|20))));
        assertFalse(RtpKeyframeDetector.isKeyframe(packet((byte)(1<<1),(byte)1)));
    }

    @Test public void honorsRtpExtensionLength(){assertTrue(RtpKeyframeDetector.isKeyframe(packet((byte)0x65)));}

    @Test public void codecSpecificDetectionAvoidsCrossCodecFalsePositives(){assertFalse(RtpKeyframeDetector.isKeyframe(packet((byte)0x65),true));assertFalse(RtpKeyframeDetector.isKeyframe(packet((byte)(19<<1),(byte)1),false));}

    private static byte[] packet(byte... payload){byte[] result=new byte[28+payload.length];result[0]=(byte)0x90;result[12]=(byte)0xab;result[13]=(byte)0xac;result[15]=3;System.arraycopy(payload,0,result,28,payload.length);return result;}
}
