import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Experimental native OCR pipeline: Apple Vision + orientation handling (in AppleVisionOCR),
/// structured JSON output, and conservative V8 regex fallback. No Core ML or SwiftUI dependency.
@available(iOS 16.0, *)
public enum BOLParserV9 {
    public struct Location: Codable {
        public let city: String
        public let state: String
        public let zip: String
    }
    public struct ParsedDocument: Codable {
        public let file: String
        public let pickup: Location?
        public let delivery: Location?
        public let pickupStatus: String
        public let deliveryStatus: String
        public let warnings: [String]
    }

    private static let states = Set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY".split(separator: " ").map(String.init))
    // Parse the complete location line, never a substring of an unrelated address.
    // Allow comma/no-comma, ZIP+4, optional US/USA, and state touching its ZIP.
    private static let stateNames: [String: String] = [
        "ALABAMA":"AL", "ALASKA":"AK", "ARIZONA":"AZ", "ARKANSAS":"AR",
        "CALIFORNIA":"CA", "COLORADO":"CO", "CONNECTICUT":"CT", "DELAWARE":"DE",
        "FLORIDA":"FL", "GEORGIA":"GA", "HAWAII":"HI", "IDAHO":"ID",
        "ILLINOIS":"IL", "INDIANA":"IN", "IOWA":"IA", "KANSAS":"KS",
        "KENTUCKY":"KY", "LOUISIANA":"LA", "MAINE":"ME", "MARYLAND":"MD",
        "MASSACHUSETTS":"MA", "MICHIGAN":"MI", "MINNESOTA":"MN", "MISSISSIPPI":"MS",
        "MISSOURI":"MO", "MONTANA":"MT", "NEBRASKA":"NE", "NEVADA":"NV",
        "NEW HAMPSHIRE":"NH", "NEW JERSEY":"NJ", "NEW MEXICO":"NM", "NEW YORK":"NY",
        "NORTH CAROLINA":"NC", "NORTH DAKOTA":"ND", "OHIO":"OH", "OKLAHOMA":"OK",
        "OREGON":"OR", "PENNSYLVANIA":"PA", "RHODE ISLAND":"RI", "SOUTH CAROLINA":"SC",
        "SOUTH DAKOTA":"SD", "TENNESSEE":"TN", "TEXAS":"TX", "UTAH":"UT",
        "VERMONT":"VT", "VIRGINIA":"VA", "WASHINGTON":"WA", "WEST VIRGINIA":"WV",
        "WISCONSIN":"WI", "WYOMING":"WY"
    ]
    private static let locationRegex: NSRegularExpression = {
        let fullNames = stateNames.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
        let stateAlternatives = (fullNames + states.sorted()).joined(separator: "|")
        let pattern = #"(?i)^\s*(?:City\s*/\s*State\s*/\s*Zip\s*:\s*)?([A-Za-z][A-Za-z .'-]{0,39}?)\s*,?\s+("# +
            stateAlternatives +
            #")\s*,?\s*(?:(?:US|USA)\s*,?\s*)?(\d{5})(?:[- ]?\d{4})?(?:\s+(?:US|USA))?\s*$"#
        return try! NSRegularExpression(pattern: pattern)
    }()
    private static func normalizedLocationText(_ raw: String) -> String {
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let billingPattern = #"(?i)\b(bill\s*to|freight\s*bill|third.party|remit\s*to|sold\s*to|invoice)\b"#

    // Conservative heading recognition for the 30-BOL heading audit.
    // Standalone FROM/TO are valid; incidental prose and signature blocks are not.
    private static let excludedHeading = #"(?i)\b(?:signature|signed|printed\s+name|authorized\s+by|carrier|driver|received\s+by|freight\s+charges|bill\s+to|freight\s+bill|third.party|remit\s+to|sold\s+to|invoice|notify\s+party|instructions|terms\s+and\s+conditions)\b"#
    private static let pickupHeading = #"(?i)^\s*(?:(?:ship\s*[- ]?\s*from|shipper|consignor|origin|pick\s*[- ]?\s*up|pickup)(?:\s*(?:/\s*shipper|address|information|info|location))?|from)\s*[:#-]?\s*$"#
    private static let deliveryHeading = #"(?i)^\s*(?:(?:ship\s*[- ]?\s*to|consignee|consigned\s*to|ultimate\s+consignee|destination|deliver\s*to|delivery|final\s+delivery)(?:\s*(?:/\s*consignee|address|information|info|location))?|receiver(?:\s+(?:address|location))?|receiving\s+(?:address|location)|to)\s*[:#-]?\s*$"#
    static func isRoleHeading(_ text: String, role: Int) -> Bool {
        guard !BOLAddressParser.matches(excludedHeading, text) else { return false }
        let pattern = role == 0 ? pickupHeading : deliveryHeading
        if BOLAddressParser.matches(pattern, text) { return true }

        // OCR can combine a legitimate heading and the first address/company line.
        // Retain legacy contextual heading recognition, excluding opposing roles
        // and unrelated long prose. Bare FROM/TO remain standalone-only.
        guard text.count <= 120 else { return false }
        return BOLAddressParser.matches(BOLAddressParser.rolePatterns[role], text) &&
               !BOLAddressParser.matches(BOLAddressParser.rolePatterns[1 - role], text)
    }


    // Internal for synthetic regression tests; output remains city, state code, ZIP5.
    static func location(_ raw: String?) -> Location? {
        guard let input = raw else { return nil }
        let text = normalizedLocationText(input)
        guard let match = locationRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4,
              let cityRange = Range(match.range(at: 1), in: text),
              let stateRange = Range(match.range(at: 2), in: text),
              let zipRange = Range(match.range(at: 3), in: text) else { return nil }
        let city = String(text[cityRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let stateText = String(text[stateRange]).uppercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let state = stateNames[stateText] ?? stateText
        guard states.contains(state), !city.isEmpty else { return nil }
        return Location(city: city, state: state, zip: String(text[zipRange]))
    }


    // Experimental region-first pass; original V8 remains unchanged.
    // OCR uses normalized coordinates with a bottom-left origin.
    private static func regionCandidate(_ doc: OCRDocument, role: Int) -> Location? {
        let lines = doc.lines
        let anchors = lines.filter {
            isRoleHeading($0.text, role: role) &&
            !isRoleHeading($0.text, role: 1-role) &&
            !BOLAddressParser.matches(billingPattern, $0.text)
        }
        struct Hit { let value: Location; let score: Double }
        var hits: [Hit] = []
        for anchor in anchors {
            let rivals = lines.filter {
                (isRoleHeading($0.text, role: 1-role) ||
                 BOLAddressParser.matches(billingPattern, $0.text)) &&
                abs($0.y - anchor.y) < 0.095
            }
            let right = rivals.filter { $0.x > anchor.x + 0.04 }.map(\.x).min()
            let left = rivals.filter { $0.x < anchor.x - 0.04 }.map(\.x).max()
            let billingFloor = lines.filter {
                BOLAddressParser.matches(billingPattern, $0.text) &&
                abs($0.x - anchor.x) < 0.20 && $0.y < anchor.y
            }.map(\.y).max()
            for line in lines {
                let dy = anchor.y - line.y
                let dx = abs(anchor.x - line.x)
                guard dy >= -0.012 && dy < 0.20 && dx < 0.25 else { continue }
                if let right, line.x >= right - 0.018 { continue }
                if let left, line.x <= left + 0.018 { continue }
                if let billingFloor, line.y <= billingFloor { continue }
                if BOLAddressParser.matches(billingPattern, line.text) { continue }
                guard let value = location(line.text) else { continue }
                hits.append(Hit(value: value, score: 150 - 170 * dy - 70 * dx))
            }
        }
        guard let best = hits.max(by: { $0.score < $1.score }) else { return nil }
        let conflict = hits.contains {
            $0.score >= best.score - 7 &&
            ($0.value.city.caseInsensitiveCompare(best.value.city) != .orderedSame ||
             $0.value.state != best.value.state || $0.value.zip != best.value.zip)
        }
        return conflict ? nil : best.value
    }


    /// Reconstruct a city + state + ZIP from separate OCR fragments inside a role's column.
    /// Require explicit role headings; never borrow a value across billing or opposite-role columns.
    private static func splitRegionCandidate(_ doc: OCRDocument, role: Int) -> Location? {
        let lines = doc.lines
        let zipOnly = #"^\s*(\d{5})(?:-?\d{4})?\s*$"#
        let stateOnly = #"^\s*([A-Za-z]{2})\s*$"#
        let cityOnly = #"^\s*[A-Za-z][A-Za-z .'-]{1,39}\s*$"#
        struct Hit { let value: Location; let score: Double }
        var hits: [Hit] = []
        for anchor in lines where isRoleHeading(anchor.text, role: role) &&
                                  !isRoleHeading(anchor.text, role: 1-role) &&
                                  !BOLAddressParser.matches(billingPattern, anchor.text) {
            let headings = lines.filter {
                abs($0.y - anchor.y) < 0.035 &&
                (isRoleHeading($0.text, role: 1-role) ||
                 BOLAddressParser.matches(billingPattern, $0.text))
            }
            let leftBound = headings.filter { $0.x < anchor.x }.map(\.x).max() ?? -0.1
            let rightBound = headings.filter { $0.x > anchor.x }.map(\.x).min() ?? 1.1
            let nextHeading = lines.filter {
                $0.y < anchor.y - 0.015 && $0.y > anchor.y - 0.28 &&
                abs($0.x - anchor.x) < 0.18 &&
                (isRoleHeading($0.text, role: 1-role) ||
                 BOLAddressParser.matches(billingPattern, $0.text))
            }.map(\.y).max() ?? -1
            let region = lines.filter {
                $0.y < anchor.y && $0.y > max(anchor.y - 0.19, nextHeading) &&
                $0.x > leftBound + 0.025 && $0.x < rightBound - 0.025 &&
                !BOLAddressParser.matches(billingPattern, $0.text)
            }
            // Reconstruct a city, state, country, and ZIP split across OCR lines.
            // Require adjacent OCR lines within the same role-scoped column.
            let cityStatePattern = #"^\s*([A-Za-z][A-Za-z .'-]{1,39}?)\s*,?\s+([A-Za-z]{2})\s*$"#
            let stateZIPPattern = #"^\s*([A-Za-z]{2})\s*,?\s+(\d{5})(?:-?\d{4})?\s*$"#
            let countryPattern = #"(?i)^\s*(?:US|USA|UNITED STATES(?: OF AMERICA)?)\s*$"#
            let ordered = region.sorted { $0.y > $1.y }
            for i in ordered.indices {
                let first = ordered[i]
                for j in (i + 1)..<min(i + 4, ordered.count) {
                    let second = ordered[j]
                    let dy = first.y - second.y
                    guard dy > 0, dy < 0.09, abs(first.x - second.x) < 0.13 else { continue }
                    guard ordered[(i + 1)..<j].allSatisfy({
                        BOLAddressParser.matches(countryPattern, $0.text)
                    }) else { continue }
                    let firstText = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let secondText = second.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let match = try? NSRegularExpression(pattern: cityStatePattern),
                       let m = match.firstMatch(in: firstText, range: NSRange(firstText.startIndex..., in: firstText)),
                       let c = Range(m.range(at: 1), in: firstText),
                       let st = Range(m.range(at: 2), in: firstText),
                       states.contains(String(firstText[st]).uppercased()),
                       BOLAddressParser.matches(zipOnly, secondText),
                       let zip = BOLAddressParser.normalizeZIP(secondText) {
                        hits.append(Hit(value: Location(city: String(firstText[c]).trimmingCharacters(in: .whitespaces),
                                                        state: String(firstText[st]).uppercased(), zip: zip),
                                        score: 120 - 180 * dy - 50 * abs(first.x - second.x)))
                    }
                    if BOLAddressParser.matches(cityOnly, firstText),
                       !BOLAddressParser.matches(BOLAddressParser.roadPattern, firstText),
                       let match = try? NSRegularExpression(pattern: stateZIPPattern),
                       let m = match.firstMatch(in: secondText, range: NSRange(secondText.startIndex..., in: secondText)),
                       let st = Range(m.range(at: 1), in: secondText),
                       let z = Range(m.range(at: 2), in: secondText),
                       states.contains(String(secondText[st]).uppercased()) {
                        hits.append(Hit(value: Location(city: firstText, state: String(secondText[st]).uppercased(),
                                                        zip: String(secondText[z])),
                                        score: 120 - 180 * dy - 50 * abs(first.x - second.x)))
                    }
                }
            }
            // Form OCR often emits city, state, and ZIP as separate fragments.
            for cityLine in region where BOLAddressParser.matches(cityOnly, cityLine.text) &&
                                         !BOLAddressParser.matches(BOLAddressParser.roadPattern, cityLine.text) {
                let city = cityLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                for stateLine in region where abs(stateLine.y - cityLine.y) < 0.045 &&
                                            BOLAddressParser.matches(stateOnly, stateLine.text) {
                    let state = stateLine.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard states.contains(state) else { continue }
                    for zipLine in region where abs(zipLine.y - stateLine.y) < 0.045 &&
                                                BOLAddressParser.matches(zipOnly, zipLine.text) {
                        guard let zip = BOLAddressParser.normalizeZIP(zipLine.text) else { continue }
                        let score = 130 - 150 * (anchor.y - cityLine.y) -
                            120 * abs(cityLine.y - stateLine.y) -
                            120 * abs(stateLine.y - zipLine.y)
                        hits.append(Hit(value: Location(city: city, state: state, zip: zip), score: score))
                    }
                }
            }
        }
        guard let best = hits.max(by: { $0.score < $1.score }) else { return nil }
        if hits.contains(where: {
            $0.score >= best.score - 8 &&
            ($0.value.city.caseInsensitiveCompare(best.value.city) != .orderedSame ||
             $0.value.state != best.value.state || $0.value.zip != best.value.zip)
        }) { return nil }
        return best.value
    }

    // Priority 3: ownership-based recovery for compact side-by-side and stacked forms.
    // Only full city/state/ZIP lines. Never cross billing or opposite-role headings.
    // Multiple distinct plausible matches require manual review.
    static func layoutOwnedCandidate(_ doc: OCRDocument, role: Int) -> Location? {
        guard role == 0 || role == 1 else { return nil }
        let headings = doc.lines.filter {
            BOLAddressParser.matches(billingPattern, $0.text) ||
            isRoleHeading($0.text, role: 0) ||
            isRoleHeading($0.text, role: 1)
        }
        struct Hit { let value: Location; let distance: Double }
        var hits: [Hit] = []
        for line in doc.lines {
            guard let candidate = location(line.text),
                  !BOLAddressParser.matches(billingPattern, line.text) else { continue }
            let owners = headings.compactMap { heading -> (role: Int, distance: Double)? in
                let dy = heading.y - line.y
                let dx = abs(heading.x - line.x)
                // Tight nearest-heading ownership, avoiding other columns and
                // unrelated repeated addresses farther down the form.
                guard dy >= -0.012, dy < 0.22, dx < 0.22 else { return nil }
                if BOLAddressParser.matches(billingPattern, heading.text) {
                    return (role: 2, distance: max(0,dy) + dx * 1.3)
                }
                let pickup = isRoleHeading(heading.text, role: 0)
                let delivery = isRoleHeading(heading.text, role: 1)
                guard pickup != delivery else { return nil }
                return (role: pickup ? 0 : 1, distance: max(0,dy) + dx * 1.3)
            }.sorted { $0.distance < $1.distance }
            guard let owner = owners.first, owner.role == role else { continue }
            // Competing headings equally close indicate an ambiguous column boundary.
            if owners.dropFirst().contains(where: {
                $0.role != role && $0.distance <= owner.distance + 0.018
            }) { continue }
            hits.append(Hit(value: candidate, distance: owner.distance))
        }
        guard let best = hits.min(by: { $0.distance < $1.distance }) else { return nil }
        // If two distinct locations occur under this role, don't guess.
        guard !hits.contains(where: {
            $0.value.city.caseInsensitiveCompare(best.value.city) != .orderedSame ||
            $0.value.state != best.value.state || $0.value.zip != best.value.zip
        }) else { return nil }
        return best.value
    }

    // Cross-rotation aggregation for every document; rotation confidence never
    // substitutes for role evidence. Caller must independently parse each angle.
    public struct RotationParse {
        public let degrees: Int
        public let document: ParsedDocument
        public init(degrees: Int, document: ParsedDocument) {
            self.degrees = degrees
            self.document = document
        }
    }

    // Private benchmark may display these fixed labels; never output location text.
    // This is diagnostic only, not a voting or confidence override.
    static func rotationDisagreementKind(_ trials: [RotationParse], role: Int) -> String {
        guard role == 0 || role == 1 else { return "invalid-role" }
        let candidates: [Location] = trials.compactMap { trial in
            let document = trial.document
            guard (role == 0 ? document.pickupStatus : document.deliveryStatus) == "review" else {
                return nil
            }
            return role == 0 ? document.pickup : document.delivery
        }
        guard candidates.count > 1 else { return "insufficient-evidence" }
        func canonicalCity(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .uppercased()
        }
        let cities = Set(candidates.map { canonicalCity($0.city) })
        let states = Set(candidates.map(\.state))
        let zips = Set(candidates.map(\.zip))
        let differences = [cities.count > 1, states.count > 1, zips.count > 1]
        if !differences.contains(true) { return "consistent" }
        if differences.filter({ $0 }).count > 1 { return "multiple-fields" }
        if differences[0] { return "city-only" }
        if differences[1] { return "state-only" }
        return "zip-only"
    }

    public static func consolidateRotations(_ trials: [RotationParse]) -> ParsedDocument {
        let file = trials.first?.document.file ?? ""
        let valid = trials.count == 4 &&
            Set(trials.map { $0.degrees }) == Set([0, 90, 180, 270]) &&
            trials.allSatisfy { $0.document.file == file }
        guard valid else {
            return ParsedDocument(file: file, pickup: nil, delivery: nil,
                                  pickupStatus: "review-required", deliveryStatus: "review-required",
                                  warnings: ["invalid rotation set; manual review required"])
        }

        func same(_ a: Location, _ b: Location) -> Bool {
            // OCR can insert doubled spaces or line-break whitespace without
            // changing the actual city. Only canonicalize whitespace/case here;
            // never fuzzy-match spellings, state codes, or ZIP digits.
            a.city.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .caseInsensitiveCompare(
                    b.city.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                ) == .orderedSame &&
            a.state == b.state && a.zip == b.zip
        }
        func select(_ role: Int) -> (Location?, Bool) {
            let candidates: [Location] = trials.compactMap { trial in
                let parsed = trial.document
                guard (role == 0 ? parsed.pickupStatus : parsed.deliveryStatus) == "review"
                else { return nil }
                return role == 0 ? parsed.pickup : parsed.delivery
            }
            guard let first = candidates.first else { return (nil, false) }
            // A conflict anywhere in the four angles defeats majority voting:
            // require manual review rather than choosing the most frequent text.
            guard candidates.allSatisfy({ same(first, $0) }) else { return (nil, true) }
            return (first, false)
        }
        var (pickup, pickupConflict) = select(0)
        var (delivery, deliveryConflict) = select(1)
        var warnings: [String] = ["combined four rotations; verify against original photograph"]
        if pickupConflict { warnings.append("pickup: cross-rotation conflict; manual review required") }
        if deliveryConflict { warnings.append("delivery: cross-rotation conflict; manual review required") }
        if let a = pickup, let b = delivery, same(a, b) {
            pickup = nil
            delivery = nil
            warnings.append("pickup and delivery matched same location; manual review required")
        }
        return ParsedDocument(file: file, pickup: pickup, delivery: delivery,
                              pickupStatus: pickup == nil ? "review-required" : "review",
                              deliveryStatus: delivery == nil ? "review-required" : "review",
                              warnings: warnings)
    }

    // Priority 1 + 2: use one location normalizer for region and V8 fallback.
    // The V8 baseline remains untouched. Do not upgrade ambiguous or billing
    // evidence into a location merely because the text looks like an address.
    // Aggregate-safe diagnostic. Never returns OCR text, address values, or evidence.
    static func fallbackRejectionCode(_ candidate: AddressSelection, role: Int) -> String {
        guard role == 0 || role == 1 else { return "invalid-role" }
        guard candidate.status == "review" else { return "v8-status-not-review" }
        guard let heading = candidate.evidence else { return "missing-anchor" }
        if BOLAddressParser.matches(billingPattern, heading) { return "billing-anchor" }
        if !isRoleHeading(heading, role: role) { return "untrusted-anchor" }
        if location(candidate.cityStateZIP) == nil { return "location-format" }
        return "accepted"
    }

    static func validatedV8Fallback(_ candidate: AddressSelection, role: Int) -> Location? {
        guard fallbackRejectionCode(candidate, role: role) == "accepted" else { return nil }
        return location(candidate.cityStateZIP)
    }

    // Returns role candidates and an aggregate-only collision flag.
    static func resolveDuplicateRoles(pickup: Location?, delivery: Location?,
                                      pickupIsLayout: Bool, deliveryIsLayout: Bool)
      -> (Location?, Location?, Bool) {
        guard let a = pickup, let b = delivery,
              a.city.caseInsensitiveCompare(b.city) == .orderedSame,
              a.state == b.state, a.zip == b.zip else {
            return (pickup, delivery, false)
        }
        if pickupIsLayout && !deliveryIsLayout { return (nil, delivery, true) }
        if deliveryIsLayout && !pickupIsLayout { return (pickup, nil, true) }
        return (nil, nil, true)
    }

    /// Only accept a V8 candidate if its supporting anchor is not a billing label.
    /// A null result is preferable to silently assigning a billing address.
    public static func parse(_ document: OCRDocument) -> ParsedDocument {
        let baseline = BOLAddressParserV8.parse(document)
        var warnings: [String] = []
        func checked(_ candidate: AddressSelection, role: String) -> Location? {
            guard let parsed = validatedV8Fallback(candidate, role: role == "pickup" ? 0 : 1) else {
                warnings.append("\(role): V8 fallback rejected; manual review required")
                return nil
            }
            warnings.append("\(role): V8 fallback requires photo verification")
            return parsed
        }
        let pickupStrong = regionCandidate(document, role: 0) ?? splitRegionCandidate(document, role: 0)
        let deliveryStrong = regionCandidate(document, role: 1) ?? splitRegionCandidate(document, role: 1)
        let pickupLayout = pickupStrong == nil ? layoutOwnedCandidate(document, role: 0) : nil
        let deliveryLayout = deliveryStrong == nil ? layoutOwnedCandidate(document, role: 1) : nil
        let pickupRegion = pickupStrong ?? pickupLayout
        let deliveryRegion = deliveryStrong ?? deliveryLayout
        var pickup = pickupRegion ?? checked(baseline.pickup, role: "pickup")
        var delivery = deliveryRegion ?? checked(baseline.delivery, role: "delivery")
        if pickupRegion != nil { warnings.append("pickup: region candidate requires photo verification") }
        if deliveryRegion != nil { warnings.append("delivery: region candidate requires photo verification") }

        // A low-priority layout guess must not erase an independently supported
        // opposite-role result when both point to the same location.
        let pickupIsLayout = pickupStrong == nil && pickupLayout != nil
        let deliveryIsLayout = deliveryStrong == nil && deliveryLayout != nil
        let collision = resolveDuplicateRoles(pickup: pickup, delivery: delivery,
                                              pickupIsLayout: pickupIsLayout,
                                              deliveryIsLayout: deliveryIsLayout)
        pickup = collision.0
        delivery = collision.1
        if collision.2 { warnings.append("same-location role conflict; manual review required") }
        return ParsedDocument(file: document.file, pickup: pickup, delivery: delivery,
                              pickupStatus: pickup == nil ? "review-required" : "review",
                              deliveryStatus: delivery == nil ? "review-required" : "review",
                              warnings: warnings)
    }

#if canImport(UIKit)
    public static func recognizeAndParse(image: UIImage, file: String = "") throws -> ParsedDocument {
        // AppleVisionOCR passes UIImage orientation to Vision and returns normalized coordinates.
        let result = try AppleVisionOCR.recognize(image: image)
        let doc = OCRDocument(file: file, lines: result.lines.map {
            OCRLine(text: $0.text, confidence: Double($0.confidence), x: $0.x, y: $0.y)
        })
        return parse(doc)
    }

#endif

#if canImport(UIKit)
    /// iOS entry point for four independently oriented images of one BOL.
    /// The caller supplies four distinct images tagged 0/90/180/270 degrees.
    /// Results remain review candidates, never automatically verified addresses.
    public static func recognizeAndConsolidate(
        rotations: [(degrees: Int, image: UIImage)], file: String = ""
    ) throws -> ParsedDocument {
        guard rotations.count == 4,
              Set(rotations.map { $0.degrees }) == Set([0, 90, 180, 270]) else {
            return consolidateRotations([])
        }
        let parsed = try rotations.map {
            RotationParse(degrees: $0.degrees,
                          document: try recognizeAndParse(image: $0.image, file: file))
        }
        return consolidateRotations(parsed)
    }
#endif

    public static func json(_ result: ParsedDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(result)
    }
}
