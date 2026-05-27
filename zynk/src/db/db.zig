const std = @import("std");

pub const Database = struct {
    allocator: std.mem.Allocator,
    connection: Connection,

    pub const Connection = union(enum) {
        none: void,
        sqlite: void,
        postgres: void,
        mysql: void,
    };

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{
            .allocator = allocator,
            .connection = .{ .none = {} },
        };
    }

    pub fn deinit(self: *Database) void {
        _ = self;
    }

    pub fn connect(self: *Database, url: []const u8) !void {
        _ = url;
        _ = self;
        std.debug.print("Database connection not yet implemented\n", .{});
    }

    pub fn query(self: *Database, sql: []const u8) !QueryResult {
        _ = self;
        _ = sql;
        return QueryResult{};
    }

    pub fn exec(self: *Database, sql: []const u8) !void {
        _ = self;
        _ = sql;
    }
};

pub const QueryResult = struct {
    rows: [][]const u8 = &.{},
    columns: [][]const u8 = &.{},

    pub fn deinit(self: *QueryResult) void {
        _ = self;
    }
};

pub const SelectQuery = struct {
    table: []const u8,
    fields: []const []const u8,
    allocator: std.mem.Allocator,
    where_clauses: std.ArrayList(WhereClause),
    order_by_fields: std.ArrayList(OrderByField),
    limit_val: ?u64 = null,

    pub const WhereClause = struct {
        column: []const u8,
        op: []const u8,
        value: []const u8,
    };

    pub const OrderByField = struct {
        column: []const u8,
        direction: enum { asc, desc },
    };

    fn init(allocator: std.mem.Allocator, table: []const u8, fields: []const []const u8) SelectQuery {
        return .{
            .table = table,
            .fields = fields,
            .allocator = allocator,
            .where_clauses = .empty,
            .order_by_fields = .empty,
        };
    }

    pub fn deinit(self: *SelectQuery) void {
        self.where_clauses.deinit(self.allocator);
        self.order_by_fields.deinit(self.allocator);
    }

    pub fn where(self: *SelectQuery, column: []const u8, op: []const u8, value: []const u8) !void {
        try self.where_clauses.append(self.allocator, .{ .column = column, .op = op, .value = value });
    }

    pub fn orderBy(self: *SelectQuery, column: []const u8, direction: []const u8) !void {
        const dir: OrderByField.direction = if (std.ascii.eqlIgnoreCase(direction, "desc")) .desc else .asc;
        try self.order_by_fields.append(self.allocator, .{ .column = column, .direction = dir });
    }

    pub fn limit(self: *SelectQuery, val: u64) void {
        self.limit_val = val;
    }

    pub fn build(self: *const SelectQuery) ![]const u8 {
        var sql = std.ArrayList(u8).init(self.allocator);
        defer sql.deinit();
        try sql.appendSlice("SELECT ");
        if (self.fields.len == 0) {
            try sql.appendSlice("*");
        } else {
            for (self.fields, 0..) |field, i| {
                if (i > 0) try sql.appendSlice(", ");
                try sql.appendSlice(field);
            }
        }
        try sql.appendSlice(" FROM ");
        try sql.appendSlice(self.table);

        if (self.where_clauses.items.len > 0) {
            try sql.appendSlice(" WHERE ");
            for (self.where_clauses.items, 0..) |clause, i| {
                if (i > 0) try sql.appendSlice(" AND ");
                try sql.appendSlice(clause.column);
                try sql.appendSlice(" ");
                try sql.appendSlice(clause.op);
                try sql.appendSlice(" ");
                try sql.appendSlice(clause.value);
            }
        }

        if (self.order_by_fields.items.len > 0) {
            try sql.appendSlice(" ORDER BY ");
            for (self.order_by_fields.items, 0..) |ob, i| {
                if (i > 0) try sql.appendSlice(", ");
                try sql.appendSlice(ob.column);
                try sql.appendSlice(if (ob.direction == .asc) " ASC" else " DESC");
            }
        }

        if (self.limit_val) |l| {
            try sql.appendSlice(" LIMIT ");
            try std.fmt.format(sql.writer(), "{d}", .{l});
        }

        return sql.toOwnedSlice();
    }
};

pub const InsertQuery = struct {
    table: []const u8,
    allocator: std.mem.Allocator,
    returning_fields: []const []const u8 = &.{},

    fn init(allocator: std.mem.Allocator, table: []const u8) InsertQuery {
        return .{ .table = table, .allocator = allocator };
    }

    pub fn returning(self: InsertQuery, fields: []const []const u8) InsertQuery {
        var result = self;
        result.returning_fields = fields;
        return result;
    }

    pub fn build(self: *const InsertQuery) ![]const u8 {
        _ = self;
        return "INSERT INTO ...";
    }
};

pub const UpdateQuery = struct {
    table: []const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, table: []const u8) UpdateQuery {
        return .{ .table = table, .allocator = allocator };
    }

    pub fn build(self: *const UpdateQuery) ![]const u8 {
        _ = self;
        return "UPDATE ...";
    }
};

pub const DeleteQuery = struct {
    table: []const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, table: []const u8) DeleteQuery {
        return .{ .table = table, .allocator = allocator };
    }

    pub fn build(self: *const DeleteQuery) ![]const u8 {
        _ = self;
        return "DELETE FROM ...";
    }
};

pub const QueryBuilder = struct {
    table: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, table: []const u8) QueryBuilder {
        return .{ .table = table, .allocator = allocator };
    }

    pub fn deinit(self: *QueryBuilder) void {
        _ = self;
    }

    pub fn select(self: *const QueryBuilder, fields: []const []const u8) SelectQuery {
        return SelectQuery.init(self.allocator, self.table, fields);
    }

    pub fn insert(self: *const QueryBuilder) InsertQuery {
        return InsertQuery.init(self.allocator, self.table);
    }

    pub fn update(self: *const QueryBuilder) UpdateQuery {
        return UpdateQuery.init(self.allocator, self.table);
    }

    pub fn delete(self: *const QueryBuilder) DeleteQuery {
        return DeleteQuery.init(self.allocator, self.table);
    }
};
