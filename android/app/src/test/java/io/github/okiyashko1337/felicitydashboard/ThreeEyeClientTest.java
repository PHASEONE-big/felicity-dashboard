package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import org.junit.Test;

public final class ThreeEyeClientTest {
    @Test public void archiveStartsAtExactBestViewTimestamp() throws Exception {
        assertEquals("2026-08-24T19:30:13.240Z",ThreeEyeClient.bestViewTime(
                "2026-08-24T19:30:13.240Z","2026-08-24T19:30:51.902Z"));
    }

    @Test public void olderServerFallsBackToGroupTimestamp() throws Exception {
        assertEquals("2026-08-24T19:30:51.902Z",ThreeEyeClient.bestViewTime("","2026-08-24T19:30:51.902Z"));
    }
}
