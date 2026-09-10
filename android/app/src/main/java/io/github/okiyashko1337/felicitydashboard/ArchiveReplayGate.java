package io.github.okiyashko1337.felicitydashboard;

/** A superseded RTSP PLAY response must never reopen delivery for an old seek. */
final class ArchiveReplayGate {
    private int requested = -1, active = -1;
    private boolean pending;

    synchronized void request(int generation) {
        requested = generation;
        active = -1;
        pending = true;
    }

    synchronized void played(int generation) {
        if (pending && requested == generation) {
            active = generation;
            pending = false;
        }
    }

    synchronized void pause() {
        active = -1;
        pending = false;
    }

    synchronized int generation() { return active; }
}
