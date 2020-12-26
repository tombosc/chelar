const std = @import("std");
const str = []const u8;
const print = std.debug.print;
const expect = std.testing.expect;
const alloc = std.testing.allocator;
const array_alloc = 100;

fn isInSlice(comptime T: type, slice: []T, element: T) bool {
    for (slice) |e| {
        if (e == element) {
            return true;
        }
    }
    return false;
}

fn addToSlice(comptime T: type, comptime opt_slice: ?[]const T, element: T) []T {
    var array = [_]T{undefined} ** array_alloc;
    if (opt_slice) |slice| {
        const N: usize = slice.len;
        //var new_slice: [slice.len + 1]T = undefined;
        //var new_slice = try alloc.alloc(T, N + 1);
        std.mem.copy(T, array[0..N], slice);
        array[N] = element;
        return array[0 .. N + 1];
    } else {
        //var new_slice = try alloc.alloc(T, 1);
        array[0] = element;
        return array[0..1];
    }
}

test "add to slice" {
    const array = [_]u32{ 0, 1, 2, 3 };
    const slice = addToSlice(u32, &array, 4);
    // defer alloc.free(slice);
    expect(slice.len == 5 and slice[4] == 4);

    const array2 = [0]u32{};
    const slice2 = addToSlice(u32, &array2, 97);
    // defer alloc.free(slice2);
    expect(slice2.len == 1 and slice2[0] == 97);

    const slice3 = addToSlice(u32, null, 131);
    // defer alloc.free(slice3);
    expect(slice3.len == 1 and slice3[0] == 131);

    comptime {
        const slice4 = addToSlice(type, null, []const u8);
        // defer alloc.free(slice4);
        comptime expect(slice4.len == 1 and slice4[0] == []const u8);
    }
}

pub fn recursivePrintTypeInfoStruct(comptime T: type, comptime depth: u8) void {
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
        const child_type = @typeInfo(T).Pointer.child;
        recursivePrintTypeInfoStruct(child_type, depth + 1);
    } else if (@typeInfo(T) == .Optional) {
        recursivePrintTypeInfoStruct(@typeInfo(T).Optional.child, depth + 1);
    }
}
pub fn recursivePrintTypeInfoStructTerm(comptime T: type, comptime depth: u8, comptime opt_seen_types: ?[]type) void {
    //const out_file = std.io.getStdOut();
    comptime var i = 0;
    if (opt_seen_types) |seen_types| {
        if (isInSlice(type, seen_types, T)) {
            return;
        }
    }
    inline while (i < depth) : (i += 1) {
        //try out_file.writer().print(">", .{});
        print(">", .{});
    }
    //print("{}\n", .{@typeInfo(T)});
    comptime const new_seen_types = addToSlice(type, opt_seen_types, T);
    // defer alloc.free(new_seen_types);
    if (@typeInfo(T) == .Struct) {
        inline for (@typeInfo(T).Struct.fields) |f| {
            comptime recursivePrintTypeInfoStructTerm(f.field_type, depth + 1, new_seen_types);
        }
    } else if (@typeInfo(T) == .Pointer) {
        const child_type = @typeInfo(T).Pointer.child;
        comptime recursivePrintTypeInfoStructTerm(child_type, depth + 1, new_seen_types);
    } else if (@typeInfo(T) == .Optional) {
        comptime recursivePrintTypeInfoStructTerm(@typeInfo(T).Optional.child, depth + 1, new_seen_types);
    }
}

test "print type recursive" {
    const StructNonRecur = struct {
        val: u32,
        next: ?*str,
    };
    //recursivePrintTypeInfoStruct(StructNonRecur, 0, null);
    recursivePrintTypeInfoStruct(StructNonRecur, 0);
    const ChainedList = struct {
        val: u32,
        next: ?*@This(),
    };
    print("Recursive:\n", .{});
    // recursivePrintTypeInfoStruct(ChainedList, 0, null);
    // TODO
    //comptime recursivePrintTypeInfoStructTerm(ChainedList, 0, null);
}

pub fn streql(str1: str, str2: str) bool {
    return std.mem.eql(u8, str1, str2);
}

pub fn generic_eql(comptime T: type, a: T, b: T) bool {
    if (T == str) {
        return std.mem.eql(u8, a, b);
    } else {
        return a == b;
    }
}

test "generic equal" {
    expect(generic_eql(str, "ababb", "ababb"));
    expect(!generic_eql(str, "!ababb", "ababb"));
    expect(generic_eql(u32, 767, 767));
    expect(!generic_eql(u32, 768, 767));
}
