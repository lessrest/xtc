const std = @import("std");

test "demonstrate improved stack trace" {
    // This will fail and show our improved stack trace
    const x = 42;
    const y = 43;
    
    // This line will fail and trigger the stack trace
    try std.testing.expectEqual(x, y);
}

test "another demo with assertion" {
    const items = [_]u32{ 1, 2, 3 };
    const expected_sum: u32 = 7; // Wrong!
    
    var sum: u32 = 0;
    for (items) |item| {
        sum += item;
    }
    
    try std.testing.expectEqual(expected_sum, sum);
}