package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import org.junit.Test;
import java.util.List;

public final class OnvifMetadataDecoderTest {
    @Test public void decodesFigureFromOnvifMetadata(){
        String payload="CgdGaWd1cmVzEkcIwJjfwcDFlgMQgJCd6RoaNggEEi4IBhACHQAAgD+6BiIKGAoKDQrXIz4VAAAAPxIKDfCnxj0VuB4FPhIENzYgJRgBGgIIAw==";
        List<OnvifMetadataDecoder.Figure> figures=OnvifMetadataDecoder.decodePayload(java.util.Base64.getDecoder().decode(payload),"2026-08-29T09:20:45.129");
        assertFalse(figures.isEmpty());
        assertEquals("2026-08-29T09:20:45.129",figures.get(0).utc);
        assertEquals(6,figures.get(0).classCode);
        assertEquals(2,figures.get(0).stateCode);
        assertEquals("76 %",figures.get(0).confidenceLabel);
        assertEquals("vehicle",figures.get(0).type());
    }

    @Test public void mapsObservedOnvifClasses(){assertEquals("person",OnvifMetadataDecoder.typeForCode(2));assertEquals("animal",OnvifMetadataDecoder.typeForCode(3));assertEquals("vehicle",OnvifMetadataDecoder.typeForCode(6));assertEquals("",OnvifMetadataDecoder.typeForCode(99));}

    @Test public void decodesFastOnvifArchiveActivityBatch(){
        String payload="CgFBEhkIwcaHipPDlgMQgJCd6RoaCCoCCAigBsIX";
        List<OnvifMetadataDecoder.Activity> activities=OnvifMetadataDecoder.decodeActivitiesPayload(java.util.Base64.getDecoder().decode(payload));
        assertEquals(1,activities.size());
        assertEquals(1787914107347L,activities.get(0).timeMs);
        assertEquals(7200000000L,activities.get(0).utcOffsetUs);
        assertEquals(8,activities.get(0).typeMask);
        assertEquals(3010,activities.get(0).sourceCode);
        assertEquals("vehicle",activities.get(0).type());
    }

    @Test public void decodesGenericMotionWithoutFigureGeometry(){
        String payload="CgFBEhoI8fyxt+/ClgMQgJCd6RoaCQoAoAbVTqgGAQ==";
        List<OnvifMetadataDecoder.Activity> activities=OnvifMetadataDecoder.decodeActivitiesPayload(java.util.Base64.getDecoder().decode(payload));
        assertEquals(1,activities.size());assertEquals("motion",activities.get(0).type());assertEquals(10069,activities.get(0).sourceCode);
    }

    @Test public void preservesCombinedActivityMask(){
        OnvifMetadataDecoder.Activity activity=new OnvifMetadataDecoder.Activity(0,0,10,0,false,false,false);
        assertEquals(java.util.Arrays.asList("person","vehicle"),activity.types());
    }

    @Test public void decodesDoorbellRingAsItsOwnActivity(){
        String payload="CgFBEhoIt/fy7qzFlgMQgJCd6RoaCTIAoAbfD6gGAQ==";
        List<OnvifMetadataDecoder.Activity> activities=OnvifMetadataDecoder.decodeActivitiesPayload(java.util.Base64.getDecoder().decode(payload));
        assertEquals(1,activities.size());assertEquals("ring",activities.get(0).type());assertEquals(2015,activities.get(0).sourceCode);assertEquals(true,activities.get(0).asserted);
    }

    @Test public void mapsObservedOnvifActivityMasks(){assertEquals("person",OnvifMetadataDecoder.activityTypeForMask(2));assertEquals("animal",OnvifMetadataDecoder.activityTypeForMask(4));assertEquals("vehicle",OnvifMetadataDecoder.activityTypeForMask(8));assertEquals("",OnvifMetadataDecoder.activityTypeForMask(16));}
}
