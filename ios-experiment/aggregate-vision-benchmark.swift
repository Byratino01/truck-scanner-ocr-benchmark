import Foundation
import Vision
import AppKit
import ImageIO
import CoreImage

// Aggregate-only benchmark. Never serialize OCR lines, locations, fingerprints, or per-document trials.
// Runs only on a trusted, temporary macOS worker. All failures are reported generically by the wrapper.
guard CommandLine.arguments.count == 3,
      let expectedCount = Int(CommandLine.arguments[2]),
      expectedCount == 30 else { fatalError("Invalid benchmark configuration") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard files.count == expectedCount else { fatalError("Invalid fixture count") }
let names = Set(files.map { $0.deletingPathExtension().lastPathComponent })
guard names.count == expectedCount,
      names == Set((1...30).map { String(format: "BOL_%02d", $0) }) else {
    fatalError("Invalid fixture structure")
}

struct Metrics {
    var documents = 0
    var trials = 0
    var v9BestBoth = 0
    var v9AnyBoth = 0
    var v8AnyBoth = 0
    var consolidatedBoth = 0
    var pickupConflict = 0
    var deliveryConflict = 0
    var noBoth = 0
    var missingStateZIP = 0
    var headingOwned = 0
    var conflictingFields = 0
    var ambiguousColumns = 0
    var origins: [String: Int] = [:]
}
var metrics = Metrics()
let stateZip = try NSRegularExpression(pattern: #"\b(?:AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\s*,?\s*\d{5}\b"#, options: [.caseInsensitive])
let heading = try NSRegularExpression(pattern: #"\b(?:shipper|consignee|ship\s*from|ship\s*to|pickup|delivery)\b"#, options: [.caseInsensitive])
func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
    regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}
func fingerprint(_ image: CGImage) -> UInt64 {
    let w = 31, h = 23
    var pixels = [UInt8](repeating: 0, count: w*h*4)
    let color = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w*4, space: color,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Pixel validation unavailable")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return pixels.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
}
for url in files {
    let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard attrs.isRegularFile == true, attrs.isSymbolicLink != true,
          let image = NSImage(contentsOf: url),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let original = bitmap.cgImage else { fatalError("Invalid fixture image") }
    var rotatedResults: [BOLParserV9.RotationParse] = []
    var fingerprints = Set<UInt64>()
    var bestScore = -Double.infinity
    var bestBoth = false
    var anyBoth = false
    var anyV8Both = false
    var anyStateZIP = false
    for (degrees, orientation) in [(0, CGImagePropertyOrientation.up), (90, .right),
                                    (180, .down), (270, .left)] {
        let rotated = CIImage(cgImage: original).oriented(forExifOrientation: Int32(orientation.rawValue))
        guard let pixels = CIContext(options: [.useSoftwareRenderer: true])
            .createCGImage(rotated, from: rotated.extent.integral) else { fatalError("Rotation failed") }
        fingerprints.insert(fingerprint(pixels))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: pixels, orientation: .up).perform([request])
        let lines = (request.results ?? []).compactMap { item -> OCRLine? in
            guard let candidate = item.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, confidence: Double(candidate.confidence),
                           x: Double(item.boundingBox.minX), y: Double(item.boundingBox.minY))
        }
        guard !lines.isEmpty else { fatalError("Empty OCR result") }
        let doc = OCRDocument(file: "benchmark", lines: lines)
        let result = BOLParserV9.parse(doc)
        let v8 = BOLAddressParserV8.parse(doc)
        rotatedResults.append(BOLParserV9.RotationParse(degrees: degrees, document: result))
        let both = result.pickup != nil && result.delivery != nil
        anyBoth = anyBoth || both
        anyV8Both = anyV8Both || (v8.pickup.cityStateZIP != nil && v8.delivery.cityStateZIP != nil)
        let zipLines = lines.filter { matches(stateZip, $0.text) }.count
        let headingLines = lines.filter { matches(heading, $0.text) }.count
        anyStateZIP = anyStateZIP || zipLines > 0
        let meanConfidence = lines.reduce(0.0) { $0 + $1.confidence } / Double(lines.count)
        let score = Double(zipLines * 8 + headingLines * 5) +
                    Double(min(lines.count, 80)) * 0.15 + meanConfidence * 10
        if score > bestScore { bestScore = score; bestBoth = both }
        let diagnostic = BOLParserV9.diagnosticSummary(doc)
        metrics.headingOwned += diagnostic.pickupHeadingOwnedLines + diagnostic.deliveryHeadingOwnedLines
        metrics.conflictingFields += diagnostic.conflictingAddressFields
        metrics.ambiguousColumns += diagnostic.ambiguousColumnBoundaries
        for origin in [diagnostic.pickupOrigin, diagnostic.deliveryOrigin] {
            guard ["none", "region", "split-region", "layout", "v8-fallback"].contains(origin) else {
                fatalError("Unexpected diagnostic origin")
            }
            metrics.origins[origin, default: 0] += 1
        }
        metrics.trials += 1
    }
    guard fingerprints.count == 4, rotatedResults.count == 4 else {
        fatalError("Rotation validation failed")
    }
    let merged = BOLParserV9.consolidateRotations(rotatedResults)
    metrics.documents += 1
    if bestBoth { metrics.v9BestBoth += 1 }
    if anyBoth { metrics.v9AnyBoth += 1 } else { metrics.noBoth += 1 }
    if anyV8Both { metrics.v8AnyBoth += 1 }
    if merged.pickup != nil && merged.delivery != nil { metrics.consolidatedBoth += 1 }
    if !anyStateZIP { metrics.missingStateZIP += 1 }
    if merged.warnings.contains(where: { $0.hasPrefix("pickup: cross-rotation conflict") }) {
        metrics.pickupConflict += 1
    }
    if merged.warnings.contains(where: { $0.hasPrefix("delivery: cross-rotation conflict") }) {
        metrics.deliveryConflict += 1
    }
}
guard metrics.documents == 30, metrics.trials == 120,
      metrics.origins.values.reduce(0, +) == 240 else { fatalError("Aggregate validation failed") }
print("AGGREGATE_V9_BENCHMARK documents=30 rotations=120")
print("AGGREGATE_SELECTION v9_score_best_both=\(metrics.v9BestBoth) v9_any_both=\(metrics.v9AnyBoth) v8_any_both=\(metrics.v8AnyBoth) consolidated_both=\(metrics.consolidatedBoth)")
print("AGGREGATE_REVIEW no_both_any_rotation=\(metrics.noBoth) no_state_zip_evidence=\(metrics.missingStateZIP) pickup_conflicts=\(metrics.pickupConflict) delivery_conflicts=\(metrics.deliveryConflict)")
print("AGGREGATE_DIAGNOSTICS heading_owned=\(metrics.headingOwned) conflicting_fields=\(metrics.conflictingFields) ambiguous_columns=\(metrics.ambiguousColumns)")
print("AGGREGATE_ORIGINS " + ["none", "region", "split-region", "layout", "v8-fallback"].map { "\($0)=\(metrics.origins[$0, default: 0])" }.joined(separator: " "))
print("UNVERIFIED: Candidate detection is not ground-truth accuracy.")
