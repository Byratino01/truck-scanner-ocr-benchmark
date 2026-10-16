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
    print("BOLParserV9 synthetic diagnostics: passed")
}

if #available(macOS 10.15, *) { runSyntheticTests() }
