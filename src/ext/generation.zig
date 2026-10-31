//! Generations of the extension host: which load of the files something
//! belongs to, and which request an answer answers. Two types, so one cannot
//! be passed where the other is meant (`list` takes a registry's and returns
//! a request's).

const std = @import("std");
const assert = std.debug.assert;

/// Which load of the files a registry is, and the registry a request was
/// made against. A request made against an older one is refused.
pub const RegistryGeneration = enum(u32) {
    /// Before the first load.
    none = 0,
    _,

    /// The generation after `generation`, never `none` (it wraps past it).
    pub fn next(generation: RegistryGeneration) RegistryGeneration {
        return nextOf(RegistryGeneration, generation);
    }
};

/// Which request an answer answers; a list's rows keep their list request's,
/// so their actions run against that list only. `none` is never handed out:
/// the window keeps it for "nothing pending".
pub const RequestGeneration = enum(u32) {
    none = 0,
    _,

    /// The generation after `generation`, never `none` (it wraps past it).
    pub fn next(generation: RequestGeneration) RequestGeneration {
        return nextOf(RequestGeneration, generation);
    }
};

fn nextOf(comptime Generation: type, generation: Generation) Generation {
    var value = @backingInt(generation) +% 1;
    if (value == @backingInt(Generation.none)) value +%= 1;
    const result: Generation = @fromBackingInt(@intCast(value));
    assert(result != .none);
    return result;
}

test "generations skip none when they wrap" {
    const last: RequestGeneration = @fromBackingInt(@intCast(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(RequestGeneration, @fromBackingInt(@intCast(1))), last.next());
    try std.testing.expectEqual(
        @as(RegistryGeneration, @fromBackingInt(@intCast(1))),
        RegistryGeneration.none.next(),
    );
}
