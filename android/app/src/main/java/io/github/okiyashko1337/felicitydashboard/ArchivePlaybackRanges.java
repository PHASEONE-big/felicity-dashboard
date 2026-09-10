package io.github.okiyashko1337.felicitydashboard;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Continuous AI coverage, independent of the order/class of metadata events. */
final class ArchivePlaybackRanges {
    private ArchivePlaybackRanges() {}

    static long endFor(List<ProfileGClient.SearchEvent> events, long target, long keyframeLead) {
        List<long[]> ranges = merged(events);
        // A real containing interval takes precedence over another interval's lead-in.
        for (long[] range : ranges) {
            if (target >= range[0] && target < range[1]) return range[1];
        }
        for (long[] range : ranges) {
            if (target < range[0] && range[0] - target <= keyframeLead) return range[1];
            if (target == range[1]) return range[1];
        }
        // Metadata can still be loading. Never invent a 15-second recording or
        // borrow an already-ended event just because it is within two minutes.
        return 0;
    }

    static long nextStart(List<ProfileGClient.SearchEvent> events, long end) {
        for (long[] range : merged(events)) {
            if (range[0] > end) return range[0];
        }
        return 0;
    }

    private static List<long[]> merged(List<ProfileGClient.SearchEvent> events) {
        List<long[]> sorted = new ArrayList<>();
        for (ProfileGClient.SearchEvent event : events) {
            if (event == null || event.type == null || event.endTime <= event.time
                    || event.type.toLowerCase(Locale.US).contains("motion")) continue;
            sorted.add(new long[]{event.time, event.endTime});
        }
        sorted.sort((a, b) -> Long.compare(a[0], b[0]));
        List<long[]> result = new ArrayList<>();
        for (long[] range : sorted) {
            if (result.isEmpty() || range[0] > result.get(result.size() - 1)[1]) {
                result.add(range);
            } else {
                long[] last = result.get(result.size() - 1);
                last[1] = Math.max(last[1], range[1]);
            }
        }
        return result;
    }
}
