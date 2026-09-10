package io.github.okiyashko1337.felicitydashboard;

import java.util.HashMap;
import java.util.Map;

/** Maps unique decoder timestamps to archive time and the seek that owns them. */
final class ArchiveFrameTracker {
    static final class Frame {
        final int generation;
        final long archiveTimeMs;
        Frame(int generation, long archiveTimeMs) {
            this.generation = generation;
            this.archiveTimeMs = archiveTimeMs;
        }
    }

    private final Map<Long, Frame> pending = new HashMap<>();
    private int generation;
    private long nextPresentationTimeUs;

    synchronized void reset(int generation) {
        this.generation = generation;
        pending.clear();
        // Do not reuse a PTS after flush: a late render callback for the same
        // absolute recording time must not consume the new seek's frame.
    }

    synchronized long queue(int generation, long archiveTimeMs) {
        if (generation != this.generation) return -1;
        long pts = ++nextPresentationTimeUs;
        pending.put(pts, new Frame(generation, archiveTimeMs));
        return pts;
    }

    synchronized Frame rendered(long presentationTimeUs) {
        Frame frame = pending.remove(presentationTimeUs);
        return frame != null && frame.generation == generation ? frame : null;
    }
}
