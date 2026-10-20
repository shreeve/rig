// bench/terminal's Dispatch side: `dispatch FILE N COLS ROWS SCROLLBACK`
// feeds FILE's bytes to N new terminals of Dispatch's engine (Term, Paul
// Miller's Swift port of Ghostty, MIT) and prints `<ns> <check>` as
// bench.rig does: the nanoseconds the N feeds took, and the 64-bit FNV-1a
// hash of the last terminal's dump, written as std.terminal's `dump`
// writes it. The corpora ask for no replies, so the dump has no reply
// line. bench-terminal compiles this as Term's main.swift, in its module.
import Foundation

let args = CommandLine.arguments
let data = Array(FileManager.default.contents(atPath: args[1])!)
let n = Int(args[2])!, cols = Int(args[3])!, rows = Int(args[4])!, scrollback = Int(args[5])!
var ns: UInt64 = 0
var check: UInt64 = 0
for i in 0..<n {
    var opts = TerminalOptions(cols: cols, rows: rows)
    opts.maxScrollbackBytes = scrollback
    // Mode 2027 off, as Ghostty and std.terminal start; Dispatch turns it on.
    opts.defaultModes = ["cursor_blinking": true]
    let t = Terminal(opts)
    var stream = Stream(handler: StreamHandler(terminal: t, options: HandlerOptions()))
    let start = DispatchTime.now().uptimeNanoseconds
    data.withUnsafeBufferPointer { stream.nextSlice($0) }
    ns += DispatchTime.now().uptimeNanoseconds - start
    if i == n - 1 { check = fnv(dump(t)) }
}
print(ns, check)

func fnv(_ s: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

/// The screen and cursor as `Terminal.dump` writes them (std/terminal/terminal.rig).
func dump(_ t: Terminal) -> [UInt8] {
    let screen = t.active
    var out: [UInt8] = []
    for y in 0..<rows {
        let p = screen.pages.pin(.active, y: y)!
        var line: [UInt8] = []
        for x in 0..<cols {
            let c = p.page.cell(p.page.cellAt(p.y, x))
            if c.wide == .spacerTail { continue }
            line += Array(String(Character(Swift.Unicode.Scalar(c.codepoint == 0 ? 0x20 : c.codepoint)!)).utf8)
        }
        while line.last == 0x20 { line.removeLast() }
        out += [0x7C] + line + [0x0A]
    }
    for y in 0..<rows {
        let p = screen.pages.pin(.active, y: y)!
        var (run, first) = ("", 0)
        for x in 0...cols {
            var attr = ""
            if x < cols {
                let c = p.page.cell(p.page.cellAt(p.y, x))
                attr = attrs(c, p.page.style(c.styleID))
            }
            if attr == run && x < cols { continue }
            if !run.isEmpty { out += Array("~\(y) \(first)-\(x - 1) \(run)\n".utf8) }
            (run, first) = (attr, x)
        }
    }
    let c = screen.cursor
    out += Array("cursor \(c.y) \(c.x)\(c.pendingWrap ? " wrap" : "")".utf8)
    return out
}

/// A cell's style as the dump writes it; empty for the plain one.
func attrs(_ c: Cell, _ s: Style) -> String {
    var parts: [String] = []
    let f = s.flags
    let flags = [("bold", f.bold), ("italic", f.italic), ("faint", f.faint), ("blink", f.blink),
                 ("inverse", f.inverse), ("invisible", f.invisible), ("strike", f.strikethrough), ("overline", f.overline)]
    for (name, on) in flags where on { parts.append(name) }
    if f.underline != .none { parts.append("ul=\(f.underline)") }
    color(&parts, "fg", s.fgColor)
    switch c.tag {
    case .bgColorPalette: color(&parts, "bg", .palette(UInt8(c.content & 0xFF)))
    case .bgColorRGB: color(&parts, "bg", .rgb(RGB(r: UInt8(c.content & 0xFF), g: UInt8(c.content >> 8 & 0xFF), b: UInt8(c.content >> 16 & 0xFF))))
    default: color(&parts, "bg", s.bgColor)
    }
    color(&parts, "ulc", s.underlineColor)
    return parts.joined(separator: " ")
}

func color(_ parts: inout [String], _ name: String, _ c: Style.Color) {
    func hex(_ b: UInt8) -> String { let s = String(b, radix: 16); return s.count == 1 ? "0" + s : s }
    switch c {
    case .none: break
    case .palette(let i): parts.append("\(name)=\(i)")
    case .rgb(let v): parts.append("\(name)=#\(hex(v.r))\(hex(v.g))\(hex(v.b))")
    }
}
