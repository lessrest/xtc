const std = @import("std");

/// A single virtual machine for executing Wren code.
///
/// Wren has no global state, so all state stored by a running interpreter lives
/// here. Each VM is completely independent and can run different programs
/// concurrently without interference.
pub const VM = opaque {};

/// A handle to a Wren object.
///
/// This lets code outside of the VM hold a persistent reference to an object.
/// After a handle is acquired, and until it is released, this ensures the
/// garbage collector will not reclaim the object it references.
pub const Handle = opaque {};

/// The type of error being reported to the error callback.
pub const ErrorType = enum(c_int) {
    /// A syntax or resolution error detected at compile time.
    compile = 0,
    /// The error message for a runtime error.
    runtime = 1,
    /// One entry of a runtime error's stack trace.
    stack_trace = 2,
};

/// The result of executing Wren code.
pub const InterpretResult = enum(c_uint) {
    /// The code executed successfully.
    success = 0,
    /// A compile-time error occurred.
    compile_error = 1,
    /// A runtime error occurred.
    runtime_error = 2,
};

/// The type of an object stored in a slot.
///
/// This is not necessarily the object's *class*, but instead its low level
/// representation type.
pub const Type = enum(c_uint) {
    /// Boolean value (true or false).
    bool = 0,
    /// Numeric value (double-precision floating point).
    num = 1,
    /// Instance of a foreign class with native C data.
    foreign = 2,
    /// Wren list object.
    list = 3,
    /// Wren map object.
    map = 4,
    /// Null value.
    null = 5,
    /// String value.
    string = 6,
    /// The object is of a type that isn't accessible by the C API.
    unknown = 7,
};

const Ptr = ?*anyopaque;
const CStr = [*:0]const u8;

/// A generic allocation function that handles all explicit memory management
/// used by Wren.
///
/// - To allocate new memory, [memory] is NULL and [newSize] is the desired
///   size. It should return the allocated memory or NULL on failure.
/// - To attempt to grow an existing allocation, [memory] is the memory, and
///   [newSize] is the desired size. It should return [memory] if it was able to
///   grow it in place, or a new pointer if it had to move it.
/// - To shrink memory, [memory] and [newSize] are the same as above but it will
///   always return [memory].
/// - To free memory, [memory] will be the memory to free and [newSize] will be
///   zero. It should return NULL.
pub const ReallocateFn = Callback(
    fn (Ptr, usize, *anyopaque) Ptr,
);
/// A function callable from Wren code, but implemented in C.
///
/// Foreign methods receive the VM and can access arguments and return values
/// through the slot API. The receiver is in slot 0, followed by arguments.
pub const ForeignMethodFn = Callback(
    fn (*VM) void,
);
/// A finalizer function for freeing resources owned by an instance of a foreign
/// class.
///
/// Unlike most foreign methods, finalizers do not have access to the VM
/// and should not interact with it since it's in the middle of a garbage
/// collection.
pub const FinalizerFn = Callback(
    fn (Ptr) void,
);
/// Gives the host a chance to canonicalize the imported module name,
/// potentially taking into account the (previously resolved) name of the module
/// that contains the import.
///
/// Typically, this is used to implement relative imports. If an import cannot be
/// resolved by the embedder, it should return NULL and Wren will report that as a
/// runtime error. Wren will take ownership of the returned string and free it.
pub const ResolveModuleFn = Callback(
    fn (*VM, CStr, CStr) CStr,
);
/// Called after loadModuleFn is called for module [name].
///
/// The original returned result is handed back to you in this callback, so that
/// you can free memory if appropriate.
pub const LoadModuleCompleteFn = Callback(
    fn (*VM, CStr, LoadModuleResult) void,
);
/// Loads and returns the source code for the module [name].
///
/// Since Wren does not talk directly to the file system, it relies on the
/// embedder to physically locate and read the source code for a module.
/// This will only be called once for any given module name. Wren caches the
/// result internally so subsequent imports will use the previous source.
pub const LoadModuleFn = Callback(
    fn (*VM, CStr) LoadModuleResult,
);
/// Returns a pointer to a foreign method on [className] in [module] with
/// [signature].
///
/// When a foreign method is declared in a class, this will be called with the
/// foreign method's module, class, and signature when the class body is
/// executed. If the foreign function could not be found, this should return
/// NULL and Wren will report it as runtime error.
pub const BindForeignMethodFn = Callback(
    fn (*VM, CStr, CStr, bool, CStr) ForeignMethodFn,
);
/// Displays a string of text to the user.
///
/// This is called when `System.print()` or other related functions are called
/// from Wren code. If this is `NULL`, Wren discards any printed text.
pub const WriteFn = Callback(
    fn (*VM, CStr) void,
);
/// Reports an error to the user.
///
/// An error detected during compile time is reported by calling this once with
/// [type] `WREN_ERROR_COMPILE`, the resolved name of the [module] and [line]
/// where the error occurs, and the compiler's error [message].
///
/// A runtime error is reported by calling this once with [type]
/// `WREN_ERROR_RUNTIME`, no [module] or [line], and the runtime error's
/// [message]. After that, a series of [type] `WREN_ERROR_STACK_TRACE` calls are
/// made for each line in the stack trace.
pub const ErrorFn = Callback(
    fn (*VM, ErrorType, CStr, c_int, CStr) void,
);
/// Returns a pair of pointers to the foreign methods used to allocate and
/// finalize the data for instances of [className] in resolved [module].
///
/// When a foreign class is declared, this will be called with the class's
/// module and name when the class body is executed. It should return the
/// foreign functions used to allocate and (optionally) finalize the bytes
/// stored in the foreign object when an instance is created.
pub const BindForeignClassFn = Callback(
    fn (*VM, CStr, CStr) ForeignClassMethods,
);

/// The result of a loadModuleFn call.
pub const LoadModuleResult = extern struct {
    /// The source code for the module, or NULL if the module is not found.
    source: ?CStr = null,
    /// An optional callback that will be called once Wren is done with the result.
    onComplete: Ptr = null,
    /// User-defined data that can be passed to the onComplete callback.
    userData: Ptr = null,
};

/// Contains the foreign methods for allocating and finalizing instances
/// of a foreign class.
pub const ForeignClassMethods = extern struct {
    /// The callback invoked when the foreign object is created.
    /// This must be provided. Inside the body of this, it must call
    /// wrenSetSlotNewForeign() exactly once.
    allocate: ForeignMethodFn = null,
    /// The callback invoked when the garbage collector is about to collect a
    /// foreign object's memory. This may be `NULL` if the foreign class does not need to finalize.
    finalize: FinalizerFn = null,
};

/// Configuration settings for a Wren virtual machine.
///
/// Initialize this struct with `wrenInitConfiguration` before setting specific fields.
pub const Configuration = extern struct {
    /// The callback Wren will use to allocate, reallocate, and deallocate memory.
    /// If `NULL`, defaults to a built-in function that uses `realloc` and `free`.
    reallocateFn: ReallocateFn = null,

    /// The callback Wren uses to resolve a module name for relative imports.
    /// If you leave this function NULL, then the original import string is
    /// treated as the resolved string.
    resolveModuleFn: ResolveModuleFn = null,

    /// The callback Wren uses to load a module's source code.
    /// This will only be called once for any given module name. Wren caches the
    /// result internally so subsequent imports will use the previous source.
    loadModuleFn: LoadModuleFn = null,

    /// The callback Wren uses to find a foreign method and bind it to a class.
    /// If the foreign function could not be found, this should return NULL and
    /// Wren will report it as runtime error.
    bindForeignMethodFn: BindForeignMethodFn = null,

    /// The callback Wren uses to find a foreign class and get its foreign methods.
    /// Should return the foreign functions used to allocate and (optionally) finalize
    /// the bytes stored in the foreign object when an instance is created.
    bindForeignClassFn: BindForeignClassFn = null,

    /// The callback Wren uses to display text when `System.print()` or the other
    /// related functions are called. If this is `NULL`, Wren discards any printed text.
    writeFn: WriteFn = null,

    /// The callback Wren uses to report errors.
    /// If this is `NULL`, Wren doesn't report any errors.
    errorFn: ErrorFn = null,

    /// The number of bytes Wren will allocate before triggering the first garbage
    /// collection. If zero, defaults to 10MB.
    initialHeapSize: usize = 0,

    /// The minimum heap size threshold after garbage collection.
    /// This can be used to ensure that the heap does not get too small, which can
    /// lead to a large number of collections afterwards. If zero, defaults to 1MB.
    minHeapSize: usize = 0,

    /// The amount of additional memory Wren will use after a collection, as a
    /// percentage of the current heap size. Setting this to a smaller number wastes
    /// less memory, but triggers more frequent garbage collections. If zero, defaults to 50.
    heapGrowthPercent: c_int = 0,

    /// User-defined data associated with the VM.
    userData: Ptr = null,
};

/// Get the current wren version number.
///
/// Returns a monotonically increasing numeric representation that can be used
/// for range checks over versions. The version is calculated as:
/// MAJOR * 1000000 + MINOR * 1000 + PATCH
pub extern fn wrenGetVersionNumber(...) c_int;

/// Initializes [configuration] with all of its default values.
///
/// Call this before setting the particular fields you care about.
/// This sets up sensible defaults for all configuration options including
/// default heap sizes, growth percentages, and null callbacks.
pub extern fn wrenInitConfiguration(configuration: *Configuration) void;

/// Creates a new Wren virtual machine using the given [configuration].
///
/// Wren will copy the configuration data, so the argument passed to this can be
/// freed after calling this. If [configuration] is `NULL`, uses a default
/// configuration. Returns null on allocation failure.
///
/// The VM contains no global state - all interpreter state lives within the VM instance.
pub extern fn wrenNewVM(configuration: *Configuration) ?*VM;

/// Disposes of all resources in use by [vm], which was previously created by a
/// call to [wrenNewVM]. After calling this, the VM pointer is invalid and must
/// not be used.
pub extern fn wrenFreeVM(vm: *VM) void;

/// Immediately run the garbage collector to free unused memory.
///
/// Normally, Wren manages memory automatically, but this can be called to force
/// collection at a specific time. This is useful for testing or when you know
/// a good time to pause for collection.
pub extern fn wrenCollectGarbage(vm: *VM) void;

/// Runs [source], a string of Wren source code in a new fiber in [vm] in the
/// context of resolved [module].
///
/// The module name is used for error reporting and import resolution.
/// Returns a WrenInterpretResult indicating success, compile error, or runtime error.
pub extern fn wrenInterpret(vm: *VM, module: CStr, source: CStr) c_uint;

/// Calls [method], using the receiver and arguments previously set up on the stack.
///
/// [method] must have been created by a call to [wrenMakeCallHandle]. The
/// arguments to the method must be already on the stack. The receiver should be
/// in slot 0 with the remaining arguments following it, in order. It is an
/// error if the number of arguments provided does not match the method's signature.
///
/// After this returns, you can access the return value from slot 0 on the stack.
pub extern fn wrenCall(vm: *VM, method: *Handle) c_uint;

/// Creates a handle that can be used to invoke a method with [signature]
/// using a receiver and arguments that are set up on the stack.
///
/// This handle can be used repeatedly to directly invoke that method from C
/// code using [wrenCall]. The signature should be in the form "methodName(_,_)"
/// where each underscore represents a parameter.
///
/// When you are done with this handle, it must be released using [wrenReleaseHandle].
pub extern fn wrenMakeCallHandle(vm: *VM, signature: CStr) ?*Handle;

/// Releases the reference stored in [handle]. After calling this, [handle] can
/// no longer be used and the garbage collector may reclaim the referenced object
/// if no other references exist.
pub extern fn wrenReleaseHandle(vm: *VM, handle: *Handle) void;

/// Returns the number of slots available to the current foreign method.
///
/// Slots are used to pass values between C and Wren code. Each foreign method
/// receives slots for the receiver (slot 0) and each argument.
pub extern fn wrenGetSlotCount(vm: *VM) c_int;

/// Ensures that the foreign method stack has at least [numSlots] available for
/// use, growing the stack if needed.
///
/// Does not shrink the stack if it has more than enough slots.
/// It is an error to call this from a finalizer.
pub extern fn wrenEnsureSlots(vm: *VM, numSlots: c_int) void;

/// Gets the type of the object in [slot].
///
/// This returns the low-level representation type (bool, num, string, etc.),
/// not necessarily the object's class. Use this to determine what getter/setter
/// functions are appropriate for the slot.
pub extern fn wrenGetSlotType(vm: *VM, slot: c_int) c_uint;

/// Reads a boolean value from [slot].
///
/// It is an error to call this if the slot does not contain a boolean value.
/// Use wrenGetSlotType() to check the type first if unsure.
pub extern fn wrenGetSlotBool(vm: *VM, slot: c_int) bool;

/// Reads a byte array from [slot].
///
/// The memory for the returned string is owned by Wren. You can inspect it
/// while in your foreign method, but cannot keep a pointer to it after the
/// function returns, since the garbage collector may reclaim it.
///
/// Returns a pointer to the first byte of the array and fills [length] with the
/// number of bytes in the array. It is an error to call this if the slot does not contain a string.
pub extern fn wrenGetSlotBytes(vm: *VM, slot: c_int, length: *c_int) [*]const u8;

/// Reads a number from [slot].
///
/// All numbers in Wren are double-precision floating point.
/// It is an error to call this if the slot does not contain a number.
pub extern fn wrenGetSlotDouble(vm: *VM, slot: c_int) f64;

/// Reads a foreign object from [slot] and returns a pointer to the foreign data
/// stored with it.
///
/// Foreign objects are instances of foreign classes that store native C data.
/// It is an error to call this if the slot does not contain an instance of a foreign class.
pub extern fn wrenGetSlotForeign(vm: *VM, slot: c_int) Ptr;

/// Reads a string from [slot].
///
/// The memory for the returned string is owned by Wren. You can inspect it
/// while in your foreign method, but cannot keep a pointer to it after the
/// function returns, since the garbage collector may reclaim it.
///
/// It is an error to call this if the slot does not contain a string.
pub extern fn wrenGetSlotString(vm: *VM, slot: c_int) CStr;

/// Creates a handle for the value stored in [slot].
///
/// This will prevent the object that is referred to from being garbage collected
/// until the handle is released by calling [wrenReleaseHandle()]. Use handles to
/// maintain persistent references to Wren objects from C code.
pub extern fn wrenGetSlotHandle(vm: *VM, slot: c_int) ?*Handle;

/// Stores the boolean [value] in [slot].
pub extern fn wrenSetSlotBool(vm: *VM, slot: c_int, value: bool) void;

/// Stores the array [length] of [bytes] in [slot].
///
/// The bytes are copied to a new string within Wren's heap, so you can free
/// memory used by them after this is called. Use this instead of wrenSetSlotString
/// if the data may contain null bytes.
pub extern fn wrenSetSlotBytes(vm: *VM, slot: c_int, bytes: [*]const u8, length: usize) void;

/// Stores the numeric [value] in [slot].
///
/// All numbers in Wren are double-precision floating point.
pub extern fn wrenSetSlotDouble(vm: *VM, slot: c_int, value: f64) void;

/// Creates a new instance of the foreign class stored in [classSlot] with [size]
/// bytes of raw storage and places the resulting object in [slot].
///
/// This does not invoke the foreign class's constructor on the new instance. If
/// you need that to happen, call the constructor from Wren, which will then
/// call the allocator foreign method. In there, call this to create the object
/// and then the constructor will be invoked when the allocator returns.
///
/// Returns a pointer to the foreign object's data.
pub extern fn wrenSetSlotNewForeign(vm: *VM, slot: c_int, classSlot: c_int, size: usize) Ptr;

/// Stores a new empty list in [slot].
///
/// Use wrenInsertInList() and other list functions to populate the list.
pub extern fn wrenSetSlotNewList(vm: *VM, slot: c_int) void;

/// Stores a new empty map in [slot].
///
/// Use wrenSetMapValue() and other map functions to populate the map.
pub extern fn wrenSetSlotNewMap(vm: *VM, slot: c_int) void;

/// Stores null in [slot].
pub extern fn wrenSetSlotNull(vm: *VM, slot: c_int) void;

/// Stores the string [text] in [slot].
///
/// The [text] is copied to a new string within Wren's heap, so you can free
/// memory used by it after this is called. The length is calculated using
/// strlen(). If the string may contain any null bytes in the middle, then you
/// should use [wrenSetSlotBytes()] instead.
pub extern fn wrenSetSlotString(vm: *VM, slot: c_int, text: CStr) void;

/// Stores the value captured in [handle] in [slot].
///
/// This does not release the handle for the value. You must still call
/// wrenReleaseHandle() when you're done with the handle.
pub extern fn wrenSetSlotHandle(vm: *VM, slot: c_int, handle: *Handle) void;

/// Returns the number of elements in the list stored in [slot].
///
/// It is an error to call this if the slot does not contain a list.
pub extern fn wrenGetListCount(vm: *VM, slot: c_int) c_int;

/// Reads element [index] from the list in [listSlot] and stores it in [elementSlot].
///
/// Negative indices count from the end of the list. It is an error if the index
/// is out of bounds or if [listSlot] does not contain a list.
pub extern fn wrenGetListElement(vm: *VM, listSlot: c_int, index: c_int, elementSlot: c_int) void;

/// Sets the value stored at [index] in the list at [listSlot],
/// to the value from [elementSlot].
///
/// It is an error if the index is out of bounds or if [listSlot] does not contain a list.
pub extern fn wrenSetListElement(vm: *VM, listSlot: c_int, index: c_int, elementSlot: c_int) void;

/// Takes the value stored at [elementSlot] and inserts it into the list stored
/// at [listSlot] at [index].
///
/// As in Wren, negative indexes can be used to insert from the end. To append
/// an element, use `-1` for the index.
pub extern fn wrenInsertInList(vm: *VM, listSlot: c_int, index: c_int, elementSlot: c_int) void;

/// Returns the number of entries in the map stored in [slot].
///
/// It is an error to call this if the slot does not contain a map.
pub extern fn wrenGetMapCount(vm: *VM, slot: c_int) c_int;

/// Returns true if the key in [keySlot] is found in the map placed in [mapSlot].
///
/// It is an error if [mapSlot] does not contain a map.
pub extern fn wrenGetMapContainsKey(vm: *VM, mapSlot: c_int, keySlot: c_int) bool;

/// Retrieves a value with the key in [keySlot] from the map in [mapSlot] and
/// stores it in [valueSlot].
///
/// If the key is not found, null is stored in [valueSlot]. It is an error if
/// [mapSlot] does not contain a map.
pub extern fn wrenGetMapValue(vm: *VM, mapSlot: c_int, keySlot: c_int, valueSlot: c_int) void;

/// Takes the value stored at [valueSlot] and inserts it into the map stored
/// at [mapSlot] with key [keySlot].
///
/// If the key already exists, its value is replaced. It is an error if
/// [mapSlot] does not contain a map.
pub extern fn wrenSetMapValue(vm: *VM, mapSlot: c_int, keySlot: c_int, valueSlot: c_int) void;

/// Removes a value from the map in [mapSlot], with the key from [keySlot],
/// and places it in [removedValueSlot]. If not found, [removedValueSlot] is
/// set to null, the same behaviour as the Wren Map API.
///
/// It is an error if [mapSlot] does not contain a map.
pub extern fn wrenRemoveMapValue(vm: *VM, mapSlot: c_int, keySlot: c_int, removedValueSlot: c_int) void;

/// Looks up the top level variable with [name] in resolved [module] and stores
/// it in [slot].
///
/// It is an error if the variable or module is not found. Use wrenHasVariable()
/// and wrenHasModule() to check for existence first.
pub extern fn wrenGetVariable(vm: *VM, module: CStr, name: CStr, slot: c_int) void;

/// Looks up the top level variable with [name] in resolved [module],
/// returns false if not found. The module must be imported at the time,
/// use wrenHasModule to ensure that before calling.
pub extern fn wrenHasVariable(vm: *VM, module: CStr, name: CStr) bool;

/// Returns true if [module] has been imported/resolved before, false if not.
///
/// Use this to check if a module exists before calling wrenHasVariable() or
/// wrenGetVariable().
pub extern fn wrenHasModule(vm: *VM, module: CStr) bool;

/// Sets the current fiber to be aborted, and uses the value in [slot] as the
/// runtime error object.
///
/// This immediately terminates execution of the current fiber and propagates
/// the error up the call stack. The error object can be any Wren value.
pub extern fn wrenAbortFiber(vm: *VM, slot: c_int) void;

/// Returns the user data associated with the WrenVM.
///
/// This is the same value that was set in the WrenConfiguration when the VM
/// was created, or by a previous call to wrenSetUserData().
pub extern fn wrenGetUserData(vm: *VM) Ptr;

/// Sets user data associated with the WrenVM.
///
/// This arbitrary pointer can be retrieved later with wrenGetUserData().
/// Useful for storing application-specific context with the VM.
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
                            .calling_convention = .c,
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
