// Sample actual screenshot pixels; UIKit's configured cell can report clear.
import AppKit
import Foundation
var samples = [[String: Any]]()
for path in CommandLine.arguments.dropFirst() {
    guard let data = NSData(contentsOfFile: path),
          let bitmap = NSBitmapImageRep(data: data as Data) else { fatalError("PNG decode failed") }
    var values = [[Int]]()
    for y in 216..<225 { for x in 12..<21 {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { fatalError("RGB conversion failed") }
        values.append([color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) })
    }}
    guard Set(values.map { $0.map(String.init).joined(separator: ",") }).count == 1 else { fatalError("Nonuniform background patch") }
    samples.append(["file": path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "rgba": values[0]])
}
let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
