const std = @import("std");
const str = []const u8;
const print = std.debug.print;

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

pub fn streql(str1: str, str2: str) bool {
    return std.mem.eql(u8, str1, str2);
}
