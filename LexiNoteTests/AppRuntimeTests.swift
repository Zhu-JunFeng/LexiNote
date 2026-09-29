import AppKit
import SwiftData
import XCTest
@testable import LexiNote

@MainActor
final class AppRuntimeTests: XCTestCase {
    func testLookupPanelOpensAndCloses() throws {
        let container = try ModelContainer(for: VocabWord.self, LookupCache.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let runtime = AppRuntime.shared
        runtime.start(container: container)

        runtime.showLookup()
        let panel = NSApp.windows.first { $0.title == "LexiNote" }
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel?.isVisible, true)
        XCTAssertEqual(panel?.frame.size, NSSize(width: 820, height: 600))

        runtime.push(.library)
        let libraryPanel = NSApp.windows.first { $0.title == "LexiNote" }
        XCTAssertTrue(panel === libraryPanel)
        XCTAssertEqual(libraryPanel?.frame.size, NSSize(width: 820, height: 600))

        panel?.setFrame(NSRect(x: 100, y: 100, width: 900, height: 650), display: false)
        runtime.push(.review)
        XCTAssertEqual(panel?.frame.size, NSSize(width: 900, height: 650))

        runtime.backOrHide()
        XCTAssertTrue(panel === NSApp.windows.first { $0.title == "LexiNote" })
        XCTAssertEqual(panel?.frame.size, NSSize(width: 900, height: 650))

        panel?.setFrame(NSRect(x: 100, y: 100, width: 820, height: 600), display: false)

        runtime.hide()
        XCTAssertEqual(panel?.isVisible, false)
    }

    func testClipboardQueryAcceptsShortEnglishAndRejectsOtherContent() {
        XCTAssertEqual(ClipboardQuery.normalized("  taking   off  "), "taking off")
        XCTAssertEqual(ClipboardQuery.normalized("context."), "context")
        XCTAssertNil(ClipboardQuery.normalized("first\nsecond"))
        XCTAssertNil(ClipboardQuery.normalized("https://example.com"))
        XCTAssertNil(ClipboardQuery.normalized("hello@example.com"))
        XCTAssertNil(ClipboardQuery.normalized(""))
    }

    func testClipboardLookupReturnsToSamePanelAndRejectsInvalidContent() throws {
        let container = try ModelContainer(for: VocabWord.self, LookupCache.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let runtime = AppRuntime.shared
        runtime.start(container: container)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        runtime.open(.library)
        let panel = NSApp.windows.first { $0.title == "LexiNote" }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("running shoes", forType: .string))
        runtime.showLookupFromClipboard(pasteboard: pasteboard)
        XCTAssertEqual(runtime.page, .lookup)
        XCTAssertEqual(runtime.lookupRequest?.term, "running shoes")
        XCTAssertTrue(panel === NSApp.windows.first { $0.title == "LexiNote" })

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("https://example.com", forType: .string))
        runtime.showLookupFromClipboard(pasteboard: pasteboard)
        XCTAssertEqual(runtime.lookupRequest?.term, "")
        runtime.hide()
    }

    func testGlobalShortcutsCannotBeIdentical() throws {
        let container = try ModelContainer(for: VocabWord.self, LookupCache.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let runtime = AppRuntime.shared
        runtime.start(container: container)
        let previous = runtime.saveShortcut
        runtime.updateSaveShortcut(runtime.shortcut)
        XCTAssertEqual(runtime.saveShortcut, previous)
        XCTAssertNotNil(runtime.hotkeyError)
    }

    func testNotificationRoutesToRecommendedOrSavedWord() {
        let id = UUID()
        XCTAssertEqual(RecommendationNotificationRoute.page(for: ["kind": "newWord", "term": "coherent"]),
                       .recommendation("coherent"))
        XCTAssertEqual(RecommendationNotificationRoute.page(for: ["kind": "review", "id": id.uuidString]),
                       .word(id))
        XCTAssertNil(RecommendationNotificationRoute.page(for: ["kind": "review", "id": "invalid"]))
    }
}
