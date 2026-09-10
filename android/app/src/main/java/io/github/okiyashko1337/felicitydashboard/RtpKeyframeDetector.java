package io.github.okiyashko1337.felicitydashboard;

/** Detects H.264/H.265 random-access NAL units in an RTP packet. */
final class RtpKeyframeDetector {
    private RtpKeyframeDetector(){}

    static boolean isKeyframe(byte[] packet){
        int offset=payloadOffset(packet);if(offset<0||offset>=packet.length)return false;
        return h264(packet,offset)||h265(packet,offset);
    }
    static boolean isKeyframe(byte[] packet,boolean hevc){int offset=payloadOffset(packet);if(offset<0||offset>=packet.length)return false;return hevc?h265(packet,offset):h264(packet,offset);}

    static String summary(byte[] packet){int offset=payloadOffset(packet);if(offset<0||offset>=packet.length)return "invalid";StringBuilder out=new StringBuilder("offset=").append(offset).append(" bytes=");for(int i=offset;i<Math.min(packet.length,offset+8);i++)out.append(String.format(java.util.Locale.US,"%02x",packet[i]&255));int h264=packet[offset]&31,h265=(packet[offset]>>1)&63;return out.append(" h264=").append(h264).append(" h265=").append(h265).toString();}

    private static int payloadOffset(byte[] packet){
        if(packet==null||packet.length<13||(packet[0]&0xc0)!=0x80)return -1;
        int offset=12+(packet[0]&0x0f)*4;if(offset>packet.length)return -1;
        if((packet[0]&0x10)!=0){if(offset+4>packet.length)return -1;int words=((packet[offset+2]&255)<<8)|(packet[offset+3]&255);offset+=4+words*4;}
        return offset<=packet.length?offset:-1;
    }

    private static boolean h264(byte[] value,int offset){
        int type=value[offset]&31;if(type==5)return true;
        if(type==28&&offset+1<value.length)return (value[offset+1]&0x80)!=0&&(value[offset+1]&31)==5;
        if(type!=24)return false;
        int at=offset+1;while(at+2<value.length){int size=((value[at]&255)<<8)|(value[at+1]&255);at+=2;if(size<1||at+size>value.length)return false;if((value[at]&31)==5)return true;at+=size;}return false;
    }

    private static boolean h265(byte[] value,int offset){
        if(offset+1>=value.length)return false;int type=(value[offset]>>1)&63;if(type>=16&&type<=23)return true;
        if(type==49&&offset+2<value.length){int fu=value[offset+2]&255,fuType=fu&63;return (fu&0x80)!=0&&fuType>=16&&fuType<=23;}
        if(type!=48)return false;
        int at=offset+2;while(at+2<value.length){int size=((value[at]&255)<<8)|(value[at+1]&255);at+=2;if(size<2||at+size>value.length)return false;int nested=(value[at]>>1)&63;if(nested>=16&&nested<=23)return true;at+=size;}return false;
    }
}
