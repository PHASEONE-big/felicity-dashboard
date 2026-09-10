package io.github.okiyashko1337.felicitydashboard;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.util.Log;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.URI;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Receives the ONVIF camera's G.722 RTP track and decodes it for Android audio output. */
final class OnvifAudioSession {
    private static final String TAG="OnvifAudio";
    private final Context context;
    private final String base,host,user,password;
    private final int port;
    private volatile boolean stopped;
    private volatile int volume;
    private Thread thread;
    private Socket socket;
    private InputStream input;
    private OutputStream output;
    private AudioTrack player;private final G722Decoder decoder=new G722Decoder();

    OnvifAudioSession(Context context,String streamUri,String user,String password){
        this.context=context.getApplicationContext();this.user=user;this.password=password;
        URI parsed=URI.create(streamUri);host=parsed.getHost();port=parsed.getPort()>0?parsed.getPort():554;
        String authority=host+(parsed.getPort()>0?":"+parsed.getPort():"");base="rtsp://"+authority+parsed.getRawPath();
    }
    void start(){thread=new Thread(this::run,"onvif-listen-rtsp");thread.start();}
    void setVolume(int value){volume=value;AudioTrack current=player;if(current!=null)current.setVolume(value/100f);}
    void stop(){stopped=true;close();}

    private void run(){
        try{
            socket=new Socket(host,port);socket.setSoTimeout(10000);
            input=new BufferedInputStream(socket.getInputStream(),32768);output=new BufferedOutputStream(socket.getOutputStream());
            Response first=request("DESCRIBE",base,1,"Accept: application/sdp\r\n",null);
            if(first.auth==null)throw new Exception("Digest challenge missing");
            Response described=request("DESCRIBE",base,2,"Accept: application/sdp\r\n",digest(first.auth,"DESCRIBE",base));
            if(described.code!=200)throw new Exception("DESCRIBE "+described.code);Log.i(TAG,"audio SDP accepted");
            String track=audioTrack(described.body);
            Response setup=request("SETUP",track,3,"Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n",digest(first.auth,"SETUP",track));
            if(setup.code!=200)throw new Exception("SETUP "+setup.code);Log.i(TAG,"audio RTP track set up");
            String session=match(setup.head,"Session:\\s*([^;\\r\\n]+)");if(session==null)throw new Exception("Audio session missing");
            openDecoder();
            Response play=request("PLAY",base,4,"Session: "+session+"\r\nRange: npt=0.000-\r\n",digest(first.auth,"PLAY",base));
            if(play.code!=200)throw new Exception("PLAY "+play.code);Log.i(TAG,"audio RTP playing");
            boolean firstPacket=true;while(!stopped){int marker=input.read();if(marker<0)break;if(marker!='$')continue;int channel=input.read(),hi=input.read(),lo=input.read();if(lo<0)break;int length=(hi<<8)|lo;byte[] packet=readFully(length);if(channel==0){writeRtpPayload(packet);if(firstPacket){firstPacket=false;Log.i(TAG,"first G.722 RTP packet decoded");}}}
        }catch(Exception error){if(!stopped)Log.e(TAG,"receive path failed: "+error.getMessage(),error);}finally{close();}
    }

    private void openDecoder()throws Exception{
        int minimum=AudioTrack.getMinBufferSize(16000,AudioFormat.CHANNEL_OUT_MONO,AudioFormat.ENCODING_PCM_16BIT);player=new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()).setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()).setBufferSizeInBytes(Math.max(minimum,8192)).setTransferMode(AudioTrack.MODE_STREAM).build();if(player.getState()!=AudioTrack.STATE_INITIALIZED)throw new Exception("AudioTrack unavailable");player.setVolume(volume/100f);player.play();Log.i(TAG,"G.722 decoder and AudioTrack started");
    }

    private void writeRtpPayload(byte[] packet){
        if(packet.length<12||(packet[0]&0xc0)!=0x80)return;int offset=12+4*(packet[0]&15);if((packet[0]&0x10)!=0){if(offset+4>packet.length)return;int extensionWords=((packet[offset+2]&255)<<8)|(packet[offset+3]&255);offset+=4+extensionWords*4;}int end=packet.length;if((packet[0]&0x20)!=0&&end>offset)end-=packet[end-1]&255;if(offset<end){short[] pcm=new short[(end-offset)*2];int count=decoder.decode(packet,offset,end-offset,pcm);player.write(pcm,0,count,AudioTrack.WRITE_BLOCKING);}
    }

    private Response request(String method,String uri,int cseq,String extra,String auth)throws Exception{
        StringBuilder request=new StringBuilder(method+" "+uri+" RTSP/1.0\r\nCSeq: "+cseq+"\r\nUser-Agent: Felicity-Android/0.15\r\n");if(auth!=null)request.append("Authorization: ").append(auth).append("\r\n");request.append(extra).append("\r\n");output.write(request.toString().getBytes("ISO-8859-1"));output.flush();ByteArrayOutputStream header=new ByteArrayOutputStream();int state=0,value;while((value=input.read())>=0){header.write(value);state=(state==0&&value=='\r')?1:(state==1&&value=='\n')?2:(state==2&&value=='\r')?3:(state==3&&value=='\n')?4:0;if(state==4)break;}String head=header.toString("ISO-8859-1");String length=match(head,"Content-Length:\\s*(\\d+)");byte[] body=length==null?new byte[0]:readFully(Integer.parseInt(length));String status=match(head,"RTSP/1.0\\s+(\\d+)");return new Response(status==null?0:Integer.parseInt(status),head,new String(body,"ISO-8859-1"),match(head,"WWW-Authenticate:\\s*Digest\\s+([^\\r\\n]+)"));
    }
    private String audioTrack(String s)throws Exception{String[] lines=s.replace("\r","").split("\n");boolean audio=false;for(String raw:lines){String line=raw.trim();if(line.startsWith("m="))audio=line.startsWith("m=audio");else if(audio&&line.startsWith("a=control:")){String control=line.substring(10).trim();if(control.startsWith("rtsp://"))return control;if(control.startsWith("/"))return "rtsp://"+host+(port==554?"":":"+port)+control;return base+(base.endsWith("/")?"":"/")+control;}}throw new Exception("G.722 audio control missing from SDP");}
    private byte[] readFully(int length)throws Exception{byte[] data=new byte[length];int offset=0;while(offset<length){int count=input.read(data,offset,length-offset);if(count<0)throw new Exception("Unexpected RTSP EOF");offset+=count;}return data;}
    private String digest(String challenge,String method,String address)throws Exception{String realm=param(challenge,"realm"),nonce=param(challenge,"nonce"),ha1=md5(user+":"+realm+":"+password),ha2=md5(method+":"+address);return "Digest username=\""+user+"\", realm=\""+realm+"\", nonce=\""+nonce+"\", uri=\""+address+"\", response=\""+md5(ha1+":"+nonce+":"+ha2)+"\"";}
    private synchronized void close(){try{if(socket!=null){socket.close();socket=null;}}catch(Exception ignored){}AudioTrack current=player;player=null;if(current!=null){try{current.pause();current.flush();current.stop();}catch(Exception ignored){}current.release();}}
    private static String param(String s,String name){Matcher m=Pattern.compile(name+"=\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):"";}private static String match(String s,String re){Matcher m=Pattern.compile(re,Pattern.CASE_INSENSITIVE).matcher(s);return m.find()?m.group(1):null;}private static String md5(String s)throws Exception{byte[] digest=MessageDigest.getInstance("MD5").digest(s.getBytes("ISO-8859-1"));StringBuilder result=new StringBuilder();for(byte value:digest)result.append(String.format(Locale.US,"%02x",value&255));return result.toString();}
    private static final class Response{final int code;final String head,body,auth;Response(int code,String head,String body,String auth){this.code=code;this.head=head;this.body=body;this.auth=auth;}}
}
