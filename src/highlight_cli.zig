const std = @import("std");
const corpus = @import("highlight/corpus.zig");
const Engine = @import("highlight/engine.zig").Engine;
const Metrics = @import("highlight/engine.zig").Metrics;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const output = &output_writer.interface;
    defer output.flush() catch {};

    const command = if (arguments.len > 1) arguments[1] else "parse";
    if (std.mem.eql(u8, command, "parse")) {
        const source = if (arguments.len > 2) arguments[2] else "echo hello";
        try parse(init.gpa, output, source, false);
        return;
    }
    if (std.mem.eql(u8, command, "tree")) {
        const source = if (arguments.len > 2) arguments[2] else "echo hello";
        try parse(init.gpa, output, source, true);
        return;
    }
    if (std.mem.eql(u8, command, "edits")) {
        if (arguments.len < 3) return error.MissingEditSequence;
        try editSequence(init.gpa, output, arguments[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "benchmark")) {
        const iterations = if (arguments.len > 2)
            try std.fmt.parseUnsigned(usize, arguments[2], 10)
        else
            1000;
        const source = if (arguments.len > 3)
            arguments[3]
        else
            corpus.cases[0].source;
        try benchmark(init.gpa, output, "custom", iterations, source);
        return;
    }
    if (std.mem.eql(u8, command, "benchmark-suite")) {
        const iterations = if (arguments.len > 2)
            try std.fmt.parseUnsigned(usize, arguments[2], 10)
        else
            1000;
        try benchmarkSuite(init.gpa, output, iterations);
        return;
    }

    try output.print(
        "usage: {s} [parse SOURCE | tree SOURCE | edits SOURCE... | benchmark [ITERATIONS [SOURCE]] | benchmark-suite [ITERATIONS]]\n",
        .{arguments[0]},
    );
    try output.flush();
    std.process.exit(2);
}

fn parse(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    source: []const u8,
    include_tree: bool,
) !void {
    var engine = try Engine.init(allocator);
    defer engine.deinit();

    var result = try engine.highlight(source);
    defer result.deinit(allocator);

    try printMetrics(output, source.len, result.metrics, result.has_parse_error);
    if (include_tree) {
        const sexp = try engine.treeSExpression(allocator);
        defer allocator.free(sexp);
        try output.print("{s}\n", .{sexp});
    }
    for (result.spans) |span| {
        try output.print("{d} {d} {s}\n", .{ span.start_byte, span.end_byte, @tagName(span.style) });
    }
}

fn editSequence(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    sources: []const []const u8,
) !void {
    var engine = try Engine.init(allocator);
    defer engine.deinit();

    for (sources, 0..) |source, index| {
        var result = try engine.highlight(source);
        defer result.deinit(allocator);
        try output.print("edit={d} ", .{index});
        try printMetrics(output, source.len, result.metrics, result.has_parse_error);
    }
}

fn printMetrics(
    output: *std.Io.Writer,
    source_length: usize,
    metrics: Metrics,
    has_parse_error: bool,
) !void {
    try output.print(
        "bytes={d} errors={} incremental={} captures={d} regions={d} parse_ns={d} query_ns={d} compose_ns={d}\n",
        .{
            source_length,
            has_parse_error,
            metrics.incremental,
            metrics.capture_count,
            metrics.region_count,
            metrics.parse_nanoseconds,
            metrics.query_nanoseconds,
            metrics.compose_nanoseconds,
        },
    );
}

fn benchmarkSuite(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    iterations: usize,
) !void {
    for (corpus.cases) |case| {
        try benchmark(allocator, output, case.name, iterations, case.source);
    }

    const stress_lengths = [_]usize{ 1024, 10 * 1024, 100 * 1024 };
    const divisors = [_]usize{ 2, 10, 100 };
    for (stress_lengths, divisors) |length, divisor| {
        const source = try corpus.stressSource(allocator, length);
        defer allocator.free(source);
        const stress_iterations = @max(10, iterations / divisor);
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "stress-{d}", .{length});
        try benchmark(allocator, output, name, stress_iterations, source);
    }
}

fn benchmark(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    name: []const u8,
    iterations: usize,
    source: []const u8,
) !void {
    if (iterations == 0) return error.NoIterations;

    const alternate_source = try std.fmt.allocPrint(allocator, "{s} ", .{source});
    defer allocator.free(alternate_source);

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    for (0..20) |index| {
        const warmup_source = if (index % 2 == 0) source else alternate_source;
        var result = try engine.highlight(warmup_source);
        result.deinit(allocator);
    }

    var samples = try Samples.init(allocator, iterations);
    defer samples.deinit(allocator);

    for (0..iterations) |index| {
        const current_source = if (index % 2 == 0) source else alternate_source;
        var result = try engine.highlight(current_source);
        samples.record(index, result.metrics);
        result.deinit(allocator);
    }
    samples.sort();

    try output.print("benchmark={s} iterations={d} bytes={d} ", .{ name, iterations, source.len });
    try printDistribution(output, "parse", samples.parse);
    try printDistribution(output, "query", samples.query);
    try printDistribution(output, "compose", samples.compose);
    try printDistribution(output, "total", samples.total);
    try output.writeByte('\n');
}

const Samples = struct {
    parse: []u64,
    query: []u64,
    compose: []u64,
    total: []u64,

    fn init(allocator: std.mem.Allocator, count: usize) !Samples {
        const parse_samples = try allocator.alloc(u64, count);
        errdefer allocator.free(parse_samples);
        const query_samples = try allocator.alloc(u64, count);
        errdefer allocator.free(query_samples);
        const compose_samples = try allocator.alloc(u64, count);
        errdefer allocator.free(compose_samples);
        const total_samples = try allocator.alloc(u64, count);
        return .{
            .parse = parse_samples,
            .query = query_samples,
            .compose = compose_samples,
            .total = total_samples,
        };
    }

    fn deinit(self: *Samples, allocator: std.mem.Allocator) void {
        allocator.free(self.parse);
        allocator.free(self.query);
        allocator.free(self.compose);
        allocator.free(self.total);
        self.* = undefined;
    }

    fn record(self: *Samples, index: usize, metrics: Metrics) void {
        self.parse[index] = metrics.parse_nanoseconds;
        self.query[index] = metrics.query_nanoseconds;
        self.compose[index] = metrics.compose_nanoseconds;
        self.total[index] = metrics.totalNanoseconds();
    }

    fn sort(self: *Samples) void {
        std.mem.sort(u64, self.parse, {}, std.sort.asc(u64));
        std.mem.sort(u64, self.query, {}, std.sort.asc(u64));
        std.mem.sort(u64, self.compose, {}, std.sort.asc(u64));
        std.mem.sort(u64, self.total, {}, std.sort.asc(u64));
    }
};

fn printDistribution(output: *std.Io.Writer, name: []const u8, samples: []const u64) !void {
    var total: u128 = 0;
    for (samples) |sample| total += sample;
    try output.print(
        "{s}_p50_ns={d} {s}_p99_ns={d} {s}_mean_ns={d} ",
        .{
            name,
            percentile(samples, 50),
            name,
            percentile(samples, 99),
            name,
            total / samples.len,
        },
    );
}

fn percentile(samples: []const u64, percentage: usize) u64 {
    const index = @min((samples.len * percentage) / 100, samples.len - 1);
    return samples[index];
}
