package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;

public final class ProfileGRepositoryTest {
    @Test public void pairsOnvifAiBoundariesAndExcludesMotion(){
        List<OnvifMetadataDecoder.Activity> source=Arrays.asList(
                activity(500,0,false,true),activity(800,0,true,true),
                activity(10_000,2,false,false),activity(17_000,2,true,false),
                activity(20_000,4,false,false),activity(24_000,4,true,false));
        List<ProfileGClient.SearchEvent> result=ProfileGRepository.activityIntervals(source);
        assertEquals(2,result.size());
        assertEquals("person",result.get(0).type);assertEquals(4_000,result.get(0).time);assertEquals(23_000,result.get(0).endTime);
        assertEquals("animal",result.get(1).type);assertEquals(14_000,result.get(1).time);assertEquals(30_000,result.get(1).endTime);
    }

    @Test public void rejectsUnclosedAndImplausiblyLongActivities(){
        List<ProfileGClient.SearchEvent> result=ProfileGRepository.activityIntervals(Arrays.asList(
                activity(1_000,2,false,false),
                activity(2_000,4,false,false),activity(2_000+11*60_000,4,true,false)));
        assertEquals(0,result.size());
    }

    @Test public void timelineGapSnapsToNearestRecordingBoundary(){
        List<ProfileGClient.SearchEvent> events=Arrays.asList(
                new ProfileGClient.SearchEvent(10_000,"person",20_000),
                new ProfileGClient.SearchEvent(40_000,"animal",50_000));
        assertEquals(20_000,ProfileGRepository.nearestActivityTime(events,26_000,0,60_000));
        assertEquals(40_000,ProfileGRepository.nearestActivityTime(events,36_000,0,60_000));
        assertEquals(20_000,ProfileGRepository.nearestActivityTime(events,30_000,0,60_000));
    }

    @Test public void timelinePressInsideRecordingKeepsRequestedTimeAndIgnoresMotion(){
        List<ProfileGClient.SearchEvent> events=Arrays.asList(
                new ProfileGClient.SearchEvent(10_000,"person",20_000),
                new ProfileGClient.SearchEvent(25_000,"motion",29_000));
        assertEquals(15_000,ProfileGRepository.nearestActivityTime(events,15_000,0,60_000));
        assertEquals(20_000,ProfileGRepository.nearestActivityTime(events,27_000,0,60_000));
    }

    private static OnvifMetadataDecoder.Activity activity(long time,int mask,boolean asserted,boolean motion){return new OnvifMetadataDecoder.Activity(time,0,mask,0,asserted,motion,false);}
}
