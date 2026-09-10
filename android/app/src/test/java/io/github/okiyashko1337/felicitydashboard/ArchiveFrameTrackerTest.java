package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.*;
import org.junit.Test;

public final class ArchiveFrameTrackerTest {
    @Test public void delayedRenderAtSameArchiveTimeCannotConsumeTheNewSeek() {
        ArchiveFrameTracker tracker = new ArchiveFrameTracker();
        tracker.reset(1);
        long old = tracker.queue(1, 10_000);
        tracker.reset(2);
        long current = tracker.queue(2, 10_000);
        assertNotEquals(old, current);
        assertNull(tracker.rendered(old));
        ArchiveFrameTracker.Frame frame = tracker.rendered(current);
        assertNotNull(frame);
        assertEquals(2, frame.generation);
        assertEquals(10_000, frame.archiveTimeMs);
    }

    @Test public void inFlightPacketsFromPreviousSeekAreRejectedAfterFlush() {
        ArchiveFrameTracker tracker = new ArchiveFrameTracker();
        tracker.reset(5);
        assertEquals(-1, tracker.queue(4, 90_000));
        long current = tracker.queue(5, 15_000);
        assertEquals(15_000, tracker.rendered(current).archiveTimeMs);
    }

    @Test public void repeatedSeekBackwardsKeepsUniqueFrameIds() {
        ArchiveFrameTracker tracker = new ArchiveFrameTracker();
        long previous = 0;
        for (int generation = 1; generation <= 20; generation++) {
            tracker.reset(generation);
            long current = tracker.queue(generation, 30_000 - generation * 100);
            assertTrue(current > previous);
            assertNull(tracker.rendered(previous));
            assertEquals(generation, tracker.rendered(current).generation);
            previous = current;
        }
    }
}
