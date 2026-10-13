//! Collections the way Reseal-js uses them through the Node driver: filters, updates and
//! documents are Vals (or anything `val.from` converts), results come back as Vals. Commands go
//! through zig-core's mongo client, so it owns the connection pool and authentication.

const std = @import("std");
const mongo = @import("mongo");
const val = @import("val.zig");
const bson = mongo.bson;
const Val = val.Val;
const Allocator = std.mem.Allocator;

pub const Error = mongo.Error || error{ OutOfMemory, InvalidBson, UnsupportedBsonType };

/// `x` as a document (Vals pass through val.toDoc, other values through val.from first).
pub fn docOf(a: Allocator, x: anytype) !bson.Doc {
    if (@TypeOf(x) == bson.Doc) return x;
    return val.toDoc(a, try val.from(a, x));
}

fn optDoc(a: Allocator, opts: anytype, comptime name: []const u8) !?bson.Doc {
    if (!@hasField(@TypeOf(opts), name)) return null;
    const x = @field(opts, name);
    if (@TypeOf(x) == @TypeOf(null)) return null;
    if (@typeInfo(@TypeOf(x)) == .optional) return if (x) |y| try docOf(a, y) else null;
    if (@TypeOf(x) == Val and x == .undef) return null;
    return try docOf(a, x);
}

fn optInt(opts: anytype, comptime name: []const u8) ?i64 {
    if (!@hasField(@TypeOf(opts), name)) return null;
    const x = @field(opts, name);
    if (@typeInfo(@TypeOf(x)) == .optional) return if (x) |y| @intCast(y) else null;
    return @intCast(x);
}

fn optBool(opts: anytype, comptime name: []const u8) bool {
    if (!@hasField(@TypeOf(opts), name)) return false;
    return @field(opts, name);
}

pub const UpdateResult = struct { matched: i64, modified: i64, upserted: ?Val };

pub const Coll = struct {
    client: *mongo.Client,
    db: []const u8,
    name: []const u8,

    fn run(c: Coll, a: Allocator, cmd: bson.Doc) !bson.Doc {
        return c.client.command(a, c.db, cmd);
    }

    /// find(filter, { projection, sort, limit, skip, maxTimeMS }).toArray()
    pub fn find(c: Coll, a: Allocator, filter: anytype, opts: anytype) ![]Val {
        var b = try bson.Builder.init(a);
        try b.string("find", c.name);
        try b.doc("filter", try docOf(a, filter));
        if (try optDoc(a, opts, "projection")) |p| try b.doc("projection", p);
        if (try optDoc(a, opts, "sort")) |p| try b.doc("sort", p);
        if (optInt(opts, "skip")) |x| try b.int64("skip", x);
        if (optInt(opts, "limit")) |x| if (x > 0) try b.int64("limit", x);
        if (optInt(opts, "maxTimeMS")) |x| try b.int64("maxTimeMS", x);
        if (optInt(opts, "limit")) |x| if (x > 0 and x < 101) try b.int32("batchSize", @intCast(x));
        return c.drain(a, try c.run(a, try b.finish()));
    }

    fn drain(c: Coll, a: Allocator, reply: bson.Doc) ![]Val {
        var out: std.ArrayList(Val) = .empty;
        var cur = reply.getDoc("cursor") orelse return error.BadReply;
        var batch = cur.getDoc("firstBatch") orelse return error.BadReply;
        var id = (cur.get("id") orelse return error.BadReply).asInt() orelse 0;
        while (true) {
            var it = batch.iterator();
            while (try it.next()) |e| switch (e.value) {
                .document => |d| try out.append(a, try val.fromDoc(a, d)),
                else => return error.BadReply,
            };
            if (id == 0) break;
            const more = try c.run(a, try bson.encode(a, .{ .getMore = id, .collection = c.name }));
            cur = more.getDoc("cursor") orelse return error.BadReply;
            id = (cur.get("id") orelse return error.BadReply).asInt() orelse 0;
            batch = cur.getDoc("nextBatch") orelse return error.BadReply;
        }
        return out.items;
    }

    pub fn findOne(c: Coll, a: Allocator, filter: anytype, opts: anytype) !?Val {
        var b = try bson.Builder.init(a);
        try b.string("find", c.name);
        try b.doc("filter", try docOf(a, filter));
        if (try optDoc(a, opts, "projection")) |p| try b.doc("projection", p);
        if (try optDoc(a, opts, "sort")) |p| try b.doc("sort", p);
        if (optInt(opts, "maxTimeMS")) |x| try b.int64("maxTimeMS", x);
        try b.int64("limit", 1);
        try b.boolean("singleBatch", true);
        const reply = try c.run(a, try b.finish());
        const cur = reply.getDoc("cursor") orelse return error.BadReply;
        const batch = cur.getDoc("firstBatch") orelse return error.BadReply;
        return switch (batch.get("0") orelse return null) {
            .document => |d| try val.fromDoc(a, d),
            else => null,
        };
    }

    /// Adds an ObjectId `_id` (first, as the server stores it) when `doc` has none; returns it.
    pub fn insertOne(c: Coll, a: Allocator, doc: Val) !Val {
        try ensureId(a, c.client.io, doc);
        var b = try bson.Builder.init(a);
        try b.string("insert", c.name);
        try b.beginArray("documents");
        try val.putBson(&b, "", doc);
        try b.end();
        _ = try c.run(a, try b.finish());
        return doc.get("_id");
    }

    /// Inserts in order; stops at the first failure (the driver's default).
    pub fn insertMany(c: Coll, a: Allocator, docs: []const Val) !void {
        if (docs.len == 0) return;
        var b = try bson.Builder.init(a);
        try b.string("insert", c.name);
        try b.beginArray("documents");
        for (docs) |d| {
            try ensureId(a, c.client.io, d);
            try val.putBson(&b, "", d);
        }
        try b.end();
        _ = try c.run(a, try b.finish());
    }

    pub fn updateOne(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype) !UpdateResult {
        return c.updateImpl(a, filter, update, opts, false);
    }

    pub fn updateMany(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype) !UpdateResult {
        return c.updateImpl(a, filter, update, opts, true);
    }

    fn updateImpl(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype, multi: bool) !UpdateResult {
        var b = try bson.Builder.init(a);
        try b.string("update", c.name);
        try b.beginArray("updates");
        try b.beginDoc("");
        try b.doc("q", try docOf(a, filter));
        try b.doc("u", try docOf(a, update));
        try b.boolean("upsert", optBool(opts, "upsert"));
        try b.boolean("multi", multi);
        if (@hasField(@TypeOf(opts), "arrayFilters")) try b.array("arrayFilters", try arrayDoc(a, try val.from(a, opts.arrayFilters)));
        try b.end();
        try b.end();
        const reply = try c.run(a, try b.finish());
        const upserted: ?Val = if (reply.getDoc("upserted")) |u| (if (u.getDoc("0")) |f| (if (f.get("_id")) |x| try val.fromBson(a, x) else null) else null) else null;
        return .{
            .matched = (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .modified = (reply.get("nModified") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0,
            .upserted = upserted,
        };
    }

    pub fn deleteOne(c: Coll, a: Allocator, filter: anytype) !i64 {
        return c.deleteImpl(a, filter, 1);
    }

    pub fn deleteMany(c: Coll, a: Allocator, filter: anytype) !i64 {
        return c.deleteImpl(a, filter, 0);
    }

    fn deleteImpl(c: Coll, a: Allocator, filter: anytype, limit: i32) !i64 {
        var b = try bson.Builder.init(a);
        try b.string("delete", c.name);
        try b.beginArray("deletes");
        try b.beginDoc("");
        try b.doc("q", try docOf(a, filter));
        try b.int32("limit", limit);
        try b.end();
        try b.end();
        const reply = try c.run(a, try b.finish());
        return (reply.get("n") orelse bson.Value{ .int32 = 0 }).asInt() orelse 0;
    }

    /// countDocuments(filter, { limit, skip })
    pub fn count(c: Coll, a: Allocator, filter: anytype, opts: anytype) !i64 {
        var b = try bson.Builder.init(a);
        try b.string("aggregate", c.name);
        try b.beginArray("pipeline");
        try b.beginDoc("");
        try b.doc("$match", try docOf(a, filter));
        try b.end();
        if (optInt(opts, "skip")) |x| {
            try b.beginDoc("");
            try b.int64("$skip", x);
            try b.end();
        }
        if (optInt(opts, "limit")) |x| {
            try b.beginDoc("");
            try b.int64("$limit", x);
            try b.end();
        }
        try b.beginDoc("");
        try b.beginDoc("$group");
        try b.int32("_id", 1);
        try b.beginDoc("n");
        try b.int32("$sum", 1);
        try b.end();
        try b.end();
        try b.end();
        try b.end();
        try b.beginDoc("cursor");
        try b.end();
        if (optInt(opts, "maxTimeMS")) |x| try b.int64("maxTimeMS", x);
        const rows = try c.drain(a, try c.run(a, try b.finish()));
        if (rows.len == 0) return 0;
        return rows[0].get("n").asInt() orelse 0;
    }

    pub fn aggregate(c: Coll, a: Allocator, pipeline: anytype) ![]Val {
        var b = try bson.Builder.init(a);
        try b.string("aggregate", c.name);
        try b.array("pipeline", try arrayDoc(a, try val.from(a, pipeline)));
        try b.beginDoc("cursor");
        try b.end();
        return c.drain(a, try c.run(a, try b.finish()));
    }

    pub fn distinct(c: Coll, a: Allocator, key: []const u8, filter: anytype) ![]Val {
        var b = try bson.Builder.init(a);
        try b.string("distinct", c.name);
        try b.string("key", key);
        try b.doc("query", try docOf(a, filter));
        const reply = try c.run(a, try b.finish());
        const values = reply.getDoc("values") orelse return &.{};
        var out: std.ArrayList(Val) = .empty;
        var it = values.iterator();
        while (try it.next()) |e| try out.append(a, try val.fromBson(a, e.value));
        return out.items;
    }

    /// findOneAndUpdate(filter, update, { returnDocument: 'after' | 'before', projection, sort, upsert })
    pub fn findOneAndUpdate(c: Coll, a: Allocator, filter: anytype, update: anytype, opts: anytype) !?Val {
        var b = try bson.Builder.init(a);
        try b.string("findAndModify", c.name);
        try b.doc("query", try docOf(a, filter));
        try b.doc("update", try docOf(a, update));
        const after = if (@hasField(@TypeOf(opts), "after")) opts.after else true;
        try b.boolean("new", after);
        try b.boolean("upsert", optBool(opts, "upsert"));
        if (try optDoc(a, opts, "sort")) |s| try b.doc("sort", s);
        if (try optDoc(a, opts, "projection")) |p| try b.doc("fields", p);
        const reply = try c.run(a, try b.finish());
        return switch (reply.get("value") orelse return null) {
            .document => |d| try val.fromDoc(a, d),
            else => null,
        };
    }

    pub fn createIndex(c: Coll, a: Allocator, keys_: Val, opts: Val) !void {
        var name: std.ArrayList(u8) = .empty;
        for (keys_.keys()) |kv| {
            if (name.items.len > 0) try name.append(a, '_');
            try name.print(a, "{s}_{s}", .{ kv.k, try val.str(a, kv.v) });
        }
        const spec = try val.from(a, .{ .key = keys_, .name = opts.get("name").asStr() orelse name.items });
        for (opts.keys()) |kv| if (!std.mem.eql(u8, kv.k, "name")) try spec.put(a, kv.k, kv.v);
        var b = try bson.Builder.init(a);
        try b.string("createIndexes", c.name);
        try b.beginArray("indexes");
        try val.putBson(&b, "", spec);
        try b.end();
        _ = try c.run(a, try b.finish());
    }
};

fn arrayDoc(a: Allocator, list: Val) !bson.Doc {
    var b = try bson.Builder.init(a);
    var i: usize = 0;
    for (list.items()) |e| {
        var key: [12]u8 = undefined;
        try val.putBson(&b, try std.fmt.bufPrint(&key, "{d}", .{i}), e);
        i += 1;
    }
    return b.finish();
}

/// Gives `doc` an `_id` (as its first key) when it has none, like the driver's insertOne.
pub fn ensureId(a: Allocator, io: std.Io, doc: Val) !void {
    if (doc != .obj) return;
    if (!doc.get("_id").isNullish()) return;
    doc.del("_id");
    try doc.obj.items.insert(a, 0, .{ .k = "_id", .v = .{ .id = bson.ObjectId.generate(io) } });
}
