const std = @import("std");
const common = @import("common.zig");
const Walker = @import("walker.zig");

const StackItem =  struct {
    index: usize,
    include: bool,
};

walker: Walker,
stack: std.ArrayListUnmanaged(StackItem),
entries: std.ArrayListUnmanaged([]const u8),
returning: bool,

pub fn init(allocator: std.mem.Allocator, path: [:0]const u8, filters: []common.Filter) !@This() {
    var walker = try Walker.init(allocator, path, filters);
    errdefer walker.deinit(allocator);

    var stack = try std.ArrayListUnmanaged(StackItem).initCapacity(allocator, 0);
    errdefer stack.deinit(allocator);

    var entries = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 0);
    errdefer entries.deinit(allocator);

    return .{
        .walker = walker,
        .stack = stack,
        .entries = entries,
        .returning = false,
    };
}

pub fn next(s: *@This()) !?[]const u8 {
    while (true) {
        if (s.returning) {
            if (s.entries.items.len > s.stack.getLast().index) {
                return s.entries.pop();
            } else {
                _ = s.stack.pop();
                s.returning = false;
            }
        }

        if (try s.walker.next()) |action_or_entry| {
            switch (action_or_entry) {
                .enter => |e| {
                    try s.stack.append(s.walker.allocator, .{
                        .index = s.entries.items.len,
                        .include = e.include_empty,
                    });
                },
                .entry => |entry| {
                    if (s.stack.items.len == 0) {
                        switch (entry.action) {
                            .include => {},
                            .exclude => {
                                return try s.walker.allocator.dupe(u8, entry.path);
                            },
                        }
                    } else {
                        switch (entry.action) {
                            .include => {
                                s.stack.items[s.stack.items.len - 1].include = true;
                            },
                            .exclude => {
                                const path = try s.walker.allocator.dupe(u8, entry.path);
                                errdefer s.walker.allocator.free(path);
                                try s.entries.append(s.walker.allocator, path);
                            },
                        }
                    }
                },
                .leave => |l| {
                    if (s.stack.getLast().include) {
                        s.returning = true;
                    } else {
                        const dir = s.stack.pop();
                        if (dir.index < s.entries.items.len) {
                            for (s.entries.items[dir.index..]) |e| s.walker.allocator.free(e);
                            s.entries.shrinkRetainingCapacity(dir.index);

                            const path = try s.walker.allocator.dupe(u8, l.path);
                            errdefer s.walker.allocator.free(path);
                            if (s.stack.items.len == 0) return path;
                            try s.entries.append(s.walker.allocator, path);
                        }
                    }
                },
            }
        } else {
            std.debug.assert(s.entries.items.len == 0);
            std.debug.assert(s.stack.items.len == 0);
            return null;
        }
    }
}

pub fn deinit(s: *@This(), allocator: std.mem.Allocator) void {
    s.walker.deinit(allocator);
    s.stack.deinit(allocator);
    for (s.entries.items) |e| allocator.free(e);
    s.entries.deinit(allocator);
    s.* = undefined;
}
