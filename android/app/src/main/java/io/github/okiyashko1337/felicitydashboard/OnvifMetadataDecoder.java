package io.github.okiyashko1337.felicitydashboard;

import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Decodes recorder activity payloads carried by the ONVIF Profile G metadata track. */
final class OnvifMetadataDecoder {
    private static final Pattern UTC=Pattern.compile("\\bUtcTime=\"([^\"]+)\"");
    private static final Pattern PAYLOAD=Pattern.compile("<(?:[A-Za-z_][\\w.-]*:)?Metadata\\b[^>]*>([^<]+)</(?:[A-Za-z_][\\w.-]*:)?Metadata>");

    static final class Figure {
        final String utc;
        final int classCode;
        final int stateCode;
        final float confidence;
        final String confidenceLabel;

        Figure(String utc,int classCode,int stateCode,float confidence,String confidenceLabel){
            this.utc=utc;this.classCode=classCode;this.stateCode=stateCode;this.confidence=confidence;this.confidenceLabel=confidenceLabel;
        }

        String type(){return typeForCode(classCode);}
    }

    /** One compact archive activity returned by the recorder's activity-only filter. */
    static final class Activity {
        final long timeMs;
        final long utcOffsetUs;
        final int typeMask;
        final int sourceCode;
        final boolean asserted;
        final boolean motion;
        final boolean ring;

        Activity(long timeMs,long utcOffsetUs,int typeMask,int sourceCode,boolean asserted,boolean motion,boolean ring){
            this.timeMs=timeMs;this.utcOffsetUs=utcOffsetUs;this.typeMask=typeMask;this.sourceCode=sourceCode;this.asserted=asserted;this.motion=motion;this.ring=ring;
        }

        String type(){List<String> values=types();return values.isEmpty()?"":values.get(0);}
        List<String> types(){ArrayList<String> values=new ArrayList<>();if(ring)values.add("ring");if(motion)values.add("motion");if((typeMask&2)!=0)values.add("person");if((typeMask&4)!=0)values.add("animal");if((typeMask&8)!=0)values.add("vehicle");return values;}
    }

    static String typeForCode(int code){if(code==2)return "person";if(code==3)return "animal";if(code==6)return "vehicle";return "";}

    /* ONVIF archive activities are a bit mask, unlike the Figure class enum above. */
    static String activityTypeForMask(int mask){if((mask&2)!=0)return "person";if((mask&4)!=0)return "animal";if((mask&8)!=0)return "vehicle";return "";}

    static List<Figure> decodeXml(String xml){
        ArrayList<Figure> result=new ArrayList<>();
        Matcher payload=PAYLOAD.matcher(xml);if(!payload.find())return result;
        Matcher time=UTC.matcher(xml);String utc=time.find()?time.group(1):"";
        try{
            return decodePayload(Base64.decode(payload.group(1).trim(),Base64.DEFAULT),utc);
        }catch(RuntimeException ignored){return result;}
    }

    static List<Figure> decodePayload(byte[] payload,String utc){
        ArrayList<Figure> result=new ArrayList<>();
        try{
            Message batch=new Message(payload);
            if(!"Figures".equals(batch.string(1)))return result;
            for(byte[] envelope:batch.bytes(2)){
                Message update=new Message(envelope);
                for(byte[] item:update.bytes(3)){
                    Message itemMessage=new Message(item);
                    for(byte[] encodedFigure:itemMessage.bytes(2)){
                        Message figure=new Message(encodedFigure);
                        List<byte[]> details=figure.bytes(103);
                        if(details.isEmpty())continue;
                        String label=new Message(details.get(0)).string(2);
                        result.add(new Figure(utc,(int)figure.varint(1,-1),(int)figure.varint(2,-1),figure.fixed32(3,Float.NaN),label));
                    }
                }
            }
        }catch(RuntimeException ignored){}
        return result;
    }

    static List<Activity> decodeActivitiesXml(String xml){
        Matcher payload=PAYLOAD.matcher(xml);if(!payload.find())return new ArrayList<>();
        try{return decodeActivitiesPayload(Base64.decode(payload.group(1).trim(),Base64.DEFAULT));}
        catch(RuntimeException ignored){return new ArrayList<>();}
    }

    static List<Activity> decodeActivitiesPayload(byte[] payload){
        ArrayList<Activity> result=new ArrayList<>();
        try{
            Message batch=new Message(payload);if(!"A".equals(batch.string(1)))return result;
            for(byte[] encoded:batch.bytes(2)){
                Message event=new Message(encoded);long timestampUs=event.varint(1,-1),offsetUs=event.varint(2,0);List<byte[]> details=event.bytes(3);
                if(timestampUs<0||details.isEmpty())continue;Message detail=new Message(details.get(0));List<byte[]> types=detail.bytes(5);
                int mask=types.isEmpty()?0:(int)new Message(types.get(0)).varint(1,0),source=(int)detail.varint(100,0);boolean asserted=detail.varint(101,0)!=0,motion=detail.has(1),ring=detail.has(6);
                Activity activity=new Activity(timestampUs/1000L,offsetUs,mask,source,asserted,motion,ring);if(!activity.types().isEmpty())result.add(activity);
            }
        }catch(RuntimeException ignored){}
        return result;
    }

    private static final class Field {
        final int number,wire;final long numberValue;final byte[] bytes;
        Field(int number,int wire,long numberValue,byte[] bytes){this.number=number;this.wire=wire;this.numberValue=numberValue;this.bytes=bytes;}
    }

    private static final class Message {
        final List<Field> fields=new ArrayList<>();
        Message(byte[] data){
            int[] position={0};
            while(position[0]<data.length){
                long tag=readVarint(data,position);int number=(int)(tag>>>3),wire=(int)(tag&7);if(number<=0)throw new IllegalArgumentException("Invalid protobuf tag");
                if(wire==0)fields.add(new Field(number,wire,readVarint(data,position),null));
                else if(wire==1){require(data,position[0],8);long value=0;for(int i=0;i<8;i++)value|=(long)(data[position[0]++]&255)<<(8*i);fields.add(new Field(number,wire,value,null));}
                else if(wire==2){int length=(int)readVarint(data,position);require(data,position[0],length);byte[] value=new byte[length];System.arraycopy(data,position[0],value,0,length);position[0]+=length;fields.add(new Field(number,wire,0,value));}
                else if(wire==5){require(data,position[0],4);long value=0;for(int i=0;i<4;i++)value|=(long)(data[position[0]++]&255)<<(8*i);fields.add(new Field(number,wire,value,null));}
                else throw new IllegalArgumentException("Unsupported protobuf wire type "+wire);
            }
        }
        long varint(int number,long fallback){for(Field field:fields)if(field.number==number&&field.wire==0)return field.numberValue;return fallback;}
        boolean has(int number){for(Field field:fields)if(field.number==number)return true;return false;}
        float fixed32(int number,float fallback){for(Field field:fields)if(field.number==number&&field.wire==5)return Float.intBitsToFloat((int)field.numberValue);return fallback;}
        String string(int number){for(Field field:fields)if(field.number==number&&field.wire==2)return new String(field.bytes,StandardCharsets.UTF_8);return "";}
        List<byte[]> bytes(int number){ArrayList<byte[]> result=new ArrayList<>();for(Field field:fields)if(field.number==number&&field.wire==2)result.add(field.bytes);return result;}
    }

    private static long readVarint(byte[] data,int[] position){long value=0;for(int shift=0;shift<64;shift+=7){require(data,position[0],1);int next=data[position[0]++]&255;value|=(long)(next&127)<<shift;if((next&128)==0)return value;}throw new IllegalArgumentException("Invalid protobuf varint");}
    private static void require(byte[] data,int offset,int length){if(length<0||offset<0||offset+length>data.length)throw new IllegalArgumentException("Truncated protobuf field");}
}
