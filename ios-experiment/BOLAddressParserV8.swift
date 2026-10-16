import Foundation
public struct OCRLine: Codable {
 public let text:String; public let confidence:Double; public let x:Double; public let y:Double
}
public struct OCRDocument: Codable { public let file:String; public let lines:[OCRLine] }
public struct AddressSelection: Codable { public let street:String?; public let cityStateZIP:String?; public let status:String; public let evidence:String? }
public struct BOLAddressResult: Codable { public let file:String; public let pickup:AddressSelection; public let delivery:AddressSelection }
public enum BOLAddressParser {
 static func matches(_ pattern:String,_ text:String)->Bool { text.range(of:pattern,options:[.regularExpression,.caseInsensitive]) != nil }
 static let rolePatterns=[#"\b(ship\s*from|shipper|ship-from|pickup|pick\s*up|origin|from\s*:)\b"#,#"\b(ship\s*to|consignee|consigned\s*to|deliver\s*to|delivery|destination|ship-to|ultimate consignee)\b"#]
 static let streetPattern=#"\b\d{1,6}\s+(?:[NSEW]\s+)?[A-Za-z0-9.'-]+(?:\s+[A-Za-z0-9.'-]+){0,8}"#
 static let zipPattern=#"\b\d{5}(?:-?\d{4})?\b"#
 static func normalizeZIP(_ raw: String) -> String? {
  let pattern = #"\b(\d{5})(?:-?\d{4})?\b"#
  guard let match = raw.range(of: pattern, options: .regularExpression) else { return nil }
  return String(raw[match].prefix(5))
 }
 static let statePattern=#"\b(?:AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\b"#
 static let roadPattern=#"\b(?:st|street|ave|avenue|avenu|rd|road|blvd|boulevard|dr|drive|ln|lane|way|ct|court|pkwy|parkway|hwy|highway|pl|place|trl|trail|circle|cir|loop|route|rte|terrace|ter|plaza|pike|park|expressway|expy)\b"#
 static let nonAddressPattern=#"(?i)(liabilit|limitation|shipment|pallet|lbs?\b|weight|freight|invoice|order|total|pieces|\bpcs\b|\bqty\b|\bpage\b|\bdate\b|\bbol\b|\bcpu\b|days remaining|\$|\bU\.S\.C\.|\d+\s*/\s*\d+)"#
 static func validStreet(_ raw:String)->Bool {
  let t=raw.replacingOccurrences(of:#"^(?i)(address|street|ship to address|ship from address)\s*:\s*"#,with:"",options:.regularExpression).trimmingCharacters(in:.whitespaces)
  return matches(#"^\d{1,6}\s+[A-Za-z]"#,t) && matches(roadPattern,t) && !matches(nonAddressPattern,t)
 }
 static func selection(_ doc:OCRDocument,role:Int)->AddressSelection {
  let lines=doc.lines
  let anchors=lines.filter { line in
   let t=line.text.lowercased()
   return matches(rolePatterns[role],t) && !matches(#"bill\s*to|freight\s*charges|third.party|sold\s*to|notes|instructions"#,t) && !matches(rolePatterns[1-role],t)
  }
  struct Choice { let score:Double; let street:String; let city:String?; let anchor:String }
  var choices:[Choice]=[]
  for anchor in anchors {
   let otherAnchors=lines.filter { matches(rolePatterns[1-role],$0.text) && abs($0.x-anchor.x)<0.24 && $0.y<anchor.y && $0.y>anchor.y-0.3 }
   let cutoff=otherAnchors.map(\.y).max() ?? -1.0
   for s in lines {
    let dy=anchor.y-s.y,dx=abs(anchor.x-s.x)
    guard dy >= -0.025 && dy < 0.23 && dx < 0.31 && s.y > cutoff else {continue}
    guard matches(streetPattern,s.text),validStreet(s.text) else {continue}
    let near=lines.filter { abs($0.x-s.x)<0.24 && abs($0.y-s.y)<0.105 && $0.text != s.text }
    let cityLine=near.filter { matches(zipPattern,$0.text) && (matches(statePattern,$0.text) || near.contains(where:{matches(statePattern,$0.text)})) }.min(by:{abs($0.y-s.y)<abs($1.y-s.y)})
    var city:String?=cityLine?.text
    if city == nil {
     let stateLine=near.filter {matches(statePattern,$0.text) && !matches(zipPattern,$0.text)}.min(by:{abs($0.y-s.y)<abs($1.y-s.y)})
     let zipLine=near.filter {matches(zipPattern,$0.text) && !matches(statePattern,$0.text)}.min(by:{abs($0.y-s.y)<abs($1.y-s.y)})
     if let st=stateLine,let zp=zipLine {city="\(st.text) \(zp.text)"}
    }
    let roleStrength:Double=matches(#"ship\s*from|ship\s*to|pick\s*up|deliver\s*to|consignee|shipper"#,anchor.text) ? 20:0
    let score=100-135*max(dy,0)-65*dx+(city == nil ? -24:18)+roleStrength
    choices.append(Choice(score:score,street:s.text,city:city,anchor:anchor.text))
   }
  }
  guard let best=choices.max(by:{$0.score<$1.score}) else {return AddressSelection(street:nil,cityStateZIP:nil,status:"missing",evidence:nil)}
  return AddressSelection(street:best.street,cityStateZIP:best.city,status:best.city == nil ? "incomplete-review":"review",evidence:best.anchor)
 }
 public static func parse(_ doc:OCRDocument)->BOLAddressResult {
  let p=selection(doc,role:0),d=selection(doc,role:1)
  if let ps=p.street,let ds=d.street,ps.caseInsensitiveCompare(ds) == .orderedSame {
   return BOLAddressResult(file:doc.file,pickup:AddressSelection(street:nil,cityStateZIP:nil,status:"ambiguous",evidence:"same street selected for both roles"),delivery:AddressSelection(street:nil,cityStateZIP:nil,status:"ambiguous",evidence:"same street selected for both roles"))
  }
  return BOLAddressResult(file:doc.file,pickup:p,delivery:d)
 }
}
public enum BOLAddressParserV8 {
 // City/state/ZIP extraction is independent of street recognition.
 private static let complete = #"(?i)\b([A-Z][A-Z.' -]{1,40}?)\s*,?\s+([A-Z]{2})\s*,?\s+(\d{5})(?:-?\d{4})?\b"#
 private static let stateZIP = #"(?i)\b([A-Z]{2})\s*,?\s+(\d{5})(?:-?\d{4})?\b"#
 private static let cityState = #"(?i)\b([A-Z][A-Z.' -]{1,40}?)\s*,?\s+([A-Z]{2})\s*$"#
 private static let cityOnly = #"(?i)^[A-Z][A-Z.' -]{1,40}$"#
 private static let blocked = #"(?i)\b(bill to|sold to|invoice|total|amount|freight charges|carrier|reference|phone|fax|weight|days remaining)\b"#
 private static let validStates: Set<String> = Set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY".split(separator:" ").map(String.init))
 private static func groups(_ pattern:String,_ value:String)->[String]? {
  guard let re=try? NSRegularExpression(pattern:pattern), let match=re.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) else {return nil}
  return (0..<match.numberOfRanges).compactMap { i in
   guard let range=Range(match.range(at:i),in:value) else{return nil}
   return String(value[range]).trimmingCharacters(in:.whitespacesAndNewlines)
  }
 }
 private static func cleanCity(_ value:String)->String {
  let trimmed=value.replacingOccurrences(of:#"(?i)^(?:ship\s*to|ship\s*from|consignee|shipper|pickup|delivery|origin|destination)\s*[:\-]?\s*"#,with:"",options:.regularExpression)
  let withoutLabel=trimmed.replacingOccurrences(of:#"(?i)^\s*(?:city\s*/\s*state\s*/\s*zip|city\s+state\s+zip)\s*:\s*"#,with:"",options:.regularExpression)
  return withoutLabel.trimmingCharacters(in:CharacterSet(charactersIn:" ,:-"))
 }
 private static func candidate(_ doc:OCRDocument, role:Int)->AddressSelection {
  let lines=doc.lines
  let anchors=lines.filter { line in
   BOLAddressParser.matches(BOLAddressParser.rolePatterns[role],line.text) &&
   !BOLAddressParser.matches(BOLAddressParser.rolePatterns[1-role],line.text) &&
   !BOLAddressParser.matches(blocked,line.text)
  }
  struct Hit { let value:String; let score:Double; let evidence:String }
  var hits:[Hit]=[]
  for anchor in anchors {
   let other=lines.filter { BOLAddressParser.matches(BOLAddressParser.rolePatterns[1-role],$0.text) && abs($0.x-anchor.x)<0.23 && $0.y<anchor.y && $0.y>anchor.y-0.28 }
   let cutoff=other.map(\.y).max() ?? -1.0
   let nearby=lines.filter { line in
    let dy=anchor.y-line.y
    return dy >= -0.028 && dy < 0.23 && abs(line.x-anchor.x)<0.28 && line.y>cutoff && !BOLAddressParser.matches(blocked,line.text)
   }.sorted { $0.y > $1.y }
   for line in nearby {
    let text=line.text
    let dy=max(0,anchor.y-line.y),dx=abs(anchor.x-line.x)
    let base=120-140*dy-55*dx
    if let g=groups(complete,text),g.count==4,validStates.contains(g[2].uppercased()) {
     let city=cleanCity(g[1])
     if !city.isEmpty && !BOLAddressParser.matches(blocked,city) {hits.append(Hit(value:"\(city), \(g[2].uppercased()) \(g[3])",score:base+35,evidence:anchor.text))}
    }
    if let g=groups(stateZIP,text),g.count==3,validStates.contains(g[1].uppercased()) {
     let before=nearby.filter { $0.y > line.y && $0.y-line.y<0.075 && abs($0.x-line.x)<0.20 }
     for cityLine in before {
      let city=cleanCity(cityLine.text)
      if groups(cityOnly,city) != nil && !BOLAddressParser.matches(blocked,city) && !BOLAddressParser.matches(BOLAddressParser.roadPattern,city) {
       hits.append(Hit(value:"\(city), \(g[1].uppercased()) \(g[2])",score:base+14,evidence:anchor.text))
      }
     }
    }
    if let g=groups(cityState,text),g.count==3,validStates.contains(g[2].uppercased()) {
     let city=cleanCity(g[1])
     if !city.isEmpty && !BOLAddressParser.matches(blocked,city) {
      for zipLine in nearby where zipLine.y<line.y && line.y-zipLine.y<0.08 && abs(zipLine.x-line.x)<0.20 {
       if let zip=BOLAddressParser.normalizeZIP(zipLine.text) {
        hits.append(Hit(value:"\(city), \(g[2].uppercased()) \(zip)",score:base+10,evidence:anchor.text))
       }
      }
     }
    }
   }
  }
  guard let best=hits.max(by:{$0.score<$1.score}) else {
   return AddressSelection(street:nil,cityStateZIP:nil,status:"missing",evidence:nil)
  }
  let distinct=hits.filter {$0.value.caseInsensitiveCompare(best.value) != .orderedSame && $0.score >= best.score-6}
  if !distinct.isEmpty {
   return AddressSelection(street:nil,cityStateZIP:nil,status:"ambiguous",evidence:"multiple plausible city/state/ZIP candidates")
  }
  return AddressSelection(street:nil,cityStateZIP:best.value,status:"review",evidence:best.evidence)
 }
 public static func parse(_ doc:OCRDocument)->BOLAddressResult {
  let pickup=candidate(doc,role:0),delivery=candidate(doc,role:1)
  if let a=pickup.cityStateZIP,let b=delivery.cityStateZIP,a.caseInsensitiveCompare(b) == .orderedSame {
   let flagged=AddressSelection(street:nil,cityStateZIP:nil,status:"ambiguous",evidence:"identical pickup and delivery location candidates")
   return BOLAddressResult(file:doc.file,pickup:flagged,delivery:flagged)
  }
  return BOLAddressResult(file:doc.file,pickup:pickup,delivery:delivery)
 }
}
