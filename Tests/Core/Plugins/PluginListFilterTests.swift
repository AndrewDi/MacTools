import XCTest
@testable import MacTools

final class PluginListFilterTests: XCTestCase {
    func testTurkishCapitalizationMatchesInBothDirections() {
        for (query, text) in [
            ("iç içe klasörler", "İç içe klasörler"),
            ("istem şablonu", "İstem Şablonu"),
            ("imleci izle", "İmleci İzle"),
            ("izleme dörtgeni hareketi", "İzleme Dörtgeni Hareketi"),
            ("Işığı azaltın", "ışığı azaltın"),
            ("Ortam Işığına", "Ortam ışığına"),
            ("Uygulama Izgarasını", "Uygulama ızgarasını"),
            ("I\u{0307}ç", "iç"),
        ] {
            XCTAssertTrue(PluginListFilter.matches(query: query, in: [text]), query)
            XCTAssertTrue(PluginListFilter.matches(query: text, in: [query]), text)
        }
        for query in ["I", "İ", "ı", "i"] {
            for text in ["I", "İ", "ı", "i"] {
                XCTAssertTrue(PluginListFilter.matches(query: query, in: [text]), "\(query) in \(text)")
            }
        }
    }

    func testGermanSharpSMatchesItsCapitalizationVariants() {
        for (query, text) in [
            ("FENSTERHÖHE VERGRÖSSERN", "Fensterhöhe vergrößern"),
            ("ANGEMESSENE GRÖSSE", "Angemessene Größe"),
            ("Straße", "STRASSE"),
            ("STRAẞE", "Straße"),
        ] {
            XCTAssertTrue(PluginListFilter.matches(query: query, in: [text]), query)
            XCTAssertTrue(PluginListFilter.matches(query: text, in: [query]), text)
        }
    }

    func testCanonicalUnicodeAndExistingSubstringBoundaries() {
        XCTAssertTrue(PluginListFilter.matches(query: "  DE\u{0301}FILEMENT  ", in: [nil, "Défilement fluide"]))
        XCTAssertFalse(PluginListFilter.matches(query: "Defilement", in: ["Défilement fluide"]))
        XCTAssertFalse(PluginListFilter.matches(query: "isik", in: ["Işık"]))
        XCTAssertTrue(PluginListFilter.matches(query: "  CPU  ", in: ["CPU monitor"]))
        XCTAssertTrue(PluginListFilter.matches(query: " \n ", in: [nil]))
        XCTAssertFalse(PluginListFilter.matches(query: "missing", in: [nil]))
    }
}
