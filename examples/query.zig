const std = @import("std");
const pw = @import("pipewrangler");

const PwQuery = struct {
    conn: pw.Connection,
    map: std.BoundedArray(pw.wire.Extension, 256) = .{},
    writer: std.io.AnyWriter,
    what: pw.wire.Extension,

    const registry_id: pw.wire.Id = .unreserved;
    const id_offset: usize = @intFromEnum(registry_id) + 1;

    pub fn init(writer: std.io.AnyWriter, what: pw.wire.Extension) !@This() {
        return .{ .conn = try pw.Connection.init(), .writer = writer, .what = what };
    }

    pub fn deinit(self: *@This()) void {
        self.conn.deinit(.close);
        self.* = undefined;
    }

    pub fn query(self: *@This()) !void {
        try self.conn.write(.core, .core, .hello, .{ .version = pw.wire.VERSION });
        try self.conn.readAll(self);
        try self.conn.write(.client, .client, .update_properties, .{
            .props = &.{
                .{ .key = .@"application.name", .value = "pipewrangler-query" },
            },
        });
        try self.conn.readAll(self);
        try self.conn.write(.core, .core, .get_registry, .{
            .version = pw.wire.VERSION,
            .new_id = registry_id,
        });
        try self.conn.readAll(self);
    }

    fn allocateId(self: *@This(), ext: pw.wire.Extension) !pw.wire.Id {
        const id = self.map.len;
        try self.map.append(ext);
        return @enumFromInt(id + id_offset);
    }

    // This handler implements these extensions
    pub const extensions: []const pw.wire.Extension = &.{
        .core,
        .client,
        .registry,
        .device,
        .factory,
        .link,
        .module,
        .node,
        .port,
        .metadata,
        .profiler,
    };

    pub fn @"pw::ext"(self: *@This(), id: pw.wire.Id) ?pw.wire.Extension {
        return switch (id) {
            .core => .core,
            .client => .client,
            registry_id => .registry,
            _ => D: {
                const idx: usize = @intFromEnum(id) - id_offset;
                if (idx >= self.map.len) return null;
                break :D self.map.get(idx);
            },
        };
    }

    pub fn @"core::info"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.Info) !void {}

    pub fn @"core::done"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.Done) !void {}

    pub fn @"core::ping"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.Ping) !void {}

    pub fn @"core::error"(_: *@This(), _: pw.wire.Id, err: pw.wire.Core.Error) !void {
        std.log.err("{s}", .{std.json.fmt(err, .{ .whitespace = .indent_2 })});
        @panic("fixme");
    }

    pub fn @"core::remove_id"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.RemoveId) !void {}

    pub fn @"core::bound_id"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.BoundId) !void {}

    pub fn @"core::add_mem"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.AddMem) !void {}

    pub fn @"core::remove_mem"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.RemoveMem) !void {}

    pub fn @"core::bound_props"(_: *@This(), _: pw.wire.Id, _: pw.wire.Core.BoundProps) !void {}

    pub fn @"client::info"(self: *@This(), id: pw.wire.Id, info: pw.wire.Client.Info) !void {
        if (id == .client) return;
        self.writer.print("{s}\n", .{std.json.fmt(info.props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client::permissions"(_: *@This(), _: pw.wire.Id, _: pw.wire.Client.Permissions) !void {}

    pub fn @"registry::global_add"(self: *@This(), id: pw.wire.Id, global_add: pw.wire.Registry.GlobalAdd) !void {
        const ext: pw.wire.Extension = try .fromName(global_add.type);
        if (ext == .core) return;
        if (ext == .client and id == .client) return;
        if (ext != self.what) return;
        try self.conn.write(.registry, id, .bind, .{
            .id = global_add.id,
            .type = global_add.type,
            .version = pw.wire.VERSION,
            .new_id = try self.allocateId(ext),
        });
    }

    pub fn @"registry::global_remove"(_: *@This(), _: pw.wire.Id, _: pw.wire.Registry.GlobalRemove) !void {}

    pub fn @"device::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Device.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info.props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"device::param"(_: *@This(), _: pw.wire.Id, _: pw.wire.Device.Param) !void {}

    pub fn @"factory::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Factory.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info.props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"link::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Link.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info.props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"module::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Module.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info.props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"node::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Node.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info.props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"node::param"(_: *@This(), _: pw.wire.Id, _: pw.wire.Node.Param) !void {}

    pub fn @"port::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Port.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info.props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"port::param"(_: *@This(), _: pw.wire.Id, _: pw.wire.Port.Param) !void {}

    pub fn @"client_node::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.ClientNode.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"metadata::property"(_: *@This(), _: pw.wire.Id, _: pw.wire.Metadata.Property) !void {}

    pub fn @"profiler::profile"(_: *@This(), _: pw.wire.Id, _: pw.wire.Profiler.Profile) !void {}
};

pub fn main() !void {
    if (std.os.argv.len < 2) return error.NoQueryParameter;

    const what = std.meta.stringToEnum(pw.wire.Extension, std.mem.span(std.os.argv[1])) orelse {
        std.log.err("unknown extension: {s}", .{std.os.argv[1]});
        return error.InvalidQueryParameter;
    };

    const writer = std.io.getStdOut().writer().any();
    var query: PwQuery = try .init(writer, what);
    defer query.deinit();
    try query.query();
}
