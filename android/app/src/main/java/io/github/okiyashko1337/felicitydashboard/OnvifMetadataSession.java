package io.github.okiyashko1337.felicitydashboard;

import android.util.Log;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.URI;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Reader for recorder metadata carried by the ONVIF Profile G replay RTP track. */
final class OnvifMetadataSession {
    interface Listener { void onFigure(OnvifMetadataDecoder.Figure figure); }
    private final String base,host,user,password;private final int port;private final long startMs;
    private final Listener listener;
    private volatile boolean stopped;private Thread thread;private Socket socket;private InputStream input;private OutputStream output;
    OnvifMetadataSession(String uri,String user,String password,long startMs,Listener listener){URI parsed=URI.create(uri);this.host=parsed.getHost();this.port=parsed.getPort()>0?parsed.getPort():554;this.base="rtsp://"+host+(port==554?"":":"+port)+parsed.getRawPath();this.user=user;this.password=password;this.startMs=startMs;this.listener=listener;}
    void start(){thread=new Thread(this::run,"onvif-metadata-rtsp");thread.start();}
    void stop(){stopped=true;close();}
    private void run(){try{socket=new Socket(host,port);socket.setSoTimeout(12000);input=new BufferedInputStream(socket.getInputStream(),65536);output=new BufferedOutputStream(socket.getOutputStream());Response first=request("DESCRIBE",base,1,"Accept: application/sdp\r\n",null);if(first.auth==null)throw new Exception("Digest challenge missing");Response described=request("DESCRIBE",base,2,"Accept: application/sdp\r\n",digest(first.auth,"DESCRIBE",base));if(described.code!=200)throw new Exception("DESCRIBE "+described.code);String track=metadataTrack(described.body);Response setup=request("SETUP",track,3,"Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nRequire: onvif-replay\r\n",digest(first.auth,"SETUP",track));if(setup.code!=200)throw new Exception("SETUP "+setup.code);String session=match(setup.head,"Session:\\s*([^;\\r\\n]+)");if(session==null)throw new Exception("Metadata session missing");Response play=request("PLAY",base,4,"Session: "+session+"\r\nRange: clock="+clock(startMs)+"-\r\nRate-Control: yes\r\nRequire: onvif-replay\r\n",digest(first.auth,"PLAY",base));if(play.code!=200)throw new Exception("PLAY "+play.code);ByteArrayOutputStream frame=new ByteArrayOutputStream();int frames=0;long deadline=System.currentTimeMillis()+12000;while(!stopped&&frames<150&&System.currentTimeMillis()<deadline){int marker=input.read();if(marker<0)break;if(marker!='$')continue;int channel=input.read(),hi=input.read(),lo=input.read();if(lo<0)break;byte[] packet=readFully((hi<<8)|lo);if(channel!=0)continue;int offset=payloadOffset(packet),end=payloadEnd(packet,offset);if(offset<0||offset>=end)continue;frame.write(packet,offset,end-offset);if((packet[1]&0x80)!=0){String xml=frame.toString("UTF-8");for(OnvifMetadataDecoder.Figure figure:OnvifMetadataDecoder.decodeXml(xml))if(listener!=null&&!figure.type().isEmpty())listener.onFigure(figure);frame.reset();frames++;}}}catch(Exception error){if(!stopped)Log.w("FelicityOnvifMetadata","metadata unavailable: "+error.getMessage());}finally{close();}}
    private Response request(String method,String uri,int cseq,String extra,String auth)throws Exception{StringBuilder value=new StringBuilder(method+" "+uri+" RTSP/1.0\r\nCSeq: "+cseq+"\r\nUser-Agent: Felicity-Metadata/1\r\n");if(auth!=null)value.append("Authorization: ").append(auth).append("\r\n");value.append(extra).append("\r\n");output.write(value.toString().getBytes("ISO-8859-1"));output.flush();ByteArrayOutputStream head=new ByteArrayOutputStream();int state=0,next;while((next=input.read())>=0){head.write(next);state=(state==0&&next=='\r')?1:(state==1&&next=='\n')?2:(state==2&&next=='\r')?3:(state==3&&next=='\n')?4:0;if(state==4)break;}String header=head.toString("ISO-8859-1"),length=match(header,"Content-Length:\\s*(\\d+)");byte[] body=length==null?new byte[0]:readFully(Integer.parseInt(length));String status=match(header,"RTSP/1.0\\s+(\\d+)");return new Response(status==null?0:Integer.parseInt(status),header,new String(body,"ISO-8859-1"),match(header,"WWW-Authenticate:\\s*Digest\\s+([^\\r\\n]+)"));}
    private String metadataTrack(String s)throws Exception{boolean metadata=false;for(String raw:s.replace("\r","").split("\n")){String line=raw.trim();if(line.startsWith("m="))metadata=line.startsWith("m=application");else if(metadata&&line.startsWith("a=control:")){String control=line.substring(10).trim();if(control.startsWith("rtsp://"))return control;if(control.startsWith("/"))return "rtsp://"+host+(port==554?"":":"+port)+control;return base+(base.endsWith("/")?"":"/")+control;}}throw new Exception("Metadata control missing from SDP");}
    private static int payloadOffset(byte[] packet){if(packet.length<12||(packet[0]&0xc0)!=0x80)return -1;int offset=12+4*(packet[0]&15);if((packet[0]&0x10)!=0){if(offset+4>packet.length)return -1;offset+=4+((((packet[offset+2]&255)<<8)|(packet[offset+3]&255))*4);}return offset;}
    private static int payloadEnd(byte[] packet,int offset){if(offset<0)return -1;int padding=(packet[0]&0x20)!=0&&packet.length>offset?packet[packet.length-1]&255:0;return padding<=packet.length-offset?packet.length-padding:-1;}
    private byte[] readFully(int length)throws Exception{byte[] result=new byte[length];int offset=0;while(offset<length){int count=input.read(result,offset,length-offset);if(count<0)throw new Exception("Unexpected RTSP EOF");offset+=count;}return result;}
    private String digest(String challenge,String method,String address)throws Exception{String realm=param(challenge,"realm"),nonce=param(challenge,"nonce"),ha1=md5(user+":"+realm+":"+password),ha2=md5(method+":"+address);return "Digest username=\""+user+"\", realm=\""+realm+"\", nonce=\""+nonce+"\", uri=\""+address+"\", response=\""+md5(ha1+":"+nonce+":"+ha2)+"\"";}
    private synchronized void close(){try{if(socket!=null){socket.close();socket=null;}}catch(Exception ignored){}}
    private static String clock(long time){SimpleDateFormat f=new SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'",Locale.US);f.setTimeZone(TimeZone.getTimeZone("UTC"));return f.format(new Date(time));}
    private static String param(String s,String name){Matcher m=Pattern.compile(name+"=\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):"";}private static String match(String s,String re){Matcher m=Pattern.compile(re,Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):null;}private static String md5(String s)throws Exception{byte[] bytes=MessageDigest.getInstance("MD5").digest(s.getBytes("ISO-8859-1"));StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format(Locale.US,"%02x",b&255));return out.toString();}
    private static final class Response{final int code;final String head,body,auth;Response(int code,String head,String body,String auth){this.code=code;this.head=head;this.body=body;this.auth=auth;}}
}
