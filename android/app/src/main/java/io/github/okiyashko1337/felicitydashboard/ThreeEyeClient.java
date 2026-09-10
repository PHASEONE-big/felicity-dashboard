package io.github.okiyashko1337.felicitydashboard;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.HashMap;
import java.util.Map;

final class ThreeEyeClient {
    interface Callback { void done(boolean ok,String error); }
    private final ThreeEyeState state;
    private final Map<String,Bitmap> images=new HashMap<>();
    private volatile String user="",password="";

    ThreeEyeClient(ThreeEyeState state){this.state=state;}
    void configure(String url,String user,String password){state.baseUrl=trim(url);this.user=user==null?"":user;this.password=password==null?"":password;}
    void load(Callback callback){
        try{
            JSONObject channels=json("/api/channels");JSONArray channelItems=channels.optJSONArray("channels");
            synchronized(state.cameras){state.cameras.clear();state.channels.clear();if(channelItems!=null)for(int i=0;i<channelItems.length();i++){JSONObject item=channelItems.getJSONObject(i);ThreeEyeState.Channel channel=new ThreeEyeState.Channel();channel.id=item.optString("id");channel.name=item.optString("name");channel.host=item.optString("host");state.cameras.add(channel.name);state.channels.add(channel);}}
            StringBuilder path=new StringBuilder("/api/objects?limit=").append(Math.max(1,Math.min(200,state.limit)));
            if(!"ALL".equals(state.camera))path.append("&cameras=").append(enc(state.camera));
            if(!"ALL".equals(state.objectClass))path.append("&classes=").append(enc(state.objectClass.toLowerCase()));else if(!(state.allowPerson&&state.allowAnimal&&state.allowVehicle&&state.allowFace)){if(state.allowPerson)path.append("&classes=person");if(state.allowVehicle)path.append("&classes=vehicle");if(state.allowAnimal)path.append("&classes=animal");if(state.allowFace)path.append("&classes=face");}
            if(state.minimumConfidence>0){String[] kinds={"person","vehicle","animal"};for(String kind:kinds)path.append("&min_").append(kind).append('=').append(state.minimumConfidence/100.0);}
            if(state.includeUncertain)path.append("&include_uncertain=true");
            JSONArray source=json(path.toString()).getJSONArray("objects");
            java.util.ArrayList<ThreeEyeState.Event> next=new java.util.ArrayList<>();
            for(int i=0;i<source.length();i++){JSONObject o=source.getJSONObject(i);ThreeEyeState.Event e=new ThreeEyeState.Event();e.trackId=o.optLong("track_id");e.objectClass=o.optString("object_class","object");e.capturedAt=bestViewTime(o);e.firstSeen=first(o,"first_seen_utc","group_first_seen_utc",e.capturedAt);e.lastSeen=first(o,"last_seen_utc","group_last_seen_utc",e.capturedAt);e.camera=o.optString("camera_name","—");e.externalTrack=o.optString("external_track_id","—");e.confidence=o.optDouble("confidence");e.verification=o.optString("verification_status","confirmed");e.groupMembers=o.optInt("group_member_count",1);e.groupCameras=o.optInt("group_camera_count",1);e.thumbnailUrl=absolute(o.optString("thumbnail_url"));e.imageUrl=absolute(o.optString("image_url"));e.thumbnail=images.get(e.thumbnailUrl);next.add(e);}
            synchronized(state){long selectedId=state.selected() == null?-1:state.selected().trackId;state.events.clear();state.events.addAll(next);state.selected=-1;for(int i=0;i<next.size();i++)if(next.get(i).trackId==selectedId)state.selected=i;state.updatedMs=System.currentTimeMillis();state.status="LIVE";state.error="";}
            if(state.loadThumbnails)for(int i=0;i<Math.min(18,next.size());i++){ThreeEyeState.Event e=next.get(i);if(e.thumbnail==null){try{e.thumbnail=bitmap(e.thumbnailUrl,320);if(e.thumbnail!=null)images.put(e.thumbnailUrl,e.thumbnail);}catch(Exception ignored){}}}
            callback.done(true,null);
        }catch(Exception e){state.status="OFFLINE";state.error=e.getMessage()==null?e.getClass().getSimpleName():e.getMessage();callback.done(false,state.error);}
    }
    void loadSelectedImage(ThreeEyeState.Event event,Callback callback){try{if(event!=null&&event.image==null)event.image=bitmap(event.imageUrl,1280);callback.done(event!=null,event==null?"No event":null);}catch(Exception e){callback.done(false,e.getMessage());}}
    private JSONObject json(String path)throws Exception{HttpURLConnection c=open(absolute(path));try{int code=c.getResponseCode();if(code!=200)throw new Exception("3ye HTTP "+code);return new JSONObject(read(c.getInputStream()));}finally{c.disconnect();}}
    private Bitmap bitmap(String address,int max)throws Exception{if(address.isEmpty())return null;HttpURLConnection c=open(address);try{if(c.getResponseCode()!=200)return null;Bitmap raw=BitmapFactory.decodeStream(c.getInputStream());if(raw==null||raw.getWidth()<=max)return raw;int h=Math.max(1,raw.getHeight()*max/raw.getWidth());Bitmap scaled=Bitmap.createScaledBitmap(raw,max,h,true);if(scaled!=raw)raw.recycle();return scaled;}finally{c.disconnect();}}
    private HttpURLConnection open(String address)throws Exception{HttpURLConnection c=(HttpURLConnection)new URL(address).openConnection();c.setConnectTimeout(3500);c.setReadTimeout(6000);c.setUseCaches(false);if(!user.isEmpty()){String token=Base64.encodeToString((user+":"+password).getBytes("UTF-8"),Base64.NO_WRAP);c.setRequestProperty("Authorization","Basic "+token);}return c;}
    private String absolute(String value){if(value==null||value.isEmpty())return "";return value.startsWith("http://")||value.startsWith("https://")?value:state.baseUrl+value;}
    private static String trim(String value){String v=value==null?"":value.trim();while(v.endsWith("/"))v=v.substring(0,v.length()-1);return v;}
    private static String enc(String value)throws Exception{return URLEncoder.encode(value,"UTF-8");}
    static String bestViewTime(JSONObject object){return bestViewTime(object.optString("captured_at_utc",""),object.optString("group_last_seen_utc",""));}
    private static String first(JSONObject object,String primary,String secondary,String fallback){String value=object.optString(primary,"").trim();if(value.isEmpty())value=object.optString(secondary,"").trim();return value.isEmpty()?fallback:value;}
    static String bestViewTime(String capturedAt,String groupLastSeen){
        String captured=capturedAt==null?"":capturedAt.trim();
        return captured.isEmpty()?(groupLastSeen==null?"":groupLastSeen.trim()):captured;
    }
    private static String read(InputStream input)throws Exception{BufferedReader r=new BufferedReader(new InputStreamReader(input));StringBuilder b=new StringBuilder();String line;while((line=r.readLine())!=null)b.append(line);return b.toString();}
}
