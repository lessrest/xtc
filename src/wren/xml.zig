// XML to DOM conversion with Wren script execution
// Uses the clean module system implementation

const std = @import("std");
const dom_mod = @import("../dom.zig");
const xmlparse = @import("../xmlparse.zig");
const wren = @import("vm.zig");
const wren_xml_clean = @import("pageload.zig");

const Dom = dom_mod.Dom;
const DomNodeId = dom_mod.DomNodeId;

// Re-export the clean implementation
pub const buildDomAndRunScripts = wren_xml_clean.buildDomAndRunScripts;

// Backward compatibility wrapper
pub fn buildDomIntoAndRunScripts(
    comptime UserData: type,
    allocator: std.mem.Allocator,
    doc: *const xmlparse.Document,
    vm: *wren.ScriptEngine(UserData),
    document: *Dom,
) !void {
    try wren_xml_clean.buildDomAndRunScripts(UserData, allocator, doc, vm, document);
}
