# chelar

Create simple parsers in [Zig](https://ziglang.org/) at compile-time. Warning: Hacky and experimental. 

API:

- `pub fn Parser(comptime T: type) (fn (?*std.mem.Allocator, *std.mem.TokenIterator) Error!T)`: given a type, returns a parsing function that takes an optional allocator (only needed for slices and pointers) and an iterator. See 2nd example.
- more experimental: `ParserStr` is identical, except that it doesn't need an iterator, but uses *formatted structs* -- structs that contain parsing information. The function returned returns not `Error!T`, but `Error!Unformat(T)`. `Unformat` recursively converts formatted structs and types containing these into types containing no nested formatted structs.

Example taken (modified) from [advent of code 2020](https://adventofcode.com/), day 8:

```Zig
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
    // opcodes and operands are space-separated
    const PInstruction = Join(Instruction, " ");
    // there's an unknown number of instructions separated by \n
    const PInstructions = Join([]PInstruction, "\n");
    // name the data structure without formatting info
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
```

Zig type | Regex | Grammar rule
---|---|---
`?T` | `T?` |
`[]T` | `T*` |
`[19]T` | `T{19}` |
`enum { a, b, c }` | `(a|b|c)` |
`const X = struct { a: T, b: U }` | | `X → TU` 
`const X = union(enum) { a: U, b: V }` | | `X → U | V`

You can also parse recursive languages, for instance:

```Zig
test "parser recursive base" {
    var alloc = std.testing.allocator;
    const LinkedList = struct {
        _0: Match("("),
        val: u32,
        next: ?*@This(),
        _1: Match(")"),

        pub fn deinit(list: *const @This(), alloc_: *std.mem.Allocator) void {
            // see src/chelar.zig
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
    const parser = Parser(*LinkedList);
    const list = try parser(
        alloc,
        &std.mem.tokenize("( 3 ( 32 ( 5 ) ) )", " "),
    );
    defer list.deinit(alloc);
    expect(list.sum() == 3 + 32 + 5);
}
```

The parser is a very naive [recursive descent parser](https://en.wikipedia.org/wiki/Recursive_descent_parser). There are major caveats:

- does not deal with runtime errors (parsing errors) gracefully.
- does not deal with compile time (errors of types). For instance, `Join(u32, " ")` should fail but doesn't. 
- numerous limitations when one creates types using `Join`, `Match` and `Unformat`.
	* These functions create types which are not named properly (they are named after the line of code where the type is described). This can make it hard to debug. See `caveat type names`.
	* Right now, `Unformat` will recur infinitely. Therefore, it cannot remove `Match` fields in the `LinkedList` above, for example. Similarly, I don't know how to stop a potential operator like `Wrap(T, match_left, match_right)` from recursing infinitely (when T occurs in T as a pointer).
	* `@Type` doesn't support creation of type with decls, as [proposed here (#6709)](https://github.com/ziglang/zig/issues/6709). See `caveat functions in structs`.

TODO:

- A new operator on types `Wrap(T, '{', '}')`? See caveats.
- Proper error handling
- Comptime verbose mode
- Serialization
