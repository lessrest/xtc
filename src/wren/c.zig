const std = @import("std");

pub const VM = opaque {};
pub const Handle = opaque {};

pub const ErrorType = enum(c_int) {
    compile = 0,
    runtime = 1,
    stack_trace = 2,
};

pub const InterpretResult = enum(c_uint) {
    success = 0,
    compile_error = 1,
    runtime_error = 2,
};

pub const Type = enum(c_uint) {
    bool = 0,
    num = 1,
    foreign = 2,
    list = 3,
    map = 4,
    null = 5,
    string = 6,
    unknown = 7,
};

const Ptr = ?*anyopaque;
const CStr = [*:0]const u8;

pub const ReallocateFn = Callback(
    fn (Ptr, usize, *anyopaque) Ptr,
);
pub const ForeignMethodFn = Callback(
    fn (*VM) void,
);
pub const FinalizerFn = Callback(
    fn (Ptr) void,
);
pub const ResolveModuleFn = Callback(
    fn (*VM, CStr, CStr) CStr,
);
pub const LoadModuleCompleteFn = Callback(
    fn (*VM, CStr, LoadModuleResult) void,
);
pub const LoadModuleFn = Callback(
    fn (*VM, CStr) LoadModuleResult,
);
pub const BindForeignMethodFn = Callback(
    fn (*VM, CStr, CStr, bool, CStr) ForeignMethodFn,
);
pub const WriteFn = Callback(
    fn (*VM, CStr) void,
);
pub const ErrorFn = Callback(
    fn (*VM, ErrorType, CStr, c_int, CStr) void,
);
pub const BindForeignClassFn = Callback(
    fn (*VM, CStr, CStr) ForeignClassMethods,
);

pub const LoadModuleResult = extern struct {
    source: ?CStr = null,
    onComplete: Ptr = null,
    userData: Ptr = null,
};

pub const ForeignClassMethods = extern struct {
    allocate: ForeignMethodFn = null,
    finalize: FinalizerFn = null,
};

pub const Configuration = extern struct {
    reallocateFn: ReallocateFn = null,
    resolveModuleFn: ResolveModuleFn = null,
    loadModuleFn: LoadModuleFn = null,
    bindForeignMethodFn: BindForeignMethodFn = null,
    bindForeignClassFn: BindForeignClassFn = null,
    writeFn: WriteFn = null,
    errorFn: ErrorFn = null,
    initialHeapSize: usize = 0,
    minHeapSize: usize = 0,
    heapGrowthPercent: c_int = 0,
    userData: Ptr = null,
};

pub extern fn wrenGetVersionNumber(...) c_int;
pub extern fn wrenInitConfiguration(configuration: *Configuration) void;
pub extern fn wrenNewVM(configuration: *Configuration) ?*VM;
pub extern fn wrenFreeVM(vm: *VM) void;
pub extern fn wrenCollectGarbage(vm: *VM) void;
pub extern fn wrenInterpret(vm: *VM, module: CStr, source: CStr) c_uint;

pub extern fn wrenCall(vm: *VM, method: *Handle) c_uint;
pub extern fn wrenMakeCallHandle(vm: *VM, signature: CStr) ?*Handle;
pub extern fn wrenReleaseHandle(vm: *VM, handle: *Handle) void;

pub extern fn wrenGetSlotCount(vm: *VM) c_int;
pub extern fn wrenEnsureSlots(vm: *VM, numSlots: c_int) void;
pub extern fn wrenGetSlotType(vm: *VM, slot: c_int) c_uint;

pub extern fn wrenGetSlotBool(vm: *VM, slot: c_int) bool;
pub extern fn wrenGetSlotBytes(vm: *VM, slot: c_int, length: *c_int) [*]const u8;
pub extern fn wrenGetSlotDouble(vm: *VM, slot: c_int) f64;
pub extern fn wrenGetSlotForeign(vm: *VM, slot: c_int) Ptr;
pub extern fn wrenGetSlotString(vm: *VM, slot: c_int) CStr;
pub extern fn wrenGetSlotHandle(vm: *VM, slot: c_int) ?*Handle;

pub extern fn wrenSetSlotBool(vm: *VM, slot: c_int, value: bool) void;
pub extern fn wrenSetSlotBytes(vm: *VM, slot: c_int, bytes: [*]const u8, length: usize) void;
pub extern fn wrenSetSlotDouble(vm: *VM, slot: c_int, value: f64) void;
pub extern fn wrenSetSlotNewForeign(vm: *VM, slot: c_int, classSlot: c_int, size: usize) Ptr;
pub extern fn wrenSetSlotNewList(vm: *VM, slot: c_int) void;
pub extern fn wrenSetSlotNewMap(vm: *VM, slot: c_int) void;
pub extern fn wrenSetSlotNull(vm: *VM, slot: c_int) void;
pub extern fn wrenSetSlotString(vm: *VM, slot: c_int, text: CStr) void;
pub extern fn wrenSetSlotHandle(vm: *VM, slot: c_int, handle: *Handle) void;

pub extern fn wrenGetListCount(vm: *VM, slot: c_int) c_int;
pub extern fn wrenGetListElement(vm: *VM, listSlot: c_int, index: c_int, elementSlot: c_int) void;
pub extern fn wrenSetListElement(vm: *VM, listSlot: c_int, index: c_int, elementSlot: c_int) void;
pub extern fn wrenInsertInList(vm: *VM, listSlot: c_int, index: c_int, elementSlot: c_int) void;

pub extern fn wrenGetMapCount(vm: *VM, slot: c_int) c_int;
pub extern fn wrenGetMapContainsKey(vm: *VM, mapSlot: c_int, keySlot: c_int) bool;
pub extern fn wrenGetMapValue(vm: *VM, mapSlot: c_int, keySlot: c_int, valueSlot: c_int) void;
pub extern fn wrenSetMapValue(vm: *VM, mapSlot: c_int, keySlot: c_int, valueSlot: c_int) void;
pub extern fn wrenRemoveMapValue(vm: *VM, mapSlot: c_int, keySlot: c_int, removedValueSlot: c_int) void;

pub extern fn wrenGetVariable(vm: *VM, module: CStr, name: CStr, slot: c_int) void;
pub extern fn wrenHasVariable(vm: *VM, module: CStr, name: CStr) bool;
pub extern fn wrenHasModule(vm: *VM, module: CStr) bool;

pub extern fn wrenAbortFiber(vm: *VM, slot: c_int) void;
pub extern fn wrenGetUserData(vm: *VM) Ptr;
pub extern fn wrenSetUserData(vm: *VM, userData: Ptr) void;

/// Convert a Zig function type to a C function pointer type.
fn Callback(comptime T: type) type {
    const t = @typeInfo(T);
    if (t != .@"fn") {
        @compileError("Expected a function type");
    }
    const fn_info = t.@"fn";

    const nullable_ptr = std.builtin.Type{
        .optional = .{
            .child = @Type(std.builtin.Type{
                .pointer = .{
                    .size = .one,
                    .is_const = true,
                    .is_volatile = false,
                    .alignment = @alignOf(T),
                    .address_space = .generic,
                    .is_allowzero = false,
                    .sentinel_ptr = null,
                    .child = @Type(std.builtin.Type{
                        .@"fn" = .{
                            .return_type = fn_info.return_type,
                            .params = fn_info.params,
                            .calling_convention = .C,
                            .is_generic = false,
                            .is_var_args = false,
                        },
                    }),
                },
            }),
        },
    };

    return @Type(nullable_ptr);
}
