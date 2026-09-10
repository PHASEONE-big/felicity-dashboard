package io.github.okiyashko1337.felicitydashboard;

import org.junit.Test;
import static org.junit.Assert.*;

public final class ArchiveSessionTest {
    @Test public void markerLivesForExactlyThirtyMinutes(){long now=2_000_000L;assertTrue(ArchiveSession.isValid(1_000_000L,now-ArchiveSession.TTL_MS,now));}
    @Test public void markerExpiresAfterThirtyMinutes(){long now=2_000_000L;assertFalse(ArchiveSession.isValid(1_000_000L,now-ArchiveSession.TTL_MS-1,now));}
    @Test public void emptyAndFutureMarkersAreInvalid(){assertFalse(ArchiveSession.isValid(0,1,2));assertFalse(ArchiveSession.isValid(1,3,2));}
}
