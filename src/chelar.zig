const std = @import("std");
const enum_parser = @import("enum_parser.zig");
const expect = std.testing.expect;
const str = []const u8;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const TokenIterator = std.mem.TokenIterator;

pub const Error = error{
    ParseError,
    ParseIntError,
    EndIterError,
    NotImplementedError,
} || Allocator.Error || enum_parser.Error;

pub fn isFormattedStruct(comptime T: type) bool {
    if (@typeInfo(T) != .Struct)
        return false;
    inline for (@typeInfo(T).Struct.decls) |decl, i| {
        if (decl.data.Var == ParseStruct) {
            return true;
        }
    }
    return false;
}

fn recursiveUnformatCast(comptime T: type, parsed: *T, unformatted: *Unformat(T)) void {
    const typeinfo_T = @typeInfo(T);
    switch (typeinfo_T) {
        .Struct => {
            // go in depth first
            comptime const is_formatted_struct = isFormattedStruct(T);
            if (!is_formatted_struct) {
                inline for (typeinfo_T.Struct.fields) |f, i| {
                    // this is not a formatted struct, so both formatted and
                    // unformatted structs should have the same field names
                    const corresponding_field_name = @typeInfo(Unformat(T)).Struct.fields[i].name;
                    comptime expect(streql(f.name, corresponding_field_name));
                    comptime expect(T == @TypeOf(parsed.*));
                    recursiveUnformatCast(
                        f.field_type,
                        &@field(parsed.*, f.name),
                        &@field(unformatted.*, f.name),
                    );
                }
            }
            if (is_formatted_struct) {
                const formatted_child = @ptrCast(
                    *Unformat(T),
                    &(parsed.*.child),
                );
                unformatted.* = formatted_child.*;
            }
        },
        else => {
            unformatted.* = parsed.*;
        },
    }
}

pub fn ParserStr(comptime T: type) (fn (*Allocator, str) Error!Unformat(T)) {
    return struct {
        const wrappedParseFn = Parser(T);
        fn parseWrap(alloc: *Allocator, val: str) Error!Unformat(T) {
            // TODO is there a never used ASCII char? I use ETX=0x03...
            const delim_bytes: []const u8 = ([1]u8{0x03})[0..];
            //const delim_bytes: []const u8 = "gaga"[0..];
            var iter = std.mem.tokenize(val, delim_bytes);
            var parsed: T = try wrappedParseFn(alloc, &iter);
            // TODO cast to Unformat(T)... ou la la! make that safe somehow?
            var unformatted: Unformat(T) = undefined;
            recursiveUnformatCast(T, &parsed, &unformatted);
            return unformatted;
        }
    }.parseWrap;
}

/// A parser function for a variety of complicated, nested types known at
/// compile time. Currently, it supports structs, slices, arrays, integers,
/// []const u8, and enums.
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
                            return Error.ParseIntError;
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
                    comptime const is_formatted_struct: bool = isFormattedStruct(t);
                    if (is_formatted_struct) {
                        var sub_iter: std.mem.TokenIterator = undefined;
                        if (iter.next()) |val| {
                            sub_iter = t.tokenize(val);
                            //return parseB(t.child_type, alloc, &sub_iter) catch return Error.ParseError;
                            return t{
                                .child = try parseB(t.child_type, alloc, &sub_iter), //catch return Error.ParseError,
                            };
                        } else {
                            return Error.ParseError;
                            //iter.index = iter_index_backup;
                        }
                    } else {
                        inline for (typeinfo.Struct.fields) |f, i| {
                            comptime var subtype = f.field_type;
                            @field(parsed, f.name) = (try parseB(subtype, alloc, iter));
                        }
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

fn recursivePrintTypeInfoStruct(comptime T: type, comptime depth: u8) void {
    comptime var i = 0;
    inline while (i < depth) : (i += 1) {
        print(">", .{});
    }
    print("{}\n", .{@typeInfo(T)});
    if (@typeInfo(T) == .Struct) {
        inline for (@typeInfo(T).Struct.fields) |f| {
            recursivePrintTypeInfoStruct(f.field_type, depth + 1);
        }
    } else if (@typeInfo(T) == .Pointer) {
        recursivePrintTypeInfoStruct(
            @typeInfo(T).Pointer.child,
            depth + 1,
        );
    } else if (@typeInfo(T) == .Optional) {
        recursivePrintTypeInfoStruct(
            @typeInfo(T).Optional.child,
            depth + 1,
        );
    }
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

/// private, indicate that struct encapsulates various tools to parse
const ParseStruct = enum {
    parse_struct,
};

// TODO explain format structs

pub fn Join(comptime T: type, comptime sep: str) type {
    return struct {
        child: T,
        // @"0": T,
        const parse_struct: ParseStruct = .parse_struct;
        const child_type: type = T;

        fn tokenize(val: str) std.mem.TokenIterator {
            // print("Tok {}\n", .{val});
            return std.mem.tokenize(val, sep);
        }
    };
}

/// Recursively de-encapsulate format structs obtained using formatters like Join
pub fn Unformat(comptime T: type) type {
    comptime var typeinfo = @typeInfo(T);
    switch (typeinfo) {
        .Struct => {
            const is_parse_struct: bool = isFormattedStruct(T);
            if (is_parse_struct) {
                return Unformat(T.child_type);
            } else {
                const StructField = std.builtin.TypeInfo.StructField;
                comptime const n_fields = typeinfo.Struct.fields.len;
                comptime var fields: [n_fields]StructField = undefined;
                std.mem.copy(StructField, fields[0..], typeinfo.Struct.fields);
                // recursively Unformat the fields
                var fields_have_changed: bool = false;
                inline for (fields) |f, i| {
                    const unfmt_type = Unformat(f.field_type);
                    fields[i].field_type = unfmt_type;
                    if (f.field_type != unfmt_type) { // type has been modified:
                        fields_have_changed = true;
                        fields[i].default_value = null; //nested_type
                    }
                }
                if (!fields_have_changed) {
                    return T;
                }
                const s = std.builtin.TypeInfo.Struct{
                    .layout = typeinfo.Struct.layout,
                    .fields = fields[0..],
                    .decls = typeinfo.Struct.decls,
                    .is_tuple = typeinfo.Struct.is_tuple,
                };
                const nested_type = @Type(std.builtin.TypeInfo{
                    .Struct = s,
                });

                return nested_type;
            }
        },
        .Pointer => {
            // Create a new type info where the child type is unformatted
            const tp = typeinfo.Pointer;
            var s: std.builtin.TypeInfo.Pointer = tp;
            s.child = Unformat(tp.child);
            return @Type(std.builtin.TypeInfo{ .Pointer = s });
        },
        .Int => return T,
        else => return T,
    }
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

test "join" {
    var alloc = std.testing.allocator;
    // we need to be able to create the "Join" type directly and with the same syntax
    // so that adding tokenizer information does not disturb the normal use
    //const u32_: type = Join(u32, " ");
    const u32_joined: type = Join([]u32, " ");
    expect(isFormattedStruct(u32_joined));
    const ufmt_u: type = Unformat(u32_joined);
    expect(ufmt_u == []u32);
    //TODO!!!
    //const parsed = ParserStr(u32_joined)(alloc, "5321");
    //print("{}\n", .{parsed});

    const ufmt: type = Unformat(u32);
    expect(ufmt == u32);

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
    var alloc = std.testing.allocator;
    print("\n", .{});
    recursivePrintTypeInfoStruct(In0, 0);
    print("\n", .{});
    recursivePrintTypeInfoStruct(Unformat(In0), 0);

    const parser = ParserStr(Join(In0, " "));
    const parsed = parser(alloc, "0 1/2-3");
    print("{}\n", .{parsed});
}

// const ErrorSet = error{Error1};
// fn a() ErrorSet!void {
//     return ErrorSet.Error1;
// }
//
// test "nesting a" {
//     try a();
// }
