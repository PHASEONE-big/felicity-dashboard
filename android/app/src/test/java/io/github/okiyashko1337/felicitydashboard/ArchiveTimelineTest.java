package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public final class ArchiveTimelineTest {
    @Test public void sparseDayShowsWholeDay(){assertEquals(ArchiveTimeline.DAY,ArchiveTimeline.adaptiveSpan(6));}
    @Test public void busyDayGetsReadableZoom(){assertEquals(6*ArchiveTimeline.HOUR,ArchiveTimeline.adaptiveSpan(30));assertEquals(3*ArchiveTimeline.HOUR,ArchiveTimeline.adaptiveSpan(80));}
    @Test public void parsesFractionalUtcExactly(){assertEquals(1787609616118L,ArchiveTimeline.parseIso8601("2026-08-24T22:13:36.118187Z"));}
    @Test public void parsesOffsetAsTheSameInstant(){assertEquals(ArchiveTimeline.parseIso8601("2026-08-24T22:13:36.118Z"),ArchiveTimeline.parseIso8601("2026-08-25T00:13:36.118+02:00"));}
}
