const std = @import("std");
const enum_parser = @import("enum_parser.zig");
const fmt = @import("fmt_structs.zig");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const str = []const u8;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const TokenIterator = std.mem.TokenIterator;
const tools = @import("tools.zig");
const streql = tools.streql;
const recursivePrintTypeInfoStruct = tools.recursivePrintTypeInfoStruct;

pub const Join = fmt.Join;
pub const Match = fmt.Match;
pub const Wrap = fmt.Wrap;
pub const Unformat = fmt.Unformat;
const countNonMatchFields = fmt.countNonMatchFields;

pub const Error = error{
    ParseError,
    ParseIntError,
    EndIterError,
    NotImplementedError,
    DelimByteError,
} || Allocator.Error || enum_parser.Error;

pub fn ParserU(comptime T: type) (fn (?*Allocator, *TokenIterator) Error!Unformat(T)) {
    return struct {
        const wrappedParseFn = Parser(T);
        fn parseWrap(alloc: ?*Allocator, iter: *TokenIterator) Error!Unformat(T) {
            var parsed: T = try wrappedParseFn(alloc, iter);
            if (@typeInfo(T) == .Pointer) {
                var unformatted = try alloc.?.create(@typeInfo(Unformat(T)).Pointer.child);
                print("create1:{}\n", .{@ptrToInt(unformatted)});
                fmt.castUnformatRecur(T, &parsed, &unformatted);
                return unformatted;
            } else {
                var unformatted: Unformat(T) = undefined;
                fmt.castUnformatRecur(T, &parsed, &unformatted);
                return unformatted;
            }
        }
    }.parseWrap;
}

pub fn ParserStr(comptime T: type) (fn (?*Allocator, str) Error!Unformat(T)) {
    return struct {
        const wrappedParseFn = Parser(T);
        fn parseWrap(alloc: ?*Allocator, val: str) Error!Unformat(T) {
            // in order to re-use the Parser(T) provided function when parsing
            // *formatted* structs, we want a dummy iterator that returns only
            // one token: the entire string. That's why I call tokenize with a
            // delimiter that's almost never used in practice: 0x0. So if 0x0
            // is encountered within a string (*not* at the last position, as
            // in a C string), it raises an error.
            // TODO: How to do create a dummy TokenIterator without the usual
            // .next() function?
            const delim_bytes: []const u8 = ([1]u8{0x0})[0..];
            var dummy_iter = std.mem.tokenize(val, delim_bytes);
            if (dummy_iter.next()) |token| {
                if (token.len != val.len) {
                    return Error.DelimByteError;
                }
            } else {
                return Error.DelimByteError;
            }
            // re-init token iterator:
            dummy_iter = std.mem.tokenize(val, delim_bytes);
            var parsed: T = try wrappedParseFn(alloc, &dummy_iter);
            // TODO:
            // 1. not sure if this is safe,
            // 2. is there a way to copy data without realloc an Unformat(T)?
            var unformatted: Unformat(T) = undefined;
            fmt.castUnformatRecur(T, &parsed, &unformatted);
            return unformatted;
        }
    }.parseWrap;
}

/// A parser function for a variety of complicated, nested types known at
/// compile time. Currently, it supports structs, slices, arrays, integers,
/// []const u8, and enums.
pub fn Parser(comptime T: type) (fn (?*Allocator, *TokenIterator) Error!T) {
    return struct {
        fn parse(opt_alloc: ?*Allocator, iter: *TokenIterator) Error!T {
            return parseRecur(T, opt_alloc, iter);
        }

        /// Parse a struct of type t. fields[i] == 1 iff we ignore the optional.
        /// If it fails, the caller can backtrack!
        fn parseStructOptions(
            opt_alloc: ?*Allocator,
            comptime n_fields: u32,
            comptime t: type,
            comptime fields: []const std.builtin.TypeInfo.StructField,
            options: [n_fields]u32,
            iter: *TokenIterator,
        ) Error!t {
            var skip = false;
            var failed = false;
            var parsed: t = undefined;
            inline for (fields) |f, i| {
                comptime const typeinfo = @typeInfo(t);
                comptime var subtype = f.field_type;
                skip = false;
                if (@typeInfo(subtype) == .Optional) {
                    // unwrap Optionals here, to allow for backtracking.
                    if (options[i] == 0) {
                        subtype = @typeInfo(subtype).Optional.child;
                    } else {
                        @field(parsed, f.name) = null;
                        // TODO: could be simplified using continue! but not
                        // supported with comptime now, it seems.
                        skip = true;
                    }
                }
                if (!skip) {
                    const parse_attempt = parseRecur(subtype, opt_alloc, iter) catch {
                        failed = true;
                        return Error.ParseError;
                        //break :blk;
                    };
                    @field(parsed, f.name) = parse_attempt;
                    skip = false;
                }
            }
            return parsed;
        }

        fn parseRecur(
            comptime t: type,
            opt_alloc: ?*Allocator,
            iter: *TokenIterator,
        ) Error!t {
            var parsed: t = undefined;
            //print("> {}\n", .{@typeInfo(t)});
            if (t == str) { // TODO move to switch()
                const v = iter.next();
                // for debugging with assembly.
                // const v = @call(.{ .modifier = .never_inline }, iter.next, .{});
                return v orelse Error.EndIterError;
            }
            comptime var typeinfo = @typeInfo(t);
            switch (typeinfo) {
                .Int => {
                    if (iter.next()) |val| {
                        print("parse int:{}\n", .{val});
                        const parsed_int: t = std.fmt.parseInt(t, val, 10) catch {
                            return Error.ParseError;
                        };
                        return parsed_int;
                    } else {
                        return Error.EndIterError;
                    }
                },
                .Optional => {
                    comptime var child_type = typeinfo.Optional.child;
                    return parseRecur(child_type, opt_alloc, iter) catch null;
                },
                .Enum => {
                    const enumParser = try enum_parser.EnumParser(t);
                    if (iter.next()) |val| {
                        return try enumParser(val);
                    } else {
                        return Error.EndIterError;
                    }
                },
                .Struct => {
                    comptime const is_fmt = fmt.isFormattedStruct(t);
                    if (is_fmt and t.fmt_struct == .join_struct) {
                        // TODO call t.parse?
                        var sub_iter: std.mem.TokenIterator = undefined;
                        if (iter.next()) |val| {
                            sub_iter = t.tokenize(val);
                            return t{
                                .child = try parseRecur(t.child_type, opt_alloc, &sub_iter),
                            };
                        } else {
                            return Error.ParseError;
                        }
                        // } else if (is_fmt and t.fmt_struct == .wrap_struct) {
                        //     return t{
                        //         .child = try parseRecur(t.child_type, opt_alloc, iter),
                        //     };
                    } else if (is_fmt and t.fmt_struct == .match_struct) {
                        const iter_backup = iter.index;
                        const maybe_matched = try parseRecur(str, opt_alloc, iter);
                        print("cur:{},to_match:{}\n", .{ maybe_matched, t.to_match });
                        if (streql(maybe_matched, t.to_match)) {
                            return t{};
                        } else {
                            iter.index = iter_backup;
                            return Error.ParseError;
                        }
                    } else {
                        const n_fields = typeinfo.Struct.fields.len;
                        comptime const n_options = computeStructMaxNValues(n_fields, typeinfo);
                        comptime const n_combinations = nFieldsCombinations(n_options[0..]);
                        comptime const fields = typeinfo.Struct.fields;
                        const backup_iter = iter.index;
                        var comb_i: u32 = 0;
                        // try to parse with every possible combination of
                        // optional and union tagswhen it fails, backtrack
                        // (rewind iterator) and try the next combination
                        while (comb_i < n_combinations) : (comb_i += 1) {
                            // iter.index = backup_iter;
                            const options = intToFieldsOptions(n_fields, comb_i, n_options);
                            parsed = parseStructOptions(opt_alloc, n_fields, t, fields, options, iter) catch {
                                iter.index = backup_iter;
                                continue;
                            };
                            return parsed;
                        }
                        iter.index = backup_iter;
                        return Error.ParseError;
                    }
                },
                .Pointer => {
                    comptime const subtype = typeinfo.Pointer.child;
                    if (typeinfo.Pointer.size == .Slice) {
                        var array = std.ArrayList(subtype).init(opt_alloc.?);
                        while (true) {
                            const e = parseRecur(subtype, opt_alloc, iter) catch |e| {
                                if (e == Error.NotImplementedError) {
                                    return e;
                                } else {
                                    break;
                                }
                            };
                            try array.append(e);
                        }
                        return array.toOwnedSlice();
                        // TODO Could we turn opt_alloc to be comptime known?
                        // thus we could check that when the type
                        // require dynamic memory allocation at comptime,
                        // alloc is not null? Or is it a misuse of optionals?
                    } else {
                        var ret = try opt_alloc.?.create(subtype);
                        print("create2:{}\n", .{@ptrToInt(ret)});
                        //print("create2:{}\n", .{ret});
                        ret.* = parseRecur(subtype, opt_alloc, iter) catch |e| {
                            print("destroy2:{}\n", .{@ptrToInt(ret)});
                            opt_alloc.?.destroy(ret);
                            return e;
                        };
                        return ret;
                    }
                },
                .Union => {
                    if (typeinfo.Union.tag_type) |tag_type| {
                        comptime const n_values = typeinfo.Union.fields.len;
                        comptime const fields = typeinfo.Union.fields;
                        const backup_iter = iter.index;
                        comptime var i = 0;
                        var res: t = undefined;
                        inline while (i < n_values) : (i += 1) {
                            iter.index = backup_iter;
                            comptime var subtype = fields[i].field_type;
                            const parsed_subtype = parseRecur(?subtype, opt_alloc, iter) catch undefined;
                            if (parsed_subtype) |p| {
                                return @unionInit(t, fields[i].name, p);
                            }
                        }
                        return Error.ParseError;
                    } else {
                        return Error.NotImplementedError;
                    }
                },
                .Array => {
                    comptime const subtype = typeinfo.Array.child;
                    if (typeinfo.Array.sentinel) |v| {
                        return Error.NotImplementedError;
                    }
                    const len: comptime_int = typeinfo.Array.len;
                    var array: [len]subtype = [_]subtype{undefined} ** len;
                    var i: u32 = 0;
                    while (i < len) : (i += 1) {
                        array[i] = parseRecur(subtype, opt_alloc, iter) catch |e| {
                            if (e == Error.NotImplementedError) {
                                return e;
                            } else {
                                break;
                            }
                        };
                    }
                    return array;
                },
                else => {
                    return Error.NotImplementedError;
                },
            }
            return parsed;
        }
    }.parse;
}

// helpers

fn structFirstFieldType(comptime T: type) type {
    return @typeInfo(T).Struct.fields[0].field_type;
}

/// For each field in the struct, return the number of possible choices - 1:
/// - optionals: 2-1=1 choices (present or absent),
/// (cancelled: - tagged unions: N-1 choices)
/// - all the other types: 0 choices.
fn computeStructMaxNValues(
    comptime n_fields: u32,
    comptime typeinfo: std.builtin.TypeInfo,
) [n_fields]u32 {
    var n_options = [_]u32{0} ** n_fields;
    inline for (typeinfo.Struct.fields) |f, i| {
        if (@typeInfo(f.field_type) == .Optional) {
            n_options[i] = 1;
        }
        //else if (@typeInfo(f.field_type) == .Union) {
        //n_options[i] = @typeInfo(f.field_type).tag_type.?.fields.len;
        //    n_options[i] = @typeInfo(f.field_type).Union.fields.len;
        //}
    }
    return n_options;
}

/// Encode an integer i in the basis defined by n_options. See examples:
/// examples:
/// - if n_options = {7, ..., 7}, then it is base 8 encoding.
/// - if n_options = {2, 0, 1}, then intToFieldsOptions will return:
///     * i = 0: {0, 0, 0}
///     * i = 1: {0, 0, 1}
///     * i = 2: {1, 0, 0}
///     * i = 3: {1, 0, 1}
///     * i = 4: {2, 0, 0}
///     * i = 5: {2, 0, 1}
fn intToFieldsOptions(comptime n: u32, i: u32, n_options: [n]u32) [n]u32 {
    var options = [_]u32{0} ** n;
    var multiples: [n]u32 = undefined;
    // multiples[i] = prod_{j<i} (n_options[j]+1)
    multiples[0] = 1;
    var k: u32 = 1;
    while (k < n) : (k += 1) {
        multiples[k] = (n_options[k - 1] + 1) * multiples[k - 1];
    }
    var j: u32 = n - 1;
    var rest: u32 = i;
    while (true) : (j -= 1) {
        if (rest < multiples[j]) {
            options[j] = 0;
        } else {
            options[j] = rest / multiples[j];
            rest = rest % multiples[j];
        }
        if (j == 0)
            break;
    }
    return options;
}

fn nFieldsCombinations(n_options: []const u32) u32 {
    var prod: u32 = 1;
    for (n_options) |e|
        prod *= (e + 1);
    return prod;
}

test "helper int 2 field" {
    const n_options: [5]u32 = .{ 1, 0, 1, 5, 3 };
    const n_combinations = nFieldsCombinations(&n_options);
    expect(n_combinations == 96);
    const u = intToFieldsOptions(n_options.len, n_combinations - 1, n_options);
    expect(std.mem.eql(u32, &u, &n_options));
    const v = intToFieldsOptions(n_options.len, 9, n_options);
    const res: [5]u32 = .{ 1, 0, 0, 2, 0 };
    expect(std.mem.eql(u32, &res, &v));
}

// tests

test "parser slice int" {
    var alloc = std.testing.allocator;
    const p = try Parser([]u32)(alloc, &std.mem.tokenize("1 3 5 3", " "));
    defer alloc.free(p);
    expect(p.len == 4);
    expect((p[0] == 1) and (p[1] == 3) and (p[2] == 5) and (p[3] == 3));
}

test "parser struct" {
    var alloc = std.testing.allocator;
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const pair = try Parser(Pair)(alloc, &std.mem.tokenize("2 49", " "));
    expect(pair.a == 2);
    expect(pair.b == 49);
}

test "parser struct enum" {
    var alloc = std.testing.allocator;
    const Result = enum {
        ok,
        not_ok,
    };
    const Pair = struct {
        res: Result,
        a: u32,
    };
    const pair = try Parser(Pair)(alloc, &std.mem.tokenize("ok 49", " "));
    expect(pair.res == .ok);
    expect(pair.a == 49);
}

test "parser array struct" {
    var alloc = std.testing.allocator;
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const OtherPair = struct {
        a: [2]u32,
    };
    const pairs = "6 78 999 0";
    const pair2 = try Parser([2]OtherPair)(alloc, &std.mem.tokenize(pairs, " "));
    expect(pair2[0].a[1] == 78 and pair2[1].a[1] == 0);

    const pair_slice: []Pair = try Parser([]Pair)(alloc, &std.mem.tokenize(pairs, " "));
    defer alloc.free(pair_slice);
    expect(pair_slice[0].a == 6 and pair_slice[1].a == 999);
}

test "fmt parser slice" {
    var alloc = std.testing.allocator;
    const q = try ParserStr(Join([]u32, " "))(alloc, "1 3 5 3");
    defer alloc.free(q);
    expect((q[0] == 1) and (q[1] == 3) and (q[2] == 5) and (q[3] == 3));
}

test "parser optional" {
    const parser = Parser(?u32);
    const q = try parser(null, &std.mem.tokenize("", " "));
    expect(q == null);
}

test "parser recursive base" {
    var alloc = std.testing.allocator;
    const ChainedList = struct {
        _0: Match("("),
        val: u32,
        next: ?*@This(),
        _1: Match(")"),

        pub fn deinit(list: *const @This(), alloc_: *std.mem.Allocator) void {
            var opt_cur: ?*const @This() = list;
            while (opt_cur) |cur| {
                var next: ?*@This() = cur.next;
                opt_cur = next;
                alloc_.destroy(cur);
            }
        }
        pub fn sum(list: *const @This()) u32 {
            var acc: u32 = 0;
            var opt_cur: ?*const @This() = list;
            while (opt_cur) |cur| {
                acc += cur.val;
                opt_cur = cur.next;
            }
            return acc;
        }
    };
    const parser = Parser(*ChainedList);
    const list = try parser(
        alloc,
        &std.mem.tokenize("( 3 ( 32 ( 5 ) ) )", " "),
    );
    defer list.deinit(alloc);
    expect(list.sum() == 3 + 32 + 5);
    print("{}\n", .{list});
}

test "parser recursive unformat" {
    var alloc = std.testing.allocator;
    const ChainedList = struct {
        _0: Match("("),
        val: u32,
        next: ?*@This(),
        _1: Match(")"),

        pub fn deinit(list: *const @This(), alloc_: *std.mem.Allocator) void {
            var opt_cur: ?*const @This() = list;
            while (opt_cur) |cur| {
                var next = cur.next;
                opt_cur = next;
                alloc_.destroy(cur);
            }
        }
        pub fn sum(list: *const @This()) u32 {
            var acc: u32 = 0;
            var opt_cur: ?*const @This() = list;
            while (opt_cur) |cur| {
                acc += cur.val;
                opt_cur = cur.next;
            }
            return acc;
        }
    };
    const UCL = Unformat(ChainedList);
    comptime expect(UCL != ChainedList);
    // verify that Unformat removed the Match
    const l1 = UCL{ .val = 333, .next = null };
    print("{}\n", .{l1});
    const parser = Parser(*UCL);
    const list = try parser(
        alloc,
        &std.mem.tokenize("( 3 ( 32 ( 5 ) ) )", " "),
    );
    //defer list.deinit(alloc);
    print("{}\n", .{list});
    //const parser = Parser(*ChainedList);
}

test "fmt parser recursive wrap" {
    var alloc = std.testing.allocator;
    const ChainedList = struct {
        val: u32,
        next: ?*@This(),

        pub fn deinit(list: *const @This(), alloc_: *std.mem.Allocator) void {
            var opt_cur: ?*const @This() = list;
            while (opt_cur) |cur| {
                var next: ?*@This() = cur.next;
                opt_cur = next;
                print("destroy cur:{} ; next:{}\n", .{ @ptrToInt(cur), @ptrToInt(next) });
                alloc_.destroy(cur);
            }
        }
        pub fn sum(list: *const @This()) u32 {
            var acc: u32 = 0;
            var opt_cur: ?*const @This() = list;
            while (opt_cur) |cur| {
                acc += cur.val;
                opt_cur = cur.next;
            }
            return acc;
        }
    };
    const WChainedList = Wrap(*ChainedList, "(", ")");
    const parser = ParserU(WChainedList);
    const list1 = try parser(
        alloc,
        // &std.mem.tokenize("( 3 ( 32 ( 5 ) ) )", " "),
        &std.mem.tokenize("( 5 )", " "),
    );
    print("Parsed correctly: {}\n", .{list1});
    // parser:
    // 1. dynamically alloc WChainedList
    // 2. dynamically try to alloc a new element and fail, so backtrack
    // 3. create a new Unformatted object and return that with casts, SKIPPING the *Wrap!!!

    defer list1.deinit(alloc);
    const list = try parser(
        alloc,
        // &std.mem.tokenize("( 3 ( 32 ( 5 ) ) )", " "),
        &std.mem.tokenize("( 3 ( 32 ) )", " "),
    );
    defer list.deinit(alloc);
    print("Parsed correctly: {}\n", .{list});
    // print("{}\n", .{list});
    // expect(list.sum() == 3 + 32 + 5);
}

test "parser union" {
    var alloc = std.testing.allocator;
    const VanillaUnion = union {
        a: u32,
        b: str,
    };
    var parser1 = Parser(VanillaUnion);
    expectError(Error.NotImplementedError, parser1(alloc, &std.mem.tokenize("32", "\t")));
    var parser2 = Parser([]VanillaUnion);
    expectError(Error.NotImplementedError, parser2(alloc, &std.mem.tokenize("32 blabla", " ")));
    var parser3 = Parser([2]VanillaUnion);
    expectError(Error.NotImplementedError, parser3(alloc, &std.mem.tokenize("32 blabla", " ")));
    const TaggedUnion = union(enum) {
        a: u32,
        b: str,
    };
    const tinfo = @typeInfo(TaggedUnion);
    // print("{}\n", .{tinfo});
    // print("{}\n", .{tinfo.Union.fields.len});
    // print("{}\n", .{@typeInfo(tinfo.Union.tag_type.?)});
    // print("{}\n", .{@typeInfo(tinfo.Union.tag_type.?).Enum.fields.len});
    const parser = Parser(TaggedUnion);
    const parsed = try parser(alloc, &std.mem.tokenize("3", " "));
    expect(parsed.a == 3);
    const parsed2 = try parser(alloc, &std.mem.tokenize("xyzzyx", " "));
    expect(streql(parsed2.b, "xyzzyx"));
    const slice_parser = Parser([]TaggedUnion);
    const parsed3 = try slice_parser(alloc, &std.mem.tokenize("chaussette 33", " "));
    defer alloc.free(parsed3);
    expect(streql(parsed3[0].b, "chaussette"));
    expect(parsed3[1].a == 33);

    const array_parser = Parser([5]TaggedUnion);
    const parsed4 = try slice_parser(alloc, &std.mem.tokenize("gism 99 endless blockades 33393", " "));
    defer alloc.free(parsed4);
    expect(streql(parsed4[0].b, "gism"));
    expect(parsed4[1].a == 99);
    expect(streql(parsed4[2].b, "endless"));
    expect(streql(parsed4[3].b, "blockades"));
    expect(parsed4[4].a == 33393);
}

test "parser nested union" {
    var alloc = std.testing.allocator;
    const E = enum {
        ok,
        not_ok,
        meh,
    };
    const TaggedUnion = union(enum) {
        a: u32,
        b: E, // order matters
        c: str,
    };
    const S = struct {
        a: u32,
        b: TaggedUnion,
        c: ?TaggedUnion,
    };

    const parser = ParserStr(Join([]Join(S, " "), "\n"));
    const ex =
        \\8 ok
        \\92 883
        \\222221 delicious
        \\21 mmm meh
    ;
    const parsed = try parser(alloc, ex);
    defer alloc.free(parsed);
    expect(parsed[0].a == 8 and parsed[0].b.b == E.ok and parsed[0].c == null);
    expect(parsed[1].a == 92 and parsed[1].b.a == 883);
    expect(parsed[2].a == 222221 and streql(parsed[2].b.c, "delicious"));
    expect(parsed[3].a == 21 and streql(parsed[3].b.c, "mmm") and parsed[3].c.?.b == E.meh);
}

test "fmt parser join" {
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const JoinPair = Join(Pair, " ");
    expect(fmt.isFormattedStruct(JoinPair));
    expect(structFirstFieldType(JoinPair) == Pair);
    expect(!fmt.isFormattedStruct(Pair));
    const pair = try ParserStr(JoinPair)(null, "28 499992");
    expect(pair.a == 28 and pair.b == 499992);
}

test "parser match" {
    const A = struct {
        _0: Match("A"),
        a: u32,
    };
    const parser = Parser(A);
    const parsed = try parser(null, &std.mem.tokenize("A 33", " "));
    expect(parsed.a == 33);

    const B = struct {
        _0: Match("B"),
        a: str,
        _1: Match("C"),
    };
    const U = union(enum) {
        a: A,
        b: B,
    };
    const parser2 = Parser(U);
    const parsed2 = try parser2(null, &std.mem.tokenize("B bobo C", " "));
    expect(streql("bobo", parsed2.b.a));
    expectError(Error.ParseError, parser2(null, &std.mem.tokenize("B bobo", " ")));
    expectError(Error.ParseError, parser2(null, &std.mem.tokenize("bobo C", " ")));
}

test "cast format unformat" {
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const JoinPair = Join(Pair, " ");
    var p = Pair{ .a = 32, .b = 966 };
    var p2 = JoinPair{ .child = .{ .a = 76, .b = 99999 } };
    var ptr = @ptrCast(*Pair, &p2);
    p = ptr.*;
    expect(p.a == 76 and p.b == 99999);
}

test "fmt parser join nested" {
    var alloc = std.testing.allocator;
    const Nested = struct {
        c: u32,
        d: u32,
    };
    const PContainer = struct {
        a: u32,
        b: Join(Nested, ":"),
    };
    const Container = Unformat(PContainer);

    const C = Container{
        .a = 3,
        .b = .{
            .c = 2,
            .d = 45,
        },
    };
    expect(C.b.c == (Nested{ .c = 2, .d = 45 }).c);
    expect(!fmt.isFormattedStruct(PContainer));
    expect(!fmt.isFormattedStruct(Container));
    const p = try ParserStr(Join([]u16, ":"))(alloc, "2323:78:333");
    defer alloc.free(p);
    expect(p.len == 3);
    expect((p[0] == 2323) and (p[1] == 78) and (p[2] == 333));
}

test "AoC day7" {
    var alloc = std.testing.allocator;
    const Color = struct {
        n: ?u32,
        modifier: str,
        color: str,
        ignore_bags: ?str,
    };
    //comptime const n_fields = @typeInfo(Color).Struct.fields.len;
    //comptime const n_options = computeStructMaxNValues(n_fields, @typeInfo(Color));
    //for (n_options) |o| print("{}\n", .{o});
    //const n_combinations = nFieldsCombinations(n_options[0..]);
    //var comb_i: u32 = 0;
    //while (comb_i < n_combinations) : (comb_i += 1) {
    //    const options = intToFieldsOptions(n_fields, comb_i, n_options);
    //    for (options) |o| print("{}-", .{o});
    //    print("\n", .{});
    //}

    const LHS_parser = Parser(Color);
    const example_1 = "dotted tomato"; // .n and .ignore_bags are absent
    var iter_lhs: TokenIterator = std.mem.tokenize(example_1, " ");
    const LHS_parsed = try LHS_parser(alloc, &iter_lhs);
    expect(streql(LHS_parsed.modifier, "dotted"));
    expect(streql(LHS_parsed.color, "tomato"));

    const slice_parser = Parser([]Color);
    const example_2 = "4 dark tomato bags, 3 plaid orange bags, 5 posh teal bags.";
    // all the fields are present here.
    var iter = std.mem.tokenize(example_2, " ");
    const RHS_parsed = try slice_parser(alloc, &iter);
    defer alloc.free(RHS_parsed);
    expect(RHS_parsed.len == 3);
    expect(RHS_parsed[0].n.? == 4);
    expect(streql(RHS_parsed[0].modifier, "dark"));
    expect(streql(RHS_parsed[0].color, "tomato"));
    expect(RHS_parsed[1].n.? == 3);
    expect(streql(RHS_parsed[1].modifier, "plaid"));
    expect(streql(RHS_parsed[1].color, "orange"));
    expect(RHS_parsed[2].n.? == 5);
    expect(streql(RHS_parsed[2].modifier, "posh"));
    expect(streql(RHS_parsed[2].color, "teal"));
}

test "AoC day8 (modified)" {
    const alloc = std.testing.allocator;
    const Opcode = enum {
        nop,
        acc,
        jmp,
    };
    const Instruction = struct {
        opcode: Opcode,
        operand: ?i32,
    };
    // Parser definition:
    // within a struct, opcodes and operands are space-separated:
    const PInstruction = Join(Instruction, " ");
    // parse unknown number of space-separated instructions, separated by \n:
    const PInstructions = Join([]PInstruction, "\n");
    // name the data structure without formatting
    const Instructions = Unformat(PInstructions);
    expect(Instructions == []Instruction);
    const parser = ParserStr(PInstructions);

    const raw_instructions =
        \\jmp +109
        \\acc +10
        \\jmp +18
        \\nop
    ;
    const parsed = try parser(alloc, raw_instructions);
    defer alloc.free(parsed);
    expect(parsed.len == 4);
    expect(parsed[2].opcode == .jmp and parsed[2].operand.? == 18);
    expect(parsed[3].opcode == .nop and parsed[3].operand == null);
}

test "simple backtrack" {
    var alloc = std.testing.allocator;
    const NoBacktrack = struct {
        a: ?u32,
        b: u32,
    };
    const parser = Parser(NoBacktrack);
    const v = try parser(alloc, &std.mem.tokenize("3 4554444", " "));
    expect(v.a.? == 3 and v.b == 4554444);

    const u = try parser(alloc, &std.mem.tokenize("91733", " "));
    expect(u.b == 91733);

    const parser_str = ParserStr(NoBacktrack);
    const w = try parser_str(alloc, "91733");
    expect(w.b == 91733);
}

test "caveat type names" {
    var alloc = std.testing.allocator;
    const In2 = struct {
        a: u32,
        b: u32,
    };
    const In1 = struct {
        a: u32,
        b: Join(In2, "-"),
    };
    const ParsableData = Join(In1, " ");
    // problem is here: the type created by Unformat will recursively look
    // for formatted structs (depth-first search). It finds that In2 has no
    // nested formatted structs, i.e. Unformat(Join(In2, "-")) = In2.
    // therefore, it doesn't need to change the type of In1.b.
    // However, when it tries to unformat ParsableData, it notices that
    // Unformat(Join(In1, " ")) != In1 (b/c in the new type, In1.b is of type
    // In2). Therefore, it has to create a new type.
    // This new type will be identical to In1 in all respects, if we
    // recursively compare the TypeInfos of the structures.
    // But the pointer .fields at the level of In1 differ!
    const Data = Unformat(ParsableData);
    const parser = ParserStr(ParsableData);
    const parsed = try parser(alloc, "0 1-2");
    const manually_created = Data{
        .a = 0,
        .b = .{
            .a = 1,
            .b = 2,
        },
    };
    // this gives struct names like this:
    // print("\n{}\n", .{parsed});
    // print("{}\n", .{manually_created});
}
