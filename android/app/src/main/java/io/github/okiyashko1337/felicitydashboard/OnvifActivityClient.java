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
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Fast, metadata-only activity query over an ONVIF Profile G replay URI. */
final class OnvifActivityClient {
    private static final String ACTIVITY_FILTER_HEADER=new String(new byte[]{88,45,65,106,97,120,45,77,101,116,97,100,97,116,97,45,70,105,108,116,101,114,58,32,65},StandardCharsets.US_ASCII);
    private final String base,host,user,password;private final int port;private Socket socket;private InputStream input;private OutputStream output;

    OnvifActivityClient(String uri,String user,String password){URI parsed=URI.create(uri);host=parsed.getHost();port=parsed.getPort()>0?parsed.getPort():554;base="rtsp://"+host+(port==554?"":":"+port)+parsed.getRawPath();this.user=user;this.password=password;}

    List<OnvifMetadataDecoder.Activity> fetch(long startMs,long endMs)throws Exception{
        ArrayList<OnvifMetadataDecoder.Activity> found=new ArrayList<>();
        try{
            socket=new Socket(host,port);socket.setSoTimeout(1200);input=new BufferedInputStream(socket.getInputStream(),65536);output=new BufferedOutputStream(socket.getOutputStream());
            Response first=request("DESCRIBE",base,1,"Accept: application/sdp\r\n",null);if(first.auth==null)throw new Exception("Digest challenge missing");
            Response described=request("DESCRIBE",base,2,"Accept: application/sdp\r\n",digest(first.auth,"DESCRIBE",base));if(described.code!=200)throw new Exception("DESCRIBE "+described.code);
            String track=metadataTrack(described.body);Response setup=request("SETUP",track,3,"Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nRequire: onvif-replay\r\n",digest(first.auth,"SETUP",track));if(setup.code!=200)throw new Exception("SETUP "+setup.code);
            String session=match(setup.head,"Session:\\s*([^;\\r\\n]+)");if(session==null)throw new Exception("Metadata session missing");
            String headers="Session: "+session+"\r\nRange: clock="+clock(startMs)+"-"+clock(endMs)+"\r\nRate-Control: no\r\n"+ACTIVITY_FILTER_HEADER+"\r\nRequire: onvif-replay\r\n";
            Response play=request("PLAY",base,4,headers,digest(first.auth,"PLAY",base));if(play.code!=200)throw new Exception("PLAY "+play.code);
            ByteArrayOutputStream frame=new ByteArrayOutputStream();
            try{
                while(true){int marker=input.read();if(marker<0)break;if(marker!='$')continue;int channel=input.read(),hi=input.read(),lo=input.read();if(lo<0)break;byte[] packet=readFully((hi<<8)|lo);if(channel==1&&isRtcpBye(packet))break;if(channel!=0)continue;int offset=payloadOffset(packet),end=payloadEnd(packet,offset);if(offset<0||offset>=end)continue;frame.write(packet,offset,end-offset);if((packet[1]&0x80)!=0){found.addAll(OnvifMetadataDecoder.decodeActivitiesXml(frame.toString("UTF-8")));frame.reset();}}
            }catch(SocketTimeoutException complete){/* The recorder sends the closed range as a compact batch, then goes idle. */}
        }finally{close();}
        Collections.sort(found,(left,right)->Long.compare(left.timeMs,right.timeMs));return deduplicate(found);
    }

    private static List<OnvifMetadataDecoder.Activity> deduplicate(List<OnvifMetadataDecoder.Activity> source){ArrayList<OnvifMetadataDecoder.Activity> result=new ArrayList<>();for(OnvifMetadataDecoder.Activity candidate:source){OnvifMetadataDecoder.Activity previous=result.isEmpty()?null:result.get(result.size()-1);if(previous!=null&&previous.typeMask==candidate.typeMask&&Math.abs(candidate.timeMs-previous.timeMs)<=250)continue;result.add(candidate);}return result;}
    private Response request(String method,String uri,int cseq,String extra,String auth)throws Exception{StringBuilder value=new StringBuilder(method+" "+uri+" RTSP/1.0\r\nCSeq: "+cseq+"\r\nUser-Agent: Felicity-Activity/1\r\n");if(auth!=null)value.append("Authorization: ").append(auth).append("\r\n");value.append(extra).append("\r\n");output.write(value.toString().getBytes("ISO-8859-1"));output.flush();ByteArrayOutputStream head=new ByteArrayOutputStream();int state=0,next;while((next=input.read())>=0){head.write(next);state=(state==0&&next=='\r')?1:(state==1&&next=='\n')?2:(state==2&&next=='\r')?3:(state==3&&next=='\n')?4:0;if(state==4)break;}String header=head.toString("ISO-8859-1"),length=match(header,"Content-Length:\\s*(\\d+)");byte[] body=length==null?new byte[0]:readFully(Integer.parseInt(length));String status=match(header,"RTSP/1.0\\s+(\\d+)");return new Response(status==null?0:Integer.parseInt(status),header,new String(body,"ISO-8859-1"),match(header,"WWW-Authenticate:\\s*Digest\\s+([^\\r\\n]+)"));}
    private String metadataTrack(String s)throws Exception{boolean metadata=false;for(String raw:s.replace("\r","").split("\n")){String line=raw.trim();if(line.startsWith("m="))metadata=line.startsWith("m=application");else if(metadata&&line.startsWith("a=control:")){String control=line.substring(10).trim();if(control.startsWith("rtsp://"))return control;if(control.startsWith("/"))return "rtsp://"+host+(port==554?"":":"+port)+control;return base+(base.endsWith("/")?"":"/")+control;}}throw new Exception("Metadata control missing from SDP");}
    private static int payloadOffset(byte[] packet){if(packet.length<12||(packet[0]&0xc0)!=0x80)return -1;int offset=12+4*(packet[0]&15);if((packet[0]&0x10)!=0){if(offset+4>packet.length)return -1;offset+=4+((((packet[offset+2]&255)<<8)|(packet[offset+3]&255))*4);}return offset;}
    private static int payloadEnd(byte[] packet,int offset){if(offset<0)return -1;int padding=(packet[0]&0x20)!=0&&packet.length>offset?packet[packet.length-1]&255:0;return padding<=packet.length-offset?packet.length-padding:-1;}
    private static boolean isRtcpBye(byte[] packet){for(int offset=0;offset+4<=packet.length;){int type=packet[offset+1]&255,length=((((packet[offset+2]&255)<<8)|(packet[offset+3]&255))+1)*4;if(type==203)return true;if(length<4||offset+length>packet.length)return false;offset+=length;}return false;}
    private byte[] readFully(int length)throws Exception{byte[] result=new byte[length];int offset=0;while(offset<length){int count=input.read(result,offset,length-offset);if(count<0)throw new Exception("Unexpected RTSP EOF");offset+=count;}return result;}
    private String digest(String challenge,String method,String address)throws Exception{String realm=param(challenge,"realm"),nonce=param(challenge,"nonce"),ha1=md5(user+":"+realm+":"+password),ha2=md5(method+":"+address);return "Digest username=\""+user+"\", realm=\""+realm+"\", nonce=\""+nonce+"\", uri=\""+address+"\", response=\""+md5(ha1+":"+nonce+":"+ha2)+"\"";}
    private void close(){try{if(socket!=null)socket.close();}catch(Exception ignored){}socket=null;}
    private static String clock(long time){SimpleDateFormat f=new SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'",Locale.US);f.setTimeZone(TimeZone.getTimeZone("UTC"));return f.format(new Date(time));}
    private static String param(String s,String name){Matcher m=Pattern.compile(name+"=\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):"";}
    private static String match(String s,String re){Matcher m=Pattern.compile(re,Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):null;}
    private static String md5(String s)throws Exception{byte[] bytes=MessageDigest.getInstance("MD5").digest(s.getBytes("ISO-8859-1"));StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format(Locale.US,"%02x",b&255));return out.toString();}
    private static final class Response{final int code;final String head,body,auth;Response(int code,String head,String body,String auth){this.code=code;this.head=head;this.body=body;this.auth=auth;}}
}
