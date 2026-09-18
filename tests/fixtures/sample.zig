const std = @import("std");
const log = std.log.scoped(.app);

pub fn main() void {
    std.log.info("start", .{}); // @log
    log.err("multi", .{ // @log
        1,
    });
    std.debug.print("print\n", .{}); // @print
    const x = compute(1);
    _ = x;
}
