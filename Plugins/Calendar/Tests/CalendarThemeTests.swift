import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import CalendarPlugin

@MainActor
final class CalendarThemeTests: XCTestCase {
    func testDateHoverUsesThemeSurfaceAndPreservesEventColors() throws {
        for fixture in themes {
            let day = makeDay(isToday: false, isInDisplayedMonth: false)
            for hovered in [false, true] {
                let bitmap = try render(
                    CalendarDayCell(day: day, isHovered: hovered, localization: .init(bundle: .main), onOpen: {})
                        .frame(width: 36, height: 36).padding(4),
                    size: NSSize(width: 44, height: 44), fixture: fixture
                )
                let fill = hovered ? fixture.theme.surfaces.controlHover : fixture.theme.surfaces.card
                try assertColor(pixel(bitmap, at: NSPoint(x: 7, y: 22), width: 44), matches: fill,
                                message: "\(fixture.name), hovered: \(hovered)")
                try assertColor(pixel(bitmap, at: NSPoint(x: 22, y: 36.5), width: 44),
                                matches: Color(red: 0.9, green: 0.25, blue: 0.55),
                                message: "\(fixture.name): EventKit colors must remain independent of the UI theme")
            }
        }
    }

    func testTodayUsesReadableTextInMonthAndAgenda() throws {
        for fixture in themes {
            let day = makeDay(isToday: true)
            let month = try render(
                CalendarDayCell(day: day, isHovered: false, localization: .init(bundle: .main), onOpen: {})
                    .frame(width: 36, height: 36).padding(4),
                size: NSSize(width: 44, height: 44), fixture: fixture
            )
            XCTAssertGreaterThan(try matchingPixels(month, color: fixture.theme.text.primary,
                region: CGRect(x: 11, y: 12, width: 22, height: 20), width: 44), 8,
                "\(fixture.name): Today must retain primary text even on a weekend")

            let agenda = try render(CalendarAgendaView(days: [day], dates: [day.date], today: day.date,
                authorization: .fullAccess, errorMessage: nil, localization: .init(bundle: .main),
                onOpenDay: { _ in }, onRequestAccess: {}, onRetry: {})
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 304, height: 150, alignment: .top),
                size: NSSize(width: 304, height: 150), fixture: fixture)
            XCTAssertGreaterThan(try matchingPixels(agenda, color: fixture.theme.text.primary,
                region: CGRect(x: 14, y: 37, width: 18, height: 18), width: 304), 8,
                "\(fixture.name): The agenda date must use readable text rather than a chart accent")
            let background = try pixel(agenda, at: NSPoint(x: 11, y: 45), width: 304)
            XCTAssertGreaterThanOrEqual(try rgb(NSColor(fixture.theme.text.primary)).contrastRatio(with: rgb(background)),
                fixture.contrast == .increased ? 6.98 : 4.48, "\(fixture.name): Agenda date contrast")
        }
    }

    func testHolidayBadgeTextKeepsThemeContrast() throws {
        for fixture in themes {
            for kind in [CalendarHolidayKind.holiday, .workday] {
                let bitmap = try render(CalendarDayCell(day: makeDay(isToday: false, holiday: kind),
                    isHovered: false, localization: .init(bundle: .main), onOpen: {})
                    .frame(width: 36, height: 36).padding(4),
                    size: NSSize(width: 44, height: 44), fixture: fixture)
                let background = try pixel(bitmap, at: NSPoint(x: 36, y: 3.5), width: 44)
                XCTAssertGreaterThanOrEqual(try rgb(NSColor(fixture.theme.text.primary)).contrastRatio(with: rgb(background)),
                    fixture.contrast == .increased ? 6.98 : 4.48, "\(fixture.name): \(kind) badge contrast")
            }
        }
    }

    private struct ThemeFixture {
        let name: String
        let theme: PluginComponentTheme
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
    }

    private var themes: [ThemeFixture] {
        MenuBarPanelBuiltInThemes.all.flatMap { definition in
            [ColorSchemeContrast.standard, .increased].map { contrast in
                let scheme = MenuBarPanelThemeResolver.colorScheme(for: definition.appearance)
                return ThemeFixture(name: "\(definition.name)-\(contrast)",
                    theme: MenuBarPanelThemeResolver.resolve(definition: definition,
                        colorScheme: scheme, contrast: contrast).componentTheme,
                    scheme: scheme, contrast: contrast)
            }
        }
    }

    private func makeDay(isToday: Bool, isInDisplayedMonth: Bool = true, holiday: CalendarHolidayKind? = nil) -> CalendarDayModel {
        let date = Date(timeIntervalSince1970: 1_779_062_400)
        let event = CalendarEventSummary(id: "event", title: "Design review", timeText: "10:00–11:00",
            startDate: date, endDate: date.addingTimeInterval(3600), isAllDay: false,
            color: .init(red: 0.9, green: 0.25, blue: 0.55, alpha: 1), calendarTitle: "Work")
        return CalendarDayModel(id: "day", date: date, dayNumber: "17", alternateCalendarText: "",
            alternateCalendarDateText: "", isInDisplayedMonth: isInDisplayedMonth, isToday: isToday,
            isWeekend: true, holidayKind: holiday, events: [event])
    }

    private func render<Content: View>(_ content: Content, size: NSSize, fixture: ThemeFixture) throws -> NSBitmapImageRep {
        let view = NSHostingView(rootView: content
            .foregroundStyle(fixture.theme.text.primary)
            .background(fixture.theme.surfaces.card)
            .background(fixture.theme.surfaces.panel)
            .environment(\.pluginComponentTheme, fixture.theme)
            .environment(\.colorScheme, fixture.scheme))
        let appearance: NSAppearance.Name = fixture.contrast == .increased
            ? (fixture.scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (fixture.scheme == .dark ? .darkAqua : .aqua)
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func pixel(_ bitmap: NSBitmapImageRep, at point: NSPoint, width: CGFloat) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / width
        return try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }

    private func matchingPixels(_ bitmap: NSBitmapImageRep, color: Color, region: CGRect, width: CGFloat) throws -> Int {
        let expected = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        let scale = CGFloat(bitmap.pixelsWide) / width
        var count = 0
        for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
                let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(pixel.redComponent - expected.redComponent) < 0.025,
                   abs(pixel.greenComponent - expected.greenComponent) < 0.025,
                   abs(pixel.blueComponent - expected.blueComponent) < 0.025 { count += 1 }
            }
        }
        return count
    }

    private func assertColor(_ actual: NSColor, matches color: Color, message: String) throws {
        let expected = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.025, message)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.025, message)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.025, message)
    }

    private func rgb(_ color: NSColor) throws -> MenuBarPanelThemeColor {
        let color = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return MenuBarPanelThemeColor(red: UInt8((color.redComponent * 255).rounded()),
            green: UInt8((color.greenComponent * 255).rounded()), blue: UInt8((color.blueComponent * 255).rounded()))
    }
}
