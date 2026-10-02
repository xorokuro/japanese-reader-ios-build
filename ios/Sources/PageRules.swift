import UIKit

/// Ruled notebook lines inside a lesson page, like the Read page's `RuledTextView`.
///
/// A web page has no fixed line pitch: headings, boxes and furigana make lines of
/// different heights, so a repeating background would drift off the text. Instead
/// this script asks the page where every line of text actually landed and draws
/// one faint rule under each line, halfway to the next line's furigana or text,
/// across the width of the paragraph or box it belongs to. It redraws whenever the
/// page changes size (text size gestures, rotation, fonts finishing loading).
///
/// It runs in the app's own script world, so the lesson files' scripts stay off.
enum PageRules {
    /// `rgba(…)|width` for the rules: the theme's tape colour, faint by default.
    /// `strength` and `thickness` are the Appearance multipliers (1 = default).
    static func color(_ style: ReaderStyle, strength: Double = 1, thickness: Double = 1) -> String {
        let rgb = Palette.rgb(style.tape)
        let alpha = min(1, (style.isDark ? 0.34 : 0.32) * strength)
        let width = 1.2 * thickness
        return "rgba(\((rgb >> 16) & 0xFF),\((rgb >> 8) & 0xFF),\(rgb & 0xFF),\(String(format: "%.3f", alpha)))|\(String(format: "%.2f", width))"
    }

    /// Sets the starting state before the page's own content loads.
    static func initial(on: Bool, color: String) -> String {
        "window.__jpRulesInit = {on: \(on), color: \"\(color)\"};"
    }

    /// Turns the rules on or off, or recolours them, on a loaded page.
    static func update(on: Bool, color: String) -> String {
        "window.__jpRules ? window.__jpRules(\(on), \"\(color)\") : false"
    }

    static let script = #"""
    (() => {
        let on = false, color = "rgba(0,0,0,.12)", width = "1.2", pending = 0, svg = null, path = null, drawn = 0;
        const SVG = "http://www.w3.org/2000/svg";
        const isBlock = (el) => {
            const d = getComputedStyle(el).display || "";
            return d !== "contents" && d !== "none" && !d.startsWith("inline") && !d.startsWith("ruby");
        };
        const blockOf = (node) => {
            let el = node.nodeType === 1 ? node.parentElement : node.parentElement;
            while (el && el !== document.body && !isBlock(el)) el = el.parentElement;
            return el || document.body;
        };
        // Text that is not shown gets no rule. The answer inside a closed <details>
        // is still laid out by newer WebKit (content-visibility) and reports boxes
        // on top of whatever follows it, which drew rules through the visible text.
        const hidden = (el) => {
            const closed = el.closest("details:not([open])");
            if (closed && !(el.closest("summary") && el.closest("summary").parentElement === closed)) return true;
            if (typeof el.checkVisibility === "function") {
                try { return !el.checkVisibility({ contentVisibilityAuto: true, visibilityProperty: true }); } catch (e) { return false; }
            }
            return false;
        };
        const sameLine = (a, b) => {
            const overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
            return overlap > 0.5 * Math.min(a.bottom - a.top, b.bottom - b.top);
        };
        const rubyLine = (lines, r) => {
            let best = null, gap = Infinity;
            for (const l of lines) {
                if (l.bottom <= r.bottom) continue;
                const g = Math.abs(l.base - r.bottom);
                if (g < gap) { gap = g; best = l; }
            }
            return best;
        };
        const draw = () => {
            pending = 0;
            if (!on) { if (svg) svg.style.display = "none"; return; }
            const sx = window.scrollX, sy = window.scrollY;
            const groups = new Map();
            const add = (block, r, ruby) => {
                let g = groups.get(block);
                if (!g) { g = { text: [], ruby: [] }; groups.set(block, g); }
                (ruby ? g.ruby : g.text).push({ top: r.top + sy, bottom: r.bottom + sy });
            };
            const range = document.createRange();
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
                if (!node.data.trim()) continue;
                const parent = node.parentElement;
                if (!parent || parent.closest("rt,svg,script,style")) continue;
                if (hidden(parent)) continue;
                range.selectNodeContents(node);
                const block = blockOf(node);
                for (const r of range.getClientRects()) if (r.width > 0 && r.height > 0) add(block, r, false);
            }
            // Furigana is drawn by CSS (rt::before), so it has boxes but no text nodes.
            for (const rt of document.querySelectorAll("rt")) {
                if (hidden(rt)) continue;
                const r = rt.getBoundingClientRect();
                if (r.height > 0) add(blockOf(rt), r, true);
            }
            const scale = window.devicePixelRatio || 1;
            let d = "", lowest = 0;
            for (const [block, g] of groups) {
                if (!g.text.length) continue;
                g.text.sort((a, b) => a.top - b.top);
                const lines = [];
                for (const r of g.text) {
                    // Same line when the boxes overlap by more than half the smaller height.
                    const line = lines.find(l => sameLine(l, r));
                    if (line) {
                        line.top = Math.min(line.top, r.top); line.bottom = Math.max(line.bottom, r.bottom);
                        line.ink = Math.min(line.ink, r.top);
                    } else {
                        lines.push({ top: r.top, bottom: r.bottom, ink: r.top, base: r.top });
                    }
                }
                lines.sort((a, b) => a.top - b.top);
                for (const r of g.ruby) {
                    // Furigana belongs to the line whose text starts just below it.
                    const base = rubyLine(lines, r);
                    if (base) base.ink = Math.min(base.ink, r.top);
                }
                const cs = getComputedStyle(block);
                const box = block.getBoundingClientRect();
                const left = box.left + sx + (parseFloat(cs.borderLeftWidth) || 0) + (parseFloat(cs.paddingLeft) || 0);
                const right = box.right + sx - (parseFloat(cs.borderRightWidth) || 0) - (parseFloat(cs.paddingRight) || 0);
                if (right - left < 24) continue;
                const size = parseFloat(cs.fontSize) || 16;
                const lineHeight = parseFloat(cs.lineHeight) || size * 1.2;
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i], next = lines[i + 1];
                    // Halfway to the next line's furigana or text. When the furigana
                    // touches this line (large text), that is the boundary itself: the
                    // rule never crosses the reading. Under the last line of a block,
                    // the same half gap the line height leaves below the glyphs.
                    let y = next
                        ? (line.bottom + next.ink) / 2
                        : line.bottom + Math.max(2, (lineHeight - (line.bottom - line.top)) / 2);
                    y = Math.round(y * scale) / scale + 0.5 / scale;
                    d += "M" + left.toFixed(1) + " " + y.toFixed(2) + "H" + right.toFixed(1);
                    lowest = Math.max(lowest, y);
                }
            }
            if (!svg) {
                svg = document.createElementNS(SVG, "svg");
                svg.setAttribute("aria-hidden", "true");
                svg.id = "jpRules";
                svg.style.cssText = "position:absolute;left:0;top:0;pointer-events:none;overflow:visible;z-index:2147483647";
                path = document.createElementNS(SVG, "path");
                path.setAttribute("fill", "none");
                path.setAttribute("stroke-width", "1.2");
                path.setAttribute("shape-rendering", "crispEdges");
                svg.appendChild(path);
                document.documentElement.appendChild(svg);
            }
            svg.style.display = "";
            svg.setAttribute("width", String(Math.max(document.documentElement.clientWidth, 1)));
            svg.setAttribute("height", String(Math.max(Math.ceil(lowest) + 2, 1)));
            path.setAttribute("stroke", color);
            path.setAttribute("stroke-width", width);
            path.setAttribute("d", d);
            svg.setAttribute("data-drawn", String(++drawn));
        };
        // A short timer rather than an animation frame: WebKit can hold animation
        // frames back (a page still off screen), and the rules must not wait for that.
        const schedule = () => { if (!pending) pending = setTimeout(draw, 40); };
        window.__jpRules = (enabled, stroke) => {
            on = !!enabled;
            if (stroke) { const parts = String(stroke).split("|"); color = parts[0]; if (parts[1]) width = parts[1]; }
            schedule(); return true;
        };
        // Redraw whenever the text can have moved: size changes (text size gesture,
        // rotation), the page finishing loading, fonts arriving, and once more
        // shortly after, when late layout (furigana, images) has settled.
        const resized = new ResizeObserver(schedule);
        resized.observe(document.body);
        window.addEventListener("resize", schedule);
        window.addEventListener("load", schedule);
        // Opening or closing an answer moves everything below it.
        document.addEventListener("toggle", schedule, true);
        if (document.fonts) {
            if (document.fonts.ready) document.fonts.ready.then(schedule);
            document.fonts.addEventListener && document.fonts.addEventListener("loadingdone", schedule);
        }
        setTimeout(schedule, 300);
        setTimeout(schedule, 1200);
        const start = window.__jpRulesInit;
        if (start && typeof start === "object") window.__jpRules(start.on, start.color);
    })();
    """#
}
