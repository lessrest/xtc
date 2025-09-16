const Self = @import("vm.zig");
const c = @import("wren.zig");
const std = @import("std");
const syscalls = @import("syscalls.zig");
const slots_api = @import("slots.zig");
const Platform = @import("platform.zig");
const ticket = @import("../ticket.zig");
const miniflex = @import("miniflex");
const Document = miniflex.dom.Dom;
const root_mod = @import("root");

const has_threads = if (@hasDecl(root_mod, "has_threads")) root_mod.has_threads else true;
const ThreadType = if (has_threads) std.Thread else struct {};

const log = std.log.scoped(.wrenctx);

const Request = syscalls.RequestUnion(Platform);
const Syscaller = syscalls.Syscaller(Platform, Self, Context);

pub const FiberID = struct {
    handle: *c.Handle,
    ticket: [10]u8,

    pub fn init(handle: *c.Handle) FiberID {
        const tix = ticket.from(handle) catch {
            std.debug.panic("failed to get ticket for handle {p}", .{handle});
        };
        return FiberID{
            .handle = handle,
            .ticket = tix,
        };
    }

    pub fn deinit(self: FiberID, vm: *c.VM) void {
        c.wrenReleaseHandle(vm, self.handle);
    }
};

pub const Context = struct {
    document: *Document,
    allocator: std.mem.Allocator,
    vm: *c.VM,

    thunks: std.ArrayList(FiberID) = .{},
    background_threads: std.ArrayList(ThreadType) = .{},
    fiber_readers: std.SegmentedList(FiberReader, 64) = .{},

    handles: std.EnumMap(enum {
        @"call()",
        @"call(_)",
        @"error",
        isDone,
    }, *c.Handle) = .{},

    pub fn init(allocator: std.mem.Allocator, document: *Document) Context {
        return Context{
            .document = document,
            .allocator = allocator,
            .vm = undefined,
        };
    }

    pub fn deinit(self: *Context) void {
        self.thunks.deinit(self.allocator);
        if (has_threads) {
            self.background_threads.deinit(self.allocator);
        }

        var it = self.fiber_readers.iterator(0);
        while (it.next()) |reader| {
            reader.deinit();
        }

        self.fiber_readers.deinit(self.allocator);
        var it2 = self.handles.iterator();
        while (it2.next()) |entry| {
            c.wrenReleaseHandle(self.vm, entry.value.*);
        }
    }

    pub fn addBackgroundThread(self: *Context, thread: ThreadType) !void {
        if (!has_threads) return error.ThreadsUnavailable;
        log.debug("starting background thread", .{});
        try self.background_threads.append(self.allocator, thread);
    }

    pub fn joinBackgroundThreads(self: *Context) !void {
        if (!has_threads) return;
        const threads = try self.background_threads.toOwnedSlice(self.allocator);
        defer self.allocator.free(threads);
        for (threads) |thread| {
            thread.join();
            log.debug("joined background thread", .{});
        }
    }

    pub fn methodHandle(self: *Context, tag: @TypeOf(self.handles).Key) *c.Handle {
        if (self.handles.get(tag)) |handle| {
            return handle;
        } else {
            const handle = c.wrenMakeCallHandle(self.vm, @tagName(tag)) orelse {
                std.debug.panic("failed to make call handle for {s}", .{@tagName(tag)});
            };
            self.handles.put(tag, handle);
            return handle;
        }
    }

    pub fn readableStreamFromFiber(self: *Context, fiber: FiberID, size: u32) !u32 {
        const index = self.fiber_readers.count();
        const reader = try self.fiber_readers.addOne(self.allocator);

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        reader.* = .init(self, fiber, buffer);
        log.debug("created reader {d} for fiber {s}", .{ index, fiber.ticket });
        return @as(u32, @intCast(index));
    }

    pub fn slots(self: *Context) slots_api.SlotBuilder {
        return slots_api.SlotBuilder.init(self.vm, self.allocator);
    }
};

pub const FiberReader = struct {
    context: *Context,
    fiber: FiberID,
    reader: std.io.Reader,

    pub fn init(context: *Context, fiber: FiberID, buffer: []u8) FiberReader {
        return FiberReader{
            .context = context,
            .fiber = fiber,
            .reader = .{
                .vtable = &std.io.Reader.VTable{
                    .stream = stream,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn deinit(self: *FiberReader) void {
        log.info("deinit fiber reader {s}", .{self.fiber.ticket});
        self.fiber.deinit(self.context.vm);
        self.context.allocator.free(self.reader.buffer);
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *FiberReader = @alignCast(@fieldParentPtr("reader", r));
        var builder = self.context.slots();

        log.debug(
            "reader pulling max {d}B from fiber {s}",
            .{ limit.toInt().?, self.fiber.ticket },
        );

        if (builder.set(0, self.fiber)
            .callWithHandle(self.context.methodHandle(.isDone))
            .as(bool) catch {
            return error.EndOfStream;
        }) {
            return error.EndOfStream;
        }

        if (builder.set(0, self.fiber)
            .set(1, limit.toInt())
            .callWithHandle(self.context.methodHandle(.@"call(_)"))
            .as(?[]const u8)) |maybe_data|
        {
            if (maybe_data) |data| {
                log.debug("fiber {s} yielded {d}B", .{ self.fiber.ticket, data.len });
                return w.write(limit.sliceConst(data)) catch {
                    return error.WriteFailed;
                };
            } else {
                log.warn("{s} yielded null", .{self.fiber.ticket});
                return error.EndOfStream;
            }
        } else |err| {
            std.debug.print(
                "{s} failed to stream: {any}\n",
                .{ self.fiber.ticket, err },
            );
            return error.ReadFailed;
        }
    }
};
