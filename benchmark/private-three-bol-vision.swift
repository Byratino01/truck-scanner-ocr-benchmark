import Foundation
import Vision
import AppKit
import ImageIO
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let names = ["BOL_14","BOL_18","BOL_27"]
struct Address: Encodable { let city: String; let state: String; let zip: String }
struct Roles: Encodable {
    let pickup: Address?
    let delivery: Address?
    enum CodingKeys: String, CodingKey { case pickup, delivery }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let pickup { try container.encode(pickup, forKey: .pickup) }
        else { try container.encodeNil(forKey: .pickup) }
        if let delivery { try container.encode(delivery, forKey: .delivery) }
        else { try container.encodeNil(forKey: .delivery) }
    }
}
struct Evidence: Encodable { let text: String; let x: Double; let y: Double }
struct Prediction: Encodable { let apple_vision: Roles; let ocr_lines: [Evidence]; let ocr_rotation_degrees: Int }
var result: [String:Prediction] = [:]
for name in names {
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.deletingPathExtension().lastPathComponent == name && ["jpg","jpeg","png","heic"].contains($0.pathExtension.lowercased()) }
    guard files.count == 1, let image = NSImage(contentsOf: files[0]),
          let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let cg = bitmap.cgImage else { fatalError("Invalid private image") }
    var rotations: [BOLParserV9.RotationParse] = []
    var bestEvidence: [Evidence] = []
    var bestQuality = -1.0
    var bestDegrees = 0
    for (degrees, orientation) in [(0,CGImagePropertyOrientation.up),(90,.right),(180,.down),(270,.left)] {
        let rotated = CIImage(cgImage:cg).oriented(forExifOrientation:Int32(orientation.rawValue))
        guard let pixels = CIContext(options:[.useSoftwareRenderer:true]).createCGImage(rotated,from:rotated.extent.integral) else { fatalError("Image rotation failed") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage:pixels,orientation:.up).perform([request])
        let lines = (request.results ?? []).compactMap { item -> OCRLine? in
            guard let candidate = item.topCandidates(1).first else { return nil }
            return OCRLine(text:candidate.string,confidence:Double(candidate.confidence),x:Double(item.boundingBox.minX),y:Double(item.boundingBox.minY))
        }
        let quality = lines.reduce(0.0) { $0 + $1.confidence * Double(max(1, $1.text.count)) }
        if quality > bestQuality {
            bestQuality = quality
            bestDegrees = degrees
            bestEvidence = lines.map { Evidence(text: $0.text, x: $0.x, y: $0.y) }
                .sorted { $0.y == $1.y ? $0.x < $1.x : $0.y > $1.y }
        }
        rotations.append(BOLParserV9.RotationParse(degrees:degrees,document:BOLParserV9.parse(OCRDocument(file:name,lines:lines))))
    }
    let merged = BOLParserV9.consolidateRotations(rotations)
    func convert(_ v:BOLParserV9.Location?) -> Address? {
        guard let v else { return nil }
        return Address(city:v.city,state:v.state,zip:v.zip)
    }
    result[name] = Prediction(apple_vision:Roles(pickup:convert(merged.pickup),delivery:convert(merged.delivery)), ocr_lines:bestEvidence, ocr_rotation_degrees:bestDegrees)
}
try JSONEncoder().encode(result).write(to:output,options:.atomic)
print("APPLE_VISION_PRIVATE_PREDICTIONS: 3/3 documents; values suppressed")
