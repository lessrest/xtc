const std = @import("std");
const dom = @import("dom.zig");
const xmlparse = @import("xmlparse.zig");
const wren_xml = @import("wren/xml.zig");
const WrenRunner = @import("wren/runtime.zig");
const ticket = @import("ticket.zig");

pub const LoadResult = struct {
    root_id: dom.DomNodeId,
    had_scripts: bool = false,
};

/// Document loading strategies
pub const DocumentLoader = struct {
    allocator: std.mem.Allocator,
    document: *dom.Dom,
    wren_runner: *WrenRunner,
    
    pub fn init(allocator: std.mem.Allocator, document: *dom.Dom, wren_runner: *WrenRunner) DocumentLoader {
        return .{
            .allocator = allocator,
            .document = document,
            .wren_runner = wren_runner,
        };
    }
    
    /// Load from XML file with optional embedded scripts
    pub fn loadXmlFile(self: *DocumentLoader, path: []const u8) !LoadResult {
        const xml_content = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
        defer self.allocator.free(xml_content);
        
        return try self.loadXmlString(xml_content, path);
    }
    
    /// Load from XML string with optional embedded scripts
    pub fn loadXmlString(self: *DocumentLoader, xml_content: []const u8, source_name: []const u8) !LoadResult {
        var reader = std.io.fixedBufferStream(xml_content);
        var xml_doc = try xmlparse.parse(self.allocator, source_name, reader.reader());
        defer xml_doc.deinit();
        
        // Build DOM and execute any embedded scripts
        try wren_xml.buildDomIntoAndRunScripts(
            WrenRunner.ScriptContext,
            self.allocator,
            &xml_doc,
            &self.wren_runner.vm,
            self.document,
        );
        
        // Determine root element
        const headers = self.document.headers.slice();
        if (headers.len > 0) {
            return .{ .root_id = 0, .had_scripts = containsScripts(&xml_doc) };
        } else {
            // Create a default root if XML was empty
            const root_id = try self.document.addElement("flex bg-slate-900");
            return .{ .root_id = root_id, .had_scripts = false };
        }
    }
    
    /// Load from Wren script file
    pub fn loadWrenFile(self: *DocumentLoader, path: []const u8) !LoadResult {
        const wren_content = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
        defer self.allocator.free(wren_content);
        
        return try self.loadWrenString(wren_content, path);
    }
    
    /// Load from Wren script string
    pub fn loadWrenString(self: *DocumentLoader, script: []const u8, source_name: []const u8) !LoadResult {
        // Create a basic root element
        const root_id = try self.document.addElement("flex");
        try self.document.setDebugId(root_id, "root");
        
        // Run the Wren script which will populate the DOM
        const script_id = ticket.from(source_name) catch blk: {
            break :blk ticket.from("inline") catch @panic("Failed to generate script ID");
        };
        try self.wren_runner.vm.interpret(&script_id, script);
        
        return .{ .root_id = root_id, .had_scripts = true };
    }
    
    /// Create default demo UI
    pub fn createDefault(self: *DocumentLoader) !LoadResult {
        const root_id = try self.document.addElement("flex flex-col bg-slate-900 items-center justify-center");
        try self.document.setDebugId(root_id, "root");
        
        const text_id = try self.document.addText("No content provided. Use --xml <file> or --wren <file> to load content.");
        self.document.appendChild(root_id, text_id);
        
        return .{ .root_id = root_id, .had_scripts = false };
    }
    
    fn containsScripts(xml_doc: anytype) bool {
        // Check if XML contains any <script> elements
        // This is a simplified check - implement based on your XML structure
        _ = xml_doc;
        return false; // TODO: Implement script detection
    }
};