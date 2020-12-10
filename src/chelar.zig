const std = @import("std");
const enum_parser = @import("enum_parser.zig");
const expect = std.testing.expect;
const str = []const u8;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const TokenIterator = std.mem.TokenIterator;

const Error = error{
    ParseError,
    EndIterError,
    NotImplementedError,
} || Allocator.Error || enum_parser.Error;

/// Custom parser functions for your own types.
/// Currently, supports structs, slices, arrays, integers, strings, enum, as
/// well as the optional variants.
pub fn Parser(comptime T: type) (fn (*Allocator, *TokenIterator) Error!T) {
    return struct {
        fn parse(alloc: *Allocator, iter: *TokenIterator) Error!T {
            return parseB(T, alloc, iter);
        }

        fn parseB(comptime t: type, alloc: *Allocator, iter: *TokenIterator) Error!t {
            var parsed: t = undefined;
            //print("> {}\n", .{@typeInfo(t)});
            const iter_index_backup = iter.index;
            if (t == str) {
                return iter.next() orelse Error.EndIterError;
            }
            comptime var typeinfo = @typeInfo(t);
            switch (typeinfo) {
                .Int => {
                    if (iter.next()) |val| {
                        const parsed_int: t = std.fmt.parseInt(t, val, 10) catch {
                            iter.index = iter_index_backup;
                            return Error.ParseError;
                        };
                        return parsed_int;
                    }
                    return Error.EndIterError;
                },
                .Optional => {
                    comptime var child_type = typeinfo.Optional.child;
                    return parseB(child_type, alloc, iter) catch return null;
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
                    inline for (typeinfo.Struct.fields) |f, i| {
                        comptime var subtype = f.field_type;
                        @field(parsed, f.name) = (try parseB(subtype, alloc, iter));
                    }
                },
                .Pointer => {
                    if (typeinfo.Pointer.size == .Slice) {
                        comptime const subtype = typeinfo.Pointer.child;
                        comptime const max_len = 10000;
                        // TODO use std container instead of hideous max_len
                        var array: [max_len]subtype = ([_]subtype{undefined} ** max_len);
                        var i: u32 = 0;
                        while (true) {
                            array[i] = parseB(subtype, alloc, iter) catch break;
                            i += 1;
                        }
                        var sliced: []subtype = try alloc.alloc(subtype, i);
                        std.mem.copy(subtype, sliced, array[0..i]);
                        return sliced;
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
                        array[i] = parseB(subtype, alloc, iter) catch break;
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

fn streql(str1: str, str2: str) bool {
    return std.mem.eql(u8, str1, str2);
}

test "AoC day7 parsing" {
    const Color = struct {
        n: ?u32,
        modifier: str,
        color: str,
        ignore_bags: ?str,
    };

    const LHSParser = Parser(Color);
    var alloc = std.testing.allocator;
    const example_1 = "dotted tomato"; // .n and .ignore_bags are absent
    var iter_lhs: TokenIterator = std.mem.tokenize(example_1, " ");
    const LHS_parsed = try LHSParser(alloc, &iter_lhs);
    expect(streql(LHS_parsed.modifier, "dotted"));
    expect(streql(LHS_parsed.color, "tomato"));

    const example_2 = "4 dark tomato bags, 3 plaid orange bags, 5 posh teal bags.";
    // all the fields are present here.
    var iter = std.mem.tokenize(example_2, " ");
    const RHS_parsed: []Color = try Parser([]Color)(alloc, &iter);
    defer alloc.free(RHS_parsed);
    expect(RHS_parsed.len == 3);
    expect(streql(RHS_parsed[0].modifier, "dark"));
    expect(streql(RHS_parsed[0].color, "tomato"));
    expect(streql(RHS_parsed[1].modifier, "plaid"));
    expect(streql(RHS_parsed[1].color, "orange"));
    expect(streql(RHS_parsed[2].modifier, "posh"));
    expect(streql(RHS_parsed[2].color, "teal"));

    // more complicated (not in the original AoC data)
    const example_3 = "dark potato bags, plaid yellow 5 posh duck bags.";
    iter = std.mem.tokenize(example_3, " ");
    const RHS2_parsed: []Color = try Parser([]Color)(alloc, &iter);
    defer alloc.free(RHS2_parsed);
    expect(RHS2_parsed.len == 3);
    expect(RHS2_parsed[0].n == null);
    expect(streql(RHS2_parsed[0].modifier, "dark"));
    expect(streql(RHS2_parsed[0].color, "potato"));
    expect(RHS2_parsed[1].n == null);
    expect(streql(RHS2_parsed[1].modifier, "plaid"));
    expect(streql(RHS2_parsed[1].color, "yellow"));
    // TODO how to deal with ambiguous parses?
    // how do regex parsers deal with ambiguity?
    // a minimal, similar case would be regex ".?.?": which "." captures a
    // single character?
    // expect(RHS2_parsed[1].ignore_bags == null);
    // expect(RHS2_parsed[2].n.? == 5);
    // expect(streql(RHS2_parsed[2].modifier, "posh"));
    // expect(streql(RHS2_parsed[2].color, "duck"));
}

test "int slice parser" {
    var alloc = std.testing.allocator;
    const p = try Parser([]u32)(alloc, &std.mem.tokenize("1 3 5 3", " "));
    defer alloc.free(p);
    expect(p.len == 4);
    expect((p[0] == 1) and (p[1] == 3) and (p[2] == 5) and (p[3] == 3));
}

test "struct parser" {
    var alloc = std.testing.allocator;
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const pair: Pair = try Parser(Pair)(alloc, &std.mem.tokenize("2 49", " "));
    expect(@typeInfo(Pair).Struct.fields.len == 2);
}

test "enum parser" {
    var alloc = std.testing.allocator;
    const Result = enum {
        ok,
        not_ok,
    };
    const Pair = struct {
        res: Result,
        a: u32,
    };
    const pair: Pair = try Parser(Pair)(alloc, &std.mem.tokenize("ok 49", " "));
    expect(pair.res == .ok);
    expect(pair.a == 49);
}

test "array struct parser" {
    var alloc = std.testing.allocator;
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const OtherPair = struct {
        a: [2]u32,
    };
    const pairs = "6 78 999 0";
    const rt_pairs = try alloc.alloc(u8, pairs.len);
    defer alloc.free(rt_pairs);
    std.mem.copy(u8, rt_pairs, pairs[0..]);
    //const pair: [2]Pair = try Parser([2]Pair)(alloc, &std.mem.tokenize(pairs, " "));
    //expect(pair[0].a == 6 and pair[1].a == 999);
    const pair2 = try Parser([2]OtherPair)(alloc, &std.mem.tokenize(rt_pairs, " "));
    expect(pair2[0].a[0] == 6 and pair2[1].a[0] == 999);
    expect(pair2[0].a[1] == 78 and pair2[1].a[1] == 0);

    const pair_slice: []Pair = try Parser([]Pair)(alloc, &std.mem.tokenize(rt_pairs, " "));
    defer alloc.free(pair_slice);
    expect(pair_slice[0].a == 6 and pair_slice[1].a == 999);
    expect(pair_slice[0].b == 78 and pair_slice[1].b == 0);
}
