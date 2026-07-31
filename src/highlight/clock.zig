const std = @import("std");

pub fn nowNanoseconds() u64 {
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &value) != 0) return 0;
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
