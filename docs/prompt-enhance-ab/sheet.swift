// Contact sheet for the prompt enhancement A/B: one row per case, the prompt as typed, then off | on.
// Usage: swift sheet.swift DIR OUT.jpg   (DIR holds results.json and the PNGs)
import AppKit
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("results.json"))) as! [[String: Any]]
var cases: [String] = []
for row in rows where !cases.contains(row["case"] as! String) { cases.append(row["case"] as! String) }

let thumb: CGFloat = 360, label: CGFloat = 330, pad: CGFloat = 12, header: CGFloat = 34
let width = label + 2 * (thumb + pad) + pad
let height = header + CGFloat(cases.count) * (thumb + pad) + pad
let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
func text(_ s: String, _ rect: NSRect, size: CGFloat, bold: Bool = false, color: NSColor = .black) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                         attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                      .foregroundColor: color, .paragraphStyle: style])
}
text("Prompt enhancement A/B — same seed, enhancement off | on (AB-D-0155 E2)", NSRect(x: pad, y: height - header + 6, width: width - 2 * pad, height: 24),
     size: 16, bold: true)
for (i, c) in cases.enumerated() {
    let top = height - header - CGFloat(i) * (thumb + pad) - thumb
    let arms = rows.filter { $0["case"] as! String == c }
    let first = arms[0]
    var lines = "\(c)\n\(first["model"]!) · \(first["policy"]!)\n\n“\(first["prompt"]!)”\n"
    for arm in arms {
        let q = (arm["quality"] as? Double).map { String(format: "%.3f", $0) } ?? "–"
        lines += "\n\(arm["arm"]!): " + String(format: "%.1f", (arm["seconds"] as? Double) ?? 0) + " s, quality \(q)"
    }
    if let on = arms.first(where: { $0["arm"] as! String == "on" }),
       let pe = ((on["effective"] as? [String: Any])?["model_params"] as? [String: Any])?["prompt_enhancement"] as? [String: Any] {
        lines += "\n\non: \(pe["outcome"] ?? "-")"
        if let p = pe["prompt"] as? String { lines += "\n\(p.prefix(420))" + (p.count > 420 ? "…" : "") }
    }
    text(lines, NSRect(x: pad, y: top, width: label - pad, height: thumb), size: 10.5)
    for (j, arm) in ["off", "on"].enumerated() {
        let rect = NSRect(x: label + pad + CGFloat(j) * (thumb + pad), y: top, width: thumb, height: thumb)
        if let name = arms.first(where: { $0["arm"] as! String == arm })?["image"] as? String,
           let img = NSImage(contentsOf: dir.appendingPathComponent(name)) {
            img.draw(in: rect)
        } else {
            NSColor.lightGray.setFill(); rect.fill()
        }
        text(arm, NSRect(x: rect.minX + 6, y: rect.maxY - 22, width: 60, height: 18), size: 13, bold: true, color: .white)
    }
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])!.write(to: out)
print("wrote \(out.path) (\(Int(width))×\(Int(height)))")
