const std = @import("std");
const testing = std.testing;

test "demo improved stack trace formatting" {
    // This test will intentionally fail to show the improved stack trace
    const expected = "hello";
    const actual = "world";
    try testing.expectEqualStrings(expected, actual);
}

test "demo assertion with multiple frames" {
    try helperFunction();
}

fn helperFunction() !void {
    try deeperFunction();
}

fn deeperFunction() !void {
    try testing.expect(false);
}