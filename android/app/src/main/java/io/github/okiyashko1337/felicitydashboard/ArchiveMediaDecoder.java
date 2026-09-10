package io.github.okiyashko1337.felicitydashboard;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Handler;
import android.util.Log;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

/** Thin hardware decoder fed with complete Annex-B access units. */
final class ArchiveMediaDecoder implements AutoCloseable {
    interface Listener{void onFrame(long archiveTimeMs);void onFormat(int width,int height,String codec);void onError(Exception error);}
    private final Listener listener;private final MediaCodec codec;private final MediaCodec.BufferInfo info=new MediaCodec.BufferInfo();private final String name;private final ConcurrentHashMap<Long,Integer> renderGenerations=new ConcurrentHashMap<>();private volatile boolean closed,waitingForKeyframe=true;private volatile int generation;private long bytes,frames,startedAt=android.os.SystemClock.elapsedRealtime();
    ArchiveMediaDecoder(boolean hevc,int width,int height,List<byte[]> csd,Surface surface,Handler callbackHandler,Listener listener)throws Exception{this.listener=listener;name=hevc?"H265":"H264";codec=MediaCodec.createDecoderByType(hevc?MediaFormat.MIMETYPE_VIDEO_HEVC:MediaFormat.MIMETYPE_VIDEO_AVC);MediaFormat format=MediaFormat.createVideoFormat(hevc?MediaFormat.MIMETYPE_VIDEO_HEVC:MediaFormat.MIMETYPE_VIDEO_AVC,Math.max(16,width),Math.max(16,height));format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE,4*1024*1024);for(int i=0;i<csd.size();i++)format.setByteBuffer("csd-"+i,ByteBuffer.wrap(csd.get(i)));codec.setOnFrameRenderedListener((ignored,presentationTimeUs,nanoTime)->{Integer queued=renderGenerations.remove(presentationTimeUs);if(!closed&&queued!=null&&queued==generation&&listener!=null)listener.onFrame(presentationTimeUs/1000L);},callbackHandler);codec.configure(format,surface,null,0);codec.start();}
    synchronized void seek(){if(closed)return;generation++;renderGenerations.clear();waitingForKeyframe=true;bytes=frames=0;startedAt=android.os.SystemClock.elapsedRealtime();try{codec.flush();}catch(Exception error){notifyError(error);}}
    synchronized void queue(byte[] access,long archiveTimeMs,boolean keyframe){if(closed||access==null||access.length==0||archiveTimeMs<=0)return;if(waitingForKeyframe&&!keyframe)return;try{int input=codec.dequeueInputBuffer(20_000);if(input<0)return;ByteBuffer buffer=codec.getInputBuffer(input);if(buffer==null)return;buffer.clear();if(access.length>buffer.remaining())throw new Exception("Archive access unit too large: "+access.length);buffer.put(access);long pts=archiveTimeMs*1000L;renderGenerations.put(pts,generation);codec.queueInputBuffer(input,0,access.length,pts,keyframe?MediaCodec.BUFFER_FLAG_KEY_FRAME:0);waitingForKeyframe=false;bytes+=access.length;drain();}catch(Exception error){notifyError(error);}}
    private void drain(){while(!closed){int output=codec.dequeueOutputBuffer(info,0);if(output>=0){frames++;codec.releaseOutputBuffer(output,true);continue;}if(output==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED){MediaFormat value=codec.getOutputFormat();int width=value.containsKey(MediaFormat.KEY_WIDTH)?value.getInteger(MediaFormat.KEY_WIDTH):0,height=value.containsKey(MediaFormat.KEY_HEIGHT)?value.getInteger(MediaFormat.KEY_HEIGHT):0;if(listener!=null)listener.onFormat(width,height,name);continue;}break;}}
    synchronized float fps(){long elapsed=Math.max(1,android.os.SystemClock.elapsedRealtime()-startedAt);return frames*1000f/elapsed;}
    synchronized float kbps(){long elapsed=Math.max(1,android.os.SystemClock.elapsedRealtime()-startedAt);return bytes*8f/elapsed;}
    private void notifyError(Exception error){Log.w("FelicityReplay","MediaCodec · "+error.getMessage());if(listener!=null)listener.onError(error);}
    @Override public synchronized void close(){if(closed)return;closed=true;try{codec.stop();}catch(Exception ignored){}try{codec.release();}catch(Exception ignored){}}
}
