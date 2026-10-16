import Foundation

@available(macOS 10.15, *)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("synthetic regression failed: \(message)") }
}

func line(_ text: String, _ x: Double, _ y: Double) -> OCRLine {
    OCRLine(text: text, confidence: 0.99, x: x, y: y)
}

@available(macOS 10.15, *)
func runSyntheticTests() {
    let sideBySide = OCRDocument(file: "synthetic-columns", lines: [
        line("SHIPPER", 0.20, 0.90), line("CONSIGNEE", 0.75, 0.90),
        line("TESTVILLE, CO 00000", 0.20, 0.82), line("SAMPLE CITY, CO 00001", 0.75, 0.82)
    ])
    let columns = BOLParserV9.diagnosticSummary(sideBySide)
    check(columns.pickupOrigin == "region" || columns.pickupOrigin == "layout", "column pickup origin")
    check(columns.deliveryOrigin == "region" || columns.deliveryOrigin == "layout", "column delivery origin")
    check(columns.pickupHeadingOwnedLines > 0 && columns.deliveryHeadingOwnedLines > 0, "heading ownership")

    let split = OCRDocument(file: "synthetic-split", lines: [
        line("SHIP FROM", 0.20, 0.90), line("TESTVILLE", 0.20, 0.82),
        line("CO 00000", 0.20, 0.77)
    ])
    let splitSummary = BOLParserV9.diagnosticSummary(split)
    check(splitSummary.pickupOrigin == "split-region" || splitSummary.pickupOrigin == "layout" || splitSummary.pickupOrigin == "none", "split-line classification is aggregate-safe")

    let billing = OCRDocument(file: "synthetic-billing", lines: [
        line("SHIPPER", 0.20, 0.90), line("BILL TO", 0.20, 0.80),
        line("BILLING CITY, CO 00002", 0.20, 0.74)
    ])
    let billingResult = BOLParserV9.parse(billing)
    check(billingResult.pickup == nil && billingResult.delivery == nil, "billing address rejected")

    let shipperThenBilling = OCRDocument(file: "synthetic-shipper-billing", lines: [
        line("SHIPPER", 0.20, 0.90), line("BILL TO", 0.20, 0.80),
        line("BILLING CITY, CO 00002", 0.20, 0.74)
    ])
    let shipperThenBillingResult = BOLParserV9.parse(shipperThenBilling)
    check(shipperThenBillingResult.pickup == nil, "billing-only section cannot become shipper")

    let legitimateThenBilling = OCRDocument(file: "synthetic-legitimate-billing", lines: [
        line("SHIPPER", 0.20, 0.90), line("ORIGIN CITY, CO 00003", 0.20, 0.82),
        line("BILL TO", 0.20, 0.70), line("BILLING CITY, CO 00002", 0.20, 0.64)
    ])
    let legitimateThenBillingResult = BOLParserV9.parse(legitimateThenBilling)
    check(legitimateThenBillingResult.pickup?.city == "ORIGIN CITY", "legitimate shipper survives billing")

    let sideBySideBilling = OCRDocument(file: "synthetic-side-by-side-billing", lines: [
        line("SHIPPER", 0.20, 0.90), line("BILL TO", 0.75, 0.90),
        line("ORIGIN CITY, CO 00003", 0.20, 0.82), line("BILLING CITY, CO 00002", 0.75, 0.82)
    ])
    let sideBySideBillingResult = BOLParserV9.parse(sideBySideBilling)
    check(sideBySideBillingResult.pickup?.city == "ORIGIN CITY", "side-by-side billing does not steal shipper")

    let consigneeThenBilling = OCRDocument(file: "synthetic-consignee-billing", lines: [
        line("CONSIGNEE", 0.75, 0.90), line("DESTINATION CITY, CO 00004", 0.75, 0.82),
        line("BILL TO", 0.20, 0.70), line("BILLING CITY, CO 00002", 0.20, 0.64)
    ])
    let consigneeThenBillingResult = BOLParserV9.parse(consigneeThenBilling)
    check(consigneeThenBillingResult.delivery?.city == "DESTINATION CITY", "consignee survives unrelated billing")

    func parsed(_ city: String) -> BOLParserV9.ParsedDocument {
        let value = BOLParserV9.Location(city: city, state: "CO", zip: "00000")
        return BOLParserV9.ParsedDocument(file: "conflict", pickup: value, delivery: nil,
                                           pickupStatus: "review", deliveryStatus: "review-required", warnings: [])
    }
    let trials = [0, 90, 180, 270].map {
        BOLParserV9.RotationParse(degrees: $0, document: parsed($0 == 90 ? "OTHER CITY" : "TESTVILLE"))
    }
    check(BOLParserV9.rotationDisagreementKind(trials, role: 0) == "city-only", "rotation disagreement category")
    check(BOLParserV9.consolidateRotations(trials).pickup == nil, "conflicting rotations remain unresolved")

    // Synthetic-only ZIP5 and role-heading safety checks. No real document values.
    check(BOLParserV9.location("EXAMPLE CITY, CO 12345-6789")?.zip == "12345",
          "ZIP+4 must normalize to five digits")
    check(BOLParserV9.location("EXAMPLE CITY, CO 12345")?.zip == "12345",
          "ZIP5 must remain unchanged")
    check(BOLParserV9.location("EXAMPLE CITY, XX 12345") == nil,
          "unknown state code must be rejected")
    check(BOLParserV9.location("EXAMPLE CITY, CO 1234") == nil,
          "short ZIP must be rejected")
    check(BOLParserV9.isRoleHeading("SHIPPER", role: 0),
          "shipper maps to pickup")
    check(BOLParserV9.isRoleHeading("CONSIGNEE", role: 1),
          "consignee maps to delivery")
    check(!BOLParserV9.isRoleHeading("BILL TO", role: 0),
          "billing heading cannot become pickup")
    check(!BOLParserV9.isRoleHeading("BILL TO", role: 1),
          "billing heading cannot become delivery")


    // Independent synthetic geometry and rotation diagnostics, with no private fixtures.
    let alignedColumns = BOLParserV9.parse(sideBySide)
    check(alignedColumns.pickup?.city == "TESTVILLE",
          "aligned shipper column retains pickup city")
    check(alignedColumns.delivery?.city == "SAMPLE CITY",
          "aligned consignee column retains delivery city")

    let splitOnly = BOLParserV9.parse(split)
    check(splitOnly.delivery == nil,
          "split pickup fragments must not invent a delivery")
    check(["none", "layout", "split-region", "region", "v8-fallback"]
          .contains(splitSummary.pickupOrigin),
          "split-fragment diagnostics use a fixed origin category")

    let ambiguousHeading = OCRDocument(file: "synthetic-ambiguous-heading", lines: [
        line("SHIPPER / CONSIGNEE", 0.30, 0.90),
        line("EXAMPLE CITY, CO 12345", 0.30, 0.82)
    ])
    let ambiguousResult = BOLParserV9.parse(ambiguousHeading)
    check(ambiguousResult.pickup == nil && ambiguousResult.delivery == nil,
          "combined opposing role heading must not imply ownership")
    check(!BOLParserV9.isRoleHeading("SHIPPER / CONSIGNEE", role: 0),
          "mixed role heading rejected for pickup")
    check(!BOLParserV9.isRoleHeading("SHIPPER / CONSIGNEE", role: 1),
          "mixed role heading rejected for delivery")

    let distinctZipDocuments: [BOLParserV9.RotationParse] = [0, 90, 180, 270].map { degree in
        let zip = degree == 180 ? "12346" : "12345"
        let candidate = BOLParserV9.Location(city: "EXAMPLE CITY", state: "CO", zip: zip)
        return BOLParserV9.RotationParse(
            degrees: degree,
            document: BOLParserV9.ParsedDocument(
                file: "synthetic-zip-conflict", pickup: candidate, delivery: nil,
                pickupStatus: "review", deliveryStatus: "review-required", warnings: []))
    }
    check(BOLParserV9.rotationDisagreementKind(distinctZipDocuments, role: 0) == "zip-only",
          "cross-rotation conflicting ZIP categorized")
    check(BOLParserV9.consolidateRotations(distinctZipDocuments).pickup == nil,
          "ZIP conflicts cannot be accepted by majority vote")


    // Diagnosis-only: distinguish absent OCR evidence from parser rejection.
    let noEvidence = OCRDocument(file: "synthetic-no-ocr-evidence", lines: [
        line("DOCUMENT HEADER", 0.20, 0.90), line("REFERENCE NUMBER", 0.20, 0.82)
    ])
    let noEvidenceReport = BOLParserV9.diagnosticSummary(noEvidence)
    check(noEvidenceReport.pickupOrigin == "none" &&
          noEvidenceReport.deliveryOrigin == "none",
          "missing OCR role/address evidence classified as no candidate")

    let unownedLocation = OCRDocument(file: "synthetic-unowned-location", lines: [
        line("DOCUMENT HEADER", 0.20, 0.90),
        line("EXAMPLE CITY, CO 12345", 0.20, 0.82)
    ])
    let unownedReport = BOLParserV9.diagnosticSummary(unownedLocation)
    check(unownedReport.pickupOrigin == "none" &&
          unownedReport.deliveryOrigin == "none",
          "legible location without trusted heading not assigned to a role")

    let unownedParsed = BOLParserV9.parse(unownedLocation)
    check(unownedParsed.pickup == nil && unownedParsed.delivery == nil,
          "unowned OCR location remains unassigned")

    let billingReport = BOLParserV9.diagnosticSummary(billing)
    check(billingReport.pickupOrigin == "none" &&
          billingReport.deliveryOrigin == "none",
          "billing-only role evidence not treated as valid candidate")

    // Inspect rejection reasons without publishing evidence or changing selection.
    let candidateAccepted = AddressSelection(street: nil, cityStateZIP: "EXAMPLE CITY, CO 12345",
                                             status: "review", evidence: "SHIPPER")
    let candidateBilling = AddressSelection(street: nil, cityStateZIP: "EXAMPLE CITY, CO 12345",
                                            status: "review", evidence: "BILL TO")
    let candidateNoAnchor = AddressSelection(street: nil, cityStateZIP: "EXAMPLE CITY, CO 12345",
                                             status: "review", evidence: nil)
    let candidateWrongRole = AddressSelection(street: nil, cityStateZIP: "EXAMPLE CITY, CO 12345",
                                              status: "review", evidence: "CONSIGNEE")
    let candidateBadLocation = AddressSelection(street: nil, cityStateZIP: "NOT A LOCATION",
                                                status: "review", evidence: "SHIPPER")
    let candidateUnreviewed = AddressSelection(street: nil, cityStateZIP: "EXAMPLE CITY, CO 12345",
                                               status: "missing", evidence: "SHIPPER")

    check(BOLParserV9.fallbackRejectionCode(candidateAccepted, role: 0) == "accepted",
          "valid fallback candidate diagnostic")
    check(BOLParserV9.fallbackRejectionCode(candidateBilling, role: 0) == "billing-anchor",
          "billing fallback rejection diagnostic")
    check(BOLParserV9.fallbackRejectionCode(candidateNoAnchor, role: 0) == "missing-anchor",
          "missing anchor rejection diagnostic")
    check(BOLParserV9.fallbackRejectionCode(candidateWrongRole, role: 0) == "untrusted-anchor",
          "wrong-role anchor rejection diagnostic")
    check(BOLParserV9.fallbackRejectionCode(candidateBadLocation, role: 0) == "location-format",
          "malformed city/state/ZIP rejection diagnostic")
    check(BOLParserV9.fallbackRejectionCode(candidateUnreviewed, role: 0) == "v8-status-not-review",
          "unreviewed baseline rejection diagnostic")
    check(BOLParserV9.fallbackRejectionCode(candidateAccepted, role: 2) == "invalid-role",
          "invalid role rejection diagnostic")

    print("BOLParserV9 synthetic diagnostics: passed")
}

if #available(macOS 10.15, *) { runSyntheticTests() }
