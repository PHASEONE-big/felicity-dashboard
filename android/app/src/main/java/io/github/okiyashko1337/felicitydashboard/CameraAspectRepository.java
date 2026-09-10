package io.github.okiyashko1337.felicitydashboard;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.util.Log;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.interfaces.IMedia;

final class CameraAspectRepository {
    private static final ExecutorService executor=Executors.newSingleThreadExecutor();
    private static final Set<String> inFlight=new HashSet<>();
    private CameraAspectRepository(){}

    static float get(SharedPreferences prefs,CameraCatalog.Camera camera){if(camera!=null&&camera.corridor)return CameraCatalog.mainAspect(camera);return prefs.getFloat(key(camera),CameraCatalog.mainAspect(camera));}

    static void probe(Context context,SharedPreferences prefs,CameraCatalog.Camera camera){
        if(camera==null||camera.corridor||camera.mainUri.isEmpty()||prefs.contains(key(camera)))return;
        synchronized(inFlight){if(!inFlight.add(camera.id))return;}
        Context app=context.getApplicationContext();
        executor.execute(()->{LibVLC vlc=null;Media media=null;try{
            ArrayList<String> options=new ArrayList<>();options.add("--rtsp-tcp");options.add("--network-caching=150");
            vlc=new LibVLC(app,options);media=new Media(vlc,Uri.parse(CameraCatalog.liveUri(prefs,camera,false)));media.addOption(":rtsp-tcp");
            CountDownLatch parsed=new CountDownLatch(1);media.setEventListener(event->{if(event.type==IMedia.Event.ParsedChanged)parsed.countDown();});media.parseAsync(IMedia.Parse.ParseNetwork,10000);parsed.await(12,TimeUnit.SECONDS);
            float aspect=0f;for(int i=0;i<media.getTrackCount();i++){IMedia.Track track=media.getTrack(i);if(track instanceof IMedia.VideoTrack){IMedia.VideoTrack video=(IMedia.VideoTrack)track;if(video.width>0&&video.height>0){int sarNum=video.sarNum>0?video.sarNum:1,sarDen=video.sarDen>0?video.sarDen:1;aspect=video.width*(float)sarNum/(video.height*(float)sarDen);break;}}}
            if(aspect>.5f&&aspect<4f){prefs.edit().putFloat(key(camera),aspect).putLong(key(camera)+"_checked",System.currentTimeMillis()).apply();Log.i("FelicityCamera","Main DAR cached · "+camera.name+" · "+String.format(java.util.Locale.US,"%.4f",aspect));}
        }catch(Exception ignored){}finally{if(media!=null)media.release();if(vlc!=null)vlc.release();synchronized(inFlight){inFlight.remove(camera.id);}}});
    }

    private static String key(CameraCatalog.Camera camera){return "camera_main_aspect_"+camera.id;}
}
