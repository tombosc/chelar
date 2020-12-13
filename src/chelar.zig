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
const recursivePrintTypeInfoStruct = tools.recursivePrintTypeInfoStruct;

pub const Error = error{
    ParseError,
    ParseIntError,
    EndIterError,
    NotImplementedError,
    DelimByteError,
} || Allocator.Error || enum_parser.Error;

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
            castUnformatRecur(T, &parsed, &unformatted);
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

        fn parseRecur(comptime t: type, opt_alloc: ?*Allocator, iter: *TokenIterator) Error!t {
            var parsed: t = undefined;
            //print("> {}\n", .{@typeInfo(t)});
            const iter_index_backup = iter.index;
            if (t == str) {
                const v = iter.next();
                // for debugging with assembly.
                // const v = @call(.{ .modifier = .never_inline }, iter.next, .{});
                return v orelse Error.EndIterError;
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
                    } else {
                        return Error.EndIterError;
                    }
                },
                .Optional => {
                    comptime var child_type = typeinfo.Optional.child;
                    return parseRecur(child_type, opt_alloc, iter) catch return null;
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
                    comptime const is_formatted_struct: bool = isFormattedStruct(t);
                    if (is_formatted_struct) {
                        var sub_iter: std.mem.TokenIterator = undefined;
                        if (iter.next()) |val| {
                            sub_iter = t.tokenize(val);
                            //return parseRecur(t.child_type, alloc, &sub_iter) catch return Error.ParseError;
                            return t{
                                .child = try parseRecur(t.child_type, opt_alloc, &sub_iter), //catch return Error.ParseError,
                            };
                        } else {
                            return Error.ParseError;
                            //iter.index = iter_index_backup;
                        }
                    } else {
                        inline for (typeinfo.Struct.fields) |f, i| {
                            comptime var subtype = f.field_type;
                            @field(parsed, f.name) = (try parseRecur(subtype, opt_alloc, iter));
                        }
                    }
                },
                .Pointer => {
                    if (typeinfo.Pointer.size == .Slice) {
                        comptime const subtype = typeinfo.Pointer.child;
                        var array = std.ArrayList(subtype).init(opt_alloc.?);
                        while (true) {
                            const e = parseRecur(subtype, opt_alloc, iter) catch break;
                            try array.append(e);
                        }
                        return array.toOwnedSlice();
                        // TODO Could we turn opt_alloc to be comptime known?
                        // thus we could check that when the type
                        // require dynamic memory allocation at comptime,
                        // alloc is not null? Or is it a misuse of optionals?
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
                        array[i] = parseRecur(subtype, opt_alloc, iter) catch break;
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

test "int slice parser" {
    var alloc = std.testing.allocator;
    const p = try Parser([]u32)(alloc, &std.mem.tokenize("1 3 5 3", " "));
    defer alloc.free(p);
    expect(p.len == 4);
    expect((p[0] == 1) and (p[1] == 3) and (p[2] == 5) and (p[3] == 3));

    const q = try ParserStr(Join([]u32, " "))(alloc, "1 3 5 3");
    defer alloc.free(q);
    expect((q[0] == 1) and (q[1] == 3) and (q[2] == 5) and (q[3] == 3));
}

test "struct parser" {
    var alloc = std.testing.allocator;
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const pair = try Parser(Pair)(alloc, &std.mem.tokenize("2 49", " "));
    expect(pair.a == 2);
    expect(pair.b == 49);
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
    const pair = try Parser(Pair)(alloc, &std.mem.tokenize("ok 49", " "));
    expect(pair.res == .ok);
    expect(pair.a == 49);
}

fn structFirstFieldType(comptime T: type) type {
    return @typeInfo(T).Struct.fields[0].field_type;
}

test "join parser" {
    var alloc = std.testing.allocator;
    const Pair = struct {
        a: u32,
        b: u32,
    };
    const JoinPair = Join(Pair, " ");
    // TODO doesn't work consistently, bugs with print at comptime?
    //print("JoinPair:\n", .{});
    //recursivePrintTypeInfoStruct(JoinPair, 0);
    //print("Orig:\n", .{});
    //recursivePrintTypeInfoStruct(Pair, 0);
    comptime expect(isFormattedStruct(JoinPair));
    comptime expect(structFirstFieldType(JoinPair) == Pair);
    comptime expect(!isFormattedStruct(Pair));
    comptime expect(!isFormattedStruct(structFirstFieldType(Pair)));
    const pair = try ParserStr(JoinPair)(alloc, "28 499992");
    expect(pair.a == 28);
    expect(pair.b == 499992);
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
    const pair2 = try Parser([2]OtherPair)(alloc, &std.mem.tokenize(pairs, " "));
    expect(pair2[0].a[1] == 78 and pair2[1].a[1] == 0);

    const pair_slice: []Pair = try Parser([]Pair)(alloc, &std.mem.tokenize(pairs, " "));
    defer alloc.free(pair_slice);
    expect(pair_slice[0].a == 6 and pair_slice[1].a == 999);
}

test "unsafe copy?" {
    var alloc = std.testing.allocator;
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
    //std.mem.copy(Pair, p2, p);
}

test "join parse" {
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
    expect(!isFormattedStruct(PContainer));
    expect(!isFormattedStruct(Container));
    const p = try ParserStr(Join([]u16, ":"))(alloc, "2323:78:333");
    defer alloc.free(p);
    expect(p.len == 3);
    expect((p[0] == 2323) and (p[1] == 78) and (p[2] == 333));
}

test "AoC day4" {
    // const HeightUnit = enum { in, cm };
    // const EyeColor = enum {
    //     amb, blu, brn, gry, grn, hzl, oth
    // };
    // const Field = union(enum) {
    //     byr: u32,
    //     eyr: u32,
    //     iyr: u32,
    //     hgt: u32,
    //     hgt_unit: HeightUnit,
    //     hcl: str,
    //     ecl: EyeColor,
    //     pid: str,
    //     cid: void,
    //     unk,
    // };
    // TODO tagged unions!
    // const Passport = struct {
    //     fields: [7]fields,
    //     cid: str,
    // };

    // const valid1 =
    //     \\ecl:gry pid:860033327 eyr:2020 hcl:#fffffd
    //     \\byr:1937 iyr:2017 cid:147 hgt:183cm
    // ;
}

test "AoC day7" {
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
    // TODO ambiguity in the struct, can't do anything?
    // how does it work for regex, for example, when it's ambiguous?
    //expect(RHS2_parsed[1].ignore_bags == null);
    //expect(RHS2_parsed[2].n.? == 5);
    //expect(streql(RHS2_parsed[2].modifier, "posh"));
    //expect(streql(RHS2_parsed[2].color, "duck"));
}

test "nesting AoC day8 (modified)" {
    var alloc = std.testing.allocator;

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
    // give a name to the data without formatting
    //const Instructions = Unformat(PInstructions);
    const parser = ParserStr(PInstructions);

    const raw_instructions =
        \\jmp +109
        \\acc +10
        \\jmp +18
        \\nop
        \\jmp +327
        \\nop  
        \\jmp +269
    ;
    // print("\n", .{});
    // recursivePrintTypeInfoStruct(Instruction, 0);
    // print("Other\n", .{});
    // recursivePrintTypeInfoStruct(Unformat(PInstruction), 0);

    //expect(Unformat(PInstruction) == Instruction);
    //expect(Unformat([]PInstruction) == []Instruction);
    //recursivePrintTypeInfoStruct(Unformat(PType), 0);
    //expect(Unformat(PType) == []Instruction);
    // TODO doesn't work consistently, bugs with print at comptime?
    //recursivePrintTypeInfoStruct(PType, 0);

    const parsed = try parser(alloc, raw_instructions);
    //const parsed: Unformat(PType) = try parser(alloc, raw_instructions);
    defer alloc.free(parsed);
    // print("{}\n", .{parsed});
    print("{}\n", .{parsed[5]});
    //expect(parsed.len == 7);
}

test "nesting" {
    //const In3 = struct {
    //    a: u32,
    //};
    const In2 = struct {
        a: u32,
        b: u32,
    };
    const In1 = struct {
        a: u32,
        b: Join(In2, "-"),
    };
    const In0 = struct {
        a: u32,
        b: Join(In1, "/"),
    };
    const U = Unformat(Join(In0, " "));
    var alloc = std.testing.allocator;
    //print("\n", .{});
    //recursivePrintTypeInfoStruct(In0, 0);
    //print("\n", .{});
    //recursivePrintTypeInfoStruct(Unformat(In0), 0);

    const parser = ParserStr(Join(In0, " "));
    const parsed = try parser(alloc, "0 1/2-3");
    recursivePrintTypeInfoStruct(U, 0);
    print("-----------------\n", .{});
    recursivePrintTypeInfoStruct(@TypeOf(parsed), 0);
    print("-----------------\n", .{});
    const parsed2 = try parser(alloc, "0 1/2-3");
    recursivePrintTypeInfoStruct(@TypeOf(parsed2), 0);
    print("{}\n", .{parsed2});
}

// const ErrorSet = error{Error1};
// fn a() ErrorSet!void {
//     return ErrorSet.Error1;
// }
//
// test "nesting a" {
//     try a();
// }
