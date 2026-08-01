const c = @cImport({
    @cInclude("time.h");
});

/// Monotonic time is appropriate for a prompt profiler: wall-clock changes
/// must not produce negative or otherwise misleading durations.
pub fn nowNanoseconds() u64 {
    var timestamp: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &timestamp) != 0) return 0;
    return @as(u64, @intCast(timestamp.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(timestamp.tv_nsec));
}

pub fn elapsedSince(start: u64) u64 {
    return nowNanoseconds() -| start;
}
