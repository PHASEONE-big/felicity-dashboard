package io.github.okiyashko1337.felicitydashboard;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/** Process-local keyframe index retained for one 30-minute archive investigation. */
final class ArchiveKeyframeIndex {
    private static final long TTL_MS=30*60_000L;
    private static final Map<String,Entry> entries=new HashMap<>();
    private ArchiveKeyframeIndex(){}

    static synchronized Long floor(String camera,boolean substream,long target,long now){Entry entry=entry(camera,substream,now,false);if(entry==null)return null;boolean covered=false;for(long[] range:entry.ranges)if(target>=range[0]&&target<=range[1]){covered=true;break;}if(!covered)return null;entry.touched=now;return entry.frames.floor(target);}

    static synchronized void add(String camera,boolean substream,long start,long end,List<Long> frames,long now){Entry entry=entry(camera,substream,now,true);entry.frames.addAll(frames);entry.ranges.add(new long[]{start,end});entry.touched=now;}

    private static Entry entry(String camera,boolean substream,long now,boolean create){entries.entrySet().removeIf(item->now-item.getValue().touched>TTL_MS);String key=camera+"\n"+(substream?"LQ":"HQ");Entry result=entries.get(key);if(result==null&&create){result=new Entry();result.touched=now;entries.put(key,result);}return result;}
    private static final class Entry {final TreeSet<Long> frames=new TreeSet<>();final List<long[]> ranges=new ArrayList<>();long touched;}
}
