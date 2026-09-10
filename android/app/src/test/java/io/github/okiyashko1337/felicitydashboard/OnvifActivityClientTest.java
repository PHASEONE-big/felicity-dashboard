package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;

public final class OnvifActivityClientTest {
    @Test public void boarBoundariesOneHundredMillisecondsApartRemainSeparateRecordings() {
        // Relative timestamps and boundary fields observed on dragon's recorder.
        List<OnvifMetadataDecoder.Activity> boundaries = OnvifActivityClient.deduplicate(Arrays.asList(
                activity(26_556, 4, 3010, false), activity(26_656, 4, 110, true),
                activity(73_076, 4, 3010, false), activity(73_176, 4, 110, true)));
        List<ProfileGClient.SearchEvent> intervals = ProfileGRepository.activityIntervals(boundaries);
        assertEquals(2, intervals.size());
        assertEquals(20_556, intervals.get(0).time);
        assertEquals(32_656, intervals.get(0).endTime);
        assertEquals(67_076, intervals.get(1).time);
        assertEquals(79_176, intervals.get(1).endTime);
        assertEquals(32_656, ArchivePlaybackRanges.endFor(intervals, 23_000, 10_000));
        assertEquals(67_076, ArchivePlaybackRanges.nextStart(intervals, 32_656));
    }

    @Test public void keepsDistinctBoundariesEvenWhenTheirTypeAndTimeMatch() {
        List<OnvifMetadataDecoder.Activity> source = Arrays.asList(
                activity(1000, 4, 3010, false), activity(1000, 4, 110, false),
                activity(1000, 4, 110, true), activity(1100, 4, 110, true),
                new OnvifMetadataDecoder.Activity(1100, 1, 4, 110, true, false, false),
                new OnvifMetadataDecoder.Activity(1100, 1, 4, 110, true, true, false),
                new OnvifMetadataDecoder.Activity(1100, 1, 4, 110, true, true, true));
        assertEquals(source.size(), OnvifActivityClient.deduplicate(source).size());
    }

    @Test public void removesOnlyIdenticalRepeatedBoundaries() {
        List<OnvifMetadataDecoder.Activity> result = OnvifActivityClient.deduplicate(Arrays.asList(
                activity(1000, 4, 3010, false), activity(1000, 4, 3010, false),
                activity(1100, 4, 110, true), activity(1100, 4, 110, true)));
        assertEquals(2, result.size());
        assertEquals(1100, result.get(1).timeMs);
    }

    private static OnvifMetadataDecoder.Activity activity(long time, int mask, int source, boolean asserted) {
        return new OnvifMetadataDecoder.Activity(time, 0, mask, source, asserted, false, false);
    }
}
