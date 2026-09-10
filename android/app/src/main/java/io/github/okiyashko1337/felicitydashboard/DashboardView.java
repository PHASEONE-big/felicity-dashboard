package io.github.okiyashko1337.felicitydashboard;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.LinearGradient;
import android.graphics.ColorMatrix;
import android.graphics.ColorMatrixColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.View;
import android.os.SystemClock;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

final class DashboardView extends View {
    interface Listener { void onPageChanged(String metric); void onSettingsRequested(); void onWeatherSettingsRequested(); void onOnvifSettingsRequested(); void onVideoAppRequested(); void onSystemSettingsRequested(); void onCameraRequested(); }
    private static final String[] METRICS={"pv","load","battery","grid","system","today"};
    private static final String[] TITLES={"SOLAR","HOME LOAD","BATTERY","GRID","SYSTEM","TODAY"};
    private final DashboardState s; private final Paint p=new Paint(3); private final RectF r=new RectF(); private final GestureDetector gestures;
    private final SimpleDateFormat date=new SimpleDateFormat("dd.MM.yyyy",Locale.getDefault()), time=new SimpleDateFormat("HH:mm:ss",Locale.getDefault());
    private Listener listener; private int page=-1; private float scale=1; private int pressedTarget=-1; private Bitmap cameraPreview,ringPreview;private long ringPreviewAt;private boolean redNight;private final Paint redNightPaint=new Paint();
    private final int bg=Color.rgb(7,17,15), header=Color.rgb(14,48,43), card=Color.rgb(13,39,35), cyan=Color.rgb(89,222,209), text=Color.rgb(232,248,244), muted=Color.rgb(150,190,184), green=Color.rgb(98,231,148), amber=Color.rgb(255,184,103);

    DashboardView(Context context, DashboardState state){super(context);s=state;setBackgroundColor(bg);ColorMatrix redMatrix=new ColorMatrix(new float[]{.72f,.24f,.04f,0,0,.045f,.015f,.005f,0,0,.018f,.006f,.002f,0,0,0,0,0,1,0});redNightPaint.setColorFilter(new ColorMatrixColorFilter(redMatrix));gestures=new GestureDetector(context,new GestureDetector.SimpleOnGestureListener(){
        @Override public boolean onDown(MotionEvent e){return true;}
        @Override public boolean onSingleTapUp(MotionEvent e){final float x=e.getX(),y=e.getY();postDelayed(()->tap(x,y),90);postDelayed(()->{pressedTarget=-1;invalidate();},150);return true;}
        @Override public void onLongPress(MotionEvent e){if(listener==null||e.getY()>=72*scale)return;if(page==-1&&e.getX()<55*scale){sound();page=-3;invalidate();}else if(e.getX()>485*scale&&e.getX()<650*scale){sound();listener.onWeatherSettingsRequested();}}
    });}
    void setListener(Listener value){listener=value;} boolean isDetail(){return page!=-1;} boolean isChartDetail(){return page>=0;} String metric(){return page<0?"pv":METRICS[page];}
    void setRedNight(boolean enabled){if(redNight==enabled)return;redNight=enabled;setBackgroundColor(enabled?Color.rgb(8,0,0):bg);invalidate();}
    void reloadCameraPreview(){if(cameraPreview!=null){cameraPreview.recycle();cameraPreview=null;}if(ringPreview!=null){ringPreview.recycle();ringPreview=null;}android.content.SharedPreferences preferences=getContext().getSharedPreferences("felicity",Context.MODE_PRIVATE);String cameraId=CameraCatalog.selected(preferences).id;cameraPreview=BitmapFactory.decodeFile(getContext().getFilesDir()+"/camera-preview-"+cameraId+".jpg");if(cameraPreview==null)cameraPreview=BitmapFactory.decodeFile(getContext().getFilesDir()+"/onvif-preview.jpg");ringPreviewAt=preferences.getLong("last_ring_preview_ms",0);if(ringPreviewAt>0&&System.currentTimeMillis()-ringPreviewAt<30*60*1000L)ringPreview=BitmapFactory.decodeFile(getContext().getFilesDir()+"/onvif-ring-preview.jpg");invalidate();}
    void showHome(){page=-1;s.chart.clear();invalidate();}
    @Override public boolean onTouchEvent(MotionEvent event){if(event.getAction()==MotionEvent.ACTION_DOWN){pressedTarget=hitTarget(event.getX(),event.getY());invalidate();}else if(event.getAction()==MotionEvent.ACTION_CANCEL){pressedTarget=-1;invalidate();}return gestures.onTouchEvent(event);}
    private int hitTarget(float x,float y){float h=64*scale;if(x>=300*scale&&x<=400*scale&&y>=5*scale&&y<=59*scale)return 40;if(page==-1&&ringPreview!=null&&System.currentTimeMillis()-ringPreviewAt<30*60*1000L&&x>=20*scale&&x<=192*scale&&y>=getHeight()-122*scale)return 41;if(page==-1&&y<h&&x<55*scale)return 22;if(y<h&&x>505*scale&&x<645*scale)return 20;if(page!=-1&&y<h&&x>=44*scale&&x<180*scale)return 21;if(page==-3&&y>=78*scale&&y<123*scale)return 30;if(page==-3&&y>=125*scale&&y<170*scale)return 31;if(page==-3&&y>=172*scale&&y<217*scale)return 32;if(page==-3&&y>=219*scale&&y<264*scale)return 34;if(page==-3&&y>=266*scale&&y<311*scale)return 35;if(page==-3&&y>=326*scale&&x>=28*scale&&x<322*scale)return 33;if(page!=-1||y<h)return -1;float gap=12*scale,pad=20*scale,top=h+12*scale,cw=(getWidth()-pad*2-gap*2)/3f,ch=(getHeight()-top-18*scale-gap)/2f;int col=(int)((x-pad)/(cw+gap)),row=(int)((y-top)/(ch+gap));return col>=0&&col<3&&row>=0&&row<2?row*3+col:-1;}
    private void tap(float x,float y){
        int target=hitTarget(x,y);if(target<0)return;
        sound();
        if(target==40||target==41){if(listener!=null)listener.onCameraRequested();return;}
        float h=64*scale;if(page==-1&&y<h&&x<55*scale){page=-3;invalidate();return;}if(y<h&&x>505*scale&&x<645*scale){page=-2;invalidate();return;}if(page!=-1){if(y<h&&x>=44*scale&&x<180*scale){showHome();return;}if(page==-3&&target==30&&listener!=null){listener.onSettingsRequested();return;}if(page==-3&&target==31&&listener!=null){listener.onWeatherSettingsRequested();return;}if(page==-3&&target==32&&listener!=null){listener.onOnvifSettingsRequested();return;}if(page==-3&&target==34&&listener!=null){listener.onVideoAppRequested();return;}if(page==-3&&target==35&&listener!=null){listener.onSystemSettingsRequested();return;}if(page==-3&&target==33){page=-4;invalidate();return;}return;}
        if(y<h)return; float gap=12*scale,pad=20*scale,top=h+12*scale; float cw=(getWidth()-pad*2-gap*2)/3f,ch=(getHeight()-top-18*scale-gap)/2f;
        int col=(int)((x-pad)/(cw+gap)),row=(int)((y-top)/(ch+gap)); if(col>=0&&col<3&&row>=0&&row<2){page=row*3+col;s.chart.clear();if(listener!=null)listener.onPageChanged(metric());invalidate();}
    }
    private void sound(){
        final int rate=16000,count=400;short[] pcm=new short[count];int noise=0x13579b;
        for(int i=0;i<count;i++){noise=noise*1103515245+12345;double envelope=Math.exp(-i/48.0);double snap=Math.sin(2*Math.PI*1850*i/rate)*.72+(((noise>>>16)&255)/127.5-1)*.28;pcm[i]=(short)(11500*envelope*snap);}
        AudioTrack track=new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()).setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()).setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(count*2).build();
        track.write(pcm,0,count);track.play();postDelayed(()->{try{track.stop();}catch(Exception ignored){}track.release();},100);
    }

    @Override protected void onDraw(Canvas c){super.onDraw(c);int layer=redNight?c.saveLayer(0,0,getWidth(),getHeight(),redNightPaint):-1;scale=Math.min(getWidth()/960f,getHeight()/480f);drawHeader(c);if(page==-1)drawHome(c);else if(page==-2)drawWeather(c);else if(page==-3)drawSettings(c);else if(page==-4)drawNetworkDiagnostics(c);else drawDetail(c);if(page==-1&&!s.live(System.currentTimeMillis()))drawOffline(c);drawCameraButton(c);if(redNight)c.restoreToCount(layer);}
    private void drawCameraButton(Canvas c){float inset=pressedTarget==40?3*scale:0;r.set(300*scale+inset,5*scale+inset,400*scale-inset,59*scale-inset);c.save();c.clipRect(r);p.setColor(Color.BLACK);c.drawRect(r,p);if(cameraPreview!=null)c.drawBitmap(cameraPreview,null,fitInside(cameraPreview,r),p);else{p.setColor(Color.rgb(10,54,49));c.drawRect(r,p);center(c,"CAM",r.centerX(),r.centerY()+5*scale,13,text,true);}c.restore();p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(pressedTarget==40?2.5f*scale:1.5f*scale);p.setColor(cyan);c.drawRoundRect(r,9*scale,9*scale,p);p.setStyle(Paint.Style.FILL);p.setColor(0xb0000000);c.drawRoundRect(new RectF(r.left+5*scale,r.bottom-18*scale,r.right-5*scale,r.bottom-3*scale),6*scale,6*scale,p);center(c,"ONVIF",r.centerX(),r.bottom-6*scale,8,cyan,true);}
    private void drawHeader(Canvas c){
        p.setStyle(Paint.Style.FILL);p.setColor(header);c.drawRect(0,0,getWidth(),64*scale,p);drawYinYang(c,30*scale,32*scale,17*scale);
        if(page!=-1){p.setColor(pressedTarget==21?Color.rgb(28,78,70):Color.rgb(18,61,55));c.drawRoundRect(new RectF(44*scale,7*scale,180*scale,57*scale),8*scale,8*scale,p);}
        p.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);p.setTextSize(17*scale);p.setColor(cyan);p.setTextAlign(Paint.Align.LEFT);
        p.setColor(pressedTarget==21?text:cyan);if(page==-1)c.drawText("v"+BuildConfig.VERSION_NAME+" · ANDROID",56*scale,39*scale,p);else{p.setTextSize(12*scale);p.setTextAlign(Paint.Align.CENTER);c.drawText("‹ ENERGY",112*scale,40*scale,p);p.setTextAlign(Paint.Align.LEFT);}
        p.setTextAlign(Paint.Align.CENTER);p.setColor(s.live(System.currentTimeMillis())?green:amber);c.drawText(s.live(System.currentTimeMillis())?"LIVE":"NO DATA",450*scale,39*scale,p);
        if(pressedTarget==20){p.setColor(Color.rgb(28,78,70));c.drawRoundRect(new RectF(495*scale,5*scale,625*scale,59*scale),14*scale,14*scale,p);}drawWeatherIcon(c,525*scale,30*scale,19*scale,s.weatherCode);p.setTextSize(23*scale);p.setColor(text);p.setTextAlign(Paint.Align.LEFT);c.drawText(s.hasWeather()?n(s.weatherTemperature,0)+"°C":"—",553*scale,41*scale,p);
        if(page==-1){p.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);p.setTextSize(27*scale);p.setColor(text);p.setTextAlign(Paint.Align.RIGHT);Date now=new Date();c.drawText(date.format(now),775*scale,43*scale,p);p.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);p.setTextSize(31*scale);p.setColor(text);c.drawText(time.format(now),942*scale,43*scale,p);}
    }
    private void drawYinYang(Canvas c,float cx,float cy,float radius){
        p.setStyle(Paint.Style.FILL);p.setColor(cyan);c.drawCircle(cx,cy,radius,p);Path dark=new Path();dark.moveTo(cx,cy-radius);dark.cubicTo(cx+radius*.67f,cy-radius,cx+radius*.67f,cy,cx,cy);dark.cubicTo(cx-radius*.67f,cy,cx-radius*.67f,cy+radius,cx,cy+radius);dark.arcTo(new RectF(cx-radius,cy-radius,cx+radius,cy+radius),90,-180);dark.close();p.setColor(bg);c.drawPath(dark,p);p.setColor(bg);c.drawCircle(cx,cy-radius/2,radius*.18f,p);p.setColor(cyan);c.drawCircle(cx,cy+radius/2,radius*.18f,p);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.5f*scale);p.setColor(cyan);c.drawCircle(cx,cy,radius,p);p.setStyle(Paint.Style.FILL);
    }
    private void drawHome(Canvas c){float gap=12*scale,pad=20*scale,top=76*scale,cw=(getWidth()-pad*2-gap*2)/3f,ch=(getHeight()-top-18*scale-gap)/2f;for(int i=0;i<6;i++){int col=i%3,row=i/3;drawCard(c,i,pad+col*(cw+gap),top+row*(ch+gap),cw,ch);}drawLastRing(c);}
    private void drawLastRing(Canvas c){if(ringPreview==null||System.currentTimeMillis()-ringPreviewAt>=30*60*1000L)return;RectF box=new RectF(24*scale,getHeight()-118*scale,188*scale,getHeight()-24*scale);p.setColor(Color.rgb(4,12,11));c.drawRoundRect(new RectF(box.left-4*scale,box.top-4*scale,box.right+4*scale,box.bottom+4*scale),10*scale,10*scale,p);c.save();c.clipRect(box);p.setColor(Color.BLACK);c.drawRect(box,p);c.drawBitmap(ringPreview,null,fitInside(ringPreview,box),p);c.restore();p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(2*scale);p.setColor(cyan);c.drawRoundRect(box,8*scale,8*scale,p);p.setStyle(Paint.Style.FILL);p.setColor(0xc8000000);c.drawRect(box.left,box.bottom-19*scale,box.right,box.bottom,p);center(c,"RING · "+new SimpleDateFormat("HH:mm",Locale.getDefault()).format(new Date(ringPreviewAt)),box.centerX(),box.bottom-5*scale,10,cyan,true);}
    private static RectF fitInside(Bitmap bitmap,RectF bounds){float ratio=Math.min(bounds.width()/bitmap.getWidth(),bounds.height()/bitmap.getHeight()),w=bitmap.getWidth()*ratio,h=bitmap.getHeight()*ratio;return new RectF(bounds.centerX()-w/2f,bounds.centerY()-h/2f,bounds.centerX()+w/2f,bounds.centerY()+h/2f);}
    private void drawCard(Canvas c,int i,float x,float y,float w,float h){float inset=pressedTarget==i?4*scale:0;r.set(x+inset,y+inset,x+w-inset,y+h-inset);p.setShader(new LinearGradient(x,y,x+w,y+h,pressedTarget==i?Color.rgb(29,81,72):Color.rgb(20,58,53),card,Shader.TileMode.CLAMP));c.drawRoundRect(r,17*scale,17*scale,p);p.setShader(null);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth((pressedTarget==i?2.4f:1.2f)*scale);p.setColor(pressedTarget==i?cyan:Color.rgb(64,143,134));c.drawRoundRect(r,17*scale,17*scale,p);p.setStyle(Paint.Style.FILL);center(c,TITLES[i],x+w/2,y+31*scale+inset,15,cyan,true);String main="",sub="";
        switch(i){case 0:main=w(s.pv);sub="PV1 "+n(s.pv1,0)+" · PV2 "+n(s.pv2,0);break;case 1:main=w(s.load);sub=n(s.l1,0)+" · "+n(s.l2,0)+" · "+n(s.l3,0);break;case 2:main=n(s.soc,0)+"%";sub=n(s.batteryV,1)+" V · "+signed(s.batteryW)+" W";break;case 3:main=n((s.gridV1+s.gridV2+s.gridV3)/3,1)+" V";sub=signed(s.gridW)+" W · "+n(s.frequency,2)+" Hz";break;case 4:main=n(s.cpu,0)+"%";sub="RAM "+n(s.ram,0)+" · TEMP "+n(s.temperature,0)+" · DISK "+n(s.disk,0);break;default:main=n(s.todayPv,2)+" kWh";sub="LOAD "+n(s.todayLoad,2)+" · COVER "+n(s.coverage,0)+"%";}
        center(c,main,x+w/2,y+h*.56f,32,(i==2&&s.soc<25)?amber:text,true);center(c,sub,x+w/2,y+h-16*scale,22,muted,false);
    }
    private void drawDetail(Canvas c){float top=80*scale,left=28*scale;center(c,TITLES[page],190*scale,top+25*scale,16,cyan,true);center(c,detailMain(),190*scale,top+75*scale,35,(page==2&&s.soc<25)?amber:text,true);String[][] facts=detailFacts();float fx=340*scale,fw=190*scale;for(int i=0;i<3;i++){p.setColor(card);r.set(fx+i*(fw+12*scale),top,fx+i*(fw+12*scale)+fw,top+92*scale);c.drawRoundRect(r,14*scale,14*scale,p);center(c,facts[i][0],r.centerX(),top+29*scale,12,muted,false);center(c,facts[i][1],r.centerX(),top+64*scale,20,text,true);}drawChart(c,new RectF(42*scale,195*scale,getWidth()-28*scale,getHeight()-22*scale));}
    private void drawWeather(Canvas c){
        center(c,"7-DAY FORECAST · "+s.location,getWidth()/2f,98*scale,24,cyan,true);float gap=8*scale,pad=18*scale,top=120*scale,w=(getWidth()-pad*2-gap*6)/7f,h=325*scale;
        for(int i=0;i<7;i++){float x=pad+i*(w+gap);r.set(x,top,x+w,top+h);p.setColor(card);c.drawRoundRect(r,14*scale,14*scale,p);String day=dayName(s.forecastDate[i],i);center(c,day,r.centerX(),top+38*scale,21,i==0?cyan:text,true);drawWeatherIcon(c,r.centerX(),top+105*scale,32*scale,s.forecastCode[i]);center(c,weatherName(s.forecastCode[i]),r.centerX(),top+172*scale,17,muted,true);center(c,n(s.forecastMax[i],0)+"°",r.centerX(),top+235*scale,32,text,true);center(c,n(s.forecastMin[i],0)+"°",r.centerX(),top+282*scale,27,muted,false);center(c,"MAX / MIN",r.centerX(),top+315*scale,14,muted,false);}
    }
    private void drawSettings(Canvas c){
        center(c,"SETTINGS",getWidth()/2f,72*scale,16,cyan,true);drawSettingRow(c,0,"FELICITY SERVER",s.serverUrl,"Tap to edit",78*scale,45*scale);drawSettingRow(c,1,"WEATHER LOCATION",s.location,"Tap to choose city",125*scale,45*scale);drawSettingRow(c,2,"ONVIF PROFILE G",s.onvifStatus,"Tap to configure",172*scale,45*scale);drawSettingRow(c,4,"VIDEO APP","YouTube / compatible client","Tap to open",219*scale,45*scale);drawSettingRow(c,5,"ANDROID SETTINGS","Brightness · Wi-Fi · system","Tap to open",266*scale,45*scale);
        float top=326*scale,gap=10*scale,w=(getWidth()-56*scale-gap*2)/3f;settingInfo(c,28*scale,top,w,"NETWORK",s.networkRecoveryStatus+"\n"+s.networkRecoveryDetail);settingInfo(c,28*scale+w+gap,top,w,"DEVICE","Uptime "+uptime()+"\nKiosk · HOME");settingInfo(c,28*scale+(w+gap)*2,top,w,"VERSIONS","Android "+BuildConfig.VERSION_NAME+"\nServer "+s.version);
    }
    private void drawNetworkDiagnostics(Canvas c){
        center(c,"NETWORK DIAGNOSTICS",getWidth()/2f,103*scale,24,cyan,true);
        center(c,s.networkRecoveryStatus,getWidth()/2f,137*scale,18,s.networkRecoveryStatus.equals("ONLINE")?green:amber,true);
        float left=48*scale,top=163*scale,right=getWidth()-48*scale,bottom=getHeight()-25*scale;p.setColor(card);r.set(left,top,right,bottom);c.drawRoundRect(r,15*scale,15*scale,p);
        p.setTextAlign(Paint.Align.LEFT);p.setTypeface(android.graphics.Typeface.MONOSPACE);p.setTextSize(17*scale);p.setColor(text);float y=top+35*scale;
        synchronized(s.networkDiagnostics){for(String line:s.networkDiagnostics){if(line==null)continue;c.drawText(fit(line,right-left-36*scale),left+18*scale,y,p);y+=35*scale;}}
        if(y==top+35*scale)center(c,"No network events recorded",r.centerX(),r.centerY(),18,muted,false);
    }
    private String fit(String value,float width){if(p.measureText(value)<=width)return value;String suffix="…";int end=value.length();while(end>0&&p.measureText(value.substring(0,end)+suffix)>width)end--;return value.substring(0,end)+suffix;}
    private void drawSettingRow(Canvas c,int index,String label,String value,String hint,float top,float height){float inset=pressedTarget==30+index?4*scale:0;r.set(45*scale+inset,top+inset,getWidth()-45*scale-inset,top+height-inset);p.setColor(pressedTarget==30+index?Color.rgb(29,81,72):card);c.drawRoundRect(r,15*scale,15*scale,p);p.setTextAlign(Paint.Align.LEFT);p.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);p.setTextSize(16*scale);p.setColor(cyan);c.drawText(label,r.left+22*scale,top+24*scale,p);p.setTypeface(android.graphics.Typeface.DEFAULT);p.setTextSize(18*scale);p.setColor(text);c.drawText(value,r.left+220*scale,top+26*scale,p);p.setTextSize(13*scale);p.setColor(muted);c.drawText(hint,r.left+220*scale,top+48*scale,p);p.setTextAlign(Paint.Align.RIGHT);p.setTextSize(26*scale);p.setColor(cyan);c.drawText("›",r.right-22*scale,top+39*scale,p);}
    private void settingInfo(Canvas c,float left,float top,float w,String label,String lines){r.set(left,top,left+w,getHeight()-12*scale);p.setColor(card);c.drawRoundRect(r,14*scale,14*scale,p);center(c,label,r.centerX(),top+25*scale,13,cyan,true);String[] split=lines.split("\\n");for(int i=0;i<split.length;i++)center(c,split[i],r.centerX(),top+(53+i*25)*scale,14,i==0?text:muted,i==0);}
    private void drawWeatherIcon(Canvas c,float x,float y,float size,int code){
        boolean rain=(code>=51&&code<=67)||(code>=80&&code<=82)||(code>=95);boolean cloudy=code>=2;boolean snow=code>=71&&code<=77;
        if(!cloudy||code<=2){p.setColor(amber);c.drawCircle(x-size*.28f,y-size*.25f,size*.38f,p);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(2*scale);for(int i=0;i<8;i++){double a=i*Math.PI/4;c.drawLine(x-size*.28f+(float)Math.cos(a)*size*.52f,y-size*.25f+(float)Math.sin(a)*size*.52f,x-size*.28f+(float)Math.cos(a)*size*.70f,y-size*.25f+(float)Math.sin(a)*size*.70f,p);}p.setStyle(Paint.Style.FILL);}
        if(cloudy){p.setColor(Color.rgb(185,207,212));c.drawCircle(x-size*.25f,y,size*.38f,p);c.drawCircle(x+size*.1f,y-size*.18f,size*.48f,p);c.drawCircle(x+size*.48f,y,size*.34f,p);c.drawRoundRect(new RectF(x-size*.6f,y,x+size*.75f,y+size*.38f),size*.18f,size*.18f,p);}
        if(rain||snow){p.setColor(snow?text:Color.rgb(105,183,255));p.setStrokeWidth(3*scale);for(int i=-1;i<=1;i++){float dx=x+i*size*.38f;if(snow)c.drawCircle(dx,y+size*.72f,3*scale,p);else c.drawLine(dx,y+size*.52f,dx-size*.1f,y+size*.78f,p);}}
    }
    private static String weatherName(int code){if(code==0)return "CLEAR";if(code<=2)return "PARTLY";if(code==3||code==45||code==48)return "CLOUDY";if(code>=71&&code<=77)return "SNOW";if(code>=95)return "STORM";if(code>=51)return "RAIN";return "WEATHER";}
    private static String dayName(String iso,int index){if(iso==null||iso.length()<10)return index==0?"TODAY":"—";try{return new SimpleDateFormat("EEE",Locale.getDefault()).format(new SimpleDateFormat("yyyy-MM-dd",Locale.US).parse(iso)).toUpperCase(Locale.getDefault());}catch(Exception e){return "—";}}
    private String detailMain(){switch(page){case 0:return w(s.pv);case 1:return w(s.load);case 2:return n(s.soc,0)+"%";case 3:return n((s.gridV1+s.gridV2+s.gridV3)/3,1)+" V";case 4:return n(s.cpu,1)+"% CPU";default:return n(s.todayPv,2)+" kWh";}}
    private String[][] detailFacts(){switch(page){case 0:return f("PV1",w(s.pv1),"PV2",w(s.pv2),"MPPT",n(s.mppt1,0)+" / "+n(s.mppt2,0)+" V");case 1:return f("L1",w(s.l1),"L2",w(s.l2),"L3",w(s.l3));case 2:return f("VOLTAGE",n(s.batteryV,1)+" V","POWER",signed(s.batteryW)+" W","BMS SOC",n(s.bms1,0)+" / "+n(s.bms2,0)+"%");case 3:return f("L1",n(s.gridV1,1)+" V","L2",n(s.gridV2,1)+" V","L3",n(s.gridV3,1)+" V");case 4:return f("RAM",n(s.ram,1)+"%","TEMP",n(s.temperature,1)+" °C","DISK",n(s.disk,1)+"%");default:return f("LOAD",n(s.todayLoad,2)+" kWh","COVER",n(s.coverage,1)+"%","GRID IN",n(s.gridImport,2)+" kWh");}}
    private void drawChart(Canvas c,RectF box){
        p.setColor(Color.rgb(9,29,26));c.drawRoundRect(box,14*scale,14*scale,p);List<float[]> rows=s.chart;if(rows.isEmpty()){center(c,"Loading chart…",box.centerX(),box.centerY(),16,muted,false);return;}
        float min=Float.MAX_VALUE,max=-Float.MAX_VALUE;for(float[] row:rows)if(row!=null)for(float v:row){min=Math.min(min,v);max=Math.max(max,v);}boolean hasNegative=min<0;if(!hasNegative){min=0;max=Math.max(1,max*1.08f);}else{max=Math.max(max,0);if(max<=min)max=min+1;float padding=(max-min)*.08f;min-=padding;max+=padding;}
        RectF plot=new RectF(box.left+82*scale,box.top+28*scale,box.right-24*scale,box.bottom-48*scale);p.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);p.setTextSize(18*scale);p.setStrokeWidth(1*scale);
        for(int i=0;i<3;i++){float y=plot.top+plot.height()*i/2f;p.setStyle(Paint.Style.STROKE);p.setColor(Color.rgb(42,80,74));c.drawLine(plot.left,y,plot.right,y,p);p.setStyle(Paint.Style.FILL);p.setColor(muted);p.setTextAlign(Paint.Align.RIGHT);c.drawText(axis(max-(max-min)*i/2f),plot.left-9*scale,y+4*scale,p);}
        String[] ticks=page==4?new String[]{"−10m","−5m","NOW"}:new String[]{"00:00","06:00","12:00","18:00","24:00"};for(int i=0;i<ticks.length;i++){float x=plot.left+plot.width()*i/(ticks.length-1);p.setStyle(Paint.Style.STROKE);p.setColor(Color.rgb(42,80,74));c.drawLine(x,plot.top,x,plot.bottom,p);p.setStyle(Paint.Style.FILL);p.setColor(muted);p.setTextAlign(i==0?Paint.Align.LEFT:i==ticks.length-1?Paint.Align.RIGHT:Paint.Align.CENTER);c.drawText(ticks[i],x,box.bottom-13*scale,p);}
        float zeroY=plot.bottom-plot.height()*(0-min)/(max-min);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(2.4f*scale);p.setColor(cyan);c.drawLine(plot.left,zeroY,plot.right,zeroY,p);p.setStyle(Paint.Style.FILL);p.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);p.setTextSize(19*scale);p.setTextAlign(Paint.Align.RIGHT);p.setColor(cyan);c.drawText("0",plot.left-10*scale,zeroY+6*scale,p);
        p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.4f*scale);p.setColor(Color.rgb(79,145,136));c.drawRect(plot,p);p.setStyle(Paint.Style.FILL);p.setTextAlign(Paint.Align.LEFT);p.setTextSize(16*scale);p.setColor(cyan);c.drawText(chartUnit(),box.left+10*scale,box.top+20*scale,p);
        int[] colors={cyan,amber,Color.rgb(115,170,255),Color.rgb(196,138,255)};c.save();c.clipRect(plot);for(int channel=0;channel<Math.min(s.chartChannels,4);channel++){Path path=new Path();boolean started=false;for(int i=0;i<rows.size();i++){float[] row=rows.get(i);if(row==null||channel>=row.length){started=false;continue;}float x=plot.left+plot.width()*i/Math.max(1,rows.size()-1);float y=plot.bottom-plot.height()*(row[channel]-min)/(max-min);if(!started){path.moveTo(x,y);started=true;}else path.lineTo(x,y);}p.setStyle(Paint.Style.STROKE);p.setStrokeWidth((channel==0?2.5f:1.5f)*scale);p.setColor(colors[channel]);c.drawPath(path,p);}c.restore();p.setStyle(Paint.Style.FILL);
    }
    private String chartUnit(){switch(page){case 0:case 1:case 5:return "POWER · W";case 2:return "SOC % / POWER W";case 3:return "VOLTAGE V / POWER W";case 4:return "SYSTEM · % / °C";default:return "VALUE";}}
    private static String axis(float value){float a=Math.abs(value);if(a>=1000)return String.format(Locale.US,"%.1fk",value/1000f);if(a>=100)return String.format(Locale.US,"%.0f",value);return String.format(Locale.US,"%.1f",value);}
    private static String uptime(){long minutes=SystemClock.elapsedRealtime()/60000;long days=minutes/1440;long hours=(minutes%1440)/60;long mins=minutes%60;return days>0?days+"d "+hours+"h":hours>0?hours+"h "+mins+"m":mins+"m";}
    private void drawOffline(Canvas c){if(s.hasData())return;p.setColor(Color.argb(220,3,12,11));c.drawRect(0,64*scale,getWidth(),getHeight(),p);center(c,"NO DATA",getWidth()/2f,getHeight()/2f-8*scale,28,amber,true);center(c,s.error,getWidth()/2f,getHeight()/2f+28*scale,14,muted,false);}
    private void center(Canvas c,String value,float x,float y,float size,int color,boolean bold){p.setTypeface(bold?android.graphics.Typeface.DEFAULT_BOLD:android.graphics.Typeface.DEFAULT);p.setTextSize(size*scale);p.setColor(color);p.setTextAlign(Paint.Align.CENTER);c.drawText(value,x,y,p);}
    private static String w(double v){return n(v,0)+" W";} private static String signed(double v){return (v<0?"−":v>0?"+":"")+n(Math.abs(v),0);} private static String n(double v,int d){return String.format(Locale.US,"%,."+d+"f",v).replace(",", " ");}
    private static String[][] f(String a,String av,String b,String bv,String c,String cv){return new String[][]{{a,av},{b,bv},{c,cv}};}
}
