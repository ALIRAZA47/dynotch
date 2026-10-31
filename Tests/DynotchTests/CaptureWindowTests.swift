import AppKit
import Combine
import Testing
@testable import Dynotch

/// Snapping a capture to a window: which windows count and where they are, then hovering and clicking.
/// Everything here is made up. Nothing reads the real screen or windows.
@MainActor
struct CaptureWindowTests {
    private typealias Listed = CaptureWindowList.Listed
    private typealias Stacked = CaptureWindowList.Stacked

    private static let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let ownProcess: pid_t = 999

    private func listed(_ id: CGWindowID, frame: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300), app: String = "Safari",
                        bundle: String = "com.apple.Safari", process: pid_t = 100, layer: Int = 0) -> Listed {
        Listed(id: id, appName: app, bundleID: bundle, processID: process, frame: frame, layer: layer)
    }

    /// The function under test, with every listed window in the stack in the order given.
    private func merged(_ windows: [Listed], on display: CGRect = main) -> [CaptureWindow] {
        CaptureWindowList.windows(on: display, listed: windows, stack: windows.map { Stacked(id: $0.id, alpha: 1) },
                                  ownProcess: Self.ownProcess)
    }

    // MARK: The order

    @Test func theStackSetsTheOrderNotTheList() {
        let windows = [listed(1), listed(2), listed(3)]
        let stack = [Stacked(id: 3, alpha: 1), Stacked(id: 1, alpha: 1), Stacked(id: 2, alpha: 1)]
        let merged = CaptureWindowList.windows(on: Self.main, listed: windows, stack: stack, ownProcess: Self.ownProcess)
        #expect(merged.map(\.id) == [3, 1, 2])
    }

    @Test func aStackWindowThatIsntListedAddsNothing() {
        let stack = [Stacked(id: 9, alpha: 1), Stacked(id: 1, alpha: 1)]
        let merged = CaptureWindowList.windows(on: Self.main, listed: [listed(1)], stack: stack, ownProcess: Self.ownProcess)
        #expect(merged.map(\.id) == [1])
    }

    @Test func aWindowWithNoPlaceInTheStackIsLeftOut() {
        let merged = CaptureWindowList.windows(on: Self.main, listed: [listed(1), listed(2)], stack: [Stacked(id: 2, alpha: 1)],
                                               ownProcess: Self.ownProcess)
        #expect(merged.map(\.id) == [2])
    }

    /// `CGWindowListCopyWindowInfo` failing means an empty stack. A capture then works as it did.
    @Test func noStackMeansNoWindows() {
        #expect(CaptureWindowList.windows(on: Self.main, listed: [listed(1)], stack: [], ownProcess: Self.ownProcess).isEmpty)
    }

    @Test func aRepeatedStackEntryKeepsItsFrontPlace() {
        let stack = [Stacked(id: 1, alpha: 1), Stacked(id: 2, alpha: 1), Stacked(id: 1, alpha: 1)]
        let merged = CaptureWindowList.windows(on: Self.main, listed: [listed(2), listed(1)], stack: stack, ownProcess: Self.ownProcess)
        #expect(merged.map(\.id) == [1, 2])
    }

    // MARK: Which windows count

    @Test func dynotchsOwnWindowsDontCount() {
        #expect(merged([listed(1, process: Self.ownProcess), listed(2)]).map(\.id) == [2])
    }

    @Test(arguments: [0, 1, 3, 8])
    func appLayersCount(layer: Int) {
        #expect(merged([listed(1, layer: layer)]).count == 1)
    }

    /// The desktop's picture and icons sit far below zero, and backdrops just below it.
    @Test(arguments: [-1, -2_147_483_603, -2_147_483_624])
    func theDesktopDoesntCount(layer: Int) {
        #expect(merged([listed(1, layer: layer)]).isEmpty)
    }

    /// The first layer past the modal one, then the Dock, the menu bar, status items and pop-up menus.
    @Test(arguments: [9, 20, 24, 25, 101, 1000])
    func systemLayersDontCount(layer: Int) {
        #expect(merged([listed(1, layer: layer)]).isEmpty)
    }

    @Test func aFullyTransparentWindowDoesntCount() {
        let stack = [Stacked(id: 1, alpha: 0), Stacked(id: 2, alpha: 0.05)]
        let merged = CaptureWindowList.windows(on: Self.main, listed: [listed(1), listed(2)], stack: stack, ownProcess: Self.ownProcess)
        #expect(merged.map(\.id) == [2])
    }

    @Test(arguments: ["Window Server", "WindowServer", "Dock", "SystemUIServer", "Control Center", "ControlCenter",
                      "Notification Center", "NotificationCenter", "WindowManager", "Wallpaper", "loginwindow"])
    func systemAppsDontCount(app: String) {
        #expect(merged([listed(1, app: app, bundle: "")]).isEmpty)
    }

    /// A translated name still gives the app away by its identifier.
    @Test(arguments: ["com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
                      "com.apple.notificationcenterui", "com.apple.WindowManager", "com.apple.wallpaper.agent",
                      "com.apple.loginwindow"])
    func systemBundlesDontCount(bundle: String) {
        #expect(merged([listed(1, app: "Mitteilungszentrale", bundle: bundle)]).isEmpty)
    }

    @Test func aWindowWithNoAppDoesntCount() {
        #expect(merged([listed(1, app: "", bundle: "", process: 0)]).isEmpty)
    }

    @Test func onlyWholeNamesAreSystemApps() {
        #expect(merged([listed(1, app: "Dock Tamer", bundle: "com.example.docktamer")]).count == 1)
    }

    @Test func aWindowUnder40PointsEitherWayDoesntCount() {
        let thin = listed(1, frame: CGRect(x: 100, y: 100, width: 39.5, height: 300))
        let short = listed(2, frame: CGRect(x: 100, y: 100, width: 300, height: 39.5))
        let smallest = listed(3, frame: CGRect(x: 100, y: 100, width: 40, height: 40))
        #expect(merged([thin, short, smallest]).map(\.id) == [3])
    }

    /// The size is the window's own, so a window reaching onto a display by a sliver still counts there.
    @Test func aSliverOfABigWindowCounts() {
        let window = listed(1, frame: CGRect(x: -500, y: 100, width: 520, height: 300))
        #expect(merged([window]).map(\.frame) == [CGRect(x: 0, y: 100, width: 20, height: 300)])
    }

    // MARK: Coordinates

    @Test func onTheMainDisplayAFrameStaysAsItIs() {
        let frame = CGRect(x: 120, y: 80, width: 800, height: 600)
        #expect(merged([listed(1, frame: frame)]).map(\.frame) == [frame])
    }

    @Test func aDisplayToTheLeftHasNegativeX() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let window = listed(1, frame: CGRect(x: -1500, y: 200, width: 800, height: 600))
        #expect(merged([window], on: left).map(\.frame) == [CGRect(x: 420, y: 200, width: 800, height: 600)])
    }

    @Test func aDisplayAboveHasNegativeY() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let window = listed(1, frame: CGRect(x: 300, y: -900, width: 800, height: 600))
        #expect(merged([window], on: above).map(\.frame) == [CGRect(x: 300, y: 180, width: 800, height: 600)])
    }

    @Test func aDisplayLowerRightIsOffsetBothWays() {
        let lower = CGRect(x: 1440, y: 300, width: 1920, height: 1080)
        let window = listed(1, frame: CGRect(x: 1500, y: 500, width: 800, height: 600))
        #expect(merged([window], on: lower).map(\.frame) == [CGRect(x: 60, y: 200, width: 800, height: 600)])
    }

    @Test func aWindowStraddlingTwoDisplaysIsOnEachClippedToIt() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let window = listed(1, frame: CGRect(x: -200, y: 100, width: 600, height: 400))
        #expect(merged([window], on: left).map(\.frame) == [CGRect(x: 1720, y: 100, width: 200, height: 400)])
        #expect(merged([window], on: Self.main).map(\.frame) == [CGRect(x: 0, y: 100, width: 400, height: 400)])
    }

    @Test func aWindowPartlyOffTheDisplayIsClipped() {
        let window = listed(1, frame: CGRect(x: 1200, y: 700, width: 800, height: 600))
        #expect(merged([window]).map(\.frame) == [CGRect(x: 1200, y: 700, width: 240, height: 200)])
    }

    @Test func aWindowOnAnotherDisplayIsntOnThisOne() {
        #expect(merged([listed(1, frame: CGRect(x: -900, y: 100, width: 800, height: 600))]).isEmpty)
    }

    /// Touching the display's edge isn't being on it.
    @Test func aWindowEndingAtTheEdgeIsntOnTheDisplay() {
        #expect(merged([listed(1, frame: CGRect(x: -800, y: 100, width: 800, height: 600))]).isEmpty)
    }

    // MARK: Reading the stack

    /// CGWindow.h gives the number as a 32-bit signed CFNumber and the alpha as a floating-point one.
    @Test func theStackIsReadFromAWindowList() {
        let entries: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: Int32(42)), kCGWindowAlpha as String: NSNumber(value: Float(0.5))],
            [kCGWindowNumber as String: NSNumber(value: Int32(7)), kCGWindowAlpha as String: NSNumber(value: 0.0)],
        ]
        let stack = CaptureWindowList.stack(from: entries)
        #expect(stack.map(\.id) == [42, 7])
        #expect(stack.map(\.alpha) == [0.5, 0])
    }

    @Test func anEntryWithNoNumberIsSkipped() {
        #expect(CaptureWindowList.stack(from: [[kCGWindowAlpha as String: NSNumber(value: 1.0)]]).isEmpty)
    }

    @Test func anEntryWithNoAlphaIsOpaque() {
        #expect(CaptureWindowList.stack(from: [[kCGWindowNumber as String: NSNumber(value: Int32(1))]]).map(\.alpha) == [1])
    }

    // MARK: Hovering

    private static let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
    private let front = CaptureWindow(id: 1, appName: "Safari", frame: CGRect(x: 100, y: 100, width: 500, height: 400))
    private let back = CaptureWindow(id: 2, appName: "Notes", frame: CGRect(x: 300, y: 200, width: 700, height: 400))
    /// In both windows, then in the back one only, then in neither.
    private let inBoth = CGPoint(x: 400, y: 300)
    private let inBackOnly = CGPoint(x: 800, y: 300)
    private let onDesktop = CGPoint(x: 1200, y: 700)

    private func display(id: CGDirectDisplayID = 1, frame: CGRect = bounds, windows: [CaptureWindow]) -> CaptureDisplay {
        var display = CaptureController.syntheticDisplay(id: id, frame: frame, scale: 1)!
        display.windows = windows
        return display
    }

    private func editor(_ displays: CaptureDisplay...) -> CaptureEditor {
        CaptureEditor(displays: displays, accent: .blue)
    }

    private var twoWindows: CaptureEditor { editor(display(windows: [front, back])) }

    private func click(_ editor: CaptureEditor, at point: CGPoint, on id: CGDirectDisplayID = 1, wholeDisplay: Bool = false) {
        editor.mouseDown(at: point, on: id, wholeDisplay: wholeDisplay)
        editor.mouseUp(at: point, on: id)
    }

    /// How many times the editor publishes while `body` runs.
    private func publishes(_ editor: CaptureEditor, during body: () -> Void) -> Int {
        var count = 0
        let subscription = editor.objectWillChange.sink { count += 1 }
        body()
        subscription.cancel()
        return count
    }

    @Test func hoverFindsTheWindowUnderThePointer() {
        let editor = twoWindows
        editor.mouseMoved(to: inBackOnly, on: 1)
        #expect(editor.hoveredWindow == back)
        #expect(editor.hoveredDisplay == 1)
    }

    @Test func hoverFindsTheFrontmostWhereWindowsOverlap() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        #expect(editor.hoveredWindow == front)
    }

    @Test func thatDependsOnTheListNotTheFrame() {
        let editor = editor(display(windows: [back, front]))
        editor.mouseMoved(to: inBoth, on: 1)
        #expect(editor.hoveredWindow == back)
    }

    @Test func hoverIsNilOverTheDesktop() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        editor.mouseMoved(to: onDesktop, on: 1)
        #expect(editor.hover == nil)
    }

    @Test func aSelectionClearsTheHover() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        click(editor, at: inBoth)
        #expect(editor.hover == nil)
        #expect(editor.highlight(on: 1) == nil)
    }

    @Test func aStagedSelectionClearsItToo() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        editor.stage(selection: CGRect(x: 10, y: 10, width: 100, height: 100), on: 1)
        #expect(editor.hover == nil)
    }

    @Test func nothingHoversOnceThereIsASelection() {
        let editor = twoWindows
        click(editor, at: inBoth)
        #expect(publishes(editor) { editor.mouseMoved(to: inBackOnly, on: 1) } == 0)
        #expect(editor.hover == nil)
        editor.wholeDisplayChanged(true)
        #expect(editor.hover == nil)
    }

    @Test func aDragClearsTheHover() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        editor.mouseDown(at: inBoth, on: 1)
        editor.mouseDragged(to: CGPoint(x: inBoth.x + 40, y: inBoth.y + 40), on: 1)
        #expect(editor.hover == nil)
        #expect(editor.rubberBand == CGRect(origin: inBoth, size: CGSize(width: 40, height: 40)))
    }

    /// A press that hasn't travelled may still be a click, and the highlight shouldn't blink.
    @Test func theHighlightStaysThroughAPress() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        editor.mouseDown(at: inBoth, on: 1)
        #expect(editor.hoveredWindow == front)
        #expect(editor.rubberBand == nil)
        editor.mouseDragged(to: CGPoint(x: inBoth.x + 2, y: inBoth.y + 1), on: 1)
        #expect(editor.hoveredWindow == front)
        #expect(editor.rubberBand == nil)
        editor.mouseUp(at: CGPoint(x: inBoth.x + 2, y: inBoth.y + 1), on: 1)
        #expect(editor.selection == front.frame)
    }

    @Test func anotherDisplayClearsTheHover() {
        let second = CaptureWindow(id: 3, appName: "Mail", frame: CGRect(x: 50, y: 50, width: 300, height: 300))
        let editor = editor(display(windows: [front]), display(id: 2, frame: CGRect(x: 1280, y: 0, width: 800, height: 600), windows: [second]))
        editor.mouseMoved(to: inBoth, on: 1)
        editor.mouseMoved(to: CGPoint(x: 700, y: 500), on: 2)
        #expect(editor.hover == nil)
        #expect(editor.highlight(on: 1) == nil)
        editor.mouseMoved(to: CGPoint(x: 100, y: 100), on: 2)
        #expect(editor.hoveredWindow == second)
        #expect(editor.hoveredDisplay == 2)
        #expect(editor.highlight(on: 1) == nil)
        #expect(editor.highlight(on: 2)?.frame == second.frame)
    }

    /// The key overlay can hear of a move over another display. Its point falls outside the display.
    @Test func aMoveOutsideTheDisplayChangesNothing() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        #expect(publishes(editor) {
            editor.mouseMoved(to: CGPoint(x: 1400, y: 300), on: 1)
            editor.mouseMoved(to: CGPoint(x: 300, y: -5), on: 1)
        } == 0)
        #expect(editor.hoveredWindow == front)
    }

    /// The point says which display a move is on, whichever overlay heard it.
    @Test func aMoveOnTheDesktopFindsItsDisplay() {
        let second = CaptureWindow(id: 3, appName: "Mail", frame: CGRect(x: 50, y: 50, width: 300, height: 300))
        let editor = editor(display(windows: [front]), display(id: 2, frame: CGRect(x: 1280, y: 0, width: 800, height: 600), windows: [second]))
        editor.mouseMoved(toDesktop: CGPoint(x: 1380, y: 500))
        #expect(editor.hoveredWindow == second)
        #expect(editor.hoveredDisplay == 2)
    }

    @Test func noPublishWhileTheTargetStaysTheSame() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        let count = publishes(editor) {
            for offset in 1...20 {
                editor.mouseMoved(to: CGPoint(x: inBoth.x + CGFloat(offset), y: inBoth.y), on: 1)
            }
        }
        #expect(count == 0)
    }

    @Test func noPublishMovingOverTheDesktop() {
        let editor = twoWindows
        let count = publishes(editor) {
            for offset in 1...20 {
                editor.mouseMoved(to: CGPoint(x: onDesktop.x + CGFloat(offset), y: onDesktop.y), on: 1)
            }
        }
        #expect(count == 0)
    }

    @Test func oneChangeIsOnePublish() {
        let editor = twoWindows
        #expect(publishes(editor) { editor.mouseMoved(to: inBoth, on: 1) } == 1)
        #expect(publishes(editor) { editor.mouseMoved(to: inBackOnly, on: 1) } == 1)
        #expect(publishes(editor) { editor.mouseMoved(to: onDesktop, on: 1) } == 1)
    }

    // MARK: ⌥

    @Test func optionHighlightsTheWholeDisplay() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        editor.wholeDisplayChanged(true)
        #expect(editor.hoveredWindow == nil)
        #expect(editor.hoveredDisplay == 1)
        #expect(editor.highlight(on: 1)?.frame == Self.bounds)
        editor.wholeDisplayChanged(false)
        #expect(editor.hoveredWindow == front)
    }

    @Test func optionOverTheDesktopHighlightsTheDisplayToo() {
        let editor = twoWindows
        editor.mouseMoved(to: onDesktop, on: 1, wholeDisplay: true)
        #expect(editor.highlight(on: 1)?.frame == Self.bounds)
    }

    @Test func aMoveCarriesOption() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1, wholeDisplay: true)
        #expect(editor.hoveredDisplay == 1)
        #expect(editor.hoveredWindow == nil)
        editor.mouseMoved(to: inBoth, on: 1)
        #expect(editor.hoveredWindow == front)
    }

    @Test func optionBeforeThePointerIsKnownDoesNothing() {
        let editor = twoWindows
        #expect(publishes(editor) { editor.wholeDisplayChanged(true) } == 0)
        #expect(editor.hover == nil)
    }

    @Test func optionChangesOnlyPublishWhenTheyChangeSomething() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1, wholeDisplay: true)
        #expect(publishes(editor) { editor.wholeDisplayChanged(true) } == 0)
    }

    // MARK: Clicking

    @Test func aClickSelectsTheWindow() {
        let editor = twoWindows
        click(editor, at: inBackOnly)
        #expect(editor.selection == back.frame)
        #expect(editor.activeDisplay == 1)
    }

    @Test func aClickSelectsTheFrontmostWindow() {
        let editor = twoWindows
        click(editor, at: inBoth)
        #expect(editor.selection == front.frame)
    }

    /// With no move before it, as when the pointer hasn't moved since the overlay opened on a parked window.
    @Test func aClickNeedsNoHoverFirst() {
        let editor = twoWindows
        #expect(editor.hover == nil)
        click(editor, at: inBoth)
        #expect(editor.selection == front.frame)
    }

    @Test func aClickSelectsWholePoints() {
        let window = CaptureWindow(id: 1, appName: "Safari", frame: CGRect(x: 100.4, y: 100.6, width: 300.2, height: 200.3))
        let editor = editor(display(windows: [window]))
        click(editor, at: CGPoint(x: 200, y: 200))
        #expect(editor.selection == window.frame.integral)
    }

    @Test func optionClickSelectsTheDisplay() {
        let editor = twoWindows
        click(editor, at: inBoth, wholeDisplay: true)
        #expect(editor.selection == Self.bounds)
    }

    @Test func aClickOnTheDesktopSelectsTheDisplay() {
        let editor = twoWindows
        click(editor, at: onDesktop)
        #expect(editor.selection == Self.bounds)
    }

    @Test func aDragFromAWindowMakesARectangle() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        let end = CGPoint(x: inBoth.x + 120, y: inBoth.y + 80)
        editor.mouseDown(at: inBoth, on: 1)
        editor.mouseDragged(to: end, on: 1)
        editor.mouseUp(at: end, on: 1)
        #expect(editor.selection == CGRect(origin: inBoth, size: CGSize(width: 120, height: 80)))
    }

    @Test func aDragJustPastTheSlopIsARectangle() {
        let editor = twoWindows
        let end = CGPoint(x: inBoth.x + 3, y: inBoth.y + 1)
        editor.mouseMoved(to: inBoth, on: 1)
        editor.mouseDown(at: inBoth, on: 1)
        editor.mouseDragged(to: end, on: 1)
        editor.mouseUp(at: end, on: 1)
        #expect(editor.selection == CGRect(origin: inBoth, size: CGSize(width: 3, height: 1)))
    }

    @Test func aWindowPartlyOffTheDisplayIsSelectedClipped() {
        let listed = listed(1, frame: CGRect(x: 1000, y: 600, width: 500, height: 400))
        let windows = CaptureWindowList.windows(on: Self.bounds, listed: [listed], stack: [Stacked(id: 1, alpha: 1)], ownProcess: Self.ownProcess)
        let editor = editor(display(windows: windows))
        click(editor, at: CGPoint(x: 1100, y: 700))
        #expect(editor.selection == CGRect(x: 1000, y: 600, width: 280, height: 200))
    }

    @Test func aClickOutsideASelectionSelectsTheWindowThere() {
        let editor = twoWindows
        let region = CGRect(x: 1100, y: 600, width: 100, height: 100)
        editor.mouseDown(at: region.origin, on: 1)
        editor.mouseDragged(to: CGPoint(x: region.maxX, y: region.maxY), on: 1)
        editor.mouseUp(at: CGPoint(x: region.maxX, y: region.maxY), on: 1)
        #expect(editor.selection == region)
        click(editor, at: inBoth)
        #expect(editor.selection == front.frame)
    }

    @Test func aClickOutsideASelectionOverTheDesktopSelectsTheDisplay() {
        let editor = twoWindows
        click(editor, at: inBoth)
        click(editor, at: onDesktop)
        #expect(editor.selection == Self.bounds)
    }

    @Test func optionClickOutsideASelectionSelectsTheDisplay() {
        let editor = twoWindows
        click(editor, at: inBoth)
        click(editor, at: inBackOnly, wholeDisplay: true)
        #expect(editor.selection == Self.bounds)
    }

    /// A selection of the whole display can't move, so a press inside it starts over.
    @Test func aClickInsideTheWholeDisplaySelectsTheWindowThere() {
        let editor = twoWindows
        click(editor, at: onDesktop)
        click(editor, at: inBoth)
        #expect(editor.selection == front.frame)
    }

    @Test func aPressInsideAWindowSelectionMovesIt() {
        let editor = twoWindows
        click(editor, at: inBoth)
        let end = CGPoint(x: inBoth.x + 30, y: inBoth.y + 20)
        editor.mouseDown(at: inBoth, on: 1)
        editor.mouseDragged(to: end, on: 1)
        editor.mouseUp(at: end, on: 1)
        #expect(editor.selection == front.frame.offsetBy(dx: 30, dy: 20))
    }

    /// With a tool in hand a click is a mark, wherever it lands.
    @Test func aClickWithAToolStaysAMark() {
        let editor = twoWindows
        click(editor, at: inBoth)
        editor.tool = .counter
        click(editor, at: onDesktop)
        #expect(editor.selection == front.frame)
        #expect(editor.document.annotations.count == 1)
    }

    /// Clipping keeps the two parts apart, and a selection never leaves its display.
    @Test func aStraddlingWindowSelectsThePartUnderThePointer() {
        let leftFrame = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let window = listed(1, frame: CGRect(x: -200, y: 100, width: 600, height: 400))
        let stack = [Stacked(id: 1, alpha: 1)]
        let onMain = display(id: 1, windows: CaptureWindowList.windows(on: Self.bounds, listed: [window], stack: stack, ownProcess: Self.ownProcess))
        let onLeft = display(id: 2, frame: leftFrame, windows: CaptureWindowList.windows(on: leftFrame, listed: [window], stack: stack, ownProcess: Self.ownProcess))

        let right = editor(onMain, onLeft)
        click(right, at: CGPoint(x: 100, y: 200), on: 1)
        #expect(right.selection == CGRect(x: 0, y: 100, width: 400, height: 400))
        #expect(right.activeDisplay == 1)

        let left = editor(onMain, onLeft)
        click(left, at: CGPoint(x: 1200, y: 200), on: 2)
        #expect(left.selection == CGRect(x: 1080, y: 100, width: 200, height: 400))
        #expect(left.activeDisplay == 2)
    }

    // MARK: The highlight

    @Test func theHighlightSaysWhatAClickWouldSelect() {
        let editor = twoWindows
        editor.mouseMoved(to: inBoth, on: 1)
        let highlight = editor.highlight(on: 1)
        #expect(highlight?.frame == front.frame)
        #expect(highlight?.label == "Safari · 500 × 400")
        editor.wholeDisplayChanged(true)
        #expect(editor.highlight(on: 1)?.label == "Whole display · 1280 × 800")
    }

    @Test func theHighlightIsInWholePointsLikeTheSelection() {
        let window = CaptureWindow(id: 1, appName: "Safari", frame: CGRect(x: 100.4, y: 100.6, width: 300.2, height: 200.3))
        let editor = editor(display(windows: [window]))
        editor.mouseMoved(to: CGPoint(x: 200, y: 200), on: 1)
        let highlight = editor.highlight(on: 1)
        click(editor, at: CGPoint(x: 200, y: 200))
        #expect(highlight?.frame == editor.selection)
    }

    // MARK: With no windows, as it always was

    @Test func withNoWindowsNothingHovers() {
        let editor = editor(display(windows: []))
        #expect(publishes(editor) {
            editor.mouseMoved(to: inBoth, on: 1)
            editor.mouseMoved(to: inBoth, on: 1, wholeDisplay: true)
            editor.wholeDisplayChanged(true)
        } == 0)
        #expect(editor.hover == nil)
        #expect(editor.highlight(on: 1) == nil)
    }

    @Test func withNoWindowsAClickSelectsTheDisplay() {
        let editor = editor(display(windows: []))
        click(editor, at: inBoth)
        #expect(editor.selection == Self.bounds)
    }

    @Test func withNoWindowsAPressStartsARubberBand() {
        let editor = editor(display(windows: []))
        editor.mouseDown(at: inBoth, on: 1)
        #expect(editor.rubberBand == CGRect(origin: inBoth, size: .zero))
        let end = CGPoint(x: inBoth.x + 2, y: inBoth.y + 1)
        editor.mouseDragged(to: end, on: 1)
        #expect(editor.rubberBand == CGRect(origin: inBoth, size: CGSize(width: 2, height: 1)))
        editor.mouseUp(at: end, on: 1)
        #expect(editor.rubberBand == nil)
        #expect(editor.selection == Self.bounds)
    }

    @Test func withNoWindowsADragMakesARectangle() {
        let editor = editor(display(windows: []))
        let end = CGPoint(x: inBoth.x + 100, y: inBoth.y + 50)
        editor.mouseDown(at: inBoth, on: 1)
        editor.mouseDragged(to: end, on: 1)
        editor.mouseUp(at: end, on: 1)
        #expect(editor.selection == CGRect(origin: inBoth, size: CGSize(width: 100, height: 50)))
    }

    /// A bare press on the desktop of a display with windows is the same as it always was too.
    @Test func overTheDesktopAPressStartsARubberBand() {
        let editor = twoWindows
        editor.mouseMoved(to: onDesktop, on: 1)
        editor.mouseDown(at: onDesktop, on: 1)
        #expect(editor.rubberBand == CGRect(origin: onDesktop, size: .zero))
    }

    /// A press on a display the hover didn't get to, as when no move arrived there first.
    @Test func aPressOnAnotherDisplayDropsTheHover() {
        let second = display(id: 2, frame: CGRect(x: 1280, y: 0, width: 800, height: 600), windows: [])
        let editor = editor(display(windows: [front]), second)
        editor.mouseMoved(to: inBoth, on: 1)
        editor.mouseDown(at: CGPoint(x: 100, y: 100), on: 2)
        #expect(editor.hover == nil)
        #expect(editor.rubberBand == CGRect(x: 100, y: 100, width: 0, height: 0))
    }

    // MARK: Made-up windows

    @Test func aMadeUpDisplayHasNoWindowsByDefault() throws {
        let display = try #require(CaptureController.syntheticDisplay(id: 1, frame: Self.bounds, scale: 1))
        #expect(display.windows.isEmpty)
    }

    /// Reads the drawn picture: each window's top and bottom edges have to land on the drawing's,
    /// whose origin is at the other corner.
    @Test func madeUpWindowsMatchTheDrawing() throws {
        let display = try #require(CaptureController.syntheticDisplay(id: 1, frame: Self.bounds, scale: 1, withWindows: true))
        #expect(display.windows.map(\.appName) == ["TextEdit", "Notes"])
        let pixels = try #require(display.image.dataProvider?.data as Data?)
        let light = { (point: CGPoint) -> Bool in
            let offset = Int(point.y) * display.image.bytesPerRow + Int(point.x) * display.image.bitsPerPixel / 8
            return pixels[offset..<offset + 3].allSatisfy { $0 > 200 }
        }
        for window in display.windows {
            let x = window.frame.minX + 40
            #expect(light(CGPoint(x: x, y: window.frame.minY + 3)))
            #expect(!light(CGPoint(x: x, y: window.frame.minY - 3)))
            #expect(light(CGPoint(x: x, y: window.frame.maxY - 3)))
            #expect(!light(CGPoint(x: x, y: window.frame.maxY + 3)))
        }
    }

    // MARK: The pointer at the start

    @Test func aDesktopPointBecomesTheDisplaysOwn() {
        let main = display(windows: [])
        #expect(main.localPoint(fromDesktop: CGPoint(x: 100, y: 700)) == CGPoint(x: 100, y: 100))
    }

    /// AppKit's y runs up from the bottom of the main display, so this one's top is at 500.
    @Test func aDesktopPointOnADisplayLeftAndLower() {
        let lower = display(id: 2, frame: CGRect(x: -1280, y: -300, width: 1280, height: 800), windows: [])
        #expect(lower.localPoint(fromDesktop: CGPoint(x: -1180, y: 400)) == CGPoint(x: 100, y: 100))
    }
}
