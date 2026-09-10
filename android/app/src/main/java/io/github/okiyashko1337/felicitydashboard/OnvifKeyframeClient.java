package io.github.okiyashko1337.felicitydashboard;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Direct, decoder-free keyframe index query against an ONVIF Profile G replay URI. */
final class OnvifKeyframeClient {
    private final String base,host,user,password;private final int port;private Socket socket;private InputStream input;private OutputStream output;
    OnvifKeyframeClient(String uri,String user,String password){URI parsed=URI.create(uri);host=parsed.getHost();port=parsed.getPort()>0?parsed.getPort():554;base="rtsp://"+host+(port==554?"":":"+port)+parsed.getRawPath();this.user=user;this.password=password;}

    List<Long> fetch(long startMs,long endMs)throws Exception{
        ArrayList<Long> found=new ArrayList<>();
        try{
            socket=new Socket(host,port);socket.setSoTimeout(2000);input=new BufferedInputStream(socket.getInputStream(),256*1024);output=new BufferedOutputStream(socket.getOutputStream());
            Response first=request("DESCRIBE",base,1,"Accept: application/sdp\r\n",null);if(first.auth==null)throw new Exception("Digest challenge missing");
            Response described=request("DESCRIBE",base,2,"Accept: application/sdp\r\n",digest(first.auth,"DESCRIBE",base));if(described.code!=200)throw new Exception("DESCRIBE "+described.code);
            String track=videoTrack(described.body);boolean hevc=described.body.toUpperCase(Locale.US).contains("H265")||described.body.toUpperCase(Locale.US).contains("HEVC");Response setup=request("SETUP",track,3,"Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nRequire: onvif-replay\r\n",digest(first.auth,"SETUP",track));if(setup.code!=200)throw new Exception("SETUP "+setup.code);
            String session=match(setup.head,"Session:\\s*([^;\\r\\n]+)");if(session==null)throw new Exception("Video session missing");
            String headers="Session: "+session+"\r\nRange: clock="+clock(startMs)+"-"+clock(endMs)+"\r\nRate-Control: no\r\nRequire: onvif-replay\r\n";Response play=request("PLAY",base,4,headers,digest(first.auth,"PLAY",base));if(play.code!=200)throw new Exception("PLAY "+play.code);
            long frameRtp=-1,frameTime=0;boolean frameIsKey=false;
            try{while(true){
                int marker=input.read();if(marker<0)break;if(marker!='$')continue;int channel=input.read(),hi=input.read(),lo=input.read();if(lo<0)break;byte[] packet=readFully((hi<<8)|lo);if(channel==1&&isRtcpBye(packet))break;if(channel!=0||packet.length<12)continue;
                long rtp=rtpTimestamp(packet);if(frameRtp!=rtp){frameRtp=rtp;frameTime=0;frameIsKey=false;}long absolute=ReplayClock.fromRtp(packet);if(absolute>0)frameTime=absolute;if(RtpKeyframeDetector.isKeyframe(packet,hevc))frameIsKey=true;
                if((packet[1]&0x80)!=0){if(frameIsKey&&frameTime>=startMs&&frameTime<=endMs&&(found.isEmpty()||found.get(found.size()-1)!=frameTime))found.add(frameTime);frameRtp=-1;frameTime=0;frameIsKey=false;}
            }}catch(SocketTimeoutException complete){/* Closed replay ranges may finish by going idle. */}
        }finally{close();}
        return found;
    }

    private Response request(String method,String uri,int cseq,String extra,String auth)throws Exception{StringBuilder value=new StringBuilder(method+" "+uri+" RTSP/1.0\r\nCSeq: "+cseq+"\r\nUser-Agent: Felicity-Keyframes/1\r\n");if(auth!=null)value.append("Authorization: ").append(auth).append("\r\n");value.append(extra).append("\r\n");output.write(value.toString().getBytes("ISO-8859-1"));output.flush();ByteArrayOutputStream head=new ByteArrayOutputStream();int state=0,next;while((next=input.read())>=0){head.write(next);state=(state==0&&next=='\r')?1:(state==1&&next=='\n')?2:(state==2&&next=='\r')?3:(state==3&&next=='\n')?4:0;if(state==4)break;}String header=head.toString("ISO-8859-1"),length=match(header,"Content-Length:\\s*(\\d+)");byte[] body=length==null?new byte[0]:readFully(Integer.parseInt(length));String status=match(header,"RTSP/1.0\\s+(\\d+)");return new Response(status==null?0:Integer.parseInt(status),header,new String(body,"ISO-8859-1"),match(header,"WWW-Authenticate:\\s*Digest\\s+([^\\r\\n]+)"));}
    private String videoTrack(String s)throws Exception{boolean video=false;for(String raw:s.replace("\r","").split("\n")){String line=raw.trim();if(line.startsWith("m="))video=line.startsWith("m=video");else if(video&&line.startsWith("a=control:")){String control=line.substring(10).trim();if(control.startsWith("rtsp://"))return control;if(control.startsWith("/"))return "rtsp://"+host+(port==554?"":":"+port)+control;return base+(base.endsWith("/")?"":"/")+control;}}throw new Exception("Video control missing from SDP");}
    private static boolean isRtcpBye(byte[] packet){for(int offset=0;offset+4<=packet.length;){int type=packet[offset+1]&255,length=((((packet[offset+2]&255)<<8)|(packet[offset+3]&255))+1)*4;if(type==203)return true;if(length<4||offset+length>packet.length)return false;offset+=length;}return false;}
    private static long rtpTimestamp(byte[] packet){return ((packet[4]&255L)<<24)|((packet[5]&255L)<<16)|((packet[6]&255L)<<8)|(packet[7]&255L);}
    private byte[] readFully(int length)throws Exception{byte[] result=new byte[length];int offset=0;while(offset<length){int count=input.read(result,offset,length-offset);if(count<0)throw new Exception("Unexpected RTSP EOF");offset+=count;}return result;}
    private String digest(String challenge,String method,String address)throws Exception{String realm=param(challenge,"realm"),nonce=param(challenge,"nonce"),ha1=md5(user+":"+realm+":"+password),ha2=md5(method+":"+address);return "Digest username=\""+user+"\", realm=\""+realm+"\", nonce=\""+nonce+"\", uri=\""+address+"\", response=\""+md5(ha1+":"+nonce+":"+ha2)+"\"";}
    private void close(){try{if(socket!=null)socket.close();}catch(Exception ignored){}socket=null;}
    private static String clock(long time){SimpleDateFormat f=new SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'",Locale.US);f.setTimeZone(TimeZone.getTimeZone("UTC"));return f.format(new Date(time));}
    private static String param(String s,String name){Matcher m=Pattern.compile(name+"=\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):"";}
    private static String match(String s,String re){Matcher m=Pattern.compile(re,Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):null;}
    private static String md5(String s)throws Exception{byte[] bytes=MessageDigest.getInstance("MD5").digest(s.getBytes("ISO-8859-1"));StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format(Locale.US,"%02x",b&255));return out.toString();}
    private static final class Response{final int code;final String head,body,auth;Response(int code,String head,String body,String auth){this.code=code;this.head=head;this.body=body;this.auth=auth;}}
}
