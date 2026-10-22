// chain — a tiny scrolling-strip window manager for macOS.
//
// Windows are columns on a horizontal strip per display. The strip scrolls just
// enough to keep the focused column visible, with a critically-damped spring.
// Behaviour is modelled on the ChainYourMac web demo (analysed with REA); the
// code here is an independent implementation.
//
// Memory: one process, no SwiftUI, no windows of its own, no per-frame
// allocation, no NSApplication. AppKit is used only for NSScreen / NSWorkspace.

import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Config

struct Config {
    var gap = 8.0
    var widths = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75]
    var defaultWidth = 0.5
    var animate = true
    var floatApps: Set<String> = []

    static func load() -> Config {
        var c = Config()
        let path = NSHomeDirectory() + "/.config/chain/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return c }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            let v = parts[1]
            switch parts[0] {
            case "gap": c.gap = Double(v) ?? c.gap
            case "default_width": c.defaultWidth = Double(v) ?? c.defaultWidth
            case "animate": c.animate = v == "true" || v == "1"
            case "widths":
                let w = v.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if !w.isEmpty { c.widths = w.sorted() }
            case "float":
                c.floatApps = Set(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            default: break
            }
        }
        return c
    }
}

var cfg = Config.load()

// MARK: - Spring (critically damped, exact step, retargetable)

struct Spring {
    var x: Double, v = 0.0, t: Double
    init(_ v: Double) { x = v; t = v }
    mutating func step(_ dt: Double, _ w: Double) -> Bool {
        if x == t && v == 0 { return false }
        let d = x - t, e = exp(-w * dt), a = (v + w * d) * dt
        x = t + (d + a) * e
        v = (v - (v + w * d) * w * dt) * e
        if abs(x - t) < 0.06 && abs(v) < 0.6 { x = t; v = 0 }
        return true
    }
    mutating func snap() { x = t; v = 0 }
}

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { max(lo, min(hi, v)) }

// MARK: - AX helpers

func axGet(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}
func axString(_ el: AXUIElement, _ attr: String) -> String? { axGet(el, attr) as? String }
func axBool(_ el: AXUIElement, _ attr: String) -> Bool { (axGet(el, attr) as? Bool) ?? false }
func axFrame(_ el: AXUIElement) -> CGRect? {
    var p = CGPoint.zero, s = CGSize.zero
    guard let pv = axGet(el, kAXPositionAttribute), let sv = axGet(el, kAXSizeAttribute),
          CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID(),
          AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}
func axSetPos(_ el: AXUIElement, _ p: CGPoint) {
    var p = p
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
}
func axSetSize(_ el: AXUIElement, _ s: CGSize) {
    var s = s
    if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
}

// MARK: - Model

final class Win {
    let el: AXUIElement, pid: pid_t, wid: CGWindowID
    var floating = false
    var placed = CGRect.null          // last frame we applied; skips redundant AX calls
    init(el: AXUIElement, pid: pid_t, wid: CGWindowID) { self.el = el; self.pid = pid; self.wid = wid }
}

final class Col {
    var wins: [Win], weights: [Double]
    var frac: Double, prevFrac: Double?
    var tabbed = false, row = 0
    var minW = 0.0                    // stubborn apps that refuse to shrink
    var x = 0.0, w = 0.0
    init(_ w: Win, frac: Double) { wins = [w]; weights = [1]; self.frac = frac }
}

var onSpace = Set<CGWindowID>()       // windows on the active Space of each display
func live(_ w: Win) -> Bool { onSpace.contains(w.wid) }
func live(_ c: Col) -> Bool { c.wins.contains(where: live) }

final class Strip {
    let display: CGDirectDisplayID
    var area = CGRect.zero            // visible frame, AX (top-left) coordinates
    var full = CGRect.zero            // whole display, AX coordinates
    var cols: [Col] = []
    var fc = 0
    var scroll = Spring(0)
    var pinL: Col?, pinR: Col?
    var raw: Double?                  // un-rubber-banded scroll while a gesture drives the strip
    var total = 0.0

    init(display: CGDirectDisplayID) { self.display = display }

    var g: Double { cfg.gap }
    var pinLW: Double { pinL.map { round($0.frac * (area.width - g)) } ?? 0 }
    var pinRW: Double { pinR.map { round($0.frac * (area.width - g)) } ?? 0 }
    var W: Double { area.width - pinLW - pinRW }
    var maxScroll: Double { max(0, total - W) }
    var focusedCol: Col? { cols.indices.contains(fc) ? cols[fc] : nil }
    var focusedWin: Win? { focusedCol.map { $0.wins[clamp($0.row, 0, $0.wins.count - 1)] } }

    func locate(_ w: Win) -> Bool {
        for (i, c) in cols.enumerated() { if let r = c.wins.firstIndex(where: { $0 === w }) { fc = i; c.row = r; return true } }
        return false
    }
    func contains(_ w: Win) -> Bool {
        cols.contains { $0.wins.contains { $0 === w } } || [pinL, pinR].contains { $0?.wins.contains { $0 === w } ?? false }
    }

    // Column geometry, relative to the strip's left edge.
    func layout() {
        var x = g
        for c in cols where live(c) {
            c.row = clamp(c.row, 0, c.wins.count - 1)
            c.x = x
            c.w = max(round(c.frac * (W - g) - g), c.minW)
            x += c.w + g
        }
        total = x
    }

    // Minimal scroll that brings the focused column into view.
    func reveal(snap: Bool = false) {
        guard let c = focusedCol, live(c) else { return }
        var s = scroll.t
        if c.x - g < s { s = c.x - g } else if c.x + c.w + g > s + W { s = c.x + c.w + g - W }
        scroll.t = clamp(s, 0, maxScroll)
        if snap || !cfg.animate { scroll.snap() }
    }

    func centre() {
        guard let c = focusedCol else { return }
        scroll.t = clamp(c.x + c.w / 2 - W / 2, 0, maxScroll)
        if !cfg.animate { scroll.snap() }
    }

    // Push frames to the windows. `force` re-sends even unchanged frames.
    func apply(force: Bool = false) {
        let top = area.minY + g, H = area.height - 2 * g
        for c in cols where live(c) {
            place(c, x: area.minX + pinLW + c.x - scroll.x, top: top, H: H, force: force)
        }
        if let p = pinL { p.w = pinLW - g; place(p, x: area.minX + g, top: top, H: H, force: force) }
        if let p = pinR { p.w = pinRW - g; place(p, x: area.maxX - pinRW, top: top, H: H, force: force) }
    }

    private func place(_ c: Col, x: Double, top: Double, H: Double, force: Bool) {
        let ws = c.wins.filter(live)
        guard !ws.isEmpty else { return }
        let tabs = c.tabbed && ws.count > 1
        let weights = ws.map { w in c.weights[c.wins.firstIndex { $0 === w }!] }
        let avail = H - Double(ws.count - 1) * g, sum = weights.reduce(0, +)
        var y = top
        for (i, w) in ws.enumerated() {
            let h = tabs ? H : round(avail * weights[i] / sum)
            var r = CGRect(x: round(x), y: y, width: c.w, height: h)
            if !tabs { y += h + g }
            // Off-screen columns must not spill onto a neighbouring display: park them in a corner.
            if !r.intersects(area), screens.contains(where: { $0.display != display && r.intersects($0.full) }) {
                r.origin = CGPoint(x: full.maxX - 1, y: full.maxY - 1)
            }
            set(w, r, force: force)
        }
        if tabs, let sel = c.wins.indices.contains(c.row) ? c.wins[c.row] : nil, live(sel) {
            AXUIElementPerformAction(sel.el, kAXRaiseAction as CFString)
        }
    }

    private func set(_ w: Win, _ r: CGRect, force: Bool) {
        if !force && w.placed == r { return }
        if force || w.placed.size != r.size {
            axSetSize(w.el, r.size); axSetPos(w.el, r.origin); axSetSize(w.el, r.size)
        } else {
            axSetPos(w.el, r.origin)
        }
        w.placed = r
    }

    // Columns whose app refused the requested width keep the width it chose.
    func respectStubborn() -> Bool {
        var changed = false
        for c in cols where live(c) {
            for w in c.wins where live(w) {
                if let f = axFrame(w.el), f.width > c.w + 2, f.width < area.width { c.minW = f.width; changed = true }
            }
        }
        return changed
    }

    func detach(_ w: Win) {
        for p in [pinL, pinR] { if let p, p.wins.first === w { if p === pinL { pinL = nil } else { pinR = nil } } }
        for (i, c) in cols.enumerated() {
            guard let r = c.wins.firstIndex(where: { $0 === w }) else { continue }
            c.wins.remove(at: r); c.weights.remove(at: r)
            if c.wins.isEmpty {
                cols.remove(at: i)
                if fc > i || fc >= cols.count { fc = max(0, fc - 1) }
            } else { c.row = clamp(c.row, 0, c.wins.count - 1) }
            return
        }
    }

    func insert(_ w: Win, after: Bool = true, frac: Double = cfg.defaultWidth) {
        let at = cols.isEmpty ? 0 : (after ? fc + 1 : cols.count)
        cols.insert(Col(w, frac: frac), at: at)
        if after || cols.count == 1 { fc = at }
    }

    // Snap to the column nearest to where the gesture's momentum would land.
    func settle(velocity v: Double) {
        let proj = scroll.x + v * 0.22, m = maxScroll
        var best = 0.0, bd = Double.infinity
        for c in cols where live(c) {
            let s = clamp(c.x - g, 0, m), d = abs(s - proj)
            if d < bd { bd = d; best = s }
        }
        scroll.t = best
        scroll.v = clamp(v, -5000, 5000)
        raw = nil
        if !cfg.animate { scroll.snap() }
        if let c = focusedCol, c.x < best - 1 || c.x + c.w > best + W + 1,
           let i = cols.firstIndex(where: { live($0) && $0.x >= best - 1 && $0.x + $0.w <= best + W + 1 }) {
            fc = i
            if let w = focusedWin { focus(w) }
        }
    }

    func rubber(_ r: Double) -> Double {
        let m = maxScroll, d = W * 0.5
        func rb(_ o: Double) -> Double { (1 - 1 / ((o * 0.55) / d + 1)) * d }
        return r < 0 ? -rb(-r) : r > m ? m + rb(r - m) : r
    }

    func drive(_ r: Double) {
        raw = clamp(r, -W * 0.7, maxScroll + W * 0.7)
        scroll.x = rubber(raw!); scroll.t = scroll.x; scroll.v = 0
        apply()
    }
}

// MARK: - Global state

var screens: [Strip] = []
var wins: [CGWindowID: Win] = [:]
var observers: [pid_t: AXObserver] = [:]
var focusedWin: Win?

func strip(for w: Win) -> Strip? { screens.first { $0.contains(w) } }
func strip(at p: CGPoint) -> Strip? { screens.first { $0.full.contains(p) } }

func relayout(_ s: Strip, snap: Bool = false, force: Bool = false) {
    s.layout()
    s.reveal(snap: snap)
    s.apply(force: force)
    if force && s.respectStubborn() { s.layout(); s.reveal(snap: true); s.apply() }
    kick()
}

// MARK: - Displays

func refreshScreens() {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    func ax(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height) }
    var next: [Strip] = []
    for sc in NSScreen.screens {
        guard let id = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
        let s = screens.first { $0.display == id } ?? Strip(display: id)
        s.area = ax(sc.visibleFrame); s.full = ax(sc.frame)
        next.append(s)
    }
    // Columns from displays that went away join the main display's strip.
    if let main = next.first {
        for old in screens where !next.contains(where: { $0 === old }) {
            main.cols += old.cols + [old.pinL, old.pinR].compactMap { $0 }
        }
    }
    screens = next
    for s in screens { for c in s.cols { c.minW = 0 }; relayout(s, snap: true, force: true) }
}

func refreshSpace() {
    onSpace.removeAll(keepingCapacity: true)
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
    for info in list { if let n = info[kCGWindowNumber as String] as? CGWindowID { onSpace.insert(n) } }
}

// MARK: - Window tracking

func manageable(_ el: AXUIElement) -> Bool {
    guard axString(el, kAXRoleAttribute) == kAXWindowRole,
          axString(el, kAXSubroleAttribute) == kAXStandardWindowSubrole,
          !axBool(el, kAXMinimizedAttribute), !axBool(el, "AXFullScreen") else { return false }
    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
    return settable.boolValue
}

@discardableResult
func track(_ el: AXUIElement, pid: pid_t, initial: Bool = false) -> Win? {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(el, &wid) == .success, wid != 0, wins[wid] == nil, manageable(el) else { return nil }
    let w = Win(el: el, pid: pid, wid: wid)
    wins[wid] = w
    onSpace.insert(wid)
    if let obs = observers[pid] {
        for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(obs, el, n as CFString, nil)
        }
    }
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    if cfg.floatApps.contains(bundle) { w.floating = true; return w }
    let frame = axFrame(el) ?? .zero
    guard let s = strip(at: CGPoint(x: frame.midX, y: frame.midY)) ?? screens.first else { return w }
    if initial {
        // Keep the user's current width, snapped to the nearest preset.
        let f = frame.width / max(1, s.area.width)
        s.insert(w, after: false, frac: cfg.widths.min { abs($0 - f) < abs($1 - f) } ?? cfg.defaultWidth)
    } else {
        // Background windows don't steal focus or scroll the strip.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        s.insert(w, after: front)
        relayout(s, force: true)
    }
    return w
}

func untrack(_ w: Win) {
    wins[w.wid] = nil
    if focusedWin === w { focusedWin = nil }
    if let s = strip(for: w) { s.detach(w); relayout(s) }
}

func scanApp(_ pid: pid_t, initial: Bool = false) {
    let app = AXUIElementCreateApplication(pid)
    if observers[pid] == nil {
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }
    for el in (axGet(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { track(el, pid: pid, initial: initial) }
}

func scanAll(initial: Bool = false) {
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        scanApp(app.processIdentifier, initial: initial)
    }
}

func onFocus(_ el: AXUIElement) {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(el, &wid) == .success, let w = wins[wid] else { return }
    focusedWin = w
    guard let s = strip(for: w), s.locate(w) else { return }
    relayout(s)
}

let axCallback: AXObserverCallback = { _, el, note, _ in
    switch note as String {
    case kAXWindowCreatedNotification:
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if let w = track(el, pid: pid) { focusedWin = w }
    case kAXWindowDeminiaturizedNotification:
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        track(el, pid: pid)
    case kAXFocusedWindowChangedNotification:
        onFocus(el)
    case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
        // Destroyed elements no longer resolve to a window id; match by identity.
        if let w = wins.values.first(where: { CFEqual($0.el, el) }) { untrack(w) }
    default: break
    }
}

func focus(_ w: Win) {
    focusedWin = w
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(w.el, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
}

// MARK: - Animation

var timer: Timer?
var lastTick = 0.0

func kick() {
    guard timer == nil else { return }
    lastTick = CACurrentMediaTime()
    let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        let now = CACurrentMediaTime(), dt = min(0.034, now - lastTick)
        lastTick = now
        var busy = false
        for s in screens where s.raw == nil {
            if s.scroll.step(dt, 13) { busy = true }
            s.apply()
        }
        if !busy { timer?.invalidate(); timer = nil }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
}

// MARK: - Actions

func current() -> (Strip, Col, Win)? {
    if let w = focusedWin, let s = strip(for: w), s.locate(w), let c = s.focusedCol { return (s, c, w) }
    for s in screens { if let c = s.focusedCol, let w = s.focusedWin { return (s, c, w) } }
    return nil
}

func neighbour(_ s: Strip, from i: Int, _ d: Int) -> Int? {
    var j = i + d
    while s.cols.indices.contains(j) { if live(s.cols[j]) { return j }; j += d }
    return nil
}

func run(_ action: String) {
    if action == "quit" { restoreAll(); exit(0) }
    if action == "reload" { cfg = Config.load(); refreshScreens(); return }
    if action == "float", let w = focusedWin { toggleFloat(w); return }
    guard let (s, c, w) = current() else { return }
    var centre = false
    let liveCols = s.cols.indices.filter { live(s.cols[$0]) }

    switch action {
    case "focus-left", "focus-right":
        guard let j = neighbour(s, from: s.fc, action == "focus-left" ? -1 : 1) else { return }
        s.fc = j
    case "focus-up", "focus-down":
        let r = clamp(c.row + (action == "focus-up" ? -1 : 1), 0, c.wins.count - 1)
        guard r != c.row else { return }
        c.row = r
    case "focus-first": s.fc = liveCols.first ?? s.fc
    case "focus-last": s.fc = liveCols.last ?? s.fc
    case "move-left", "move-right":
        guard let j = neighbour(s, from: s.fc, action == "move-left" ? -1 : 1) else { return }
        s.cols.swapAt(s.fc, j); s.fc = j
    case "move-up", "move-down":
        let r = c.row + (action == "move-up" ? -1 : 1)
        guard c.wins.indices.contains(r) else { return }
        c.wins.swapAt(c.row, r); c.weights.swapAt(c.row, r); c.row = r
    case "move-first", "move-last":
        s.cols.remove(at: s.fc)
        let at = action == "move-first" ? 0 : s.cols.count
        s.cols.insert(c, at: at); s.fc = at
    case "cycle-width":
        c.frac = cfg.widths.first { $0 > c.frac + 0.01 } ?? cfg.widths[0]; c.minW = 0
    case "full-width":
        if c.frac >= 0.99 { c.frac = c.prevFrac ?? cfg.defaultWidth } else { c.prevFrac = c.frac; c.frac = 1 }
        c.minW = 0
    case "wider": c.frac = min(1, c.frac + 0.05)
    case "narrower": c.frac = max(0.1, c.frac - 0.05); c.minW = 0
    case "taller", "shorter":
        guard c.wins.count > 1 else { return }
        c.weights[c.row] *= action == "taller" ? 1.15 : 1 / 1.15
    case "equalize": c.weights = c.weights.map { _ in 1 }
    case "center": centre = true
    case "stack-left", "stack-right":
        guard let t = neighbour(s, from: s.fc, action == "stack-left" ? -1 : 1) else { return }
        let target = s.cols[t]
        s.detach(w)
        target.wins.append(w); target.weights.append(1); target.row = target.wins.count - 1
        _ = s.locate(w)
    case "unstack-right", "unstack-left":
        guard c.wins.count > 1 else { return }
        s.detach(w)
        let n = Col(w, frac: c.frac)
        let at = action == "unstack-right" ? s.fc + 1 : s.fc
        s.cols.insert(n, at: at); s.fc = at
    case "tabbed":
        guard c.wins.count > 1 else { return }
        c.tabbed.toggle()
    case "pin-left", "pin-right":
        let left = action == "pin-left"
        if let p = left ? s.pinL : s.pinR {           // unpin
            if left { s.pinL = nil } else { s.pinR = nil }
            s.cols.insert(p, at: left ? 0 : s.cols.count)
            s.fc = left ? 0 : s.cols.count - 1
        } else {
            s.cols.remove(at: s.fc)
            if left { s.pinL = c } else { s.pinR = c }
            s.fc = min(s.fc, max(0, s.cols.count - 1))
        }
        s.apply(force: true)
    case "next-display":
        guard screens.count > 1, let i = screens.firstIndex(where: { $0 === s }) else { return }
        let to = screens[(i + 1) % screens.count]
        s.detach(w); to.insert(w, frac: c.frac)
        relayout(s, force: true); relayout(to, force: true)
        focus(w)
        return
    default:
        if let n = Int(action.split(separator: "-").last ?? ""), (1...9).contains(n), !liveCols.isEmpty {
            let target = n == 9 ? liveCols.last! : liveCols[min(n - 1, liveCols.count - 1)]
            if action.hasPrefix("focus-") { s.fc = target }
            else if action.hasPrefix("move-to-") { s.cols.remove(at: s.fc); s.cols.insert(c, at: target); s.fc = target }
        } else { return }
    }

    s.layout()
    if centre { s.centre() } else { s.reveal() }
    s.apply(force: true)  // sizes/rows may have changed; positions settle via the spring
    kick()
    if let nw = s.focusedWin, nw !== w || action.hasPrefix("focus") { focus(nw) }
}

func toggleFloat(_ w: Win) {
    if w.floating {
        w.floating = false
        let f = axFrame(w.el) ?? .zero
        if let s = strip(at: CGPoint(x: f.midX, y: f.midY)) ?? screens.first { s.insert(w); relayout(s, force: true) }
    } else if let s = strip(for: w) {
        w.floating = true
        s.detach(w)
        // Drop the floating window in the middle of the visible area.
        let size = CGSize(width: min(w.placed.width, s.area.width * 0.6), height: min(w.placed.height, s.area.height * 0.7))
        axSetSize(w.el, size)
        axSetPos(w.el, CGPoint(x: s.area.midX - size.width / 2, y: s.area.midY - size.height / 2))
        w.placed = .null
        relayout(s, force: true)
    }
}

// Put every window back inside its display before exiting.
func restoreAll() {
    for s in screens {
        var i = 0.0
        for c in s.cols + [s.pinL, s.pinR].compactMap({ $0 }) {
            for w in c.wins {
                let size = CGSize(width: min(w.placed.width, s.area.width), height: min(w.placed.height, s.area.height))
                axSetPos(w.el, CGPoint(x: s.area.minX + 20 * i, y: s.area.minY + 20 * i))
                if size.width > 0 { axSetSize(w.el, size) }
                i = (i + 1).truncatingRemainder(dividingBy: 10)
            }
        }
    }
}

// MARK: - Keyboard and trackpad (one event tap)

// keycode -> (action, action with shift, action with cmd, action with cmd+shift)
let keymap: [Int64: [String?]] = {
    var m: [Int64: [String?]] = [
        4: ["focus-left", "move-left"], 123: ["focus-left", "move-left", "focus-first", "move-first"],
        37: ["focus-right", "move-right"], 124: ["focus-right", "move-right", "focus-last", "move-last"],
        38: ["focus-down", "move-down"], 125: ["focus-down", "move-down"],
        40: ["focus-up", "move-up"], 126: ["focus-up", "move-up"],
        15: ["cycle-width"], 3: ["full-width"], 8: ["center"],
        24: ["wider", "taller"], 27: ["narrower", "shorter"], 29: ["equalize"],
        30: ["stack-left", "unstack-right"], 33: ["stack-right", "unstack-left"],
        17: ["float", "tabbed"], 45: ["next-display"], 35: ["pin-left", "pin-right"], 12: ["quit"],
    ]
    for (i, k) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() { m[Int64(k)] = ["focus-\(i + 1)", "move-to-\(i + 1)"] }
    return m
}()

var tap: CFMachPort?
var gesture: (strip: Strip, last: Double, vel: Double)?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let f = event.flags
    let chord = f.contains(.maskControl) && f.contains(.maskAlternate)

    if type == .keyDown, chord {
        let shift = f.contains(.maskShift), cmd = f.contains(.maskCommand)
        let slot = (cmd ? 2 : 0) + (shift ? 1 : 0)
        if let acts = keymap[event.getIntegerValueField(.keyboardEventKeycode)], slot < acts.count, let a = acts[slot] {
            run(a)
            return nil
        }
    }

    if type == .scrollWheel, chord || gesture != nil {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if momentum != 0 { return gesture == nil && !chord ? Unmanaged.passUnretained(event) : nil }
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            // Mouse wheel: one notch, one column.
            let d = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if d != 0 { run(d > 0 ? "focus-left" : "focus-right") }
            return nil
        }
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let d = abs(dx) >= abs(dy) ? dx : dy
        let now = CACurrentMediaTime()
        if gesture == nil, let s = strip(at: event.location) ?? screens.first {
            gesture = (s, now, 0); timer?.invalidate(); timer = nil
            s.raw = s.scroll.x
        }
        guard var gs = gesture else { return nil }
        let s = gs.strip
        if d != 0 {
            s.drive((s.raw ?? s.scroll.x) - d)
            let dt = max(0.004, now - gs.last)
            gs.vel = 0.6 * gs.vel + 0.4 * (-d / dt); gs.last = now
            gesture = gs
        }
        if phase == 4 /* ended */ || phase == 8 /* cancelled */ {
            s.settle(velocity: gs.vel)
            gesture = nil
            kick()
        }
        return nil
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so messages show up in logs
let args = CommandLine.arguments
let cmdName = Notification.Name("dev.chain.cmd")

if args.count > 1 {
    // `chain <action>`: forward to the running instance.
    DistributedNotificationCenter.default().postNotificationName(cmdName, object: args[1], userInfo: nil, deliverImmediately: true)
    exit(0)
}

// Single instance.
let lockPath = NSTemporaryDirectory() + "dev.chain.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 { print("chain is already running"); exit(1) }

if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    print("chain needs Accessibility permission: System Settings → Privacy & Security → Accessibility.")
    while !AXIsProcessTrusted() { sleep(2) }
}

AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

refreshSpace()
refreshScreens()
scanAll(initial: true)
for s in screens { s.fc = 0; relayout(s, snap: true, force: true) }
if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
   let el = axGet(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) {
    onFocus(el as! AXUIElement)
}

let ws = NSWorkspace.shared.notificationCenter
ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
    guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.activationPolicy == .regular else { return }
    // Apps often aren't ready for AX right at launch.
    for delay in [0.3, 1.0, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scanApp(a.processIdentifier) } }
}
ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
    guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    let pid = a.processIdentifier
    observers[pid] = nil
    for w in wins.values where w.pid == pid { untrack(w) }
}
ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
    guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let el = axGet(AXUIElementCreateApplication(a.processIdentifier), kAXFocusedWindowAttribute) else { return }
    onFocus(el as! AXUIElement)
}
ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
    refreshSpace(); scanAll()
    for s in screens { relayout(s, snap: true, force: true) }
}
ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshSpace(); refreshScreens() }
}
CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    if !flags.contains(.beginConfigurationFlag) { DispatchQueue.main.async { refreshScreens() } }
}, nil)
DistributedNotificationCenter.default().addObserver(forName: cmdName, object: nil, queue: .main) { n in
    if let a = n.object as? String { run(a) }
}

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { restoreAll(); exit(0) }
    src.resume()
    _ = Unmanaged.passRetained(src)
}

let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil) else {
    print("could not create the event tap (is Accessibility granted?)"); exit(1)
}
tap = t
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
CGEvent.tapEnable(tap: t, enable: true)

print("chain running — ⌃⌥H/L to move focus, ⌃⌥Q to quit")
CFRunLoopRun()  // no NSApplication: saves ~2 MB
