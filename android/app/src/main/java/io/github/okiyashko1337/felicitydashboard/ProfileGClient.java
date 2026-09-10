package io.github.okiyashko1337.felicitydashboard;

import android.util.Log;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CompletionService;
import java.util.concurrent.ExecutorCompletionService;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class ProfileGClient {
    private static final String TAG="FelicityProfileG";
    private static final String DEVICE_NS="http://www.onvif.org/ver10/device/wsdl";
    private static final String RECORDING_NS="http://www.onvif.org/ver10/recording/wsdl";
    private static final String SEARCH_NS="http://www.onvif.org/ver10/search/wsdl";
    private static final String REPLAY_NS="http://www.onvif.org/ver10/replay/wsdl";
    private static final String MEDIA_NS="http://www.onvif.org/ver10/media/wsdl";
    private final String host,user,password;

    static final class Recording {
        final String token,name,sourceId;
        Recording(String token,String name,String sourceId){this.token=token;this.name=name;this.sourceId=sourceId;}
    }
    static final class ProbeResult {
        String recordingEndpoint="",searchEndpoint="",replayEndpoint="",mediaEndpoint="";
        String dataFrom="",dataUntil="",replayUri="";
        int recordingCount;
        final List<Recording> recordings=new ArrayList<>();
        final List<MediaProfile> profiles=new ArrayList<>();
    }
    static final class MediaProfile {
        final String token,name,sourceToken,uri;final int width,height,rotation;
        MediaProfile(String token,String name,String sourceToken,String uri,int width,int height,int rotation){this.token=token;this.name=name;this.sourceToken=sourceToken;this.uri=uri;this.width=width;this.height=height;this.rotation=rotation;}
        boolean substream(){String value=(token+" "+name).toLowerCase(Locale.US);return value.endsWith("-sub")||value.contains(" sub")||value.endsWith("_s")||value.contains("secondary");}
    }
    static final class SearchEvent {
        final long time,endTime;final String type;
        SearchEvent(long time,String type){this(time,type,0);}
        SearchEvent(long time,String type,long endTime){this.time=time;this.type=type;this.endTime=endTime;}
    }

    ProfileGClient(String host,String user,String password){this.host=host;this.user=user;this.password=password;}

    static final class Discovery {
        final String host;
        final ProbeResult result;
        Discovery(String host,ProbeResult result){this.host=host;this.result=result;}
    }

    static Discovery discoverNvr(String configuredHost,String user,String password)throws Exception{
        int colon=configuredHost.lastIndexOf(':');
        int port=colon>0?Integer.parseInt(configuredHost.substring(colon+1)):8080;
        String ip=colon>0?configuredHost.substring(0,colon):configuredHost;
        int dot=ip.lastIndexOf('.');
        if(dot<0)throw new Exception("Profile G discovery requires a local IPv4 address");
        String prefix=ip.substring(0,dot+1);
        ExecutorService pool=Executors.newFixedThreadPool(16);
        CompletionService<Discovery> completed=new ExecutorCompletionService<>(pool);
        int submitted=0;
        try{
            for(int i=1;i<255;i++){
                final String candidate=prefix+i+":"+port;
                completed.submit(()->{
                    if(!open(candidate,180))return null;
                    try{return new Discovery(candidate,new ProfileGClient(candidate,user,password).probe());}
                    catch(Exception error){if(error.getMessage()!=null&&!error.getMessage().contains("not exposed"))Log.w(TAG,"Recorder candidate · "+candidate+" · "+error.getMessage());return null;}
                });
                submitted++;
            }
            long deadline=System.currentTimeMillis()+70000;
            for(int i=0;i<submitted&&System.currentTimeMillis()<deadline;i++){
                Future<Discovery> future=completed.poll(Math.max(1,deadline-System.currentTimeMillis()),TimeUnit.MILLISECONDS);
                if(future==null)break;
                Discovery found=future.get();
                if(found!=null)return found;
            }
            throw new Exception("No Profile G recorder found on "+prefix+"0/24");
        }finally{pool.shutdownNow();}
    }

    private static boolean open(String host,int timeout){
        int colon=host.lastIndexOf(':');
        try(Socket socket=new Socket()){
            socket.connect(new InetSocketAddress(host.substring(0,colon),Integer.parseInt(host.substring(colon+1))),timeout);
            return true;
        }catch(Exception ignored){return false;}
    }

    ProbeResult probe() throws Exception {
        String device="http://"+host+"/onvif/device_service";
        String information=post(device,DEVICE_NS+"/GetDeviceInformation",envelope(device,DEVICE_NS+"/GetDeviceInformation","<tds:GetDeviceInformation/>","xmlns:tds=\""+DEVICE_NS+"\""));
        Log.i(TAG,"ONVIF device · "+value(information,"Manufacturer")+" · "+value(information,"Model")+" · firmware "+value(information,"FirmwareVersion"));
        String services=post(device,DEVICE_NS+"/GetServices",getServices(device));
        ProbeResult result=new ProbeResult();
        Matcher serviceBlocks=Pattern.compile("<(?:\\w+:)?Service\\b[^>]*>(.*?)</(?:\\w+:)?Service>",Pattern.CASE_INSENSITIVE|Pattern.DOTALL).matcher(services);
        while(serviceBlocks.find()){
            String block=serviceBlocks.group(1),namespace=element(block,"Namespace"),address=element(block,"XAddr");
            if(namespace==null||address==null)continue;
            Log.i(TAG,"ONVIF service · "+namespace+" · "+address);
            if(namespace.contains("/recording/wsdl"))result.recordingEndpoint=address;
            else if(namespace.contains("/search/wsdl"))result.searchEndpoint=address;
            else if(namespace.contains("/replay/wsdl"))result.replayEndpoint=address;
            else if(namespace.contains("/media/wsdl"))result.mediaEndpoint=address;
        }
        if(result.recordingEndpoint.isEmpty()||result.searchEndpoint.isEmpty()||result.replayEndpoint.isEmpty()){
            String capabilities=post(device,DEVICE_NS+"/GetCapabilities",envelope(device,DEVICE_NS+"/GetCapabilities","<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>","xmlns:tds=\""+DEVICE_NS+"\""));
            Matcher extensions=Pattern.compile("<(?:[\\w.-]+:)?(Recording|Search|Replay)\\b([^>]*)>",Pattern.CASE_INSENSITIVE).matcher(capabilities);
            while(extensions.find()){String kind=extensions.group(1),address=attribute(extensions.group(2),"XAddr");if(address==null||address.isEmpty())continue;Log.i(TAG,"Profile G capability · "+kind+" · "+address);if(kind.equalsIgnoreCase("Recording"))result.recordingEndpoint=address;else if(kind.equalsIgnoreCase("Search"))result.searchEndpoint=address;else if(kind.equalsIgnoreCase("Replay"))result.replayEndpoint=address;}
        }
        if(result.recordingEndpoint.isEmpty()||result.searchEndpoint.isEmpty()||result.replayEndpoint.isEmpty())throw new Exception("Profile G not exposed for this ONVIF user");
        if(!result.mediaEndpoint.isEmpty())loadProfiles(result);
        loadRecordings(result);
        if(result.recordings.isEmpty())throw new Exception("Profile G returned no recordings");
        Log.i(TAG,"Profile G catalog ready · recordings="+result.recordings.size());
        return result;
    }

    private void loadProfiles(ProbeResult result)throws Exception{
        String xml=post(result.mediaEndpoint,MEDIA_NS+"/GetProfiles",envelope(result.mediaEndpoint,MEDIA_NS+"/GetProfiles","<trt:GetProfiles/>","xmlns:trt=\""+MEDIA_NS+"\""));
        Matcher items=Pattern.compile("<(?:\\w+:)?Profiles\\b([^>]*)>(.*?)</(?:\\w+:)?Profiles>",Pattern.CASE_INSENSITIVE|Pattern.DOTALL).matcher(xml);
        while(items.find()){
            String token=attribute(items.group(1),"token"),block=items.group(2);if(token==null||token.isEmpty())continue;
            String name=value(block,"Name"),source=value(element(block,"VideoSourceConfiguration"),"SourceToken");
            String encoder=element(block,"VideoEncoderConfiguration"),resolution=element(encoder,"Resolution");
            int width=integer(value(resolution,"Width")),height=integer(value(resolution,"Height")),rotation=integer(value(element(block,"Rotate"),"Degree"));
            String uri;try{uri=streamUri(result.mediaEndpoint,token);}catch(Exception streamError){Log.w(TAG,"GetStreamUri fallback · token="+safeToken(token)+" · "+streamError.getMessage());uri=recorderStreamUri(token);}
            result.profiles.add(new MediaProfile(token,name,source,uri,width,height,normalizeRotation(rotation)));
            Log.i(TAG,"Media profile · token="+safeToken(token)+" · name="+name+" · "+width+"x"+height+" · rotation="+normalizeRotation(rotation));
        }
    }

    private String recorderStreamUri(String profileToken){String address=host;int colon=address.lastIndexOf(':');if(colon>0)address=address.substring(0,colon);String path=profileToken.replaceFirst("(?i)-main$","_m").replaceFirst("(?i)-sub$","_s");return "rtsp://"+address+":8554/"+path;}
    private static String cleanProfileName(String name){return name==null?"":name.replaceFirst("(?i)(?:[_ -](?:main|sub|secondary))$","").trim();}

    private String streamUri(String endpoint,String profileToken)throws Exception{
        String body="<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>"+escape(profileToken)+"</trt:ProfileToken></trt:GetStreamUri>";
        String response=post(endpoint,MEDIA_NS+"/GetStreamUri",envelope(endpoint,MEDIA_NS+"/GetStreamUri",body,"xmlns:trt=\""+MEDIA_NS+"\" xmlns:tt=\"http://www.onvif.org/ver10/schema\""));
        String uri=element(response,"Uri");if(uri==null||uri.isEmpty())throw new Exception("ONVIF stream URI missing");return uri;
    }

    private static int integer(String value){try{return Integer.parseInt(value);}catch(Exception ignored){return 0;}}
    private static int normalizeRotation(int value){int rotation=((value%360)+360)%360;return rotation==90||rotation==180||rotation==270?rotation:0;}

    private void loadRecordings(ProbeResult result)throws Exception{
        String xml=post(result.recordingEndpoint,RECORDING_NS+"/GetRecordings",envelope(result.recordingEndpoint,RECORDING_NS+"/GetRecordings","<trc:GetRecordings/>","xmlns:trc=\""+RECORDING_NS+"\""));
        Matcher items=Pattern.compile("<(?:\\w+:)?RecordingItem\\b[^>]*>(.*?)</(?:\\w+:)?RecordingItem>",Pattern.CASE_INSENSITIVE|Pattern.DOTALL).matcher(xml);
        while(items.find()){
            String block=items.group(1),token=element(block,"RecordingToken");
            if(token==null||token.isEmpty())continue;
            String configuration=element(block,"Configuration"),name=value(configuration==null?block:configuration,"Name"),source=value(configuration==null?block:configuration,"SourceId");
            result.recordings.add(new Recording(token,name,source));
            Log.i(TAG,"Recording · token="+safeToken(token)+" · name="+name+" · source="+source);
        }
    }

    private static boolean hasRecording(ProbeResult result,String token){for(Recording recording:result.recordings)if(recording.token.equals(token))return true;return false;}
    private static String safeToken(String token){return token.length()<=12?token:token.substring(0,6)+"…"+token.substring(token.length()-4);}

    String replayUri(String endpoint,String recordingToken)throws Exception{
        String body="<trp:GetReplayUri><trp:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trp:StreamSetup><trp:RecordingToken>"+escape(recordingToken)+"</trp:RecordingToken></trp:GetReplayUri>";
        String response=post(endpoint,REPLAY_NS+"/GetReplayUri",envelope(endpoint,REPLAY_NS+"/GetReplayUri",body,"xmlns:trp=\""+REPLAY_NS+"\" xmlns:tt=\"http://www.onvif.org/ver10/schema\""));
        String uri=element(response,"Uri");if(uri==null||uri.isEmpty())throw new Exception("Profile G replay URI missing");return uri;
    }

    boolean supportsMetadataSearch(String endpoint)throws Exception{
        String action=SEARCH_NS+"/GetServiceCapabilities",body="<tse:GetServiceCapabilities/>";
        String response=post(endpoint,action,envelope(endpoint,action,body,"xmlns:tse=\""+SEARCH_NS+"\""));
        Matcher capabilities=Pattern.compile("<(?:\\w+:)?Capabilities\\b([^>]*)>",Pattern.CASE_INSENSITIVE).matcher(response);
        String value=capabilities.find()?attribute(capabilities.group(1),"MetadataSearch"):null;
        boolean supported="true".equalsIgnoreCase(value)||"1".equals(value);Log.i(TAG,"Metadata search capability · "+supported);return supported;
    }

    List<SearchEvent> searchEvents(String endpoint,String recordingToken,long start,long end)throws Exception{
        String body="<tse:FindEvents><tse:StartPoint>"+utc(start)+"</tse:StartPoint><tse:EndPoint>"+utc(end)+"</tse:EndPoint><tse:Scope><tt:IncludedRecordings>"+escape(recordingToken)+"</tt:IncludedRecordings></tse:Scope><tse:SearchFilter/><tse:IncludeStartState>false</tse:IncludeStartState><tse:MaxMatches>1000</tse:MaxMatches><tse:KeepAliveTime>PT20S</tse:KeepAliveTime></tse:FindEvents>";
        String response=post(endpoint,SEARCH_NS+"/FindEvents",envelope(endpoint,SEARCH_NS+"/FindEvents",body,"xmlns:tse=\""+SEARCH_NS+"\" xmlns:tt=\"http://www.onvif.org/ver10/schema\""));
        String token=element(response,"SearchToken");if(token==null||token.isEmpty())throw new Exception("Profile G event search token missing");
        String resultsBody="<tse:GetEventSearchResults><tse:SearchToken>"+escape(token)+"</tse:SearchToken><tse:MinResults>0</tse:MinResults><tse:MaxResults>1000</tse:MaxResults><tse:WaitTime>PT8S</tse:WaitTime></tse:GetEventSearchResults>";
        String results=post(endpoint,SEARCH_NS+"/GetEventSearchResults",envelope(endpoint,SEARCH_NS+"/GetEventSearchResults",resultsBody,"xmlns:tse=\""+SEARCH_NS+"\""));
        ArrayList<SearchEvent> found=new ArrayList<>();Matcher blocks=Pattern.compile("<(?:\\w+:)?Result\\b[^>]*>(.*?)</(?:\\w+:)?Result>",Pattern.CASE_INSENSITIVE|Pattern.DOTALL).matcher(results);
        while(blocks.find()){String block=blocks.group(1),rawTime=element(block,"Time");long at=parseUtc(rawTime);if(at<=0)continue;found.add(new SearchEvent(at,classify(block)));}
        Log.i(TAG,"Profile G events · recording="+safeToken(recordingToken)+" · count="+found.size());return found;
    }

    private static String classify(String block){String value=block.toLowerCase(Locale.US);if(value.contains("person")||value.contains("human"))return "person";if(value.contains("vehicle")||value.contains("car"))return "vehicle";if(value.contains("animal")||value.contains("pet"))return "animal";return "motion";}
    private static String utc(long time){SimpleDateFormat f=new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",Locale.US);f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));return f.format(new Date(time));}
    private static long parseUtc(String value){if(value==null||value.length()<19)return 0;try{SimpleDateFormat f=new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss",Locale.US);f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));return f.parse(value.substring(0,19)).getTime();}catch(Exception ignored){return 0;}}

    private String post(String address,String action,String xml)throws Exception{Response first=send(address,action,xml,null);if(first.code==200)return checked(first.body);if(first.code!=401)throw new Exception("Profile G HTTP "+first.code);if(first.auth==null)throw new Exception("Profile G auth challenge missing");Response second=send(address,action,xml,digest(first.auth,"POST",address));if(second.code!=200)throw new Exception("Profile G auth HTTP "+second.code);return checked(second.body);}
    private static String checked(String body)throws Exception{if(Pattern.compile("<(?:[\\w.-]+:)?Fault\\b",Pattern.CASE_INSENSITIVE).matcher(body).find()){String reason=element(body,"Text");if(reason==null||reason.isEmpty())reason="SOAP fault";throw new Exception("Profile G SOAP · "+reason);}return body;}
    private Response send(String address,String action,String xml,String auth)throws Exception{HttpURLConnection c=(HttpURLConnection)new URL(address).openConnection();c.setConnectTimeout(4000);c.setReadTimeout(60000);c.setRequestMethod("POST");c.setDoOutput(true);c.setRequestProperty("Connection","close");c.setRequestProperty("Content-Type","application/soap+xml; charset=utf-8; action=\""+action+"\"");if(auth!=null)c.setRequestProperty("Authorization",auth);byte[] bytes=xml.getBytes("UTF-8");c.setFixedLengthStreamingMode(bytes.length);try(OutputStream out=c.getOutputStream()){out.write(bytes);}int code=c.getResponseCode();String challenge=c.getHeaderField("WWW-Authenticate");InputStream input=code>=400?c.getErrorStream():c.getInputStream();String body=input==null?"":read(input);c.disconnect();return new Response(code,body,challenge);}
    private String digest(String challenge,String method,String address)throws Exception{
        String realm=parameter(challenge,"realm"),nonce=parameter(challenge,"nonce"),opaque=parameter(challenge,"opaque"),algorithm=tokenParameter(challenge,"algorithm"),qopList=parameter(challenge,"qop"),uri=new URL(address).getPath();
        String qop="";for(String candidate:qopList.split(","))if("auth".equalsIgnoreCase(candidate.trim())){qop="auth";break;}
        String cnonce=java.util.UUID.randomUUID().toString().replace("-","").substring(0,16),nc="00000001";
        String ha1=md5(user+":"+realm+":"+password);if("MD5-sess".equalsIgnoreCase(algorithm))ha1=md5(ha1+":"+nonce+":"+cnonce);
        String ha2=md5(method+":"+uri),response=qop.isEmpty()?md5(ha1+":"+nonce+":"+ha2):md5(ha1+":"+nonce+":"+nc+":"+cnonce+":"+qop+":"+ha2);
        StringBuilder header=new StringBuilder("Digest username=\"").append(user).append("\", realm=\"").append(realm).append("\", nonce=\"").append(nonce).append("\", uri=\"").append(uri).append("\", response=\"").append(response).append("\"");
        if(!algorithm.isEmpty())header.append(", algorithm=").append(algorithm);if(!opaque.isEmpty())header.append(", opaque=\"").append(opaque).append("\"");if(!qop.isEmpty())header.append(", qop=").append(qop).append(", nc=").append(nc).append(", cnonce=\"").append(cnonce).append("\"");return header.toString();
    }
    private static String getServices(String endpoint){return envelope(endpoint,DEVICE_NS+"/GetServices","<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>","xmlns:tds=\""+DEVICE_NS+"\"");}
    private static String envelope(String endpoint,String action,String body,String namespaces){return "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:wsa=\"http://www.w3.org/2005/08/addressing\" "+namespaces+"><s:Header><wsa:Action s:mustUnderstand=\"1\">"+action+"</wsa:Action><wsa:MessageID>urn:uuid:"+java.util.UUID.randomUUID()+"</wsa:MessageID><wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo><wsa:To s:mustUnderstand=\"1\">"+endpoint+"</wsa:To></s:Header><s:Body>"+body+"</s:Body></s:Envelope>";}
    private static String element(String xml,String local){if(xml==null)return null;Matcher m=Pattern.compile("<(?:[\\w.-]+:)?"+Pattern.quote(local)+"(?:\\s[^>]*)?>(.*?)</(?:[\\w.-]+:)?"+Pattern.quote(local)+">",Pattern.CASE_INSENSITIVE|Pattern.DOTALL).matcher(xml);return m.find()?decode(m.group(1).trim()):null;}
    private static String value(String xml,String local){String result=element(xml,local);return result==null?"":result;}
    private static String parameter(String input,String name){Matcher m=Pattern.compile(name+"=\"([^\"]+)\"",Pattern.CASE_INSENSITIVE).matcher(input);return m.find()?m.group(1):"";}
    private static String tokenParameter(String input,String name){Matcher m=Pattern.compile("(?:^|[,\\s])"+Pattern.quote(name)+"\\s*=\\s*(?:\"([^\"]+)\"|([^,\\s]+))",Pattern.CASE_INSENSITIVE).matcher(input);return m.find()?(m.group(1)!=null?m.group(1):m.group(2)):"";}
    private static String attribute(String input,String name){Matcher m=Pattern.compile("\\b"+Pattern.quote(name)+"\\s*=\\s*(['\"])(.*?)\\1",Pattern.CASE_INSENSITIVE|Pattern.DOTALL).matcher(input);return m.find()?decode(m.group(2)):null;}
    private static String md5(String value)throws Exception{byte[] digest=MessageDigest.getInstance("MD5").digest(value.getBytes("ISO-8859-1"));StringBuilder result=new StringBuilder();for(byte b:digest)result.append(String.format(Locale.US,"%02x",b&255));return result.toString();}
    private static String read(InputStream input)throws Exception{BufferedReader reader=new BufferedReader(new InputStreamReader(input));StringBuilder result=new StringBuilder();String line;while((line=reader.readLine())!=null)result.append(line);return result.toString();}
    private static String escape(String value){return value.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;");}
    private static String decode(String value){return value.replace("&amp;","&").replace("&lt;","<").replace("&gt;",">");}
    private static String safeShape(String xml){String shape=xml.replaceAll(">[^<]+<",">…<");return shape.length()>2400?shape.substring(0,2400)+"…":shape;}
    private static final class Response{final int code;final String body,auth;Response(int code,String body,String auth){this.code=code;this.body=body;this.auth=auth;}}
}
