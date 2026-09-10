package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.*;
import org.junit.Test;

public final class ArchiveReplayGateTest {
    @Test public void latePlayResponseCannotDeliverPreviousEvent() {
        ArchiveReplayGate gate = new ArchiveReplayGate();
        gate.request(1);
        gate.request(2);
        gate.played(1);
        assertEquals(-1, gate.generation());
        gate.played(2);
        assertEquals(2, gate.generation());
    }

    @Test public void pauseWhilePlayIsPendingKeepsMediaDisabled() {
        ArchiveReplayGate gate = new ArchiveReplayGate();
        gate.request(1);
        gate.pause();
        gate.played(1);
        assertEquals(-1, gate.generation());
        gate.request(2);
        gate.played(2);
        assertEquals(2, gate.generation());
        gate.pause();
        assertEquals(-1, gate.generation());
    }
}
