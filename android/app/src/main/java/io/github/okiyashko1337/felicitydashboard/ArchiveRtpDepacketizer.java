package io.github.okiyashko1337.felicitydashboard;

import java.io.ByteArrayOutputStream;

/** Reassembles H.264/H.265 RTP into Annex-B access units. */
final class ArchiveRtpDepacketizer {
    interface Listener{void onAccessUnit(byte[] data,long archiveTimeMs,long rtpTimestamp,boolean keyframe);}
    private final boolean hevc;private final Listener listener;private final ByteArrayOutputStream access=new ByteArrayOutputStream(256*1024);private long timestamp=-1,archiveTime;private boolean keyframe;
    ArchiveRtpDepacketizer(boolean hevc,Listener listener){this.hevc=hevc;this.listener=listener;}
    void reset(){access.reset();timestamp=-1;archiveTime=0;keyframe=false;}
    void accept(byte[] packet){int offset=payloadOffset(packet);if(offset<0||offset>=packet.length)return;long next=read32(packet,4)&0xffffffffL;if(timestamp!=-1&&timestamp!=next)emit();timestamp=next;long utc=ReplayClock.fromRtp(packet);if(utc>0)archiveTime=utc;if(hevc)h265(packet,offset);else h264(packet,offset);if((packet[1]&0x80)!=0)emit();}
    private void emit(){if(access.size()>4&&listener!=null)listener.onAccessUnit(access.toByteArray(),archiveTime,timestamp,keyframe);access.reset();archiveTime=0;keyframe=false;}
    private void h264(byte[] p,int o){int type=p[o]&31;if(type>=1&&type<=23){nal(p,o,p.length-o);keyframe|=type==5;return;}if(type==24){int at=o+1;while(at+2<=p.length){int size=((p[at]&255)<<8)|(p[at+1]&255);at+=2;if(size<1||at+size>p.length)return;keyframe|=(p[at]&31)==5;nal(p,at,size);at+=size;}return;}if(type!=28||o+2>p.length)return;int fu=p[o+1]&255,fuType=fu&31;if((fu&0x80)!=0){start();access.write((p[o]&0xe0)|fuType);keyframe|=fuType==5;}access.write(p,o+2,p.length-o-2);}
    private void h265(byte[] p,int o){if(o+2>p.length)return;int type=(p[o]>>1)&63;if(type<48){nal(p,o,p.length-o);keyframe|=type>=16&&type<=23;return;}if(type==48){int at=o+2;while(at+2<=p.length){int size=((p[at]&255)<<8)|(p[at+1]&255);at+=2;if(size<2||at+size>p.length)return;int nested=(p[at]>>1)&63;keyframe|=nested>=16&&nested<=23;nal(p,at,size);at+=size;}return;}if(type!=49||o+3>p.length)return;int fu=p[o+2]&255,fuType=fu&63;if((fu&0x80)!=0){start();access.write((p[o]&0x81)|(fuType<<1));access.write(p[o+1]);keyframe|=fuType>=16&&fuType<=23;}access.write(p,o+3,p.length-o-3);}
    private void nal(byte[] value,int offset,int length){start();access.write(value,offset,length);}
    private void start(){access.write(0);access.write(0);access.write(0);access.write(1);}
    static int payloadOffset(byte[] p){if(p==null||p.length<12||(p[0]&0xc0)!=0x80)return -1;int offset=12+(p[0]&15)*4;if(offset>p.length)return -1;if((p[0]&16)!=0){if(offset+4>p.length)return -1;int words=((p[offset+2]&255)<<8)|(p[offset+3]&255);offset+=4+words*4;}if((p[0]&32)!=0&&offset<p.length){}return offset<=p.length?offset:-1;}
    private static int read32(byte[] v,int o){return ((v[o]&255)<<24)|((v[o+1]&255)<<16)|((v[o+2]&255)<<8)|(v[o+3]&255);}
}
