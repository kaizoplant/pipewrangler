//! Pipewire protocol
//! Shares similarities with the wayland protocol
//! <https://docs.pipewire.org/page_native_protocol.html>

const std = @import("std");
const spa = @import("spa/spa.zig");
const pod = spa.pod;
const Pod = pod.Pod;

pub const VERSION: u32 = 3;

pub const ReadError = error{
    InvalidHeader,
    InvalidFooter,
    DestinationTypeIncompatible,
} || pod.ReadError;

pub const WriteError = pod.WriteError;

pub const E = D: {
    var fields = std.meta.fields(std.posix.E)[0..].*;
    for (&fields) |*field| field.value = @as(u32, @bitCast(@as(i32, -field.value)));
    break :D @Type(.{
        .@"enum" = .{
            .tag_type = u32,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
};

// I wanted to make this a packed struct and store the extension in the ID
// However the pipewire server has hard limitation that clients have to allocate IDs contiguously which kind of sucks
// So I refactored pipewrangler to leave the ID bookkeeping responsibility to the application
pub const Id = enum(u32) {
    core,
    client,
    _,

    pub const unreserved: @This() = @enumFromInt(2);

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.stream.print("\"{}\"", .{self});
        jws.endWriteRaw();
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            inline .core, .client => try writer.print("local!{s}", .{@tagName(self)}),
            _ => try writer.print("local!{}", .{@intFromEnum(self)}),
        }
    }
};

pub const Global = enum(u32) {
    _,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.stream.print("\"{}\"", .{self});
        jws.endWriteRaw();
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("global!{}", .{@intFromEnum(self)});
    }
};

pub const Memory = enum(u32) {
    _,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.stream.print("\"{}\"", .{self});
        jws.endWriteRaw();
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("mem!{}", .{@intFromEnum(self)});
    }
};

pub const ServerFooter = struct {
    pub const Generation = struct {
        registry_generation: u64,
    };

    pub const OpCode = union(enum) {
        generation: Generation,
    };

    footer: pod.types.Struct,
    index: usize = 0,

    pub fn init(footer: Pod) !@This() {
        if (footer != .@"struct") return error.InvalidFooter;
        return .{ .footer = footer.@"struct" };
    }

    pub fn next(self: *@This()) !?OpCode {
        if (self.index < self.footer.fields.len) {
            defer self.index += 2;
            const code = self.footer.fields[self.index].id;
            inline for (std.meta.fields(OpCode), 0..) |field, tag| {
                if (@intFromEnum(code) == tag) {
                    const data = self.footer.fields[self.index + 1];
                    return @unionInit(OpCode, field.name, try data.map(field.type));
                }
            }
        }
        return null;
    }
};

pub const ClientFooter = union(enum) {
    pub const Generation = struct {
        client_generation: u64,
    };
    generation: Generation,
};

pub const Header = extern struct {
    id: Id,
    msg: packed struct(u32) {
        size: u24,
        opcode: u8,
    },
    seq: i32,
    n_fds: u32,

    pub fn init(reader: anytype) ReadError!@This() {
        var header: @This() = undefined;
        try header.read(reader);
        return header;
    }

    pub fn read(self: *@This(), reader: anytype) ReadError!void {
        const ret = try reader.readAll(std.mem.asBytes(self));
        if (ret != @sizeOf(@This())) return error.InvalidHeader;
        if (!std.mem.isAligned(self.msg.size, 8)) return error.InvalidHeader;
    }

    pub fn readPod(self: @This(), arena: std.mem.Allocator, reader: anytype) ReadError!Pod {
        return Pod.read(arena, self.msg.size, reader);
    }

    pub fn readFooter(self: @This(), arena: std.mem.Allocator, reader: anytype) ReadError!ServerFooter {
        return .init(try Pod.read(arena, self.msg.size, reader));
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == 16);
    }
};

pub const Access = enum {
    unrestricted,
    flatpak,
};

pub const Core = struct {
    pub const Type = "PipeWire:Interface:Core";

    pub const Method = enum(u16) {
        hello = 1,
        sync,
        pong,
        @"error",
        get_registry,
        create_object,
        destroy,
    };

    pub const Hello = struct {
        version: u32,
    };

    pub const Sync = struct {
        /// The id will be returned in the Done event
        id: Global,
        /// Is usually generated automatically and will be returned in the Done event
        seq: i32,
    };

    pub const Pong = struct {
        id: Global,
        seq: i32,
    };

    pub const Error = struct {
        /// The id of the proxy that is in error
        id: Id,
        /// A seq number from the failing request (if any)
        seq: i32,
        /// A negative errno style error code
        res: E,
        /// An error message
        msg: [:0]const u8,
    };

    pub const GetRegistry = struct {
        /// The version of the registry interface used on the client
        version: u32,
        /// The id of the new proxy with the registry interface
        new_id: Id,
    };

    pub const CreateObject = struct {
        /// The name of a server factory object to use
        factory_name: [:0]const u8,
        /// The type of the object to create, this is also the type of the interface of the new_id proxy
        type: [:0]const u8,
        /// Version of the object
        version: u32,
        /// Extra properties to create the object
        props: []const pod.containers.Prop,
        /// The proxy id of the new object
        new_id: Id,
    };

    pub const Destroy = struct {
        /// The proxy id of the object to destroy.
        id: Id,
    };

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .hello => Hello,
            .sync => Sync,
            .pong => Pong,
            .@"error" => Error,
            .get_registry => GetRegistry,
            .create_object => CreateObject,
            .destroy => Destroy,
        };
    }

    pub const Events = enum(u16) {
        info,
        done,
        ping,
        @"error",
        remove_id,
        bound_id,
        add_mem,
        remove_mem,
        bound_props,
    };

    pub const Info = struct {
        /// The id of the server (0)
        id: Global,
        /// A unique cookie for this server
        cookie: u32,
        /// The name of the user running the server
        user_name: [:0]const u8,
        /// The name of the host running the server
        host_name: [:0]const u8,
        /// A version string of the server
        version: [:0]const u8,
        /// The name of the server
        name: [:0]const u8,
        /// A set of bits with changes to the info
        change_mask: packed struct(u64) {
            props: bool,
            _: u63 = 0,
        },
        /// Optional key/value properties, valid when change_mask has (1<<0)
        props: pod.containers.KeyValue.Map,
    };

    pub const Done = struct {
        id: Global,
        seq: i32,
    };

    pub const Ping = struct {
        id: Global,
        seq: i32,
    };

    // Error is same as method

    pub const RemoveId = struct {
        id: Id,
    };

    pub const BoundId = struct {
        id: Id,
        global_id: Global,
    };

    pub const AddMem = struct {
        /// A server allocated id for this memory
        id: Memory,
        /// The memory type, see enum spa_data_type
        type: spa.wire.DataType,
        /// The index of the fd sent with this message
        fd: u64,
        /// Extra flags
        flags: spa.flags.Data,
    };

    pub const RemoveMem = struct {
        id: Memory,
    };

    pub const BoundProps = struct {
        /// A proxy id
        id: Id,
        /// The global_id as it will appear in the registry
        global_id: Global,
        /// The properties of the global
        props: pod.containers.KeyValue.Map,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
            .done => Done,
            .ping => Ping,
            .@"error" => Error,
            .remove_id => RemoveId,
            .bound_id => BoundId,
            .add_mem => AddMem,
            .remove_mem => RemoveMem,
            .bound_props => BoundProps,
        };
    }
};

pub const Client = struct {
    pub const Type = "PipeWire:Interface:Client";

    pub const Method = enum(u16) {
        @"error" = 1,
        update_properties,
        get_permissions,
        update_permissions,
    };

    pub const Error = struct {
        /// A client proxy id to send the error to
        id: Id,
        /// A negative errno style error code
        res: E,
        /// An error message
        msg: [:0]const u8,
    };

    pub const UpdateProperties = struct {
        props: []const pod.containers.Prop,
    };

    pub const GetPermissions = struct {
        /// The start index of the permissions to get
        index: u32,
        /// The number of permissions to get
        num: u32,
    };

    pub const UpdatePermissions = []const pod.containers.IdPermission;

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .@"error" => Error,
            .update_properties => UpdateProperties,
            .get_permissions => GetPermissions,
            .update_permissions => UpdatePermissions,
        };
    }

    pub const Events = enum(u16) {
        info,
        permissions,
    };

    pub const Info = struct {
        /// The global id of the client
        id: Global,
        /// The changes emitted by this event
        change_mask: packed struct(u64) {
            props: bool,
            _: u63 = 0,
        },
        /// Properties of this object, valid when change_mask has (1<<0)
        props: pod.containers.KeyValue.Map,
    };

    pub const Permissions = struct {
        /// Index of the first permission
        index: u32,
        // The permission for the given id
        permissions: pod.containers.IdPermission.List,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
            .permissions => Permissions,
        };
    }
};

pub const Registry = struct {
    pub const Type = "PipeWire:Interface:Registry";

    pub const Method = enum(u16) {
        bind = 1,
        destroy,
    };

    pub const Bind = struct {
        id: Global,
        type: [:0]const u8,
        version: u32,
        new_id: Id,
    };

    pub const Destroy = struct {
        id: Id,
    };

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .bind => Bind,
            .destroy => Destroy,
        };
    }

    pub const Events = enum(u16) {
        global_add,
        global_remove,
    };

    pub const GlobalAdd = struct {
        id: Global,
        permission: spa.flags.Permission,
        type: [:0]const u8,
        version: u32,
        props: pod.containers.KeyValue.Map,
    };

    pub const GlobalRemove = struct {
        id: Global,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .global_add => GlobalAdd,
            .global_remove => GlobalRemove,
        };
    }
};

pub const Device = struct {
    pub const Type = "PipeWire:Interface:Device";

    pub const Method = enum(u16) {
        subscribe_params = 1,
        enum_params,
        set_param,
    };

    pub const SubscribeParams = struct {
        /// Array of param Ids to subscribe to
        ids: []const spa.wire.ParamType,
    };

    pub const EnumParams = struct {
        /// An automatically generated sequence number, will be copied into the reply
        seq: i32,
        /// The param id to enumerate
        id: spa.wire.ParamType,
        /// The first param index to retrieve
        index: u32,
        /// The number of params to receive
        num: u32,
        /// An optional filter object for the param
        filter: Pod,
    };

    pub const SetParam = struct {
        /// The param id to set
        id: spa.wire.ParamType,
        /// Extra flags
        flags: spa.flags.Param,
        /// The param object to set
        param: Pod,
    };

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .subscribe_params => SubscribeParams,
            .enum_params => EnumParams,
            .set_param => SetParam,
        };
    }

    pub const Events = enum(u16) {
        info,
        param,
    };

    pub const Info = struct {
        /// The global id of the device
        id: Global,
        /// A bitmask of changed fields
        change_mask: packed struct(u64) {
            props: bool,
            param_infos: bool,
            _: u62 = 0,
        },
        /// Extra properties, valid when change_mask is (1<<0)
        props: pod.containers.KeyValue.Map,
        /// Info about the parameters, valid when change_mask is (1<<1) For each parameter, the id and current flags are given
        param_infos: pod.containers.ParamInfo.Map,
    };

    pub const Param = struct {
        /// The sequence number send by the client EnumParams or server generated in the SubscribeParams case
        seq: i32,
        /// The param id that is reported, see enum spa_param_type
        id: spa.wire.ParamType,
        /// The index of the parameter
        index: u32,
        /// The index of the next parameter
        next: u32,
        /// The parameter. The object type depends on the id
        param: Pod,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
            .param => Param,
        };
    }
};

pub const Factory = struct {
    pub const Type = "PipeWire:Interface:Factory";

    pub const Method = enum(u16) {};

    pub const Events = enum(u16) {
        info,
    };

    pub const Info = struct {
        /// The global id of the factory
        id: Global,
        /// The name of the factory. This can be used as the name for Core::CreateObject
        name: [:0]const u8,
        /// The object type produced by this factory
        type: [:0]const u8,
        /// The version of the object interface
        version: u32,
        /// Bitfield of changed values
        change_mask: packed struct(u64) {
            props: bool,
            _: u63 = 0,
        },
        /// Optional properties of the factory, valid when change_mask is (1<<0)
        props: pod.containers.KeyValue.Map,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
        };
    }
};

pub const Link = struct {
    pub const Type = "PipeWire:Interface:Link";

    pub const Method = enum(u16) {};

    pub const Events = enum(u16) {
        info,
    };

    pub const Info = struct {
        /// The global id of the link
        id: Global,
        /// The global id of the output node
        output_node_id: Global,
        /// The global id of the output port
        output_port_id: Global,
        /// The global id of the input node
        input_node_id: Global,
        /// The global id of the input port
        input_port_id: Global,
        /// Bitfield of changed values
        change_mask: packed struct(u64) {
            state: bool,
            format: bool,
            props: bool,
            _: u61 = 0,
        },
        /// The state of the link, valid when change_mask has (1<<0)
        state: spa.wire.LinkState,
        /// An error message
        @"error": ?[:0]const u8,
        /// An optional format for the link, valid when change_mask has (1<<1)
        format: Pod,
        /// Optional properties of the link, valid when change_mask is (1<<2)
        props: pod.containers.KeyValue.Map,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
        };
    }
};

pub const Module = struct {
    pub const Type = "PipeWire:Interface:Module";

    pub const Method = enum(u16) {};

    pub const Events = enum(u16) {
        info,
    };

    pub const Info = struct {
        /// The global id of the module
        id: Global,
        /// The name of the module
        name: [:0]const u8,
        /// The file name of the module
        file_name: [:0]const u8,
        /// Arguments passed when loading the module
        args: ?[:0]const u8,
        /// Bitfield of changed values
        change_mask: packed struct(u64) {
            props: bool,
            _: u63 = 0,
        },
        /// Optional properties of the link, valid when change_mask is (1<<0)
        props: pod.containers.KeyValue.Map,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
        };
    }
};

pub const Node = struct {
    pub const Type = "PipeWire:Interface:Node";

    pub const Method = enum(u16) {
        subscribe_params = 1,
        enum_params,
        set_param,
        send_command,
    };

    pub const SubscribeParams = struct {
        // Array of param Ids to subscribe to
        ids: []const spa.wire.ParamType,
    };

    pub const EnumParams = struct {
        /// An automatically generated sequence number, will be copied into the reply
        seq: i32,
        /// The param id to enumerate
        id: spa.wire.ParamType,
        /// The first param index to retrieve
        index: u32,
        /// The number of params to retrieve
        num: u32,
        /// An optional filter object for the param
        filter: Pod,
    };

    pub const SetParam = struct {
        /// The param id to set
        id: spa.wire.ParamType,
        /// Extra flags
        flags: spa.flags.Param,
        /// The param object to set
        param: Pod,
    };

    pub const SendCommand = struct {
        /// The command to send. See enum spa_node_command
        cmd: spa.wire.NodeCommand,
    };

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .subscribe_params => SubscribeParams,
            .enum_params => EnumParams,
            .set_param => SetParam,
            .send_command => SendCommand,
        };
    }

    pub const Info = struct {
        /// The global id of the node
        id: Global,
        /// The maximum input ports for the node
        max_input_ports: u32,
        /// The maximum output ports for the node
        max_output_ports: u32,
        /// Bitfield of changed values
        change_mask: packed struct(u64) {
            n_input_ports: bool,
            n_output_ports: bool,
            state: bool,
            props: bool,
            param_infos: bool,
            _: u59 = 0,
        },
        /// The number of input ports, when change_mask has (1<<0)
        n_input_ports: u32,
        /// The number of output ports, when change_mask has (1<<1)
        n_output_ports: u32,
        /// The current node state, when change_mask has (1<<2)
        state: spa.wire.NodeState,
        /// An error message
        @"error": ?[:0]const u8,
        /// Extra properties, valid when change_mask is (1<<3)
        props: pod.containers.KeyValue.Map,
        /// Info about the parameters, valid when change_mask is (1<<4) For each parameter, the id and current flags are given
        param_infos: pod.containers.ParamInfo.Map,
    };

    pub const Param = struct {
        /// The sequence number send by the client EnumParams or server generated in the SubscribeParams case.
        seq: i32,
        /// The param id that is reported, see enum spa_param_type
        id: spa.wire.ParamType,
        /// The index of the parameter
        index: u32,
        /// The index of the next parameter
        next: u32,
        /// The parameter. The object type depends on the id
        param: Pod,
    };

    pub const Events = enum(u16) {
        info,
        param,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
            .param => Param,
        };
    }
};

pub const Port = struct {
    pub const Type = "PipeWire:Interface:Port";

    pub const Method = enum(u16) {
        subscribe_params = 1,
        enum_params,
    };

    pub const SubscribeParams = struct {
        /// Array of param Ids to subscribe to
        ids: []const spa.wire.ParamType,
    };

    pub const EnumParams = struct {
        /// An automatically generated sequence number, will be copied into the reply
        seq: i32,
        /// The param id to enumerate
        id: spa.wire.ParamType,
        /// The first param index to retrieve
        index: u32,
        /// The number of params to retrieve
        num: u32,
        /// An optional filter object for the param
        filter: Pod,
    };

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .subscribe_params => SubscribeParams,
            .enum_params => EnumParams,
        };
    }

    pub const Events = enum(u16) {
        info,
        param,
    };

    pub const Info = struct {
        /// The global id of the port
        id: Global,
        /// The direction of the port, see enum pw_direction
        direction: spa.wire.Direction,
        /// Bitfield of changed values
        change_mask: packed struct(u64) {
            props: bool,
            param_infos: bool,
            _: u62 = 0,
        },
        /// Extra properties, valid when change_mask is (1<<0)
        props: pod.containers.KeyValue.Map,
        /// Info about the parameters, valid when change_mask is (1<<1) For each parameter, the id and current flags are given
        param_infos: pod.containers.ParamInfo.Map,
    };

    pub const Param = struct {
        /// The sequence number send by the client EnumParams or server generated in the SubscribeParams case.
        seq: i32,
        /// The param id that is reported, see enum spa_param_type
        id: spa.wire.ParamType,
        /// The index of the parameter
        index: u32,
        /// The index of the next parameter
        next: u32,
        /// The parameter. The object type depends on the id
        param: Pod,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .info => Info,
            .param => Param,
        };
    }
};

pub const ClientNode = struct {
    pub const Type = "PipeWire:Interface:ClientNode";

    pub const Method = enum(u16) {
        get_node = 1,
        update,
        port_update,
        set_active,
        event,
        port_buffers,
    };

    pub const GetNode = struct {
        version: u32,
        new_id: Global,
    };

    pub const Update = struct {
        change_mask: packed struct(u32) {
            params: bool,
            info: bool,
            _: u30 = 0,
        },
        n_params: u32,
        // TODO: (param: Pod)*
        info: struct {
            max_input_ports: u32,
            max_output_ports: u32,
            change_mask: packed struct(u64) {
                flags: bool,
                items: bool,
                params: bool,
                _: u61 = 0,
            },
            flags: packed struct(u64) {
                rt: bool,
                in_dynamic_ports: bool,
                out_dynamic_ports: bool,
                in_port_config: bool,
                need_configure: bool,
                @"async": bool,
                _: u58 = 0,
            },
            props: []const pod.containers.Prop,
            params: []const pod.containers.ParamInfo,
        },
    };

    pub const PortUpdate = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
        change_mask: packed struct(u32) {
            params: bool,
            info: bool,
            _: u30 = 0,
        },
        n_params: u32,
        // TODO: (param: Pod)*
        info: struct {
            change_mask: packed struct(u64) {
                flags: bool,
                rate_denom: bool,
                items: bool,
                params: bool,
                _: u60 = 0,
            },
            flags: spa.flags.Port,
            rate: pod.types.Fraction,
            props: []const pod.containers.Prop,
            params: []const pod.containers.ParamInfo,
        },
    };

    pub const SetActive = struct {
        active: bool,
    };

    pub const Event = struct {
        event: Pod,
    };

    pub const PortBuffers = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
        mix_id: pod.types.Id,
        // TODO: n_buffers struct here ..
    };

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .get_node => GetNode,
            .update => Update,
            .port_update => PortUpdate,
            .set_active => SetActive,
            .event => Event,
            .port_buffers => PortBuffers,
        };
    }

    pub const Events = enum(u16) {
        transport,
        set_param,
        set_io,
        event,
        command,
        add_port,
        remove_port,
        port_set_param,
        use_buffers,
        port_set_io,
        set_activation,
        port_set_mix_info,
    };

    pub const Transport = struct {
        read_fd: pod.types.Fd,
        write_fd: pod.types.Fd,
        memfd: u32,
        offset: u32,
        size: u32,
    };

    pub const SetParam = struct {
        /// The param id to set
        id: spa.wire.ParamType,
        /// Extra flags
        flags: spa.flags.Param,
        /// The param object to set
        param: Pod,
    };

    pub const SetIo = struct {
        id: spa.wire.IoType,
        memid: u32,
        offset: u32,
        size: u32,
    };

    pub const Command = struct {
        cmd: Pod,
    };

    pub const AddPort = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
        props: []const pod.containers.Prop,
    };

    pub const RemovePort = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
    };

    pub const PortSetParam = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
        id: spa.wire.ParamType,
        flags: spa.flags.PortParam,
        param: Pod,
    };

    pub const UseBuffers = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
        mix_id: pod.types.Id,
        flags: packed struct(u32) {
            alloc: bool,
            _: u31 = 0,
        },
        // TODO: n_buffers struct here ..
    };

    pub const PortSetIo = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
        mix_id: pod.types.Id,
        id: spa.wire.IoType,
        memid: u32,
        offset: u32,
        size: u32,
    };

    pub const SetActivation = struct {
        node_id: pod.types.Id,
        signal_fd: pod.types.Fd,
        memid: u32,
        offset: u32,
        size: u32,
    };

    pub const PortSetMixInfo = struct {
        direction: spa.wire.Direction,
        port_id: pod.types.Id,
        mix_id: pod.types.Id,
        peer_id: pod.types.Id,
        props: []const pod.containers.Prop,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .transport => Transport,
            .set_param => SetParam,
            .set_io => SetIo,
            .event => Event,
            .command => Command,
            .add_port => AddPort,
            .remove_port => RemovePort,
            .port_set_param => PortSetParam,
            .use_buffers => UseBuffers,
            .port_set_io => PortSetIo,
            .set_activation => SetActivation,
            .port_set_mix_info => PortSetMixInfo,
        };
    }
};

pub const Metadata = struct {
    pub const Type = "PipeWire:Interface:Metadata";

    pub const Method = enum(u16) {
        set_property = 1,
        clear,
    };

    pub const SetProperty = struct {
        /// the id of the object, this needs to be a valid global_id
        subject: Global,
        key: [:0]const u8,
        type: [:0]const u8,
        value: [:0]const u8,
    };

    pub const Clear = struct {};

    pub fn MethodArgs(comptime method: Method) type {
        return switch (method) {
            .set_property => SetProperty,
            .clear => Clear,
        };
    }

    pub const Events = enum(u16) {
        property,
    };

    pub const Property = struct {
        /// the id of the object, this is a valid global_id
        subject: Global,
        key: [:0]const u8,
        type: [:0]const u8,
        value: [:0]const u8,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .property => Property,
        };
    }
};

pub const Profiler = struct {
    pub const Type = "PipeWire:Interface:Profiler";

    pub const Method = enum(u16) {};

    pub const Events = enum(u16) {
        profile,
    };

    pub const Profile = struct {
        /// a SPA_TYPE_OBJECT_Profiler object. See enum spa_profiler
        object: Pod,
    };

    pub fn EventArgs(comptime event: Events) type {
        return switch (event) {
            .profile => Profile,
        };
    }
};

pub const SecurityContext = struct {
    pub const Type = "PipeWire:Interface:SecurityContext";

    pub const Method = enum(u16) {
        add_listener,
        create,
    };

    pub const Events = enum(u16) {};
};

pub const Extension = enum {
    core,
    client,
    registry,
    device,
    factory,
    link,
    module,
    node,
    port,
    client_node,
    metadata,
    profiler,
    security_context,

    pub fn fromName(type_name: [:0]const u8) error{UnknownExtension}!@This() {
        inline for (comptime std.enums.values(@This())) |ext| {
            if (std.mem.eql(u8, type_name, ext.Schema().Type)) {
                return ext;
            }
        }
        return error.UnknownExtension;
    }

    pub fn Schema(comptime self: @This()) type {
        return switch (self) {
            .core => Core,
            .client => Client,
            .registry => Registry,
            .device => Device,
            .factory => Factory,
            .link => Link,
            .module => Module,
            .node => Node,
            .port => Port,
            .client_node => ClientNode,
            .metadata => Metadata,
            .profiler => Profiler,
            .security_context => SecurityContext,
        };
    }

    pub const Extra = struct {
        footers: []const ClientFooter = &.{},
        fds: []const std.posix.fd_t = &.{},
    };

    fn writeFooters(footers: []const ClientFooter, writer: anytype) !void {
        var counter = std.io.countingWriter(std.io.null_writer);
        for (footers) |footer| switch (footer) {
            inline else => |tag, payload| {
                try Pod.write(tag, counter.writer());
                try Pod.write(payload, counter.writer());
            },
        };
        const header: pod.types.Header = .{
            .type = .@"struct",
            .size = @intCast(counter.bytes_written),
        };
        try writer.writeAll(std.mem.asBytes(&header));
        for (footers) |footer| switch (footer) {
            inline else => |tag, payload| {
                try Pod.write(tag, writer);
                try Pod.write(payload, writer);
            },
        };
    }

    pub fn write(comptime self: @This(), id: Id, comptime method: self.Schema().Method, seq: i32, args: self.Schema().MethodArgs(method), extra: Extra, writer: anytype) WriteError!void {
        var counter = std.io.countingWriter(std.io.null_writer);
        try Pod.write(args, counter.writer());
        try writeFooters(extra.footers, counter.writer());
        std.debug.assert(std.mem.isAligned(counter.bytes_written, 8));
        const header: Header = .{
            .id = id,
            .msg = .{
                .opcode = @intFromEnum(method),
                .size = @intCast(counter.bytes_written),
            },
            .seq = seq,
            .n_fds = @intCast(extra.fds.len),
        };
        try writer.writeAll(std.mem.asBytes(&header));
        try Pod.write(args, writer);
        try writeFooters(extra.footers, writer);
    }
};
