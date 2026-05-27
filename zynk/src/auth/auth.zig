const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Session = struct {
    id: []const u8,
    data: std.StringHashMap([]const u8),
    expires_at: i64,
};

fn epochSec() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub const JWT = struct {
    secret: []const u8,

    pub fn init(secret: []const u8) JWT {
        return .{ .secret = secret };
    }

    pub fn encode(self: *const JWT, payload: struct { sub: []const u8, exp: i64 }, allocator: std.mem.Allocator) ![]const u8 {
        const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
        const payload_obj = try std.fmt.allocPrint(allocator,
            "{{\"sub\":\"{s}\",\"exp\":{d}}}",
            .{ payload.sub, payload.exp },
        );
        defer allocator.free(payload_obj);

        const b64_header = encodeBase64(allocator, header);
        defer allocator.free(b64_header);
        const b64_payload = encodeBase64(allocator, payload_obj);
        defer allocator.free(b64_payload);

        const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ b64_header, b64_payload });
        defer allocator.free(signing_input);

        var sig: [32]u8 = undefined;
        std.crypto.auth.hmac.Hmac(std.crypto.sha2.Sha256).create(&sig, signing_input, self.secret);

        const b64_sig = encodeBase64(allocator, &sig);
        defer allocator.free(b64_sig);

        return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ b64_header, b64_payload, b64_sig });
    }

    pub fn decode(self: *const JWT, token: []const u8, allocator: std.mem.Allocator) !struct { sub: []const u8, exp: i64 } {
        var it = std.mem.splitScalar(u8, token, '.');
        const b64_header = it.next() orelse return error.InvalidToken;
        const b64_payload = it.next() orelse return error.InvalidToken;
        const b64_sig = it.next() orelse return error.InvalidToken;

        const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ b64_header, b64_payload });
        defer allocator.free(signing_input);

        var expected_sig: [32]u8 = undefined;
        std.crypto.auth.hmac.Hmac(std.crypto.sha2.Sha256).create(&expected_sig, signing_input, self.secret);

        const sig_len = try decodeBase64Len(b64_sig);
        const sig = try allocator.alloc(u8, sig_len);
        defer allocator.free(sig);
        try decodeBase64(sig, b64_sig);

        if (!std.mem.eql(u8, sig, &expected_sig)) return error.InvalidSignature;

        const payload_len = try decodeBase64Len(b64_payload);
        const payload_raw = try allocator.alloc(u8, payload_len);
        defer allocator.free(payload_raw);
        try decodeBase64(payload_raw, b64_payload);

        return parsePayload(payload_raw, allocator);
    }

    fn parsePayload(raw: []const u8, allocator: std.mem.Allocator) !struct { sub: []const u8, exp: i64 } {
        var sub: []const u8 = "";
        var exp: i64 = 0;

        if (std.json.parseFromSlice(std.json.Value, allocator, raw, .{})) |parsed| {
            defer parsed.deinit();
            const obj = parsed.value.object;
            if (obj.get("sub")) |s| sub = try allocator.dupe(u8, s.string);
            if (obj.get("exp")) |e| exp = @intCast(e.integer);
        } else |_| {}

        return .{ .sub = sub, .exp = exp };
    }

    fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
        _ = std.base64.standard.Encoder.encode(b64, data);
        return b64;
    }

    fn decodeBase64Len(encoded: []const u8) !usize {
        return std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidEncoding;
    }

    fn decodeBase64(buffer: []u8, encoded: []const u8) !void {
        try std.base64.standard.Decoder.decode(buffer, encoded);
    }
};

pub const SessionStore = struct {
    sessions: std.StringHashMap(Session),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionStore {
        return .{
            .sessions = std.StringHashMap(Session).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionStore) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.data.deinit();
        }
        self.sessions.deinit();
    }

    pub fn create(self: *SessionStore) ![]const u8 {
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        const id = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.bytesToHex(buf, .lower)});
        try self.sessions.put(id, .{
            .id = id,
            .data = std.StringHashMap([]const u8).init(self.allocator),
            .expires_at = epochSec() + 86400,
        });
        return id;
    }

    pub fn get(self: *SessionStore, id: []const u8) ?Session {
        const entry = self.sessions.get(id) orelse return null;
        if (entry.expires_at < epochSec()) {
            self.sessions.remove(id);
            return null;
        }
        return entry;
    }

    pub fn destroy(self: *SessionStore, id: []const u8) void {
        _ = self.sessions.remove(id);
    }
};

pub fn sessionMiddleware(store: *SessionStore) context.MiddlewareFn {
    const Wrapper = struct {
        store: *SessionStore,
        pub fn handle(w: *@This(), ctx: *Context, next: Handler) !void {
            const cookie = ctx.header("cookie") orelse "";
            var it = std.mem.splitScalar(u8, cookie, ';');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (std.mem.startsWith(u8, trimmed, "session=")) {
                    const sid = trimmed["session=".len..];
                    _ = w.store.get(sid);
                }
            }
            try next(ctx);
        }
    };
    const wrapper = Wrapper{ .store = store };
    return struct {
        pub fn call(c: *Context, n: Handler) anyerror!void {
            return wrapper.handle(@constCast(&wrapper), c, n);
        }
    }.call;
}

pub fn requireAuth(ctx: *Context, next: Handler) !void {
    const auth = ctx.header("authorization") orelse {
        ctx.response.status_code = 401;
        try ctx.response.setHeader("www-authenticate", "Bearer");
        try ctx.text("Unauthorized");
        return;
    };
    if (!std.ascii.startsWithIgnoreCase(auth, "bearer ")) {
        ctx.response.status_code = 401;
        try ctx.text("Unauthorized");
        return;
    }
    try next(ctx);
}
