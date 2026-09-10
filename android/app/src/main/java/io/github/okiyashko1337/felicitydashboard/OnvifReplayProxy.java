package io.github.okiyashko1337.felicitydashboard;

import android.net.Uri;
import android.util.Log;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class OnvifReplayProxy implements Closeable {
    private static final AtomicInteger ACTIVE=new AtomicInteger();
    private final String upstream,user,password,upstreamBase;
    private volatile long startMs;private final long stopAtMs;private volatile boolean rateControlled,intraOnly;
    private final ServerSocket server;
    private final ExecutorService threads=Executors.newCachedThreadPool();
    private final ScheduledExecutorService keepAlive=Executors.newSingleThreadScheduledExecutor();
    private volatile String challenge="",localBase="",playCseq="",session="",playUri="",injectedPlayCseq="",injectedPauseCseq="",keepaliveCseq="";private volatile boolean closed,targetFrameReached,replayCapped,injectedSeekWaiting,injectedSeekReady,pauseAfterFrame,pauseSent,keyframeSeenForPause,upstreamPaused,pausedHold,hevc,awaitingRtpAnchor;private volatile long firstPacketTimeMs,latestPacketTimeMs,rangeStartTimeMs,cappedFrameTimeMs,keyframeAtOrBeforeMs,seekIssuedAt,rtpTimestampOffset;private final List<Long> keyframes=new ArrayList<>();private int probeSamples,injectedCseq=900000,framesAfterKeyframe,injectedPlayAuthRetries,injectedPauseAuthRetries,holdGeneration,lastRtpTimestamp,lastRtpSsrc,lastRtpSequence,lastRtpPayloadType,rtpSequenceOffset;private long forwardedPackets,forwardedOctets;private Socket client,remote;private OutputStream remoteOut,clientOut;

    OnvifReplayProxy(String upstream,String user,String password,long startMs)throws Exception{this(upstream,user,password,startMs,true,0,false);}
    OnvifReplayProxy(String upstream,String user,String password,long startMs,boolean rateControlled)throws Exception{this(upstream,user,password,startMs,rateControlled,0,false);}
    OnvifReplayProxy(String upstream,String user,String password,long startMs,boolean rateControlled,long stopAtMs)throws Exception{this(upstream,user,password,startMs,rateControlled,stopAtMs,false);}
    OnvifReplayProxy(String upstream,String user,String password,long startMs,boolean rateControlled,long stopAtMs,boolean intraOnly)throws Exception{
        this.upstream=upstream;this.user=user;this.password=password;this.startMs=startMs;this.rateControlled=rateControlled;this.stopAtMs=stopAtMs;this.intraOnly=intraOnly;
        URI parsed=new URI(upstream);int port=parsed.getPort()>0?parsed.getPort():554;this.upstreamBase="rtsp://"+parsed.getHost()+":"+port;
        server=new ServerSocket(0,1,java.net.InetAddress.getByName("127.0.0.1"));Log.i("FelicityReplay","Proxy opened · active="+ACTIVE.incrementAndGet());
    }

    String start(){localBase="rtsp://127.0.0.1:"+server.getLocalPort();threads.execute(this::accept);return "rtsp://"+Uri.encode(user)+":"+Uri.encode(password)+"@127.0.0.1:"+server.getLocalPort()+"/replay";}

    synchronized boolean seek(long time,boolean controlled,boolean onlyIntra){
        pausedHold=false;holdGeneration++;startMs=time;rateControlled=controlled;intraOnly=onlyIntra;firstPacketTimeMs=0;latestPacketTimeMs=0;rangeStartTimeMs=0;
        if(remoteOut==null||session.isEmpty()||playUri.isEmpty()||challenge.isEmpty())return false;
        try{
            injectedSeekWaiting=true;injectedSeekReady=false;injectedPlayAuthRetries=0;injectedPauseAuthRetries=0;pauseAfterFrame=false;pauseSent=false;keyframeSeenForPause=false;framesAfterKeyframe=0;awaitingRtpAnchor=true;seekIssuedAt=android.os.SystemClock.elapsedRealtime();injectedPlayCseq="";
            if(upstreamPaused){Log.i("FelicityReplay","Injected seek reuses paused transport · "+clock(time));return playAfterPause();}
            int pauseCseq=++injectedCseq;injectedPauseCseq=Integer.toString(pauseCseq);String request="PAUSE "+playUri+" RTSP/1.0\r\nCSeq: "+pauseCseq+"\r\nSession: "+session+"\r\nAuthorization: "+digest(challenge,"PAUSE",playUri)+"\r\n\r\n";
            synchronized(remoteOut){remoteOut.write(request.getBytes("ISO-8859-1"));remoteOut.flush();}
            Log.i("FelicityReplay","Injected ONVIF PAUSE for seek · "+clock(time)+" · cseq="+pauseCseq);return true;
        }catch(Exception error){injectedSeekWaiting=false;Log.w("FelicityReplay","Injected seek failed · "+error.getClass().getSimpleName()+": "+error.getMessage());return false;}
    }

    private boolean playAfterPause(){try{int cseq=++injectedCseq;injectedPlayCseq=Integer.toString(cseq);String request="PLAY "+playUri+" RTSP/1.0\r\nCSeq: "+cseq+"\r\nSession: "+session+"\r\nRequire: onvif-replay\r\nRange: clock="+clock(startMs)+"-\r\nRate-Control: "+(rateControlled?"yes":"no")+"\r\nFrames: "+(intraOnly?"intra":"all")+"\r\nImmediate: yes\r\nScale: 1.0\r\nAuthorization: "+digest(challenge,"PLAY",playUri)+"\r\n\r\n";synchronized(remoteOut){remoteOut.write(request.getBytes("ISO-8859-1"));remoteOut.flush();}Log.i("FelicityReplay","Injected ONVIF PLAY after PAUSE · "+clock(startMs)+" · cseq="+cseq);return true;}catch(Exception error){injectedSeekWaiting=false;Log.w("FelicityReplay","Injected PLAY failed · "+error.getClass().getSimpleName());return false;}}

    private void pauseUpstreamAfterFrame(){if(pauseSent||remoteOut==null||session.isEmpty()||playUri.isEmpty())return;pauseSent=true;try{int cseq=++injectedCseq;injectedPauseCseq=Integer.toString(cseq);String request="PAUSE "+playUri+" RTSP/1.0\r\nCSeq: "+cseq+"\r\nSession: "+session+"\r\nAuthorization: "+digest(challenge,"PAUSE",playUri)+"\r\n\r\n";synchronized(remoteOut){remoteOut.write(request.getBytes("ISO-8859-1"));remoteOut.flush();}Log.i("FelicityReplay","Injected PAUSE after clean frame · cseq="+cseq);}catch(Exception error){Log.w("FelicityReplay","Injected pause failed · "+error.getClass().getSimpleName());}}
    synchronized void pause(){pausedHold=true;int generation=++holdGeneration;injectedPauseAuthRetries=0;pauseAfterFrame=false;pauseUpstreamAfterFrame();schedulePausedKeepalive(generation,1000);}

    /** Keeps both RTSP endpoints alive while absolutely no video is requested from the NVR. */
    private void schedulePausedKeepalive(int generation,long delayMs){keepAlive.schedule(()->pausedKeepalive(generation),delayMs,TimeUnit.MILLISECONDS);}
    private synchronized void pausedKeepalive(int generation){
        if(closed||!pausedHold||generation!=holdGeneration)return;
        if(upstreamPaused)sendUpstreamKeepalive();
        sendDownstreamTransportKeepalive();
        schedulePausedKeepalive(generation,4000);
    }
    private void sendUpstreamKeepalive(){
        if(remoteOut==null||session.isEmpty()||playUri.isEmpty())return;
        try{int cseq=++injectedCseq;keepaliveCseq=Integer.toString(cseq);String authorization=challenge.isEmpty()?"":"Authorization: "+digest(challenge,"GET_PARAMETER",playUri)+"\r\n";String request="GET_PARAMETER "+playUri+" RTSP/1.0\r\nCSeq: "+cseq+"\r\nSession: "+session+"\r\n"+authorization+"Content-Length: 0\r\n\r\n";synchronized(remoteOut){remoteOut.write(request.getBytes("ISO-8859-1"));remoteOut.flush();}Log.d("FelicityReplay","Paused RTSP keepalive · cseq="+cseq);}catch(Exception error){Log.w("FelicityReplay","Paused keepalive failed · "+error.getClass().getSimpleName());}
    }
    private void sendDownstreamTransportKeepalive(){
        OutputStream out=clientOut;if(out==null||lastRtpSsrc==0)return;
        try{byte[] rtp=rtpFillerKeepalive(lastRtpSsrc,lastRtpTimestamp,nextInjectedSequence(),lastRtpPayloadType,hevc),report=rtcpSenderReport(lastRtpSsrc,lastRtpTimestamp,forwardedPackets,forwardedOctets,System.currentTimeMillis());synchronized(out){writeInterleaved(out,0,rtp);writeInterleaved(out,1,report);out.flush();}Log.d("FelicityReplay","Paused filler/RTCP keepalive · frame=0 · codec="+(hevc?"H265":"H264")+" · packets="+forwardedPackets);}catch(Exception error){Log.w("FelicityReplay","Paused transport keepalive failed · "+error.getClass().getSimpleName());}
    }
    private static void writeInterleaved(OutputStream out,int channel,byte[] packet)throws Exception{out.write('$');out.write(channel);out.write((packet.length>>>8)&255);out.write(packet.length&255);out.write(packet);}

    private void accept(){try{client=server.accept();URI parsed=new URI(upstream);remote=new Socket();remote.connect(new java.net.InetSocketAddress(parsed.getHost(),parsed.getPort()>0?parsed.getPort():554),5000);remote.setTcpNoDelay(true);client.setTcpNoDelay(true);remoteOut=remote.getOutputStream();clientOut=client.getOutputStream();threads.execute(()->relay(client,remote,true));relay(remote,client,false);}catch(Exception ignored){close();}}

    private void relay(Socket from,Socket to,boolean requestDirection){
        try{
            InputStream in=from.getInputStream();OutputStream out=to.getOutputStream();
            while(!closed){
                int first=in.read();if(first<0)break;
                if(first=='$'){
                    byte[] prefix=new byte[3];readFully(in,prefix);int length=((prefix[1]&255)<<8)|(prefix[2]&255);byte[] payload=new byte[length];readFully(in,payload);boolean capAfter=false;
                    if(!requestDirection){
                        if(injectedSeekWaiting&&!injectedSeekReady)continue;
                        int channel=prefix[0]&255;if(channel==0){translateRtpSequence(payload);observeReplayTime(payload);observeRtpCounters(payload);}
                        if(stopAtMs>0&&channel==0){long packetTime=ReplayClock.fromRtp(payload);if(packetTime>0&&probeSamples++<16)Log.i("FelicityReplay","Probe NAL · "+RtpKeyframeDetector.summary(payload));if(packetTime>0&&packetTime<=stopAtMs&&RtpKeyframeDetector.isKeyframe(payload)){keyframeAtOrBeforeMs=packetTime;synchronized(keyframes){if(keyframes.isEmpty()||keyframes.get(keyframes.size()-1)!=packetTime)keyframes.add(packetTime);}}if(packetTime>=stopAtMs){targetFrameReached=true;cappedFrameTimeMs=packetTime;}capAfter=targetFrameReached&&payload.length>1&&(payload[1]&0x80)!=0;}
                        if(pauseAfterFrame&&channel==0){if(RtpKeyframeDetector.isKeyframe(payload))keyframeSeenForPause=true;if(keyframeSeenForPause&&!pauseSent&&payload.length>1&&(payload[1]&0x80)!=0&&++framesAfterKeyframe>=(intraOnly?1:8))pauseUpstreamAfterFrame();}
                    }
                    if(stopAtMs<=0){synchronized(out){out.write(first);out.write(prefix);out.write(payload);out.flush();}}
                    if(capAfter){replayCapped=true;Log.i("FelicityReplay","RTSP probe complete · target="+stopAtMs+" · keyframe="+keyframeAtOrBeforeMs);while(!closed)Thread.sleep(25);break;}
                    continue;
                }
                byte[] header=readHeader(in,first);String text=new String(header,"ISO-8859-1");int length=contentLength(text);byte[] body=new byte[length];readFully(in,body);String bodyText=length==0?"":new String(body,"ISO-8859-1");if(!requestDirection&&!bodyText.isEmpty()){String upper=bodyText.toUpperCase(Locale.US);if(upper.contains("H265")||upper.contains("HEVC"))hevc=true;else if(upper.contains("H264"))hevc=false;}String rewritten=requestDirection?rewriteRequest(text):rewriteResponse(text);if(rewritten==null)continue;bodyText=requestDirection?toUpstream(bodyText):toLocal(bodyText);rewritten=setContentLength(rewritten,bodyText.getBytes("ISO-8859-1").length);synchronized(out){out.write(rewritten.getBytes("ISO-8859-1"));out.write(bodyText.getBytes("ISO-8859-1"));out.flush();}
            }
        }catch(Exception error){if(!closed)Log.w("FelicityReplay","RTSP relay stopped · "+error.getClass().getSimpleName()+": "+error.getMessage());}finally{close();}
    }

    private String rewriteRequest(String header)throws Exception{
        String result=toUpstream(header);String first=line(result,0);String[] words=first.split(" ");String method=words.length>0?words[0]:"",requestUri=words.length>1?words[1]:upstream;
        Log.i("FelicityReplay","RTSP client request · "+method+" · "+headerValue(result,"Range"));
        if("SETUP".equals(method)||"PLAY".equals(method)){result=removeHeader(result,"Require");result=insertHeader(result,"Require: onvif-replay");}
        if("PLAY".equals(method)){playCseq=headerValue(result,"CSeq");playUri=requestUri;pauseAfterFrame=false;pauseSent=false;keyframeSeenForPause=false;framesAfterKeyframe=0;String localRange=headerValue(result,"Range");result=removeHeader(result,"Range");result=insertHeader(result,"Range: clock="+clock(startMs)+"-");result=removeHeader(result,"Rate-Control");result=insertHeader(result,"Rate-Control: "+(rateControlled?"yes":"no"));result=removeHeader(result,"Frames");result=insertHeader(result,"Frames: "+(intraOnly?"intra":"all"));result=removeHeader(result,"Immediate");result=insertHeader(result,"Immediate: yes");result=removeHeader(result,"Scale");result=insertHeader(result,"Scale: 1.0");Log.i("FelicityReplay","RTSP PLAY · local="+localRange+" · upstream="+headerValue(result,"Range")+" · require="+headerValue(result,"Require")+" · rate="+headerValue(result,"Rate-Control")+" · frames="+headerValue(result,"Frames"));}
        if(!challenge.isEmpty()){result=removeHeader(result,"Authorization");result=insertHeader(result,"Authorization: "+digest(challenge,method,requestUri));}
        return result;
    }

    private String rewriteResponse(String header){String auth=headerValue(header,"WWW-Authenticate");if(auth!=null&&!auth.isEmpty())challenge=auth;String nextSession=headerValue(header,"Session");if(nextSession!=null&&!nextSession.isEmpty())session=nextSession.split(";")[0].trim();String range=headerValue(header,"Range"),rtp=headerValue(header,"RTP-Info"),cseq=headerValue(header,"CSeq"),status=line(header,0);long rangeTime=ReplayClock.fromRange(range);if(rangeTime>0&&!playCseq.isEmpty()&&playCseq.equals(cseq))rangeStartTimeMs=rangeTime;if(cseq!=null&&cseq.equals(keepaliveCseq)){Log.d("FelicityReplay","Paused RTSP keepalive accepted · status="+status);return null;}if(cseq!=null&&cseq.equals(injectedPlayCseq)){if(status.contains(" 401 ")&&auth!=null&&injectedPlayAuthRetries++<1){Log.i("FelicityReplay","Injected PLAY auth challenge · retrying immediately");playAfterPause();return null;}if(rangeTime>0)rangeStartTimeMs=rangeTime;injectedSeekReady=true;upstreamPaused=false;Log.i("FelicityReplay","Injected PLAY accepted · "+(android.os.SystemClock.elapsedRealtime()-seekIssuedAt)+" ms · status="+status);return null;}if(cseq!=null&&cseq.equals(injectedPauseCseq)){if(status.contains(" 401 ")&&auth!=null&&injectedPauseAuthRetries++<1){Log.i("FelicityReplay","Injected PAUSE auth challenge · retrying immediately");pauseSent=false;pauseUpstreamAfterFrame();return null;}if(status.contains(" 200 "))upstreamPaused=true;Log.i("FelicityReplay","Injected PAUSE accepted · status="+status);if(injectedSeekWaiting&&!injectedSeekReady)playAfterPause();else injectedSeekWaiting=false;return null;}if(cseq!=null&&cseq.equals(playCseq)&&status.contains(" 200 "))upstreamPaused=false;if(range!=null||rtp!=null)Log.i("FelicityReplay","RTSP response · status="+status+" · range="+range+" · rtp="+(rtp==null?"—":"present"));return toLocal(header);}
    private void observeReplayTime(byte[] packet){long time=ReplayClock.fromRtp(packet);if(time<=0)return;latestPacketTimeMs=time;if(firstPacketTimeMs==0){firstPacketTimeMs=time;Log.i("FelicityReplay","First ONVIF frame time · "+time);}}
    private void observeRtpCounters(byte[] packet){if(packet==null||packet.length<12)return;lastRtpSequence=((packet[2]&255)<<8)|(packet[3]&255);lastRtpPayloadType=packet[1]&127;lastRtpTimestamp=read32(packet,4);lastRtpSsrc=read32(packet,8);forwardedPackets++;int offset=12+(packet[0]&15)*4;if((packet[0]&16)!=0&&offset+4<=packet.length)offset+=4+((((packet[offset+2]&255)<<8)|(packet[offset+3]&255))*4);forwardedOctets+=Math.max(0,packet.length-offset);}
    private synchronized void translateRtpSequence(byte[] packet){if(packet==null||packet.length<12)return;int originalSequence=((packet[2]&255)<<8)|(packet[3]&255);long originalTimestamp=read32(packet,4)&0xffffffffL;if(awaitingRtpAnchor&&lastRtpSsrc!=0){rtpSequenceOffset=(lastRtpSequence+1-originalSequence)&0xffff;long desired=(lastRtpTimestamp&0xffffffffL)+9000L;rtpTimestampOffset=(desired-originalTimestamp)&0xffffffffL;awaitingRtpAnchor=false;Log.i("FelicityReplay","RTP discontinuity bridged · seq="+lastRtpSequence+"→"+((originalSequence+rtpSequenceOffset)&0xffff)+" · tsStep=9000");}put16(packet,2,(originalSequence+rtpSequenceOffset)&0xffff);put32(packet,4,(int)((originalTimestamp+rtpTimestampOffset)&0xffffffffL));}
    private synchronized int nextInjectedSequence(){rtpSequenceOffset=(rtpSequenceOffset+1)&0xffff;lastRtpSequence=(lastRtpSequence+1)&0xffff;return lastRtpSequence;}
    static byte[] rtpFillerKeepalive(int ssrc,int rtpTimestamp,int sequence,int payloadType,boolean hevc){byte[] out=new byte[hevc?16:15];out[0]=(byte)0x80;out[1]=(byte)(payloadType&127);put16(out,2,sequence);put32(out,4,rtpTimestamp);put32(out,8,ssrc);if(hevc){out[12]=0x4c;out[13]=1;out[14]=(byte)0xff;out[15]=(byte)0x80;}else{out[12]=0x0c;out[13]=(byte)0xff;out[14]=(byte)0x80;}return out;}
    static byte[] rtcpSenderReport(int ssrc,int rtpTimestamp,long packetCount,long octetCount,long unixMs){byte[] out=new byte[28];out[0]=(byte)0x80;out[1]=(byte)200;put16(out,2,6);put32(out,4,ssrc);long seconds=unixMs/1000L+2208988800L,fraction=((unixMs%1000L)<<32)/1000L;put32(out,8,(int)seconds);put32(out,12,(int)fraction);put32(out,16,rtpTimestamp);put32(out,20,(int)packetCount);put32(out,24,(int)octetCount);return out;}
    private static int read32(byte[] value,int offset){return ((value[offset]&255)<<24)|((value[offset+1]&255)<<16)|((value[offset+2]&255)<<8)|(value[offset+3]&255);}
    private static void put16(byte[] value,int offset,int number){value[offset]=(byte)(number>>>8);value[offset+1]=(byte)number;}
    private static void put32(byte[] value,int offset,int number){value[offset]=(byte)(number>>>24);value[offset+1]=(byte)(number>>>16);value[offset+2]=(byte)(number>>>8);value[offset+3]=(byte)number;}
    long replayStartTimeMs(){return firstPacketTimeMs>0?firstPacketTimeMs:rangeStartTimeMs;}
    long replayCurrentTimeMs(){return latestPacketTimeMs>0?latestPacketTimeMs:replayStartTimeMs();}
    long cappedFrameTimeMs(){return replayCapped?cappedFrameTimeMs:0;}
    boolean probeComplete(){return replayCapped;}
    long keyframeAtOrBeforeMs(){return keyframeAtOrBeforeMs;}
    List<Long> keyframes(){synchronized(keyframes){return new ArrayList<>(keyframes);}}
    private String toUpstream(String value){return value.replace(localBase+"/replay",upstream).replace(localBase,upstreamBase);}
    private String toLocal(String value){return value.replace(upstream,localBase+"/replay").replace(upstreamBase,localBase);}

    private String digest(String source,String method,String uri)throws Exception{
        String realm=parameter(source,"realm"),nonce=parameter(source,"nonce"),qop=parameter(source,"qop"),opaque=parameter(source,"opaque"),algorithm=parameter(source,"algorithm");if(algorithm.isEmpty())algorithm="MD5";
        String ha1=md5(user+":"+realm+":"+password),ha2=md5(method+":"+uri),response,extra="";
        if(!qop.isEmpty()){String selected=qop.toLowerCase(Locale.US).contains("auth")?"auth":qop.split(",")[0].trim(),nc="00000001",cnonce=md5(Long.toHexString(System.nanoTime())).substring(0,16);response=md5(ha1+":"+nonce+":"+nc+":"+cnonce+":"+selected+":"+ha2);extra=", qop="+selected+", nc="+nc+", cnonce=\""+cnonce+"\"";}else response=md5(ha1+":"+nonce+":"+ha2);
        return "Digest username=\""+user+"\", realm=\""+realm+"\", nonce=\""+nonce+"\", uri=\""+uri+"\", response=\""+response+"\", algorithm="+algorithm+(opaque.isEmpty()?"":", opaque=\""+opaque+"\"")+extra;
    }

    private static byte[] readHeader(InputStream in,int first)throws Exception{ByteArrayOutputStream result=new ByteArrayOutputStream();result.write(first);int state=first=='\r'?1:0;while(state<4){int value=in.read();if(value<0)throw new java.io.EOFException();result.write(value);if((state==0||state==2)&&value=='\r')state++;else if((state==1||state==3)&&value=='\n')state++;else state=value=='\r'?1:0;if(result.size()>256*1024)throw new Exception("RTSP header too large");}return result.toByteArray();}
    private static void readFully(InputStream in,byte[] buffer)throws Exception{int offset=0;while(offset<buffer.length){int count=in.read(buffer,offset,buffer.length-offset);if(count<0)throw new java.io.EOFException();offset+=count;}}
    private static int contentLength(String header){String value=headerValue(header,"Content-Length");try{return value==null?0:Integer.parseInt(value.trim());}catch(Exception ignored){return 0;}}
    private static String setContentLength(String header,int length){if(headerValue(header,"Content-Length")==null)return header;if(length==0)return removeHeader(header,"Content-Length");return header.replaceFirst("(?im)^Content-Length\\s*:\\s*\\d+\\s*$","Content-Length: "+length);}
    private static String removeHeader(String header,String name){return header.replaceFirst("(?im)^"+Pattern.quote(name)+"\\s*:[^\\r\\n]*(?:\\r?\\n)","");}
    private static String insertHeader(String header,String value){int end=header.indexOf("\r\n\r\n");return end<0?header:header.substring(0,end)+"\r\n"+value+header.substring(end);}
    private static String headerValue(String header,String name){Matcher matcher=Pattern.compile("(?im)^"+Pattern.quote(name)+"\\s*:\\s*([^\\r\\n]+)").matcher(header);return matcher.find()?matcher.group(1).trim():null;}
    private static String line(String text,int index){String[] lines=text.split("\\r?\\n");return index<lines.length?lines[index]:"";}
    private static String parameter(String input,String name){Matcher matcher=Pattern.compile("(?:^|[, ])"+name+"\\s*=\\s*(?:\"([^\"]*)\"|([^, ]+))",Pattern.CASE_INSENSITIVE).matcher(input);return matcher.find()?(matcher.group(1)!=null?matcher.group(1):matcher.group(2)):"";}
    private static String md5(String value)throws Exception{byte[] bytes=MessageDigest.getInstance("MD5").digest(value.getBytes("ISO-8859-1"));StringBuilder result=new StringBuilder();for(byte valueByte:bytes)result.append(String.format(Locale.US,"%02x",valueByte&255));return result.toString();}
    private static String clock(long time){SimpleDateFormat format=new SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'",Locale.US);format.setTimeZone(TimeZone.getTimeZone("UTC"));return format.format(new Date(time));}

    @Override public synchronized void close(){if(closed)return;closed=true;pausedHold=false;holdGeneration++;try{server.close();}catch(Exception ignored){}try{if(client!=null)client.close();}catch(Exception ignored){}try{if(remote!=null)remote.close();}catch(Exception ignored){}threads.shutdownNow();keepAlive.shutdownNow();Log.i("FelicityReplay","Proxy closed · active="+ACTIVE.decrementAndGet());}
}
