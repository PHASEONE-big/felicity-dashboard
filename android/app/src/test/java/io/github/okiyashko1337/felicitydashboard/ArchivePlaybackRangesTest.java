package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.*;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.Test;

public final class ArchivePlaybackRangesTest {
    private static ProfileGClient.SearchEvent event(long start, String type, long end) {
        return new ProfileGClient.SearchEvent(start, type, end);
    }

    @Test public void petContinuesAfterOverlappingPersonEventEnds() {
        List<ProfileGClient.SearchEvent> events = Arrays.asList(
                event(10_000, "person", 20_000), event(15_000, "animal", 35_000),
                event(60_000, "animal", 70_000));
        assertEquals(35_000, ArchivePlaybackRanges.endFor(events, 19_000, 10_000));
        assertEquals(60_000, ArchivePlaybackRanges.nextStart(events, 35_000));
    }

    @Test public void chainOfOverlapsDoesNotSkipSecondBoar() {
        List<ProfileGClient.SearchEvent> events = Arrays.asList(
                event(28_000, "pet", 40_000), event(10_000, "person", 20_000),
                event(18_000, "pet", 30_000), event(80_000, "vehicle", 90_000));
        assertEquals(40_000, ArchivePlaybackRanges.endFor(events, 19_000, 0));
        assertEquals(80_000, ArchivePlaybackRanges.nextStart(events, 40_000));
    }

    @Test public void separateEventsKeepSeparateBoundaries() {
        List<ProfileGClient.SearchEvent> events = Arrays.asList(
                event(10_000, "animal", 20_000), event(40_000, "animal", 50_000));
        assertEquals(20_000, ArchivePlaybackRanges.endFor(events, 15_000, 0));
        assertEquals(40_000, ArchivePlaybackRanges.nextStart(events, 20_000));
        assertEquals(50_000, ArchivePlaybackRanges.endFor(events, 45_000, 0));
        assertEquals(0, ArchivePlaybackRanges.nextStart(events, 50_000));
    }

    @Test public void missingMetadataNeverGuessesAShortClipOrAnEarlierEvent() {
        assertEquals(0, ArchivePlaybackRanges.endFor(Collections.emptyList(), 50_000, 10_000));
        assertEquals(0, ArchivePlaybackRanges.endFor(
                Arrays.asList(event(10_000, "animal", 20_000)), 25_000, 10_000));
    }

    @Test public void keyframeLeadDoesNotOverrideTheContainingEvent() {
        List<ProfileGClient.SearchEvent> events = Arrays.asList(
                event(10_000, "pet", 20_000), event(25_000, "pet", 35_000));
        assertEquals(20_000, ArchivePlaybackRanges.endFor(events, 18_000, 10_000));
        assertEquals(35_000, ArchivePlaybackRanges.endFor(events, 24_000, 10_000));
        assertEquals(0, ArchivePlaybackRanges.endFor(events, 24_000, 0));
    }

    @Test public void motionAndPointMarkersDoNotBridgeRecordings() {
        List<ProfileGClient.SearchEvent> events = Arrays.asList(
                event(10_000, "pet", 20_000), event(15_000, "Motion", 45_000),
                event(22_000, "face", 22_000), event(40_000, "pet", 50_000));
        assertEquals(20_000, ArchivePlaybackRanges.endFor(events, 15_000, 0));
        assertEquals(40_000, ArchivePlaybackRanges.nextStart(events, 20_000));
    }
}
