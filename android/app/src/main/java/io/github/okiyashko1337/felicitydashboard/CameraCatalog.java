package io.github.okiyashko1337.felicitydashboard;

import android.content.SharedPreferences;
import android.net.Uri;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** The recorder owns camera media; 3ye only enriches it with AI events. */
final class CameraCatalog {
    static final int RECORDER_SCHEMA=3;
    private static final String RECORDER_KEY="recorder_camera_catalog",THREE_EYE_KEY="threeeye_camera_catalog";
    static final class Camera {
        final String id,name,host,sourceToken,mainProfile,subProfile,mainUri,subUri,mainRecording,subRecording;
        final int mainWidth,mainHeight,subWidth,subHeight,rotationDegrees;final boolean doorbell,corridor;
        Camera(String id,String name,String host){this(id,name,host,id,"","","","","","",0,0,0,isDoorbellName(name));}
        Camera(String id,String name,String host,String sourceToken,String mainProfile,String subProfile,String mainUri,String subUri,String mainRecording,String subRecording,int mainWidth,int mainHeight,int rotationDegrees,boolean doorbell){this(id,name,host,sourceToken,mainProfile,subProfile,mainUri,subUri,mainRecording,subRecording,mainWidth,mainHeight,0,0,rotationDegrees,doorbell);}
        Camera(String id,String name,String host,String sourceToken,String mainProfile,String subProfile,String mainUri,String subUri,String mainRecording,String subRecording,int mainWidth,int mainHeight,int subWidth,int subHeight,int rotationDegrees,boolean doorbell){this.id=id;this.name=name;this.host=host;this.sourceToken=sourceToken;this.mainProfile=mainProfile;this.subProfile=subProfile;this.mainUri=mainUri;this.subUri=subUri;this.mainRecording=mainRecording;this.subRecording=subRecording;this.mainWidth=mainWidth;this.mainHeight=mainHeight;this.subWidth=subWidth;this.subHeight=subHeight;this.rotationDegrees=rotationDegrees;this.doorbell=doorbell;this.corridor=isCorridor(sourceToken,name);}
    }
    private CameraCatalog(){}

    static void save(SharedPreferences prefs,List<ThreeEyeState.Channel> channels){JSONArray array=new JSONArray();try{for(ThreeEyeState.Channel channel:channels){JSONObject item=new JSONObject();item.put("id",channel.id);item.put("name",channel.name);item.put("host",channel.host);array.put(item);}}catch(Exception ignored){}prefs.edit().putString(THREE_EYE_KEY,array.toString()).apply();}

    static void saveRecorder(SharedPreferences prefs,String recorderHost,ProfileGClient.ProbeResult probe){
        Map<String,Builder> grouped=new LinkedHashMap<>();for(ProfileGClient.MediaProfile profile:probe.profiles){String base=baseToken(profile.token,profile.sourceToken);Builder item=grouped.get(base);if(item==null){item=new Builder();item.source=base;grouped.put(base,item);}item.profiles.add(profile);}
        JSONArray array=new JSONArray();String plainHost=recorderHost.split(":")[0];try{for(Builder group:grouped.values()){ProfileGClient.MediaProfile main=null,sub=null;for(ProfileGClient.MediaProfile profile:group.profiles)if(main==null||pixels(profile)>pixels(main))main=profile;for(ProfileGClient.MediaProfile profile:group.profiles)if(profile!=main&&(sub==null||pixels(profile)<pixels(sub)))sub=profile;if(main==null)continue;String name=cleanName(main.name,group.source);JSONObject item=new JSONObject();item.put("id",group.source);item.put("name",name);item.put("host",plainHost);item.put("source",group.source);item.put("main_profile",main.token);item.put("sub_profile",sub==null?"":sub.token);item.put("main_uri",main.uri);item.put("sub_uri",sub==null?"":sub.uri);item.put("main_recording",recording(probe,group.source,name,false));item.put("sub_recording",recording(probe,group.source,name,true));item.put("main_width",main.width);item.put("main_height",main.height);item.put("sub_width",sub==null?0:sub.width);item.put("sub_height",sub==null?0:sub.height);item.put("rotation",main.rotation);item.put("doorbell",isDoorbellName(name));array.put(item);}}catch(Exception ignored){}
        prefs.edit().putString(RECORDER_KEY,array.toString()).putString("recorder_media_endpoint",probe.mediaEndpoint).putInt("recorder_camera_catalog_schema",RECORDER_SCHEMA).putLong("recorder_camera_catalog_updated",System.currentTimeMillis()).apply();
    }

    static List<Camera> load(SharedPreferences prefs){ArrayList<Camera> result=new ArrayList<>();String raw=prefs.getString(RECORDER_KEY,"");if(raw.isEmpty())raw=prefs.getString("camera_catalog","[]");try{JSONArray array=new JSONArray(raw);for(int i=0;i<array.length();i++){JSONObject o=array.getJSONObject(i);result.add(new Camera(o.optString("id"),o.optString("name"),o.optString("host"),o.optString("source",o.optString("id")),o.optString("main_profile"),o.optString("sub_profile"),o.optString("main_uri"),o.optString("sub_uri"),o.optString("main_recording"),o.optString("sub_recording"),o.optInt("main_width"),o.optInt("main_height"),o.optInt("sub_width"),o.optInt("sub_height"),o.optInt("rotation"),o.optBoolean("doorbell",isDoorbellName(o.optString("name")))));}}catch(Exception ignored){}if(result.isEmpty())result.add(new Camera("recorder","Recorder","192.168.13.234"));return result;}
    static Camera selected(SharedPreferences prefs){String id=prefs.getString("selected_camera_id",""),name=prefs.getString("selected_camera_name","");for(Camera camera:load(prefs))if((!id.isEmpty()&&id.equals(camera.id))||(!name.isEmpty()&&name.equalsIgnoreCase(camera.name)))return camera;return doorbell(prefs);}
    static void select(SharedPreferences prefs,Camera camera){prefs.edit().putString("selected_camera_id",camera.id).putString("selected_camera_name",camera.name).apply();}
    static Camera find(SharedPreferences prefs,String value){if(value!=null)for(Camera camera:load(prefs))if(value.equals(camera.id)||value.equals(camera.sourceToken)||value.equalsIgnoreCase(camera.name))return camera;return selected(prefs);}
    static Camera doorbell(SharedPreferences prefs){for(Camera camera:load(prefs))if(camera.doorbell)return camera;String configured=prefs.getString("threeeye_doorbell_camera","");if(!configured.isEmpty())for(Camera camera:load(prefs))if(configured.equalsIgnoreCase(camera.name))return camera;return load(prefs).get(0);}
    static Camera findBySource(SharedPreferences prefs,String token){if(token!=null&&!token.isEmpty()){String wanted=normal(token);for(Camera camera:load(prefs))if(normal(camera.sourceToken).equals(wanted)||normal(camera.mainProfile).contains(wanted)||normal(camera.subProfile).contains(wanted))return camera;}return doorbell(prefs);}
    static String recordingToken(Camera camera,boolean substream){if(camera==null)return "";String token=substream?camera.subRecording:camera.mainRecording;return token.isEmpty()?camera.mainRecording:token;}
    static int[] fallbackVideoSize(Camera camera,boolean substream){if(camera!=null&&substream&&camera.subWidth>0&&camera.subHeight>0)return new int[]{camera.subWidth,camera.subHeight};if(camera!=null&&camera.mainWidth>0&&camera.mainHeight>0)return new int[]{camera.mainWidth,camera.mainHeight};return new int[]{1920,1080};}
    static String liveUri(SharedPreferences prefs,Camera camera,boolean lowLatency){String raw=lowLatency?camera.subUri:camera.mainUri;if(raw.isEmpty())return "";String user=prefs.getString("profile_g_user",""),password=prefs.getString("profile_g_password","");try{Uri uri=Uri.parse(raw);if(uri.getUserInfo()!=null||user.isEmpty())return raw;String authority=Uri.encode(user)+":"+Uri.encode(password)+"@"+uri.getEncodedAuthority();return uri.buildUpon().encodedAuthority(authority).build().toString();}catch(Exception ignored){return raw;}}
    static int displayRotation(Camera camera){if(camera==null)return 0;return camera.rotationDegrees==90||camera.rotationDegrees==180||camera.rotationDegrees==270?camera.rotationDegrees:0;}
    static float encodedAspect(Camera camera){if(camera!=null&&camera.mainWidth>0&&camera.mainHeight>0)return camera.mainWidth/(float)camera.mainHeight;return 16f/9f;}
    static float mainAspect(Camera camera){float encoded=encodedAspect(camera);if(displayRotation(camera)==90||displayRotation(camera)==270)return 1f/encoded;if(camera!=null&&camera.corridor)return 9f/16f;return encoded;}
    static float playerAspect(Camera camera){return displayRotation(camera)==90||displayRotation(camera)==270?encodedAspect(camera):mainAspect(camera);}
    static float[] textureFit(float aspect,int width,int height){if(aspect<=0||width<=0||height<=0)return new float[]{1f,1f};float viewAspect=width/(float)height;if(aspect>viewAspect)return new float[]{1f,viewAspect/aspect};return new float[]{aspect/viewAspect,1f};}

    private static String recording(ProfileGClient.ProbeResult probe,String source,String name,boolean sub){ProfileGClient.Recording fallback=null;String wanted=normal(source),wantedName=normal(name);for(ProfileGClient.Recording r:probe.recordings){boolean isSub=ProfileGRepository.isSub(r);String hay=normal(r.token+" "+r.sourceId+" "+r.name);if((hay.contains(wanted)||hay.contains(wantedName))&&isSub==sub)return r.token;if((hay.contains(wanted)||hay.contains(wantedName))&&fallback==null)fallback=r;}return fallback==null?"":fallback.token;}
    private static String baseToken(String token,String source){if(source!=null&&!source.isEmpty())return source;String value=token==null?"":token;return value.replaceFirst("(?i)(?:-main|-sub)$","");}
    private static String cleanName(String name,String fallback){String value=name==null?"":name.replaceFirst("(?i)(?:[_ -](?:main|sub|secondary))$","").trim();return value.isEmpty()?fallback:value;}
    private static boolean isDoorbellName(String name){String value=normal(name);return value.contains("doorbell")||value.contains("doorchime")||value.contains("звонок")||value.matches("db\\d.*");}
    private static boolean isCorridor(String source,String name){String token=source==null?"":source;String value=normal(name);return token.startsWith("JasU1Wn1xB-")||token.startsWith("RufpaSMY9J-")||token.startsWith("NyNMfSr7K1-")||value.contains("vertical");}
    private static String normal(String value){return value==null?"":value.toLowerCase(Locale.US).replaceAll("[^\\p{L}\\p{N}]+","");}
    private static long pixels(ProfileGClient.MediaProfile profile){return Math.max(0,profile.width)*(long)Math.max(0,profile.height);}
    private static final class Builder{String source;final List<ProfileGClient.MediaProfile> profiles=new ArrayList<>();}
}
