package io.github.okiyashko1337.felicitydashboard;

import android.app.Activity;
import android.Manifest;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.net.Uri;
import android.os.Bundle;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.TextureView;
import android.view.View;
import android.view.VelocityTracker;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.OverScroller;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Locale;
import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;
import org.videolan.libvlc.interfaces.IMedia;
import org.videolan.libvlc.interfaces.IVLCVout;

public final class CameraActivity extends Activity {
    private static final long TALK_TIMEOUT_MS=30_000L;
    private FrameLayout videoContainer;
    private LibVLC vlc;private MediaPlayer player;private TextureView surface;private TextView clock,stats;private Button qualityButton;private PrivacyButton muteButton,micButton;private ImageView ringSnapshot,poster;private Bitmap ringBitmap,posterBitmap;private boolean muted=true,listenEnabled,audioReady,micEnabled,ringEvent,videoLayoutKnown,substream;private BackchannelSession backchannel;private OnvifAudioSession inboundAudio;private float zoom=1f,panX,panY,smoothedFps=-1f,smoothedKbps=-1f,displayAspect=16f/9f;private int videoWidth=1024,videoHeight=576,lastPictures,lastReadBytes=-1;private long lastStatsMs;private OverScroller scroller;
    private final android.os.Handler handler=new android.os.Handler(android.os.Looper.getMainLooper());private boolean snapshotTaken,created;
    private long streamStartedMs;private int streamGeneration;
    private SharedPreferences prefs;private CameraCatalog.Camera camera;private String backLabel="‹ ENERGY",backDestination="finish",originBackLabel="‹ ENERGY";private int pickerPage;
    private final Runnable finishRunnable=()->{forcePrivacyMute();finish();};
    private final Runnable talkTimeoutRunnable=()->{android.util.Log.i("FelicityAudio","Microphone safety timeout · 30 s");forcePrivacyMute();if(ringEvent)finish();};
    private final Runnable uiTick=new Runnable(){@Override public void run(){clock.setText(new SimpleDateFormat("dd.MM.yyyy\nHH:mm:ss",Locale.getDefault()).format(new Date()));updateStats();if(zoom<=1.001f)fitSurface();handler.postDelayed(this,1000);}};

    @Override protected void onCreate(Bundle state){super.onCreate(state);prefs=getSharedPreferences("felicity",MODE_PRIVATE);String requested=getIntent().getStringExtra("camera_name");camera=CameraCatalog.find(prefs,requested);String requestedBack=getIntent().getStringExtra("back_label");if(requestedBack!=null&&!requestedBack.isEmpty())backLabel=requestedBack;backDestination=getIntent().getStringExtra("back_destination");if(backDestination==null||backDestination.isEmpty())backDestination="finish";String requestedOrigin=getIntent().getStringExtra("origin_back_label");originBackLabel=requestedOrigin==null||requestedOrigin.isEmpty()?("‹ CAMERAS".equals(backLabel)?"‹ ENERGY":backLabel):requestedOrigin;pickerPage=getIntent().getIntExtra("picker_page",0);CameraCatalog.select(prefs,camera);substream=StreamQuality.useSubstream(this,prefs,camera);int[] fallback=CameraCatalog.fallbackVideoSize(camera,substream);videoWidth=fallback[0];videoHeight=fallback[1];videoLayoutKnown=true;displayAspect=CameraAspectRepository.get(prefs,camera);CameraAspectRepository.probe(this,prefs,camera);ringEvent=getIntent().getBooleanExtra("ring",false);boolean redNight=getIntent().getBooleanExtra("red_night",false);int foreground=redNight?Color.rgb(255,72,52):Color.WHITE,accent=redNight?Color.rgb(210,35,25):Color.rgb(89,222,209),panel=redNight?Color.rgb(30,0,0):Color.rgb(7,17,15);getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);if(redNight){WindowManager.LayoutParams attributes=getWindow().getAttributes();attributes.screenBrightness=.18f;getWindow().setAttributes(attributes);}DeviceUi.apply(this);FrameLayout root=new FrameLayout(this);root.setBackgroundColor(Color.BLACK);float ui=Math.min(getResources().getDisplayMetrics().widthPixels/960f,getResources().getDisplayMetrics().heightPixels/480f);
        videoContainer=new FrameLayout(this);FrameLayout.LayoutParams videoParams=new FrameLayout.LayoutParams(-1,-1);videoParams.topMargin=Math.round(64*ui);root.addView(videoContainer,videoParams);surface=new TextureView(this);surface.setOpaque(false);videoContainer.addView(surface,new FrameLayout.LayoutParams(-1,-1,Gravity.CENTER));poster=new ImageView(this);poster.setBackgroundColor(Color.BLACK);poster.setScaleType(ImageView.ScaleType.FIT_CENTER);videoContainer.addView(poster,new FrameLayout.LayoutParams(-1,-1,Gravity.CENTER));CameraOrientation.apply(videoContainer,surface,camera);scroller=new OverScroller(this);installZoom();
        ringSnapshot=new ImageView(this);ringSnapshot.setScaleType(ImageView.ScaleType.CENTER_CROP);ringSnapshot.setVisibility(View.GONE);android.graphics.drawable.GradientDrawable snapshotFrame=new android.graphics.drawable.GradientDrawable();snapshotFrame.setColor(panel);snapshotFrame.setStroke(Math.max(2,Math.round(2*ui)),accent);snapshotFrame.setCornerRadius(12*ui);ringSnapshot.setBackground(snapshotFrame);ringSnapshot.setPadding(3,3,3,3);FrameLayout.LayoutParams rp=new FrameLayout.LayoutParams(Math.round(250*ui),Math.round(142*ui),Gravity.BOTTOM|Gravity.LEFT);rp.setMargins(Math.round(18*ui),0,0,Math.round(18*ui));root.addView(ringSnapshot,rp);
        View header=new HeaderBackground(this,redNight);root.addView(header,new FrameLayout.LayoutParams(-1,Math.round(64*ui),Gravity.TOP));Button back=button(backLabel,redNight);back.setTextSize(10.5f*ui);FrameLayout.LayoutParams bp=new FrameLayout.LayoutParams(Math.round(92*ui),Math.round(50*ui),Gravity.TOP|Gravity.LEFT);bp.setMargins(Math.round(48*ui),Math.round(7*ui),0,0);root.addView(back,bp);back.setOnClickListener(v->navigateBack());
        Button cameraButton=button(camera.name,redNight);cameraButton.setTextSize(9.5f*ui);FrameLayout.LayoutParams cap=new FrameLayout.LayoutParams(Math.round(116*ui),Math.round(50*ui),Gravity.TOP|Gravity.LEFT);cap.setMargins(Math.round(142*ui),Math.round(7*ui),0,0);root.addView(cameraButton,cap);cameraButton.setOnClickListener(v->pickCamera(false));
        stats=new TextView(this);stats.setText("CONNECTING…");stats.setTextColor(foreground);stats.setTextSize(10.5f*ui);stats.setGravity(Gravity.CENTER);stats.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);stats.setLines(2);FrameLayout.LayoutParams sp=new FrameLayout.LayoutParams(Math.round(160*ui),Math.round(58*ui),Gravity.TOP|Gravity.LEFT);sp.setMargins(Math.round(260*ui),Math.round(3*ui),0,0);root.addView(stats,sp);
        muteButton=new PrivacyButton(this,false,redNight);FrameLayout.LayoutParams mup=new FrameLayout.LayoutParams(Math.round(48*ui),Math.round(50*ui),Gravity.TOP|Gravity.LEFT);mup.setMargins(Math.round(422*ui),Math.round(7*ui),0,0);root.addView(muteButton,mup);muteButton.setOnClickListener(v->toggleMute());
        micButton=new PrivacyButton(this,true,redNight);FrameLayout.LayoutParams mip=new FrameLayout.LayoutParams(Math.round(48*ui),Math.round(50*ui),Gravity.TOP|Gravity.LEFT);mip.setMargins(Math.round(472*ui),Math.round(7*ui),0,0);root.addView(micButton,mip);micButton.setOnClickListener(v->toggleMic());
        Button events=button("EVENTS",redNight);events.setTextSize(10*ui);FrameLayout.LayoutParams ep=new FrameLayout.LayoutParams(Math.round(78*ui),Math.round(48*ui),Gravity.TOP|Gravity.LEFT);ep.setMargins(Math.round(522*ui),Math.round(8*ui),0,0);root.addView(events,ep);events.setOnClickListener(v->openEvents());
        Button archive=button("ARCHIVE",redNight);archive.setTextSize(9*ui);FrameLayout.LayoutParams ap=new FrameLayout.LayoutParams(Math.round(84*ui),Math.round(48*ui),Gravity.TOP|Gravity.LEFT);ap.setMargins(Math.round(602*ui),Math.round(8*ui),0,0);root.addView(archive,ap);archive.setOnClickListener(v->openArchive());
        qualityButton=button(substream?"LQ":"HQ",redNight);qualityButton.setTextSize(11*ui);qualityButton.setContentDescription("Toggle stream quality");FrameLayout.LayoutParams qp=new FrameLayout.LayoutParams(Math.round(64*ui),Math.round(48*ui),Gravity.TOP|Gravity.LEFT);qp.setMargins(Math.round(688*ui),Math.round(8*ui),0,0);root.addView(qualityButton,qp);qualityButton.setOnClickListener(v->toggleQuality());
        clock=new TextView(this);clock.setTextColor(foreground);clock.setTextSize(15*ui);clock.setGravity(Gravity.RIGHT|Gravity.CENTER_VERTICAL);clock.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);clock.setLines(2);FrameLayout.LayoutParams cp=new FrameLayout.LayoutParams(Math.round(194*ui),Math.round(58*ui),Gravity.TOP|Gravity.RIGHT);cp.setMargins(0,Math.round(3*ui),Math.round(12*ui),0);root.addView(clock,cp);
        setContentView(root);updateStatus();created=true;handler.post(uiTick);scheduleFinish();}

    private void installZoom(){
        GestureDetector doubleTap=new GestureDetector(this,new GestureDetector.SimpleOnGestureListener(){
            @Override public boolean onDown(MotionEvent e){return true;}
            @Override public boolean onDoubleTap(MotionEvent e){
                if(zoom>1.05f){zoom=1f;panX=panY=0;applyZoom();}
                else{float[] point=screenPoint(e,0);zoomAt(point[0],point[1],2.5f);}
                return true;
            }
        });
        surface.setOnTouchListener(new View.OnTouchListener(){
            float pinchStartSpan,pinchStartZoom,pinchFocusX,pinchFocusY,lastX,lastY;
            boolean pinching,moved;
            VelocityTracker velocity;

            @Override public boolean onTouch(View view,MotionEvent event){
                doubleTap.onTouchEvent(event);
                switch(event.getActionMasked()){
                    case MotionEvent.ACTION_DOWN:
                        scroller.forceFinished(true);pinching=false;moved=false;
                        lastX=event.getX();lastY=event.getY();
                        velocity=VelocityTracker.obtain();velocity.addMovement(event);
                        return true;
                    case MotionEvent.ACTION_POINTER_DOWN:
                        if(event.getPointerCount()>=2){
                            scroller.forceFinished(true);pinching=true;moved=true;
                            float[] geometry=pinchGeometry(event);
                            pinchStartSpan=Math.max(1f,geometry[0]);pinchFocusX=geometry[1];pinchFocusY=geometry[2];
                            pinchStartZoom=zoom;
                            if(velocity!=null)velocity.clear();
                        }
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        if(pinching&&event.getPointerCount()>=2){
                            float[] geometry=pinchGeometry(event);
                            float next=Math.max(1f,Math.min(6f,pinchStartZoom*geometry[0]/pinchStartSpan));
                            if(next<1.035f)next=1f;
                            panX+=geometry[1]-pinchFocusX;panY+=geometry[2]-pinchFocusY;
                            pinchFocusX=geometry[1];pinchFocusY=geometry[2];
                            zoomAt(pinchFocusX,pinchFocusY,next);
                        }else if(!pinching&&event.getPointerCount()==1&&zoom>1f){
                            float x=event.getX(),y=event.getY();
                            panX+=(x-lastX)*zoom;panY+=(y-lastY)*zoom;lastX=x;lastY=y;moved=true;applyZoom();
                            if(velocity!=null)velocity.addMovement(event);
                        }
                        return true;
                    case MotionEvent.ACTION_POINTER_UP:
                        if(pinching){
                            pinching=false;
                            if(zoom<1.08f){zoom=1f;panX=panY=0;applyZoom();}
                            int remaining=event.getActionIndex()==0?1:0;
                            if(remaining<event.getPointerCount()){lastX=event.getX(remaining);lastY=event.getY(remaining);}
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                        if(zoom<1.08f){zoom=1f;panX=panY=0;applyZoom();}
                        else if(!moved&&zoom>1f){applyZoom();}
                        fling(velocity);recycleVelocity();return true;
                    case MotionEvent.ACTION_CANCEL:
                        recycleVelocity();pinching=false;return true;
                    default:return true;
                }
            }

            private void fling(VelocityTracker tracker){
                if(tracker==null||pinching||zoom<=1f)return;
                tracker.computeCurrentVelocity(1000);
                float[] bounds=panBounds();
                scroller.fling(Math.round(panX),Math.round(panY),Math.round(tracker.getXVelocity()*zoom),Math.round(tracker.getYVelocity()*zoom),Math.round(-bounds[0]),Math.round(bounds[0]),Math.round(-bounds[1]),Math.round(bounds[1]));
                surface.postOnAnimation(CameraActivity.this::continueFling);
            }
            private void recycleVelocity(){if(velocity!=null){velocity.recycle();velocity=null;}}
        });
    }
    private float[] screenPoint(MotionEvent event,int index){float[] point={event.getX(index),event.getY(index)};surface.getMatrix().mapPoints(point);return point;}
    private float[] pinchGeometry(MotionEvent event){float[] a=screenPoint(event,0),b=screenPoint(event,1);float dx=b[0]-a[0],dy=b[1]-a[1];return new float[]{(float)Math.hypot(dx,dy),(a[0]+b[0])/2f,(a[1]+b[1])/2f};}
    private void zoomAt(float focusX,float focusY,float next){float old=zoom,ratio=next/old,cx=surface.getWidth()/2f,cy=surface.getHeight()/2f;panX=ratio*panX+(1-ratio)*(focusX-cx);panY=ratio*panY+(1-ratio)*(focusY-cy);zoom=next;if(zoom<=1.001f){zoom=1f;panX=panY=0;}applyZoom();}
    private float[] panBounds(){float vw=surface.getWidth(),vh=surface.getHeight(),videoAspect=displayAspect,viewAspect=vw/Math.max(1f,vh),baseW,baseH;if(videoAspect>viewAspect){baseW=vw;baseH=vw/videoAspect;}else{baseH=vh;baseW=vh*videoAspect;}return new float[]{Math.max(0,(baseW*zoom-vw)/2f),Math.max(0,(baseH*zoom-vh)/2f)};}
    private void applyZoom(){if(zoom<=1.001f)fitSurface();float[] bounds=panBounds();panX=Math.max(-bounds[0],Math.min(bounds[0],panX));panY=Math.max(-bounds[1],Math.min(bounds[1],panY));surface.setPivotX(surface.getWidth()/2f);surface.setPivotY(surface.getHeight()/2f);surface.setScaleX(zoom);surface.setScaleY(zoom);surface.setTranslationX(panX);surface.setTranslationY(panY);updateStats();}
    private void fitSurface(){if(player==null||videoContainer==null)return;displayAspect=CameraAspectRepository.get(prefs,camera);int cw=videoContainer.getWidth(),ch=videoContainer.getHeight();if(cw<1||ch<1)return;float playerAspect=CameraCatalog.playerAspect(camera);player.setVideoScale(MediaPlayer.ScaleType.SURFACE_BEST_FIT);player.setAspectRatio(Math.max(1,Math.round(playerAspect*1000))+":1000");player.setScale(0);player.getVLCVout().setWindowSize(cw,ch);}
    private void continueFling(){if(scroller.computeScrollOffset()){panX=scroller.getCurrX();panY=scroller.getCurrY();applyZoom();surface.postOnAnimation(this::continueFling);}}
    private void startPlayer(){
        if(player!=null)return;
        showPoster();
        String url=CameraCatalog.liveUri(prefs,camera,substream);
        if(url.isEmpty()){stats.setText("REFRESH RECORDER");micEnabled=false;micButton.setEnabled(false);return;}
        final int generation=++streamGeneration;
        streamStartedMs=android.os.SystemClock.elapsedRealtime();
        android.util.Log.i("FelicityVideo","RTSP start · camera="+camera.name+" · "+(substream?"LQ":"HQ"));
        ArrayList<String> options=new ArrayList<>();options.add("--rtsp-tcp");options.add("--network-caching=180");
        vlc=new LibVLC(this,options);player=new MediaPlayer(vlc);player.setUseOrientationFromBounds(false);player.setVolume(0);player.setVideoScale(MediaPlayer.ScaleType.SURFACE_BEST_FIT);
        IVLCVout output=player.getVLCVout();output.setVideoView(surface);output.attachViews((vout,width,height,visibleWidth,visibleHeight,sarNum,sarDen)->runOnUiThread(()->{if(generation==streamGeneration&&visibleWidth>0&&visibleHeight>0){videoWidth=visibleWidth;videoHeight=visibleHeight;videoLayoutKnown=true;fitSurface();}}));
        player.setEventListener(event->{
            if(event.type==MediaPlayer.Event.Vout&&event.getVoutCount()>0){
                long firstFrameMs=android.os.SystemClock.elapsedRealtime()-streamStartedMs;android.util.Log.i("FelicityVideo","First video output · camera="+camera.name+" · "+(substream?"LQ":"HQ")+" · "+firstFrameMs+" ms");
                runOnUiThread(()->{if(generation!=streamGeneration||player==null)return;player.setVideoScale(MediaPlayer.ScaleType.SURFACE_BEST_FIT);zoom=1f;panX=panY=0;applyZoom();audioReady=true;setInboundVolume();updateStatus();awaitLiveFrame(generation,0);takePreview();});
            }else if(event.type==MediaPlayer.Event.EncounteredError)runOnUiThread(()->{if(generation==streamGeneration)stats.setText("STREAM ERROR");});
        });
        Media media=new Media(vlc,Uri.parse(url));media.setHWDecoderEnabled(true,false);media.addOption(":rtsp-tcp");media.addOption(":network-caching=180");if(camera.doorbell)media.addOption(":no-audio");player.setMedia(media);media.release();player.play();
        if(camera.doorbell){String user=prefs.getString("profile_g_user",""),password=prefs.getString("profile_g_password","");inboundAudio=new OnvifAudioSession(this,url,user,password);inboundAudio.setVolume(0);inboundAudio.start();}
        micEnabled=false;micButton.setEnabled(camera.doorbell);
    }

    private void showPoster(){hidePoster();File file=new File(getFilesDir(),"camera-preview-"+camera.id+".jpg");BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;BitmapFactory.decodeFile(file.getAbsolutePath(),bounds);if(bounds.outWidth<1||bounds.outHeight<1){poster.setVisibility(View.GONE);return;}int sample=1;while(bounds.outWidth/sample>1280||bounds.outHeight/sample>720)sample*=2;BitmapFactory.Options options=new BitmapFactory.Options();options.inSampleSize=sample;options.inPreferredConfig=Bitmap.Config.RGB_565;posterBitmap=BitmapFactory.decodeFile(file.getAbsolutePath(),options);if(posterBitmap!=null){poster.setAlpha(1f);poster.setImageBitmap(posterBitmap);poster.setVisibility(View.VISIBLE);}else poster.setVisibility(View.GONE);}
    private void awaitLiveFrame(int generation,int attempt){if(generation!=streamGeneration||player==null)return;IMedia media=player.getMedia();IMedia.Stats live=media==null?null:media.getStats();boolean rendered=live!=null&&live.displayedPictures>0;if(rendered){if(poster.getVisibility()==View.VISIBLE)poster.animate().alpha(0f).setDuration(140).withEndAction(this::hidePoster).start();return;}if(attempt<200)handler.postDelayed(()->awaitLiveFrame(generation,attempt+1),50);}
    private void hidePoster(){if(poster==null)return;poster.setImageDrawable(null);poster.setVisibility(View.GONE);if(posterBitmap!=null){posterBitmap.recycle();posterBitmap=null;}}

    private void toggleQuality(){substream=!substream;StreamQuality.select(prefs,camera,substream);if(qualityButton!=null)qualityButton.setText(substream?"LQ":"HQ");int[] fallback=CameraCatalog.fallbackVideoSize(camera,substream);videoWidth=fallback[0];videoHeight=fallback[1];lastStatsMs=0;lastPictures=0;lastReadBytes=-1;smoothedFps=smoothedKbps=-1f;stats.setText((substream?"LQ":"HQ")+" CONNECTING…");stopPlayer();startPlayer();}

    private void stopPlayer(){streamGeneration++;audioReady=false;if(inboundAudio!=null){inboundAudio.stop();inboundAudio=null;}if(player!=null){try{player.setEventListener(null);player.stop();player.getVLCVout().detachViews();}catch(Exception ignored){}player.release();player=null;}if(vlc!=null){vlc.release();vlc=null;}}

    private void openEvents(){startActivity(new Intent(this,EventsActivity.class).putExtra("camera_name",camera.name).putExtra("back_label","‹ LIVE"));}
    private void openArchive(){startActivity(new Intent(this,ArchiveActivity.class).putExtra("camera",camera.name).putExtra("from_live",true).putExtra("back_label","‹ LIVE"));}
    private void pickCamera(boolean fromBack){Intent picker=new Intent(this,CameraPickerActivity.class).putExtra("initial_page",pickerPage);if(fromBack)picker.putExtra("back_label",originBackLabel).putExtra("close_camera_on_back",true);else picker.putExtra("back_label","‹ LIVE");startActivityForResult(picker,CameraPickerActivity.REQUEST);}
    private void navigateBack(){if("cameras".equals(backDestination)){pickCamera(true);return;}finish();}
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request!=CameraPickerActivity.REQUEST)return;if(result!=RESULT_OK||data==null){if(data!=null&&data.getBooleanExtra("close_camera",false))finish();return;}CameraCatalog.Camera selected=CameraCatalog.find(prefs,data.getStringExtra("camera_name"));pickerPage=data.getIntExtra("camera_page",pickerPage);CameraCatalog.select(prefs,selected);startActivity(new Intent(this,CameraActivity.class).putExtra("manual",true).putExtra("camera_id",selected.id).putExtra("camera_name",selected.name).putExtra("back_label","‹ CAMERAS").putExtra("back_destination","cameras").putExtra("origin_back_label",originBackLabel).putExtra("picker_page",pickerPage));finish();}
    private void updateStats(){if(player==null)return;IMedia.VideoTrack track=player.getCurrentVideoTrack();IMedia media=player.getMedia();IMedia.Stats live=media==null?null:media.getStats();String codec="H264";int width=videoWidth,height=videoHeight;float fps=0;if(track!=null){String raw=track.codec==null?"":track.codec.toUpperCase(Locale.US);codec=raw.contains("H265")||raw.contains("HEVC")?"H265":raw.contains("H264")||raw.contains("AVC")?"H264":raw.length()>8?raw.substring(0,8):raw;if(track.width>0&&track.height>0){width=track.width;height=track.height;videoWidth=width;videoHeight=height;}if(track.frameRateDen>0)fps=(float)track.frameRateNum/track.frameRateDen;}if(live!=null){long now=System.currentTimeMillis(),elapsed=lastStatsMs>0?now-lastStatsMs:0;int trafficBytes=Math.max(live.readBytes,live.demuxReadBytes);if(elapsed>0&&live.displayedPictures>=lastPictures){float measuredFps=(live.displayedPictures-lastPictures)*1000f/elapsed;smoothedFps=smoothedFps<0f?measuredFps:smoothedFps*.9f+measuredFps*.1f;}float measuredKbps=0;if(elapsed>0&&lastReadBytes>=0&&trafficBytes>=lastReadBytes)measuredKbps=(trafficBytes-lastReadBytes)*8f/elapsed;if(measuredKbps<=0){float nativeRate=Math.max(live.inputBitrate,live.demuxBitrate);if(nativeRate>0)measuredKbps=nativeRate*8000f;}if(measuredKbps>0)smoothedKbps=smoothedKbps<0f?measuredKbps:smoothedKbps*.8f+measuredKbps*.2f;lastPictures=live.displayedPictures;lastReadBytes=trafficBytes;lastStatsMs=now;}if(smoothedFps>=0f)fps=smoothedFps;String bitrate=smoothedKbps<0f?"—":Integer.toString(Math.round(smoothedKbps));String first=bitrate+" kbps · "+String.format(Locale.US,"%.1f",fps)+" FPS",resolution=width+"×"+height,second=resolution+" · "+codec,value=first+"\n"+second;android.text.SpannableString styled=new android.text.SpannableString(value);styled.setSpan(new android.text.style.RelativeSizeSpan(1.22f),0,bitrate.length(),android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);int resolutionStart=first.length()+1;styled.setSpan(new android.text.style.RelativeSizeSpan(1.28f),resolutionStart,resolutionStart+resolution.length(),android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);int codecStart=value.length()-codec.length();styled.setSpan(new android.text.style.RelativeSizeSpan(.72f),codecStart,value.length(),android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);stats.setText(styled);}
    private void toggleMute(){muted=!muted;if(muted){listenEnabled=false;micEnabled=false;if(backchannel!=null)endTalk();}else listenEnabled=true;setInboundVolume();updateStatus();}
    private void toggleMic(){if(micEnabled){micEnabled=false;endTalk();return;}if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO},41);return;}muted=false;listenEnabled=true;beginTalk();setInboundVolume();updateStatus();}
    private void setInboundVolume(){boolean audible=!muted&&listenEnabled;if(player!=null)player.setVolume(audible?100:0);if(inboundAudio!=null)inboundAudio.setVolume(audible?100:0);}
    private void updateStatus(){if(muteButton!=null)muteButton.setCrossed(muted);if(micButton!=null)micButton.setCrossed(!micEnabled);}
    private void beginTalk(){if(backchannel!=null||!camera.doorbell)return;handler.removeCallbacks(finishRunnable);handler.removeCallbacks(talkTimeoutRunnable);handler.postDelayed(talkTimeoutRunnable,TALK_TIMEOUT_MS);micEnabled=true;String user=prefs.getString("profile_g_user",""),password=prefs.getString("profile_g_password",""),stream=CameraCatalog.liveUri(prefs,camera,true);backchannel=new BackchannelSession(this,stream,user,password,new BackchannelSession.Listener(){@Override public void onStarted(){runOnUiThread(()->{android.util.Log.i("FelicityAudio","Backchannel started");micEnabled=true;updateStatus();});}@Override public void onError(String message){runOnUiThread(()->{android.util.Log.e("FelicityAudio","Backchannel failed: "+message);handler.removeCallbacks(talkTimeoutRunnable);if(backchannel!=null){backchannel.stop();backchannel=null;}micEnabled=false;setInboundVolume();updateStatus();scheduleFinish();android.widget.Toast.makeText(CameraActivity.this,"MIC: "+message,android.widget.Toast.LENGTH_LONG).show();});}});backchannel.start();updateStatus();}
    private void endTalk(){handler.removeCallbacks(talkTimeoutRunnable);if(backchannel!=null){backchannel.stop();backchannel=null;}setInboundVolume();updateStatus();scheduleFinish();}
    private void forcePrivacyMute(){handler.removeCallbacks(talkTimeoutRunnable);muted=true;listenEnabled=false;micEnabled=false;if(backchannel!=null){backchannel.stop();backchannel=null;}setInboundVolume();updateStatus();}
    private void scheduleFinish(){handler.removeCallbacks(finishRunnable);if(ringEvent)handler.postDelayed(finishRunnable,60000);}
    @Override public void onRequestPermissionsResult(int requestCode,String[] permissions,int[] results){super.onRequestPermissionsResult(requestCode,permissions,results);if(requestCode==41&&results.length>0&&results[0]==PackageManager.PERMISSION_GRANTED){muted=false;listenEnabled=true;beginTalk();setInboundVolume();updateStatus();}}
    private void takePreview(){if(snapshotTaken||player==null)return;snapshotTaken=true;handler.postDelayed(()->{if(surface.getWidth()<1||surface.getHeight()<1){snapshotTaken=false;return;}Bitmap bitmap=surface.getBitmap();if(bitmap==null){snapshotTaken=false;return;}try(FileOutputStream out=new FileOutputStream(new File(getFilesDir(),"camera-preview-"+camera.id+".jpg"))){bitmap.compress(Bitmap.CompressFormat.JPEG,86,out);}catch(Exception ignored){}if(camera.doorbell){try(FileOutputStream out=new FileOutputStream(new File(getFilesDir(),"onvif-preview.jpg"))){bitmap.compress(Bitmap.CompressFormat.JPEG,86,out);}catch(Exception ignored){}}if(ringEvent){try(FileOutputStream out=new FileOutputStream(new File(getFilesDir(),"onvif-ring-preview.jpg"))){bitmap.compress(Bitmap.CompressFormat.JPEG,90,out);}catch(Exception ignored){}prefs.edit().putLong("last_ring_preview_ms",System.currentTimeMillis()).apply();ringBitmap=bitmap;ringSnapshot.setImageBitmap(ringBitmap);ringSnapshot.setVisibility(View.VISIBLE);}else bitmap.recycle();},700);}
    private Button button(String label,boolean redNight){Button b=new Button(this);b.setText(label);b.setTextColor(Color.WHITE);b.setTextSize(17);ControlStyle.apply(b,redNight);return b;}
    @Override protected void onStart(){super.onStart();if(created&&player==null)startPlayer();}
    @Override protected void onStop(){forcePrivacyMute();stopPlayer();super.onStop();}
    @Override protected void onDestroy(){handler.removeCallbacksAndMessages(null);if(backchannel!=null)backchannel.stop();if(inboundAudio!=null)inboundAudio.stop();stopPlayer();hidePoster();if(ringBitmap!=null){ringSnapshot.setImageDrawable(null);ringBitmap.recycle();ringBitmap=null;}super.onDestroy();}

    private static final class PrivacyButton extends View {
        private final Paint paint=new Paint(3);private final boolean microphone,redNight;private boolean crossed;
        PrivacyButton(android.content.Context context,boolean microphone,boolean redNight){super(context);this.microphone=microphone;this.redNight=redNight;setClickable(true);setFocusable(true);setContentDescription(microphone?"Microphone":"Speaker");}
        void setCrossed(boolean crossed){this.crossed=crossed;setContentDescription((microphone?"Microphone":"Speaker")+(crossed?" off":" on"));invalidate();}
        @Override protected void drawableStateChanged(){super.drawableStateChanged();invalidate();}
        @Override protected void onDraw(Canvas canvas){super.onDraw(canvas);float w=getWidth(),h=getHeight(),cx=w/2f,cy=h/2f;paint.setStyle(Paint.Style.FILL);paint.setColor(redNight?(isPressed()?0x99d72a1e:0x553e0805):(isPressed()?0x9959ded1:0x351ca99d));canvas.drawRoundRect(new RectF(2,2,w-2,h-2),12,12,paint);paint.setColor(redNight?Color.rgb(255,72,52):Color.WHITE);paint.setStrokeWidth(3.2f);paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
            if(microphone){paint.setStyle(Paint.Style.STROKE);canvas.drawRoundRect(new RectF(cx-7,10,cx+7,31),7,7,paint);canvas.drawArc(new RectF(cx-13,18,cx+13,38),0,180,false,paint);canvas.drawLine(cx,38,cx,44,paint);canvas.drawLine(cx-7,44,cx+7,44,paint);}
            else{paint.setStyle(Paint.Style.FILL);canvas.drawRect(cx-14,20,cx-7,32,paint);Path cone=new Path();cone.moveTo(cx-7,20);cone.lineTo(cx+3,12);cone.lineTo(cx+3,40);cone.lineTo(cx-7,32);cone.close();canvas.drawPath(cone,paint);paint.setStyle(Paint.Style.STROKE);canvas.drawArc(new RectF(cx-4,17,cx+13,35),-58,116,false,paint);canvas.drawArc(new RectF(cx-7,12,cx+21,40),-52,104,false,paint);}
            if(crossed){paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(4.5f);paint.setColor(0xffff6b6b);canvas.drawLine(11,10,w-11,h-10,paint);}
        }
    }

    private static final class HeaderBackground extends View {private final Paint p=new Paint(3);private final boolean redNight;HeaderBackground(android.content.Context c,boolean redNight){super(c);this.redNight=redNight;setBackgroundColor(redNight?Color.rgb(36,0,0):Color.rgb(14,48,43));}@Override protected void onDraw(Canvas c){super.onDraw(c);float x=29,y=32,r=17;p.setColor(redNight?Color.rgb(230,48,35):Color.rgb(89,222,209));c.drawCircle(x,y,r,p);Path dark=new Path();dark.moveTo(x,y-r);dark.cubicTo(x+r*.67f,y-r,x+r*.67f,y,x,y);dark.cubicTo(x-r*.67f,y,x-r*.67f,y+r,x,y+r);dark.arcTo(new RectF(x-r,y-r,x+r,y+r),90,-180);dark.close();p.setColor(redNight?Color.rgb(8,0,0):Color.rgb(7,17,15));c.drawPath(dark,p);c.drawCircle(x,y-r/2,r*.18f,p);p.setColor(redNight?Color.rgb(230,48,35):Color.rgb(89,222,209));c.drawCircle(x,y+r/2,r*.18f,p);}}
}
