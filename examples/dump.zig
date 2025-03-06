const std = @import("std");
const pw = @import("pipewrangler");

const PwDumper = struct {
    conn: pw.Connection,
    map: std.BoundedArray(pw.wire.Extension, 256) = .{},
    writer: std.io.AnyWriter,

    const registry_id: pw.wire.Id = .unreserved;
    const id_offset: usize = @intFromEnum(registry_id) + 1;

    pub fn init(writer: std.io.AnyWriter) !@This() {
        return .{ .conn = try pw.Connection.init(), .writer = writer };
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
                .{ .key = .@"application.name", .value = "pipewrangler-dump" },
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
    pub const extensions: []const pw.wire.Extension = std.enums.values(pw.wire.Extension);

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

    pub fn @"core::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Core.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"core::done"(self: *@This(), _: pw.wire.Id, done: pw.wire.Core.Done) !void {
        self.writer.print("{s}\n", .{std.json.fmt(done, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"core::ping"(self: *@This(), _: pw.wire.Id, ping: pw.wire.Core.Ping) !void {
        self.writer.print("{s}\n", .{std.json.fmt(ping, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"core::error"(_: *@This(), _: pw.wire.Id, err: pw.wire.Core.Error) !void {
        if (err.res == .IO or err.res == .NOENT) return;
        std.log.err("{s}", .{std.json.fmt(err, .{ .whitespace = .indent_2 })});
        @panic("fixme");
    }

    pub fn @"core::remove_id"(self: *@This(), _: pw.wire.Id, remove_id: pw.wire.Core.RemoveId) !void {
        self.writer.print("{s}\n", .{std.json.fmt(remove_id, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"core::bound_id"(self: *@This(), _: pw.wire.Id, bound_id: pw.wire.Core.BoundId) !void {
        self.writer.print("{s}\n", .{std.json.fmt(bound_id, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"core::add_mem"(self: *@This(), _: pw.wire.Id, add_mem: pw.wire.Core.AddMem) !void {
        self.writer.print("{s}\n", .{std.json.fmt(add_mem, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"core::remove_mem"(self: *@This(), _: pw.wire.Id, remove_mem: pw.wire.Core.RemoveMem) !void {
        self.writer.print("{s}\n", .{std.json.fmt(remove_mem, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"core::bound_props"(self: *@This(), _: pw.wire.Id, bound_props: pw.wire.Core.BoundProps) !void {
        self.writer.print("{s}\n", .{std.json.fmt(bound_props, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Client.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client::permissions"(self: *@This(), _: pw.wire.Id, permissions: pw.wire.Client.Permissions) !void {
        self.writer.print("{s}\n", .{std.json.fmt(permissions, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"registry::global_add"(self: *@This(), id: pw.wire.Id, global_add: pw.wire.Registry.GlobalAdd) !void {
        self.writer.print("{s}\n", .{std.json.fmt(global_add, .{ .whitespace = .indent_2 })}) catch {};
        const ext: pw.wire.Extension = try .fromName(global_add.type);
        if (ext == .core) return;
        if (ext == .client and id == .client) return;
        try self.conn.write(.registry, id, .bind, .{
            .id = global_add.id,
            .type = global_add.type,
            .version = pw.wire.VERSION,
            .new_id = try self.allocateId(ext),
        });
    }

    pub fn @"registry::global_remove"(self: *@This(), _: pw.wire.Id, global_remove: pw.wire.Registry.GlobalRemove) !void {
        self.writer.print("{s}\n", .{std.json.fmt(global_remove, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"device::info"(self: *@This(), id: pw.wire.Id, info: pw.wire.Device.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
        var iter = info.param_infos.iterator();
        while (iter.next()) |kv| {
            if (!kv.flags.read) continue;
            try self.conn.write(.device, id, .enum_params, .{
                .seq = 69,
                .id = kv.id,
                .index = 0,
                .num = 99,
                .filter = .none,
            });
        }
    }

    pub fn @"device::param"(self: *@This(), _: pw.wire.Id, param: pw.wire.Device.Param) !void {
        self.writer.print("{s}\n", .{std.json.fmt(param, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"factory::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Factory.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"link::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Link.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"module::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.Module.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"node::info"(self: *@This(), id: pw.wire.Id, info: pw.wire.Node.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
        var iter = info.param_infos.iterator();
        while (iter.next()) |kv| {
            try self.conn.write(.node, id, .enum_params, .{
                .seq = 69,
                .id = kv.id,
                .index = 0,
                .num = 99,
                .filter = .none,
            });
        }
    }

    pub fn @"node::param"(self: *@This(), _: pw.wire.Id, param: pw.wire.Node.Param) !void {
        self.writer.print("{s}\n", .{std.json.fmt(param, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"port::info"(self: *@This(), id: pw.wire.Id, info: pw.wire.Port.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
        var iter = info.param_infos.iterator();
        while (iter.next()) |kv| {
            try self.conn.write(.port, id, .enum_params, .{
                .seq = 69,
                .id = kv.id,
                .index = 0,
                .num = 99,
                .filter = .none,
            });
        }
    }

    pub fn @"port::param"(self: *@This(), _: pw.wire.Id, param: pw.wire.Port.Param) !void {
        self.writer.print("{s}\n", .{std.json.fmt(param, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::info"(self: *@This(), _: pw.wire.Id, info: pw.wire.ClientNode.Info) !void {
        self.writer.print("{s}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::transport"(self: *@This(), _: pw.wire.Id, transport: pw.wire.ClientNode.Transport) !void {
        self.writer.print("{s}\n", .{std.json.fmt(transport, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::set_param"(self: *@This(), _: pw.wire.Id, set_param: pw.wire.ClientNode.SetParam) !void {
        self.writer.print("{s}\n", .{std.json.fmt(set_param, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::set_io"(self: *@This(), _: pw.wire.Id, set_io: pw.wire.ClientNode.SetIo) !void {
        self.writer.print("{s}\n", .{std.json.fmt(set_io, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::event"(self: *@This(), _: pw.wire.Id, event: pw.wire.ClientNode.Event) !void {
        self.writer.print("{s}\n", .{std.json.fmt(event, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::command"(self: *@This(), _: pw.wire.Id, command: pw.wire.ClientNode.Command) !void {
        self.writer.print("{s}\n", .{std.json.fmt(command, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::add_port"(self: *@This(), _: pw.wire.Id, add_port: pw.wire.ClientNode.AddPort) !void {
        self.writer.print("{s}\n", .{std.json.fmt(add_port, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::remove_port"(self: *@This(), _: pw.wire.Id, remove_port: pw.wire.ClientNode.RemovePort) !void {
        self.writer.print("{s}\n", .{std.json.fmt(remove_port, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::port_set_param"(self: *@This(), _: pw.wire.Id, port_set_param: pw.wire.ClientNode.PortSetParam) !void {
        self.writer.print("{s}\n", .{std.json.fmt(port_set_param, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::use_buffers"(self: *@This(), _: pw.wire.Id, use_buffers: pw.wire.ClientNode.UseBuffers) !void {
        self.writer.print("{s}\n", .{std.json.fmt(use_buffers, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::port_set_io"(self: *@This(), _: pw.wire.Id, port_set_io: pw.wire.ClientNode.PortSetIo) !void {
        self.writer.print("{s}\n", .{std.json.fmt(port_set_io, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::set_activation"(self: *@This(), _: pw.wire.Id, set_activation: pw.wire.ClientNode.SetActivation) !void {
        self.writer.print("{s}\n", .{std.json.fmt(set_activation, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"client_node::port_set_mix_info"(self: *@This(), _: pw.wire.Id, port_set_mix_info: pw.wire.ClientNode.PortSetMixInfo) !void {
        self.writer.print("{s}\n", .{std.json.fmt(port_set_mix_info, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"metadata::property"(self: *@This(), _: pw.wire.Id, property: pw.wire.Metadata.Property) !void {
        self.writer.print("{s}\n", .{std.json.fmt(property, .{ .whitespace = .indent_2 })}) catch {};
    }

    pub fn @"profiler::profile"(self: *@This(), _: pw.wire.Id, profile: pw.wire.Profiler.Profile) !void {
        self.writer.print("{s}\n", .{std.json.fmt(profile, .{ .whitespace = .indent_2 })}) catch {};
    }
};

pub fn main() !void {
    const writer = std.io.getStdOut().writer().any();
    var dumper: PwDumper = try .init(writer);
    defer dumper.deinit();
    try dumper.query();
}
