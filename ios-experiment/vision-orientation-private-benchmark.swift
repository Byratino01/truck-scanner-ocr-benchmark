import Foundation
import Vision
import AppKit
import ImageIO

// Private offline test. Input images never appear in logs or artifacts.
guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Expected private image directory and optional count") }
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let requestedCount: Int? = CommandLine.arguments.count == 3 ? Int(CommandLine.arguments[2]) : 2
let manager = FileManager.default
let files = try manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    .filter { ["jpeg", "jpg", "png", "heic"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard let expectedCount = requestedCount, [2, 3, 4, 5, 30].contains(expectedCount), files.count == expectedCount else {
    fatalError("Unexpected fixture image count")
}
guard Set(files.map { $0.deletingPathExtension().lastPathComponent }).count == expectedCount else {
    fatalError("Duplicate fixture image identifiers")
}
struct Trial: Encodable {
    var consolidatedPickupDetected = false
    var consolidatedDeliveryDetected = false
    var consolidatedPickupDisagreement = "insufficient-evidence"
    var consolidatedDeliveryDisagreement = "insufficient-evidence"
    var consolidatedPickupConflict = false
    var consolidatedDeliveryConflict = false
    var pickupOrigin = "none"
    var deliveryOrigin = "none"
    var pickupHeadingOwnedLines = 0
    var deliveryHeadingOwnedLines = 0
    var conflictingAddressFields = 0
    var ambiguousColumnBoundaries = 0
    let file: String
    let rotationClockwise: Int
    let lines: Int
    let meanConfidence: Double
    let roleHeadings: Int
    let stateZIPLines: Int
    let score: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let pixelFingerprint: String
    let pickupDetected: Bool
    let deliveryDetected: Bool
    let v8PickupDetected: Bool
    let v8DeliveryDetected: Bool
    let v8PickupFallbackReason: String
    let v8DeliveryFallbackReason: String
    let pickupAnchors: Int
    let deliveryAnchors: Int
    let pickupNearbyLines: Int
    let deliveryNearbyLines: Int
    let completeLocationLines: Int
    let pickupRegionStateZIPLines: Int
    let deliveryRegionStateZIPLines: Int
    let pickupRegionCompleteLines: Int
    let deliveryRegionCompleteLines: Int
    let zipTokenLines: Int
    let stateTokenLines: Int
    let cityStateFragmentLines: Int
    let completeLocationPickupOnly: Int
    let completeLocationDeliveryOnly: Int
    let completeLocationBothRegions: Int
    let completeLocationOutsideRegions: Int
}
let role = try NSRegularExpression(pattern: #"(?i)\b(ship\s*(?:from|to)|shipper|consignee|pickup|delivery)\b"#)
let completeLocation = try NSRegularExpression(pattern: #"(?i)\b[A-Z][A-Z .\u0027-]{1,39}\s*,?\s+(?:AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\s*,?\s+\d{5}\b"#)
let zip = try NSRegularExpression(pattern: #"(?i)\b(?:AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\s+\d{5}\b"#)
let zipToken = try NSRegularExpression(pattern: #"\b\d{5}(?:-?\d{4})?\b"#)
let stateToken = try NSRegularExpression(pattern: BOLAddressParser.statePattern, options: [.caseInsensitive])
let cityStateFragment = try NSRegularExpression(pattern: #"(?i)\b[A-Z][A-Z .'-]{1,39}\s*,?\s+(?:AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\b"#)
func count(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}
var output: [Trial] = []
for (index, url) in files.enumerated() {
    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
        fatalError("Expected regular fixture image")
    }
    // Preserve synthetic test labels; private reports use anonymous document IDs.
    let name = expectedCount == 30 ? String(format: "BOL_%02d", index + 1) : url.deletingPathExtension().lastPathComponent
    guard let source = NSImage(contentsOf: url),
          let tiff = source.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cg = bitmap.cgImage else { fatalError("Cannot load image \(name)") }
    var parsedRotations: [BOLParserV9.RotationParse] = []
    for (degrees, orientation) in [(0, CGImagePropertyOrientation.up), (90, .right), (180, .down), (270, .left)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        // Materialize rotated pixels: orientation metadata alone produced identical
        // OCR scores on all four rotations in macOS CI.
        let rotated = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(orientation.rawValue))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let rotatedCG = context.createCGImage(rotated, from: rotated.extent.integral) else {
            fatalError("Failed to materialize rotated pixels")
        }
        // A small pixel fingerprint proves that the physical image varies by rotation,
        // independently of Vision's orientation-invariant text recognition.
        let sampleW = 31
        let sampleH = 23
        var pixels = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let sampleSpace = CGColorSpaceCreateDeviceRGB()
        guard let sampleContext = CGContext(data: &pixels, width: sampleW, height: sampleH,
                                            bitsPerComponent: 8, bytesPerRow: sampleW * 4,
                                            space: sampleSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Cannot create pixel fingerprint context")
        }
        sampleContext.interpolationQuality = .high
        sampleContext.draw(rotatedCG, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        var hash: UInt64 = 14695981039346656037
        for byte in pixels {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let fingerprint = String(hash, radix: 16)
        try VNImageRequestHandler(cgImage: rotatedCG, orientation: .up).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let roles = lines.filter { count(role, $0.string) }.count
        let locations = lines.filter { count(zip, $0.string) }.count
        let confidence = lines.isEmpty ? 0 : lines.reduce(0.0) { $0 + Double($1.confidence) } / Double(lines.count)
        let score = Double(locations * 8 + roles * 5) + Double(min(lines.count,80)) * 0.15 + confidence * 10
        let doc = OCRDocument(file: name, lines: (request.results ?? []).compactMap { item in
            guard let candidate = item.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, confidence: Double(candidate.confidence), x: Double(item.boundingBox.minX), y: Double(item.boundingBox.minY))
        })
        let baseline = BOLAddressParserV8.parse(doc)
        func anchorStats(_ index: Int) -> (Int, Int, Int, Int) {
            let own = BOLAddressParser.rolePatterns[index]
            let other = BOLAddressParser.rolePatterns[1 - index]
            let anchors = doc.lines.filter {
                BOLAddressParser.matches(own, $0.text) &&
                !BOLAddressParser.matches(other, $0.text)
            }
            let nearby = doc.lines.filter { line in
                anchors.contains { anchor in
                    let dy = anchor.y - line.y
                    return dy >= -0.012 && dy < 0.20 && abs(anchor.x - line.x) < 0.25
                }
            }
            return (anchors.count, nearby.count, nearby.filter { count(zip, $0.text) }.count,
                    nearby.filter { count(completeLocation, $0.text) }.count)
        }
        let pickupStats = anchorStats(0)
        let deliveryStats = anchorStats(1)
        func inRoleWindow(_ line: OCRLine, roleIndex: Int) -> Bool {
            let own = BOLAddressParser.rolePatterns[roleIndex]
            let other = BOLAddressParser.rolePatterns[1 - roleIndex]
            return doc.lines.contains { anchor in
                guard BOLAddressParser.matches(own, anchor.text),
                      !BOLAddressParser.matches(other, anchor.text) else { return false }
                let dy = anchor.y - line.y
                return dy >= -0.012 && dy < 0.20 && abs(anchor.x - line.x) < 0.25
            }
        }
        let completeLines = doc.lines.filter { count(completeLocation, $0.text) }
        let pickupOnly = completeLines.filter { inRoleWindow($0, roleIndex: 0) && !inRoleWindow($0, roleIndex: 1) }.count
        let deliveryOnly = completeLines.filter { inRoleWindow($0, roleIndex: 1) && !inRoleWindow($0, roleIndex: 0) }.count
        let bothRegions = completeLines.filter { inRoleWindow($0, roleIndex: 0) && inRoleWindow($0, roleIndex: 1) }.count
        let outsideRegions = completeLines.count - pickupOnly - deliveryOnly - bothRegions
        let parsed = BOLParserV9.parse(doc)
        let diagnostics = BOLParserV9.diagnosticSummary(doc)
        parsedRotations.append(BOLParserV9.RotationParse(degrees: degrees, document: parsed))
        var trial = Trial(file: name, rotationClockwise: degrees, lines: lines.count,
                            meanConfidence: confidence, roleHeadings: roles, stateZIPLines: locations, score: score,
                            pixelWidth: rotatedCG.width, pixelHeight: rotatedCG.height,
                            pixelFingerprint: fingerprint,
                            pickupDetected: parsed.pickup != nil, deliveryDetected: parsed.delivery != nil,
                            v8PickupDetected: baseline.pickup.cityStateZIP != nil,
                            v8DeliveryDetected: baseline.delivery.cityStateZIP != nil,
                            v8PickupFallbackReason: BOLParserV9.fallbackRejectionCode(baseline.pickup, role: 0),
                            v8DeliveryFallbackReason: BOLParserV9.fallbackRejectionCode(baseline.delivery, role: 1),
                            pickupAnchors: pickupStats.0, deliveryAnchors: deliveryStats.0,
                            pickupNearbyLines: pickupStats.1, deliveryNearbyLines: deliveryStats.1,
                            completeLocationLines: doc.lines.filter { count(completeLocation, $0.text) }.count,
                            pickupRegionStateZIPLines: pickupStats.2, deliveryRegionStateZIPLines: deliveryStats.2,
                            pickupRegionCompleteLines: pickupStats.3, deliveryRegionCompleteLines: deliveryStats.3,
                            zipTokenLines: doc.lines.filter { count(zipToken, $0.text) }.count,
                            stateTokenLines: doc.lines.filter { count(stateToken, $0.text) }.count,
                            cityStateFragmentLines: doc.lines.filter { count(cityStateFragment, $0.text) }.count,
                            completeLocationPickupOnly: pickupOnly,
                            completeLocationDeliveryOnly: deliveryOnly,
                            completeLocationBothRegions: bothRegions,
                            completeLocationOutsideRegions: outsideRegions)
        trial.pickupOrigin = diagnostics.pickupOrigin
        trial.deliveryOrigin = diagnostics.deliveryOrigin
        trial.pickupHeadingOwnedLines = diagnostics.pickupHeadingOwnedLines
        trial.deliveryHeadingOwnedLines = diagnostics.deliveryHeadingOwnedLines
        trial.conflictingAddressFields = diagnostics.conflictingAddressFields
        trial.ambiguousColumnBoundaries = diagnostics.ambiguousColumnBoundaries
        output.append(trial)
    }
    let merged = BOLParserV9.consolidateRotations(parsedRotations)
    for i in (output.count - 4)..<output.count {
        output[i].consolidatedPickupDetected = merged.pickup != nil
        output[i].consolidatedDeliveryDetected = merged.delivery != nil
        output[i].consolidatedPickupDisagreement = BOLParserV9.rotationDisagreementKind(parsedRotations, role: 0)
        output[i].consolidatedDeliveryDisagreement = BOLParserV9.rotationDisagreementKind(parsedRotations, role: 1)
        output[i].consolidatedPickupConflict = merged.warnings.contains { $0.hasPrefix("pickup: cross-rotation conflict") }
        output[i].consolidatedDeliveryConflict = merged.warnings.contains { $0.hasPrefix("delivery: cross-rotation conflict") }
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(output))


