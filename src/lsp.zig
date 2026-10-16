//! `rig lsp`: a language server (LSP 3.17) on stdin and stdout.
//!
//! Messages are JSON-RPC, each after a `Content-Length` header. The server
//! keeps the text of each open document (full sync) and answers:
//!
//!   * diagnostics: the parse errors of the text as it is typed, and on
//!     open and save the diagnostics `rig check` gives for the document as
//!     the root of its program, read through the same path `rig check`
//!     takes (`modules.ModuleGraph`), each with its notes;
//!   * semantic tokens, document symbols, and folding ranges, from
//!     `src/editor.zig`.
//!
//! Positions are lines and characters in UTF-16 code units, or in bytes
//! when the client offers `utf-8` among its `positionEncodings`. Every
//! request and notification is handled before the next is read; the
//! memory of each lives in an arena freed when it is answered.

const std = @import("std");
const build_options = @import("build_options");
const diag = @import("diag.zig");
const modules = @import("modules.zig");
const inlining = @import("inlining.zig");
const editor = @import("editor.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// The largest message the server reads.
pub const max_message_bytes = 64 << 20;

// =============================================================================
// Framing
// =============================================================================

pub const FrameError = error{
    /// A header line is malformed, or `Content-Length` is missing.
    BadHeader,
    /// `Content-Length` is over `max_message_bytes`.
    MessageTooLarge,
};

/// The body of the next message from `r`, allocated in `a`; null at the
/// end of input between messages.
pub fn readMessage(r: *std.Io.Reader, a: Allocator) (FrameError || Allocator.Error || std.Io.Reader.Error)!?[]u8 {
    var length: ?usize = null;
    var headers = false;
    while (true) {
        const raw = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.BadHeader,
            error.ReadFailed => return error.ReadFailed,
        } orelse {
            if (headers) return error.EndOfStream;
            return null;
        };
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (headers) break;
            continue;
        }
        headers = true;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return error.BadHeader;
        length = n;
    }
    const n = length orelse return error.BadHeader;
    if (n > max_message_bytes) return error.MessageTooLarge;
    return try r.readAllocAll(a, n);
}

/// Write `body` as one message.
pub fn writeMessage(w: *std.Io.Writer, body: []const u8) std.Io.Writer.Error!void {
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
    try w.flush();
}

// =============================================================================
// Positions
// =============================================================================

/// How a position counts the characters of a line.
pub const Encoding = enum {
    utf16,
    utf8,

    fn name(e: Encoding) []const u8 {
        return switch (e) {
            .utf16 => "utf-16",
            .utf8 => "utf-8",
        };
    }
};

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };

/// The lines of a text, to turn byte offsets into positions. A line ends
/// at `\n`, `\r\n`, or a lone `\r`, as the protocol says. A UTF-8 byte
/// order mark at the start is no part of the first line, as an editor
/// shows it.
pub const Lines = struct {
    text: []const u8,
    /// The offset where each line starts.
    starts: []const u32,
    encoding: Encoding,

    pub fn init(a: Allocator, text: []const u8, encoding: Encoding) Allocator.Error!Lines {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(a, if (std.mem.startsWith(u8, text, bom)) bom.len else 0);
        var i: usize = 0;
        while (i < text.len) : (i += 1) switch (text[i]) {
            '\n' => try starts.append(a, @intCast(i + 1)),
            '\r' => if (i + 1 < text.len and text[i + 1] == '\n') {
                i += 1;
                try starts.append(a, @intCast(i + 1));
            } else try starts.append(a, @intCast(i + 1)),
            else => {},
        };
        return .{ .text = text, .starts = starts.items, .encoding = encoding };
    }

    /// The position of byte `offset` (clamped to the text). An offset
    /// inside a character, or inside a line's ending, is the position
    /// before it.
    pub fn position(self: Lines, offset: u32) Position {
        var c: Cursor = .{ .lines = self };
        return c.position(offset);
    }

    pub fn range(self: Lines, start: u32, end: u32) Range {
        var c: Cursor = .{ .lines = self };
        return .{ .start = c.position(start), .end = c.position(@max(start, end)) };
    }

    /// The line `at` is on: the last that starts at or before it.
    fn lineOf(self: Lines, at: u32) u32 {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.starts[mid] <= at) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// Where the text of `line` ends, before its line ending.
    pub fn lineEnd(self: Lines, line: u32) u32 {
        if (line + 1 >= self.starts.len) return @intCast(self.text.len);
        var end = self.starts[line + 1];
        if (end > 0 and self.text[end - 1] == '\n') end -= 1;
        if (end > 0 and self.text[end - 1] == '\r') end -= 1;
        return @max(end, self.starts[line]);
    }
};

/// Positions of offsets in ascending order, each counted on from the one
/// before on its line, so a line's characters are counted once however
/// many offsets it holds. An offset before the last starts the count again.
pub const Cursor = struct {
    lines: Lines,
    line: u32 = 0,
    /// The offset counted to on `line`, and its units from the line's start.
    at: u32 = 0,
    units: u32 = 0,
    counted: bool = false,

    pub fn position(c: *Cursor, offset: u32) Position {
        const text = c.lines.text;
        const at: u32 = @intCast(@min(offset, text.len));
        const line = c.lines.lineOf(at);
        const start = c.lines.starts[line];
        if (!c.counted or line != c.line or at < c.at) c.* = .{ .lines = c.lines, .line = line, .at = start, .units = 0, .counted = true };
        if (at < start) return .{ .line = line, .character = 0 };
        var i: usize = c.at;
        while (i < at) {
            const ch = text[i];
            if (ch == '\n' or ch == '\r') break;
            const n = sequenceLength(text[i..]);
            if (i + n > at) break;
            c.units += switch (c.lines.encoding) {
                .utf8 => @intCast(n),
                .utf16 => if (n == 4) 2 else 1,
            };
            i += n;
        }
        c.at = @intCast(i);
        return .{ .line = line, .character = c.units };
    }
};

const bom = "\xEF\xBB\xBF";

/// The bytes of the UTF-8 character `s` starts with; 1 for a byte that
/// starts none, or a sequence cut short.
fn sequenceLength(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 1;
    if (n > s.len) return 1;
    for (s[1..n]) |c| if (c & 0xC0 != 0x80) return 1;
    return n;
}

// =============================================================================
// URIs
// =============================================================================

/// The path a `file:` URI names, percent-decoded; null for any other URI.
pub fn uriToPath(a: Allocator, uri: []const u8) Allocator.Error!?[]u8 {
    const scheme = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, scheme)) return null;
    var rest = uri[scheme.len..];
    // An authority: empty or `localhost`, for a file on this machine.
    const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    if (host.len > 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
    rest = rest[slash..];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const byte = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch {
                try out.append(a, '%');
                continue;
            };
            try out.append(a, byte);
            i += 2;
        } else try out.append(a, rest[i]);
    }
    return out.items;
}

/// The `file:` URI of an absolute path, every byte but the unreserved
/// ones and `/` percent-encoded.
pub fn pathToUri(a: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "-._~/", c) != null) {
            try out.append(a, c);
        } else try out.print(a, "%{X:0>2}", .{c});
    }
    return out.items;
}

// =============================================================================
// The server
// =============================================================================

/// JSON-RPC and LSP error codes.
const Code = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    server_not_initialized = -32002,
};

/// `rig lsp`: serve until `exit` or the end of input. The exit status is
/// 0 after `shutdown` then `exit`, else 1, as the protocol says. Memory
/// comes from a checking allocator; a leak at the end is reported on
/// stderr and makes the status 1.
pub fn run(io: std.Io, environ: *const std.process.Environ.Map) u8 {
    const trace = if (environ.get("RIG_LEAK_TRACE")) |v| v.len > 0 and !std.mem.eql(u8, v, "0") else false;
    var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{
        .stack_trace_frames = if (trace) 8 else 0,
        .check_write_after_free = true,
    });
    var status: u8 = 1;
    {
        var in_buffer: [64 * 1024]u8 = undefined;
        var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);
        var out_buffer: [64 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
        var server: Server = .{ .gpa = sa.allocator(), .io = io, .out = &out.interface, .std_dir = nonEmpty(environ.get("RIG_STD")) };
        defer server.deinit();
        status = server.serve(&in.interface);
    }
    const leaks = sa.deinit();
    if (leaks > 0) {
        std.debug.print("rig lsp: {d} allocation{s} leaked\n", .{ leaks, if (leaks == 1) "" else "s" });
        return 1;
    }
    return status;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

/// An open document.
const Doc = struct {
    uri: []u8,
    text: []u8,
    version: i64,
    /// The diagnostics of the last full check (a JSON array), and a hash
    /// of the text it checked; they are shown while the text is that text.
    checked: ?[]u8 = null,
    checked_hash: u64 = 0,
    /// The other files the last full check published diagnostics to.
    others: std.ArrayList([]u8) = .empty,

    fn deinit(d: *Doc, gpa: Allocator) void {
        gpa.free(d.uri);
        gpa.free(d.text);
        if (d.checked) |c| gpa.free(c);
        for (d.others.items) |o| gpa.free(o);
        d.others.deinit(gpa);
    }
};

const Server = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    /// `$RIG_STD`, as `rig check` reads it.
    std_dir: ?[]const u8,
    encoding: Encoding = .utf16,
    /// `initialize` was answered.
    initialized: bool = false,
    /// `shutdown` was answered.
    shut_down: bool = false,
    docs: std.ArrayList(Doc) = .empty,

    fn deinit(s: *Server) void {
        for (s.docs.items) |*d| d.deinit(s.gpa);
        s.docs.deinit(s.gpa);
    }

    /// Read and handle messages; the exit status.
    fn serve(s: *Server, in: *std.Io.Reader) u8 {
        while (true) {
            var arena = std.heap.ArenaAllocator.init(s.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const body = readMessage(in, a) catch |err| {
                std.debug.print("rig lsp: cannot read a message: {s}\n", .{@errorName(err)});
                return 1;
            } orelse return 1;
            const exit = s.handle(a, body) catch |err| {
                std.debug.print("rig lsp: {s}\n", .{@errorName(err)});
                return 1;
            };
            if (exit) |code| return code;
        }
    }

    /// Handle one message; the exit status once it is `exit`.
    fn handle(s: *Server, a: Allocator, body: []const u8) !?u8 {
        const msg = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch {
            try s.respondError(a, .null, .parse_error, "the message is not JSON");
            return null;
        };
        if (msg != .object) {
            try s.respondError(a, .null, .invalid_request, "a message is a JSON object");
            return null;
        }
        const id = msg.object.get("id");
        const method = msg.object.get("method") orelse return null; // a response: the server sends no requests
        if (method != .string) {
            if (id) |i| try s.respondError(a, i, .invalid_request, "`method` is a string");
            return null;
        }
        const params = msg.object.get("params") orelse .null;
        if (id) |i| {
            try s.request(a, i, method.string, params);
            return null;
        }
        return s.notification(a, method.string, params);
    }

    fn request(s: *Server, a: Allocator, id: Value, method: []const u8, params: Value) !void {
        if (eql(method, "initialize")) {
            if (s.initialized) return s.respondError(a, id, .invalid_request, "`initialize` was already called");
            s.encoding = negotiate(params);
            s.initialized = true;
            return s.respond(a, id, InitializeResult{
                .capabilities = .{ .positionEncoding = s.encoding.name() },
                .serverInfo = .{ .name = "rig", .version = build_options.version },
            });
        }
        if (!s.initialized) return s.respondError(a, id, .server_not_initialized, "`initialize` comes first");
        if (s.shut_down) return s.respondError(a, id, .invalid_request, "the server is shutting down");
        if (eql(method, "shutdown")) {
            s.shut_down = true;
            return s.respond(a, id, null);
        }
        if (eql(method, "textDocument/semanticTokens/full")) {
            const d = s.docOf(params) orelse return s.respond(a, id, null);
            return s.respond(a, id, .{ .data = try s.semanticTokens(a, d.text) });
        }
        if (eql(method, "textDocument/documentSymbol")) {
            const d = s.docOf(params) orelse return s.respond(a, id, null);
            return s.respond(a, id, try s.documentSymbols(a, d.text));
        }
        if (eql(method, "textDocument/foldingRange")) {
            const d = s.docOf(params) orelse return s.respond(a, id, null);
            return s.respond(a, id, try s.foldingRanges(a, d.text));
        }
        try s.respondError(a, id, .method_not_found, try a.print("unknown method `{s}`", .{method}));
    }

    fn notification(s: *Server, a: Allocator, method: []const u8, params: Value) !?u8 {
        if (eql(method, "exit")) return if (s.shut_down) 0 else 1;
        if (!s.initialized) return null;
        if (eql(method, "textDocument/didOpen")) {
            const td = field(params, "textDocument");
            const uri = string(field(td, "uri")) orelse return null;
            const text = string(field(td, "text")) orelse return null;
            const version = integer(field(td, "version")) orelse 0;
            const d = try s.open(uri, text, version);
            try s.check(a, d);
            try s.publish(a, d);
        } else if (eql(method, "textDocument/didChange")) {
            const d = s.docOf(params) orelse return null;
            const changes = field(params, "contentChanges");
            if (changes != .array or changes.array.items.len == 0) return null;
            // Full sync: each change holds the whole text; the last wins.
            const text = string(field(changes.array.items[changes.array.items.len - 1], "text")) orelse return null;
            const copy = try s.gpa.dupe(u8, text);
            s.gpa.free(d.text);
            d.text = copy;
            d.version = integer(field(field(params, "textDocument"), "version")) orelse d.version;
            try s.publish(a, d);
        } else if (eql(method, "textDocument/didSave")) {
            const d = s.docOf(params) orelse return null;
            try s.check(a, d);
            try s.publish(a, d);
        } else if (eql(method, "textDocument/didClose")) {
            const uri = string(field(field(params, "textDocument"), "uri")) orelse return null;
            for (s.docs.items, 0..) |*d, i| if (eql(d.uri, uri)) {
                var gone = d.*;
                _ = s.docs.swapRemove(i);
                defer gone.deinit(s.gpa);
                try s.publishRaw(a, gone.uri, null, "[]");
                // A file the closed one's check published to keeps what
                // another open file's check put there.
                for (gone.others.items) |o| if (s.findDoc(o) == null and !s.publishesTo(o)) try s.publishRaw(a, o, null, "[]");
                break;
            };
        }
        // Every other notification (`initialized`, `$/cancelRequest`, ...)
        // asks nothing of this server.
        return null;
    }

    /// The position encoding: UTF-8 when the client offers it, else the
    /// protocol's default, UTF-16.
    fn negotiate(params: Value) Encoding {
        const offered = field(field(field(params, "capabilities"), "general"), "positionEncodings");
        if (offered != .array) return .utf16;
        for (offered.array.items) |e| if (e == .string and eql(e.string, "utf-8")) return .utf8;
        return .utf16;
    }

    /// Whether an open document's last check published to `uri`.
    fn publishesTo(s: *Server, uri: []const u8) bool {
        for (s.docs.items) |d| for (d.others.items) |o| if (eql(o, uri)) return true;
        return false;
    }

    fn findDoc(s: *Server, uri: []const u8) ?*Doc {
        for (s.docs.items) |*d| if (eql(d.uri, uri)) return d;
        return null;
    }

    /// The open document `params.textDocument.uri` names.
    fn docOf(s: *Server, params: Value) ?*Doc {
        const uri = string(field(field(params, "textDocument"), "uri")) orelse return null;
        return s.findDoc(uri);
    }

    fn open(s: *Server, uri: []const u8, text: []const u8, version: i64) !*Doc {
        if (s.findDoc(uri)) |d| {
            const copy = try s.gpa.dupe(u8, text);
            s.gpa.free(d.text);
            d.text = copy;
            d.version = version;
            return d;
        }
        const u = try s.gpa.dupe(u8, uri);
        errdefer s.gpa.free(u);
        const t = try s.gpa.dupe(u8, text);
        errdefer s.gpa.free(t);
        try s.docs.append(s.gpa, .{ .uri = u, .text = t, .version = version });
        return &s.docs.items[s.docs.items.len - 1];
    }

    // -------------------------------------------------------------------------
    // Diagnostics
    // -------------------------------------------------------------------------

    /// Publish the diagnostics of `d`: the last full check's while the
    /// text is the text it checked; else the parse errors of the text.
    fn publish(s: *Server, a: Allocator, d: *Doc) !void {
        if (d.checked) |json| if (std.hash.Wyhash.hash(0, d.text) == d.checked_hash) return s.publishRaw(a, d.uri, d.version, json);
        const found = try editor.parseDiagnostics(a, d.text);
        var files: Files = .{ .a = a, .encoding = s.encoding };
        var items: std.ArrayList(Item) = .empty;
        try addDiagnostics(a, &items, found, .{ .source = d.text, .path = "" }, &.{}, .home, null);
        try s.publishRaw(a, d.uri, d.version, try files.json(items.items, "", d.uri, s.io));
    }

    /// Check the program `d` is the root of, as `rig check` does, from the
    /// text of `d`; keep its diagnostics for `d`, and publish those in
    /// other files of the program.
    fn check(s: *Server, a: Allocator, d: *Doc) !void {
        const path = (try uriToPath(a, d.uri)) orelse return;
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const ga = arena.allocator();
        var graph = modules.ModuleGraph.init(ga, s.io);
        defer graph.deinit();
        graph.std_dir = s.std_dir;
        graph.root_source = d.text;
        try graph.loadRoot(path);
        if (!graph.hasErrors()) try inlining.decide(ga, &graph, inlining.max_size);

        // Every diagnostic of every module, in the order `rig check`
        // prints them, by the file it is in.
        const all = try a.alloc(diag.File, graph.modules.items.len);
        const shown = try a.alloc(bool, graph.modules.items.len);
        for (graph.modules.items, all, shown) |m, *f, *ok| {
            f.* = .{ .source = m.source, .path = m.display, .parts = m.parts };
            // The standard library built into the compiler has no file to
            // open.
            ok.* = !(m.is_std and s.std_dir == null);
        }
        var items: std.ArrayList(Item) = .empty;
        for (graph.errors.items) |message| try items.append(a, .{ .path = path, .text = d.text, .start = 0, .end = 0, .severity = .@"error", .message = try a.dupe(u8, message) });
        // As many errors as `rig check` prints (`writeAllDiagnostics`).
        var budget: u32 = diag.max_errors;
        for (graph.modules.items, all, shown) |m, home, ok| {
            // The errors of a module no editor can open still count.
            if (!ok) {
                for (m.sema.diagnostics.items) |x| if (x.severity == .@"error") {
                    budget -|= 1;
                };
                continue;
            }
            try addDiagnostics(a, &items, m.sema.diagnostics.items, home, all, .{ .shown = shown }, &budget);
        }
        // Copy what the graph holds before it goes: each file's path, made
        // absolute as its URI is, and its text once, and each message.
        var copies: std.StringHashMapUnmanaged([2][]const u8) = .empty;
        for (items.items) |*it| {
            const file = try copyFile(a, s.io, &copies, it.path, it.text);
            it.path = file[0];
            it.text = file[1];
            it.message = try a.dupe(u8, it.message);
            for (it.related.items) |*r| {
                const rf = try copyFile(a, s.io, &copies, r.path, r.text);
                r.path = rf[0];
                r.text = rf[1];
                r.message = try a.dupe(u8, r.message);
            }
        }

        var files: Files = .{ .a = a, .encoding = s.encoding };
        const own_json = try files.json(items.items, path, d.uri, s.io);
        const kept = try s.gpa.dupe(u8, own_json);
        if (d.checked) |old| s.gpa.free(old);
        d.checked = kept;
        d.checked_hash = std.hash.Wyhash.hash(0, d.text);

        // The other files: each once, in order, unless it is open (its own
        // check speaks for it). `d` holds them from here on.
        var old = d.others;
        d.others = .empty;
        defer {
            for (old.items) |o| s.gpa.free(o);
            old.deinit(s.gpa);
        }
        for (items.items) |it| {
            if (eql(it.path, path)) continue;
            const uri = try pathToUri(a, it.path);
            if (s.findDoc(uri) != null) continue;
            for (d.others.items) |o| {
                if (eql(o, uri)) break;
            } else {
                const owned = try s.gpa.dupe(u8, uri);
                d.others.append(s.gpa, owned) catch |err| {
                    s.gpa.free(owned);
                    return err;
                };
            }
        }
        for (d.others.items) |uri| {
            const file = try uriToPath(a, uri) orelse continue;
            try s.publishRaw(a, uri, null, try files.json(items.items, file, uri, s.io));
        }
        // Clear the files the last check published to and this one did not.
        for (old.items) |o| {
            for (d.others.items) |now| {
                if (eql(o, now)) break;
            } else if (s.findDoc(o) == null and !s.publishesTo(o)) try s.publishRaw(a, o, null, "[]");
        }
    }

    /// Send `textDocument/publishDiagnostics` with a JSON array of them.
    fn publishRaw(s: *Server, a: Allocator, uri: []const u8, version: ?i64, diagnostics: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(a);
        var j: std.json.Stringify = .{ .writer = &out.writer };
        try j.beginObject();
        try j.objectField("jsonrpc");
        try j.write("2.0");
        try j.objectField("method");
        try j.write("textDocument/publishDiagnostics");
        try j.objectField("params");
        try j.beginObject();
        try j.objectField("uri");
        try j.write(uri);
        if (version) |v| {
            try j.objectField("version");
            try j.write(v);
        }
        try j.objectField("diagnostics");
        try j.beginWriteRaw();
        try out.writer.writeAll(diagnostics);
        j.endWriteRaw();
        try j.endObject();
        try j.endObject();
        try writeMessage(s.out, out.written());
    }

    // -------------------------------------------------------------------------
    // Requests on a document
    // -------------------------------------------------------------------------

    fn semanticTokens(s: *Server, a: Allocator, text: []const u8) ![]const u32 {
        var parsed = try editor.Parsed.init(a, text);
        defer parsed.deinit();
        const toks = try editor.tokens(a, text, &parsed);
        const lines = try Lines.init(a, text, s.encoding);
        var data: std.ArrayList(u32) = .empty;
        var prev: Position = .{ .line = 0, .character = 0 };
        // The tokens come in order, so one cursor counts each line once.
        var cursor: Cursor = .{ .lines = lines };
        for (toks) |t| {
            const start = cursor.position(t.pos);
            // A token is cut at the end of its line.
            const end = cursor.position(@min(t.end, lines.lineEnd(start.line)));
            if (end.line != start.line or end.character <= start.character) continue;
            const delta_line = start.line - prev.line;
            try data.appendSlice(a, &.{
                delta_line,
                if (delta_line == 0) start.character - prev.character else start.character,
                end.character - start.character,
                @backingInt(t.kind),
                t.modifiers,
            });
            prev = start;
        }
        return data.items;
    }

    fn documentSymbols(s: *Server, a: Allocator, text: []const u8) ![]const DocumentSymbol {
        var parsed = try editor.Parsed.init(a, text);
        defer parsed.deinit();
        const lines = try Lines.init(a, text, s.encoding);
        return convertSymbols(a, lines, try editor.symbols(a, &parsed));
    }

    fn convertSymbols(a: Allocator, lines: Lines, syms: []const editor.Symbol) ![]const DocumentSymbol {
        const out = try a.alloc(DocumentSymbol, syms.len);
        for (syms, out) |sym, *o| o.* = .{
            .name = sym.name,
            .detail = sym.detail,
            .kind = @backingInt(sym.kind),
            .range = lines.range(sym.span.start, sym.span.end),
            .selectionRange = lines.range(sym.name_span.start, sym.name_span.end),
            .children = try convertSymbols(a, lines, sym.children),
        };
        return out;
    }

    fn foldingRanges(s: *Server, a: Allocator, text: []const u8) ![]const FoldingRange {
        const lines = try Lines.init(a, text, s.encoding);
        var out: std.ArrayList(FoldingRange) = .empty;
        for (try editor.folds(a, text)) |f| {
            const start = lines.position(f.start).line;
            const end = lines.position(f.end).line;
            if (end <= start) continue;
            try out.append(a, .{ .startLine = start, .endLine = end, .kind = if (f.comment) "comment" else null });
        }
        std.mem.sort(FoldingRange, out.items, {}, struct {
            fn lt(_: void, x: FoldingRange, y: FoldingRange) bool {
                return x.startLine < y.startLine or (x.startLine == y.startLine and x.endLine > y.endLine);
            }
        }.lt);
        return out.items;
    }

    // -------------------------------------------------------------------------
    // Responses
    // -------------------------------------------------------------------------

    fn respond(s: *Server, a: Allocator, id: Value, result: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{ .emit_null_optional_fields = false });
        try writeMessage(s.out, body);
    }

    fn respondError(s: *Server, a: Allocator, id: Value, code: Code, message: []const u8) !void {
        const body = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @backingInt(code), .message = message } }, .{});
        try writeMessage(s.out, body);
    }
};

// =============================================================================
// Diagnostics, from the compiler's to the protocol's
// =============================================================================

/// One diagnostic in the file it points into: the compiler's message and
/// severity, its range in that file's text, and, for an error, its notes
/// (for a note, its error).
const Item = struct {
    path: []const u8,
    text: []const u8,
    start: u32,
    end: u32,
    severity: diag.Severity,
    message: []const u8,
    related: std.ArrayList(Related) = .empty,
};

const Related = struct { path: []const u8, text: []const u8, start: u32, end: u32, message: []const u8 };

const Where = union(enum) {
    /// The diagnostics of one text with no other file (the parse errors
    /// of an open document).
    home,
    /// Which modules have a file to open (`all` by module id - 1).
    shown: []const bool,
};

/// Append the compiler's diagnostics `found`, reported by the module whose
/// text is `home`, as items: each in the file its position is in (a
/// diagnostic may point into another module, `Diagnostic.module`), its
/// notes attached to it. With a `budget`, each error takes one from it, as
/// `diag.writeSome` counts them, and an error past it is left out with its
/// notes.
fn addDiagnostics(a: Allocator, items: *std.ArrayList(Item), found: []const diag.Diagnostic, home: diag.File, all: []const diag.File, where: Where, budget: ?*u32) !void {
    var last_error: ?usize = null;
    var showing = true;
    for (found) |d| {
        if (budget) |b| if (d.severity == .@"error") {
            showing = b.* > 0;
            if (showing) b.* -= 1;
        };
        if (!showing) continue;
        const module = if (d.module != 0 and d.module <= all.len) d.module else 0;
        const file = if (module == 0) home else all[module - 1];
        const at = file.locate(d.pos);
        const start = d.pos -| at.start;
        const end = @max(d.end, d.pos) -| at.start;
        const message = if (d.message.len == 0) "(no message)" else d.message;
        const openable = switch (where) {
            .home => true,
            .shown => |shown| module == 0 or shown[module - 1],
        };
        if (d.severity == .@"error") {
            last_error = null;
            if (!openable) continue;
            try items.append(a, .{ .path = at.path, .text = at.text, .start = start, .end = end, .severity = .@"error", .message = message });
            last_error = items.items.len - 1;
            continue;
        }
        const err_index = last_error;
        if (!openable) {
            // A note in a file no editor can open (the standard library
            // built into the compiler) stays with its error, named by its
            // place as `rig check` prints it.
            const e = err_index orelse continue;
            const lc = diag.lineCol(at.text, start);
            const err = &items.items[e];
            try err.related.append(a, .{ .path = err.path, .text = err.text, .start = err.start, .end = err.end, .message = try a.print("{s}:{d}:{d}: {s}", .{ at.path, lc.line, lc.col, message }) });
            continue;
        }
        try items.append(a, .{ .path = at.path, .text = at.text, .start = start, .end = end, .severity = .note, .message = message });
        if (err_index) |e| {
            const note = &items.items[items.items.len - 1];
            const err = &items.items[e];
            try err.related.append(a, .{ .path = note.path, .text = note.text, .start = note.start, .end = note.end, .message = note.message });
            try note.related.append(a, .{ .path = err.path, .text = err.text, .start = err.start, .end = err.end, .message = err.message });
        }
    }
}

/// The files diagnostics point into, with their lines, and the JSON of a
/// file's diagnostics.
const Files = struct {
    a: Allocator,
    encoding: Encoding,
    lines: std.StringHashMapUnmanaged(Lines) = .empty,

    fn linesOf(f: *Files, path: []const u8, text: []const u8) !Lines {
        const gop = try f.lines.getOrPut(f.a, path);
        if (!gop.found_existing) gop.value_ptr.* = try Lines.init(f.a, text, f.encoding);
        return gop.value_ptr.*;
    }

    /// The JSON array of the diagnostics in `path`, the file `uri` names.
    fn json(f: *Files, items: []const Item, path: []const u8, uri: []const u8, io: std.Io) ![]const u8 {
        var out: std.ArrayList(Diagnostic) = .empty;
        for (items) |it| {
            if (!eql(it.path, path)) continue;
            const lines = try f.linesOf(it.path, it.text);
            const related = try f.a.alloc(RelatedInformation, it.related.items.len);
            for (it.related.items, related) |r, *o| {
                const rl = try f.linesOf(r.path, r.text);
                const ruri = if (eql(r.path, path)) uri else try pathToUri(f.a, try absolute(f.a, io, r.path));
                o.* = .{ .location = .{ .uri = ruri, .range = rl.range(r.start, r.end) }, .message = r.message };
            }
            try out.append(f.a, .{
                .range = lines.range(it.start, it.end),
                .severity = switch (it.severity) {
                    .@"error" => 1,
                    .note => 3,
                },
                .message = it.message,
                .relatedInformation = if (related.len > 0) related else null,
            });
        }
        return std.json.Stringify.valueAlloc(f.a, out.items, .{ .emit_null_optional_fields = false });
    }
};

/// The copy in `a` of a file's path, made absolute, and of its text, made
/// once per path.
fn copyFile(a: Allocator, io: std.Io, copies: *std.StringHashMapUnmanaged([2][]const u8), path: []const u8, text: []const u8) ![2][]const u8 {
    const gop = try copies.getOrPut(a, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, path);
        gop.value_ptr.* = .{ try a.dupe(u8, try absolute(a, io, path)), try a.dupe(u8, text) };
    }
    return gop.value_ptr.*;
}

/// `path` made absolute against the working directory.
fn absolute(a: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = std.process.currentPathAlloc(io, a) catch return path;
    return std.fs.path.resolve(a, &.{ cwd, path });
}

// =============================================================================
// Protocol types
// =============================================================================

const Diagnostic = struct {
    range: Range,
    severity: u8,
    source: []const u8 = "rig",
    message: []const u8,
    relatedInformation: ?[]const RelatedInformation = null,
};

const RelatedInformation = struct {
    location: struct { uri: []const u8, range: Range },
    message: []const u8,
};

const DocumentSymbol = struct {
    name: []const u8,
    detail: []const u8,
    kind: u8,
    range: Range,
    selectionRange: Range,
    children: []const DocumentSymbol,
};

const FoldingRange = struct {
    startLine: u32,
    endLine: u32,
    kind: ?[]const u8 = null,
};

/// The names of a Zig enum's fields, in order: the semantic tokens legend.
fn names(comptime E: type) []const []const u8 {
    const fields = @typeInfo(E).@"enum".field_names;
    comptime var out: [fields.len][]const u8 = undefined;
    inline for (fields, 0..) |n, i| out[i] = n;
    const final = out;
    return &final;
}

const InitializeResult = struct {
    capabilities: struct {
        positionEncoding: []const u8,
        textDocumentSync: struct {
            openClose: bool = true,
            /// Full: each change holds the whole text.
            change: u8 = 1,
            save: struct { includeText: bool = false } = .{},
        } = .{},
        semanticTokensProvider: struct {
            legend: struct {
                tokenTypes: []const []const u8 = names(editor.Kind),
                tokenModifiers: []const []const u8 = names(editor.Modifier),
            } = .{},
            full: bool = true,
        } = .{},
        documentSymbolProvider: bool = true,
        foldingRangeProvider: bool = true,
    },
    serverInfo: struct { name: []const u8, version: []const u8 },
};

// =============================================================================
// JSON helpers
// =============================================================================

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `v[name]`, or null when `v` is no object or has no such field.
fn field(v: Value, name: []const u8) Value {
    if (v != .object) return .null;
    return v.object.get(name) orelse .null;
}

fn string(v: Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}

fn integer(v: Value) ?i64 {
    return if (v == .integer) v.integer else null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test {
    _ = editor;
}

test "readMessage: headers in any case, then the body; null at the end" {
    var r: std.Io.Reader = .fixed("Content-Length: 2\r\n\r\n{}content-type: x\r\ncontent-length:  7\r\n\r\n[1,2,3]");
    const one = (try readMessage(&r, testing.allocator)).?;
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("{}", one);
    const two = (try readMessage(&r, testing.allocator)).?;
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("[1,2,3]", two);
    try testing.expectEqual(null, try readMessage(&r, testing.allocator));
}

test "readMessage: a missing length, a bad length, a cut body" {
    var no_length: std.Io.Reader = .fixed("Content-Type: x\r\n\r\n{}");
    try testing.expectError(error.BadHeader, readMessage(&no_length, testing.allocator));
    var bad: std.Io.Reader = .fixed("Content-Length: x\r\n\r\n{}");
    try testing.expectError(error.BadHeader, readMessage(&bad, testing.allocator));
    var big: std.Io.Reader = .fixed("Content-Length: 99999999999\r\n\r\n{}");
    try testing.expectError(error.MessageTooLarge, readMessage(&big, testing.allocator));
    var cut: std.Io.Reader = .fixed("Content-Length: 10\r\n\r\n{}");
    try testing.expectError(error.EndOfStream, readMessage(&cut, testing.allocator));
    var no_body: std.Io.Reader = .fixed("Content-Length: 2\r\n");
    try testing.expectError(error.EndOfStream, readMessage(&no_body, testing.allocator));
}

test "writeMessage: the length in bytes, then the body" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeMessage(&w, "{\"é\":1}");
    try testing.expectEqualStrings("Content-Length: 8\r\n\r\n{\"é\":1}", w.buffered());
}

test "Lines: UTF-16 counts a character past U+FFFF as two units, UTF-8 counts bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `é` is 2 bytes and 1 unit, `😀` 4 bytes and 2 units (a surrogate pair).
    const text = "aé😀b\ncd";
    const b = std.mem.findScalar(u8, text, 'b').?;
    const u16s = try Lines.init(arena.allocator(), text, .utf16);
    try testing.expectEqual(Position{ .line = 0, .character = 4 }, u16s.position(@intCast(b)));
    const u8s = try Lines.init(arena.allocator(), text, .utf8);
    try testing.expectEqual(Position{ .line = 0, .character = 7 }, u8s.position(@intCast(b)));
    // The next line starts again at 0; the end clamps to the text.
    try testing.expectEqual(Position{ .line = 1, .character = 1 }, u16s.position(@intCast(text.len - 1)));
    try testing.expectEqual(Position{ .line = 1, .character = 2 }, u16s.position(999));
    // An offset inside a character is the position before it.
    try testing.expectEqual(Position{ .line = 0, .character = 2 }, u16s.position(4));
}

test "Lines: \\r\\n and a lone \\r end a line; a byte order mark takes no column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try Lines.init(arena.allocator(), "\xEF\xBB\xBFab\r\ncd\ref", .utf16);
    try testing.expectEqual(Position{ .line = 0, .character = 0 }, lines.position(3));
    try testing.expectEqual(Position{ .line = 0, .character = 1 }, lines.position(4));
    // The line ending belongs to the end of its line.
    try testing.expectEqual(Position{ .line = 0, .character = 2 }, lines.position(6));
    try testing.expectEqual(Position{ .line = 1, .character = 0 }, lines.position(7));
    try testing.expectEqual(Position{ .line = 2, .character = 1 }, lines.position(11));
}

test "URIs: a path round-trips, percent-encoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = try pathToUri(a, "/tmp/My Dir/a+b é.rig");
    try testing.expectEqualStrings("file:///tmp/My%20Dir/a%2Bb%20%C3%A9.rig", uri);
    try testing.expectEqualStrings("/tmp/My Dir/a+b é.rig", (try uriToPath(a, uri)).?);
    try testing.expectEqualStrings("/x.rig", (try uriToPath(a, "file://localhost/x.rig")).?);
    try testing.expectEqual(null, try uriToPath(a, "untitled:Untitled-1"));
    try testing.expectEqual(null, try uriToPath(a, "file://server/share/x.rig"));
}
