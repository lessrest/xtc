// Module root for the Wren integration.
// Kept at src/ so that fiberscript/vm.zig can import sibling files
// without hitting Zig 0.15's module path restrictions.
pub const VM = @import("fiberscript/vm.zig");

