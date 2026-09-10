package io.github.okiyashko1337.felicitydashboard;

import android.graphics.Bitmap;
import java.util.ArrayList;
import java.util.List;

final class ThreeEyeState {
    static final class Channel {
        String id="",name="",host="";
    }
    static final class Event {
        long trackId;
        String objectClass="object", capturedAt="", firstSeen="", lastSeen="", camera="—", externalTrack="—";
        String verification="confirmed", thumbnailUrl="", imageUrl="";
        double confidence;
        int groupMembers=1, groupCameras=1;
        Bitmap thumbnail, image;
    }

    final List<Event> events=new ArrayList<>();
    final List<String> cameras=new ArrayList<>();
    final List<Channel> channels=new ArrayList<>();
    String baseUrl="http://192.168.13.148:8765";
    String status="NOT CONFIGURED", error="";
    String camera="ALL", objectClass="ALL";
    int minimumConfidence;
    int limit=40;
    boolean loadThumbnails=true;
    boolean allowPerson=true,allowAnimal=true,allowVehicle=true,allowFace=true;
    boolean includeUncertain;
    int selected=-1;
    long updatedMs;

    synchronized List<Event> snapshot(){return new ArrayList<>(events);}
    synchronized Event selected(){return selected>=0&&selected<events.size()?events.get(selected):null;}
}
