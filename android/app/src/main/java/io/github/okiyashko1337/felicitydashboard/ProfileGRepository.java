package io.github.okiyashko1337.felicitydashboard;

import android.content.SharedPreferences;
import android.util.Log;
import java.util.List;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Locale;
import java.util.HashMap;
import java.util.Map;

final class ProfileGRepository {
    private static final long ACTIVITY_CONTEXT_MS=6_000;
    static final class Replay {
        final String uri,user,password,recordingName;
        Replay(String uri,String user,String password,String recordingName){this.uri=uri;this.user=user;this.password=password;this.recordingName=recordingName;}
    }
    private static String host="",user="",password="";
    private static ProfileGClient.ProbeResult catalog;
    private static Boolean metadataSearch;
    private static final Map<String,String> replayUris=new HashMap<>();
    private static final Map<String,List<ProfileGClient.SearchEvent>> activityRanges=new HashMap<>();
    private ProfileGRepository(){}

    static synchronized void set(String valueHost,String valueUser,String valuePassword,ProfileGClient.ProbeResult valueCatalog){if(!valueHost.equals(host)||!valueUser.equals(user)||!valuePassword.equals(password)){replayUris.clear();activityRanges.clear();metadataSearch=null;}host=valueHost;user=valueUser;password=valuePassword;catalog=valueCatalog;}

    private static boolean probeMetadataSearch(ProfileGClient client,String endpoint){synchronized(ProfileGRepository.class){if(metadataSearch!=null)return metadataSearch;}try{boolean supported=client.supportsMetadataSearch(endpoint);synchronized(ProfileGRepository.class){metadataSearch=supported;}return supported;}catch(Exception error){Log.w("FelicityProfileG","Metadata search capability unavailable · "+error.getMessage());synchronized(ProfileGRepository.class){metadataSearch=false;}return false;}}

    private static String cachedReplayUri(ProfileGClient client,String endpoint,String cacheKey,String recordingToken)throws Exception{synchronized(ProfileGRepository.class){String cached=replayUris.get(cacheKey);if(cached!=null)return cached;}String loaded=client.replayUri(endpoint,recordingToken);synchronized(ProfileGRepository.class){replayUris.put(cacheKey,loaded);}return loaded;}

    static ProfileGClient.ProbeResult load(String valueHost,String valueUser,String valuePassword)throws Exception{synchronized(ProfileGRepository.class){if(catalog!=null&&valueHost.equals(host)&&valueUser.equals(user))return catalog;}ProfileGClient.ProbeResult loaded=new ProfileGClient(valueHost,valueUser,valuePassword).probe();synchronized(ProfileGRepository.class){if(catalog==null||!valueHost.equals(host)||!valueUser.equals(user))set(valueHost,valueUser,valuePassword,loaded);return catalog;}}

    static Replay replay(SharedPreferences prefs,String camera,boolean substream)throws Exception{
        String currentHost=prefs.getString("profile_g_host","192.168.13.234:8080"),currentUser=prefs.getString("profile_g_user",""),currentPassword=prefs.getString("profile_g_password","");
        CameraCatalog.Camera selected=CameraCatalog.find(prefs,camera);String directToken=CameraCatalog.recordingToken(selected,substream);ProfileGClient client=new ProfileGClient(currentHost,currentUser,currentPassword);if(!directToken.isEmpty()){try{String key=currentHost+"|"+currentUser+"|"+currentPassword.hashCode()+"|"+directToken;Log.i("FelicityProfileG","Replay fast path · camera="+camera+" · "+(substream?"sub":"main"));String uri=cachedReplayUri(client,"http://"+currentHost+"/onvif/replay_service",key,directToken);Log.i("FelicityProfileG","Replay URI ready · camera="+camera);return new Replay(uri,currentUser,currentPassword,camera);}catch(Exception fastError){Log.w("FelicityProfileG","Replay fast path fallback · "+fastError.getMessage());}}
        ProfileGClient.ProbeResult active=load(currentHost,currentUser,currentPassword);ProfileGClient.Recording recording=find(active,camera,substream);if(recording==null)throw new Exception(camera+" is not recorded by the NVR");String key=currentHost+"|"+currentUser+"|"+currentPassword.hashCode()+"|"+recording.token;String uri=cachedReplayUri(client,active.replayEndpoint,key,recording.token);return new Replay(uri,currentUser,currentPassword,recording.name);
    }

    static List<ProfileGClient.SearchEvent> events(SharedPreferences prefs,String camera,long start,long end,boolean substream)throws Exception{
        if(end<=start)return Collections.emptyList();Replay replay=replay(prefs,camera,substream);String key=replay.uri+"|"+start+"|"+end; synchronized(ProfileGRepository.class){List<ProfileGClient.SearchEvent> cached=activityRanges.get(key);if(cached!=null)return new ArrayList<>(cached);}
        long began=android.os.SystemClock.elapsedRealtime();List<OnvifMetadataDecoder.Activity> activities=new OnvifActivityClient(replay.uri,replay.user,replay.password).fetch(start,end);ArrayList<ProfileGClient.SearchEvent> loaded=new ArrayList<>();
        loaded.addAll(activityIntervals(activities));
        synchronized(ProfileGRepository.class){if(activityRanges.size()>31)activityRanges.clear();activityRanges.put(key,new ArrayList<>(loaded));}Log.i("FelicityProfileG","ONVIF activities · camera="+camera+" · events="+loaded.size()+" · "+(android.os.SystemClock.elapsedRealtime()-began)+" ms");return loaded;
    }

    static List<ProfileGClient.SearchEvent> activityIntervals(List<OnvifMetadataDecoder.Activity> activities){
        ArrayList<ProfileGClient.SearchEvent> result=new ArrayList<>();Map<String,Long> opened=new HashMap<>();
        for(OnvifMetadataDecoder.Activity activity:activities)for(String type:activity.types()){
            if(type.isEmpty()||"motion".equals(type))continue;
            if(!activity.asserted){Long abandoned=opened.put(type,activity.timeMs);if(abandoned!=null)warn("Unclosed ONVIF "+type+" activity · "+new java.util.Date(abandoned)+" · replaced at "+new java.util.Date(activity.timeMs));continue;}
            Long start=opened.remove(type);
            if(start!=null&&activity.timeMs>start&&activity.timeMs-start<=10*60_000)addInterval(result,Math.max(0,start-ACTIVITY_CONTEXT_MS),activity.timeMs+ACTIVITY_CONTEXT_MS,type);
            else if("ring".equals(type))addInterval(result,Math.max(0,activity.timeMs-ACTIVITY_CONTEXT_MS),activity.timeMs+ACTIVITY_CONTEXT_MS,type);
        }
        for(Map.Entry<String,Long> entry:opened.entrySet())warn("Unclosed ONVIF "+entry.getKey()+" activity · "+new java.util.Date(entry.getValue()));Collections.sort(result,(left,right)->Long.compare(left.time,right.time));return result;
    }

    /**
     * Snaps a timeline press to the nearest point covered by an AI recording.
     * A press in a gap is compared with the end of the earlier interval and the
     * start of the later one. Ties deliberately prefer the earlier recording.
     */
    static long nearestActivityTime(List<ProfileGClient.SearchEvent> events,long target,long dayStart,long dayEnd){
        long best=target,distance=Long.MAX_VALUE;
        for(ProfileGClient.SearchEvent event:events){
            if(event==null||event.type==null||event.type.toLowerCase(Locale.US).contains("motion")||event.time<dayStart||event.time>=dayEnd)continue;
            long end=Math.max(event.time,event.endTime),candidate=target<event.time?event.time:target>end?end:target,next=Math.abs(candidate-target);
            if(next<distance||(next==distance&&candidate<best)){distance=next;best=candidate;}
        }
        return best;
    }

    private static void addInterval(List<ProfileGClient.SearchEvent> result,long start,long end,String type){for(ProfileGClient.SearchEvent existing:result)if(existing.type.equals(type)&&Math.abs(existing.time-start)<=250)return;result.add(new ProfileGClient.SearchEvent(start,type,end));}
    private static void warn(String value){try{Log.w("FelicityActivity",value);}catch(RuntimeException ignored){}}


    static ProfileGClient.Recording find(ProfileGClient.ProbeResult source,String camera){
        return find(source,camera,false);
    }

    static ProfileGClient.Recording find(ProfileGClient.ProbeResult source,String camera,boolean substream){
        String wanted=normal(camera);ProfileGClient.Recording fallback=null;
        for(ProfileGClient.Recording item:source.recordings){String name=normal(item.name),id=normal(item.sourceId);if(name.equals(wanted)||id.equals(wanted)){if(isSub(item)==substream)return item;if(fallback==null)fallback=item;}}
        for(ProfileGClient.Recording item:source.recordings){String name=normal(item.name),id=normal(item.sourceId);if(name.contains(wanted)||wanted.contains(name)||id.contains(wanted)){if(isSub(item)==substream)return item;if(fallback==null)fallback=item;}}
        return fallback;
    }

    static boolean isSub(ProfileGClient.Recording item){String value=(item.token+" "+item.name+" "+item.sourceId).toLowerCase(Locale.US);return value.contains("-sub-r")||value.contains("sub")||value.endsWith("_s")||value.contains("secondary");}
    private static String normal(String value){return value==null?"":value.toLowerCase(Locale.US).replaceAll("[^\\p{L}\\p{N}]+","");}
}
