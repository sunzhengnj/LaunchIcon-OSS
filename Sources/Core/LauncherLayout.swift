import Foundation
import CoreServices

public enum LayoutItemRef: Hashable, Sendable {
    case topLevel(UUID)
    case folderMember(folderID: UUID, itemID: UUID)
}

public enum LayoutDestination: Hashable, Sendable {
    case topLevelIndex(Int)
    case merge(LayoutItemRef)
    case folderIndex(folderID: UUID, index: Int)
}

public struct LayoutDrop: Hashable, Sendable {
    public var source: LayoutItemRef
    public var destination: LayoutDestination

    public init(source: LayoutItemRef, destination: LayoutDestination) {
        self.source = source
        self.destination = destination
    }
}

/// One entry of the app context menu「移到文件夹」submenu.
public struct FolderMenuTarget: Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum LayoutMutationError: Error, Equatable, Sendable {
    case missingSource
    case missingTarget
    case nestedFolder
    case cannotDropOnSelf
}


/// Multi-select foundation for ⌘-click / Shift-click chrome. Plain click
/// replaces; Command toggles; Shift selects a contiguous range in the
/// *presented* order (current page / list only — never pages). Marquee and
/// multi-drag are later. Does not own paging, focus, or reorder.
public struct LauncherItemSelection: Equatable, Sendable {
    public private(set) var orderedIDs: [UUID]
    /// Anchor for Shift-click ranges. Updated by replace/toggle; preserved
    /// across successive Shift-clicks so the range grows from the same end.
    public private(set) var rangeAnchorID: UUID?

    public init(orderedIDs: [UUID] = [], rangeAnchorID: UUID? = nil) {
        var seen = Set<UUID>()
        var unique: [UUID] = []
        unique.reserveCapacity(orderedIDs.count)
        for id in orderedIDs where seen.insert(id).inserted {
            unique.append(id)
        }
        self.orderedIDs = unique
        if let rangeAnchorID, unique.contains(rangeAnchorID) {
            self.rangeAnchorID = rangeAnchorID
        } else {
            self.rangeAnchorID = unique.last
        }
    }

    public static let empty = LauncherItemSelection()

    public var isEmpty: Bool { orderedIDs.isEmpty }
    public var count: Int { orderedIDs.count }

    public func contains(_ id: UUID) -> Bool {
        orderedIDs.contains(id)
    }

    public mutating func clear() {
        orderedIDs.removeAll(keepingCapacity: false)
        rangeAnchorID = nil
    }

    public mutating func selectOnly(_ id: UUID) {
        orderedIDs = [id]
        rangeAnchorID = id
    }

    public mutating func toggle(_ id: UUID) {
        if let index = orderedIDs.firstIndex(of: id) {
            orderedIDs.remove(at: index)
        } else {
            orderedIDs.append(id)
        }
        rangeAnchorID = id
    }

    public mutating func remove(_ id: UUID) {
        orderedIDs.removeAll { $0 == id }
        if rangeAnchorID == id {
            rangeAnchorID = orderedIDs.last
        }
    }

    /// Drop IDs that left the layout (hide, uninstall, reconcile, folder dissolve).
    public mutating func removeAbsent(from presentIDs: Set<UUID>) {
        orderedIDs.removeAll { !presentIDs.contains($0) }
        if let anchor = rangeAnchorID, !presentIDs.contains(anchor) {
            rangeAnchorID = orderedIDs.last
        }
    }

    public func pruningAbsent(from presentIDs: Set<UUID>) -> LauncherItemSelection {
        var next = self
        next.removeAbsent(from: presentIDs)
        return next
    }

    public enum ClickKind: Equatable, Sendable {
        /// Plain click — selection becomes only this item.
        case replace
        /// ⌘-click — toggle membership without clearing others.
        case toggle
    }

    public static func applying(
        kind: ClickKind,
        itemID: UUID,
        to current: LauncherItemSelection
    ) -> LauncherItemSelection {
        var next = current
        switch kind {
        case .replace:
            next.selectOnly(itemID)
        case .toggle:
            next.toggle(itemID)
        }
        return next
    }

    /// ⌘A: replace selection with every id on the current presented page
    /// (order preserved). Empty `ids` yields an empty selection.
    public static func selectingAll(ids: [UUID]) -> LauncherItemSelection {
        LauncherItemSelection(orderedIDs: ids, rangeAnchorID: ids.first)
    }

    /// Shift-click: select contiguous ids from the range anchor through `itemID`
    /// in `presentedOrder` only. Does not invent off-list / other-page ids.
    public static func applyingRange(
        to itemID: UUID,
        presentedOrder: [UUID],
        current: LauncherItemSelection
    ) -> LauncherItemSelection {
        let anchor = current.rangeAnchorID
            ?? current.orderedIDs.last
            ?? itemID
        guard let i = presentedOrder.firstIndex(of: anchor),
              let j = presentedOrder.firstIndex(of: itemID) else {
            return applying(kind: .replace, itemID: itemID, to: current)
        }
        let lo = min(i, j)
        let hi = max(i, j)
        let slice = Array(presentedOrder[lo...hi])
        return LauncherItemSelection(orderedIDs: slice, rangeAnchorID: anchor)
    }
}

public enum LauncherLayout {
    public enum PageIndicatorSlot: Equatable, Sendable {
        case page(Int)
        case ellipsis
    }

    public static let pageColumns = 7
    public static let pageRows = 5
    public static let pageCapacity = pageColumns * pageRows
    public static let folderColumns = 5
    public static let folderRows = 5
    public static let pageIndicatorLimit = 7
    public static let pageAnimationDuration: TimeInterval = 0.28
    /// Cubic control points of the page slide. Dots sample the same curve.
    // Leave visible travel through the middle of the turn. The previous
    // curve spent almost all its distance in the first half and then coasted.
    public static let pageTurnCurveX1: CGFloat = 0.25
    public static let pageTurnCurveY1: CGFloat = 0.55
    public static let pageTurnCurveX2: CGFloat = 0.45
    public static let pageTurnCurveY2: CGFloat = 1
    /// How far a finger must travel, as a fraction of the page, before the
    /// page turns. A fast flick can still turn below this. This is not how
    /// far the pages slide.
    public static let pageTurnDistanceFraction: CGFloat = 0.18
    /// Keep the two page hosts adjacent while a finger drags. A shorter
    /// travel makes their grids overlap and appear to drift through each other.
    public static let pageDragSlideFraction: CGFloat = 1
    /// Arrow, keyboard, and page-dot turns use the same adjacent-page travel.
    /// The drag-to-turn threshold stays `pageTurnDistanceFraction`.
    public static let discretePageSlideFraction: CGFloat = 1
    public static let discretePageTurnThreshold: CGFloat = 3
    public static let dragLiftScale: CGFloat = 1.06
    public static let dragLiftShadowOpacity: CGFloat = 0.18
    /// Cell chrome fill alphas for `AppGridTileView` (neutral white over wallpaper).
    /// Idle/resting tiles stay fully transparent — no permanent gray plate.
    public static let tileChromeIdleAlpha: CGFloat = 0
    /// Keyboard focus affordance only (not resting, not mouse-idle).
    public static let tileChromeFocusAlpha: CGFloat = 0.08
    /// ⌘-click multi-select fill (between keyboard focus and drop-target).
    public static let tileChromeSelectionAlpha: CGFloat = 0.10
    /// Active merge/drop-target highlight while the pointer is targeting a tile.
    public static let tileChromeDropTargetAlpha: CGFloat = 0.12
    /// In-place「正在启动…」highlight.
    public static let tileChromeLaunchingAlpha: CGFloat = 0.35

    /// Fill alpha for tile cell chrome. Idle stays 0 (fully clear — use `nil`
    /// background, not white@0). Drag-lift snapshots must call
    /// `tileChromeFillAlphaForDragLiftSnapshot` so focus/drop/launch fills
    /// are never baked into the flying image.
    public static func tileChromeFillAlpha(
        isLaunching: Bool,
        isDropTarget: Bool,
        focused: Bool,
        selected: Bool = false,
        folderPanelChromeInFlight: Bool = false
    ) -> CGFloat {
        if isLaunching { return tileChromeLaunchingAlpha }
        if isDropTarget { return tileChromeDropTargetAlpha }
        // Folder members: suppress focus/selection fills while open/close chrome
        // is still traveling (same keys as title pointer/AX). Drop/launch stay.
        if !folderPanelChromeInFlight {
            if selected { return tileChromeSelectionAlpha }
            if focused { return tileChromeFocusAlpha }
        }
        return tileChromeIdleAlpha
    }

    /// Drag-lift pictures always use idle chrome (fully clear).
    public static func tileChromeFillAlphaForDragLiftSnapshot() -> CGFloat {
        tileChromeIdleAlpha
    }

    /// Keyboard focus fill (idle ↔ 8%) retargets from presentation.
    public static let tileChromeFillFadeAnimationKey = "tile-chrome-fill"

    public static let reorderSlideDuration: TimeInterval = 0.18
    /// Time to feed `reorderSpringStep`, measured to the frame about to draw.
    /// A timer that waits a full interval first holds the icon, then jumps.
    /// A late frame is kept whole. A clock that runs backwards, or a bad
    /// clock, integrates nothing so the mark does not rewind.
    public static func reorderSlideElapsed(now: TimeInterval, lastTick: TimeInterval) -> TimeInterval {
        guard now.isFinite, lastTick.isFinite else { return 0 }
        return max(now - lastTick, 0)
    }

    /// Critical damping keeps a neighbor's velocity when the drag gap changes.
    /// About 95% of a stationary start's travel completes in reorderSlideDuration.
    public static func reorderSpringStep(
        position: CGSize, velocity: CGSize, target: CGSize, elapsed: TimeInterval
    ) -> (position: CGSize, velocity: CGSize) {
        // This closed-form solution is stable across delayed frames; do not
        // discard elapsed time when the main run loop delivers a late tick.
        let step = CGFloat(max(elapsed, 0))
        let response = CGFloat(4.8 / reorderSlideDuration)
        let decay = CGFloat(exp(Double(-response * step)))
        func axis(_ position: CGFloat, _ velocity: CGFloat, _ target: CGFloat) -> (CGFloat, CGFloat) {
            let displacement = position - target
            let slope = velocity + response * displacement
            return (
                target + (displacement + slope * step) * decay,
                (velocity - response * slope * step) * decay
            )
        }
        let x = axis(position.width, velocity.width, target.width)
        let y = axis(position.height, velocity.height, target.height)
        return (CGSize(width: x.0, height: y.0), CGSize(width: x.1, height: y.1))
    }

    /// How far a page host travels. `discrete` is an arrow, key, or dot.
    /// A finger drag stays on `pageDragSlideFraction`, so a full-width pull
    /// still docks the incoming page and the turn threshold is unchanged.
    /// A width that cannot be measured travels nowhere.
    public static func pageSlideDistance(pageWidth: CGFloat, discrete: Bool) -> CGFloat {
        guard pageWidth.isFinite else { return 0 }
        let width = max(pageWidth, 0)
        let fraction = discrete ? discretePageSlideFraction : pageDragSlideFraction
        return width * fraction
    }

    /// A full pull has already drawn the destination and can land now. Small
    /// remaining distances should not sit in the old 120 ms minimum tail.
    public static func pageSlideCompletionDuration(remainingFraction: CGFloat) -> TimeInterval {
        let fraction = min(max(remainingFraction, 0), 1)
        guard fraction > 0 else { return 0 }
        return max(0.06, pageAnimationDuration * pow(Double(fraction), 0.55))
    }

    /// Offsets while a finger is down. `distance` is the finger travel in
    /// points, negative when the next page is coming in from the right.
    /// `direction` is +1 toward the next page. At a full page of travel the
    /// incoming page sits at 0 and the outgoing page has moved by
    /// `pageDragSlideFraction`. The rubber band at the ends is the caller's.
    public static func pageDragFollowOffsets(
        distance: CGFloat,
        pageWidth: CGFloat,
        direction: Int
    ) -> (activeX: CGFloat, stagingX: CGFloat) {
        let width = pageWidth.isFinite ? max(pageWidth, 1) : 1
        let clamped = distance.isFinite ? min(max(distance, -width), width) : 0
        let follow = clamped * pageDragSlideFraction
        let travel = pageSlideDistance(pageWidth: width, discrete: false)
        return (follow, CGFloat(direction) * travel + follow)
    }

    /// Where a page dot is along the same ease-out as the page slide.
    /// `elapsed` is measured to the frame about to draw, not to a timer that
    /// waits a full interval first. That wait lands on the steep part of
    /// this curve, so the dot jumps. 0 is the old page. 1 is the new page.
    /// A bad clock stays on the old page. A duration that is not positive
    /// has already finished once any time has passed.
    public static func pageDotWeightProgress(elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard elapsed.isFinite, duration.isFinite else { return 0 }
        guard duration > 0 else { return elapsed > 0 ? 1 : 0 }
        let linear = min(max(elapsed / duration, 0), 1)
        return pageTurnCurveProgress(CGFloat(linear))
    }

    /// Clock time 0...1 along the page slide, mapped through `pageTurnCurve*`.
    /// Ease-out: halfway through the clock, most of the visual change is done.
    public static func pageTurnCurveProgress(_ time: CGFloat) -> CGFloat {
        let time = min(max(time, 0), 1)
        if time == 0 || time == 1 { return time }
        let parameter = unitBezierParameter(
            forX: time, x1: pageTurnCurveX1, x2: pageTurnCurveX2
        )
        return unitBezierComponent(parameter, c1: pageTurnCurveY1, c2: pageTurnCurveY2)
    }

    private static func unitBezierComponent(_ t: CGFloat, c1: CGFloat, c2: CGFloat) -> CGFloat {
        let oneMinus = 1 - t
        return 3 * oneMinus * oneMinus * t * c1
            + 3 * oneMinus * t * t * c2
            + t * t * t
    }

    private static func unitBezierDerivative(_ t: CGFloat, c1: CGFloat, c2: CGFloat) -> CGFloat {
        let oneMinus = 1 - t
        return 3 * oneMinus * oneMinus * c1
            + 6 * oneMinus * t * (c2 - c1)
            + 3 * t * t * (1 - c2)
    }

    /// Newton, then bisection. The page curve's x controls stay inside (0, 1).
    private static func unitBezierParameter(forX x: CGFloat, x1: CGFloat, x2: CGFloat) -> CGFloat {
        var t = x
        for _ in 0..<8 {
            let delta = unitBezierComponent(t, c1: x1, c2: x2) - x
            if abs(delta) < 0.000_01 { return min(max(t, 0), 1) }
            let slope = unitBezierDerivative(t, c1: x1, c2: x2)
            if abs(slope) < 0.000_001 { break }
            t -= delta / slope
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        t = min(max(t, 0), 1)
        for _ in 0..<12 {
            let estimate = unitBezierComponent(t, c1: x1, c2: x2)
            if abs(estimate - x) < 0.000_01 { return t }
            if estimate < x {
                low = t
            } else {
                high = t
            }
            t = (low + high) / 2
        }
        return t
    }

    /// Open-folder backdrop. Reduced motion keeps this opacity and drops the scale and blur.
    public static let folderBackdropOpenOpacity: CGFloat = 0.45
    public static let folderBackdropOpenScale: CGFloat = 0.96
    /// PRD `motion.fast`: search results appear or the grid returns.
    public static let searchTransitionDuration: TimeInterval = 0.12
    /// Same clock as search chrome: idle ↔ focus fill crossfade.
    public static let tileChromeFillFadeDuration: TimeInterval = searchTransitionDuration

    public static func shouldAnimateTileChromeFocusFill(
        fromAlpha: CGFloat,
        toAlpha: CGFloat,
        reducesMotion: Bool
    ) -> Bool {
        guard !reducesMotion else { return false }
        func inFocusBand(_ alpha: CGFloat) -> Bool {
            abs(alpha - tileChromeIdleAlpha) < 0.001
                || abs(alpha - tileChromeFocusAlpha) < 0.001
        }
        guard inFocusBand(fromAlpha), inFocusBand(toAlpha) else { return false }
        return abs(fromAlpha - toAlpha) > 0.004
    }


    /// Reduced motion: search↔grid presence snaps (no 0.12s opacity half-fade).
    /// Full motion still crossfades with `searchTransitionDuration`.
    public static func shouldSnapSearchChromeForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Search and the grid trade places. The outgoing surface stays drawn and
    /// fades out with the incoming one, so the page does not vanish first.
    /// Reduced motion, a launcher fade, or an open-folder backdrop skip that
    /// and land immediately. The backdrop keeps its own dim. The outgoing
    /// surface does not take clicks while it fades: the new page does.
    public struct SearchChromeFade: Equatable, Sendable {
        public var incomingOpacity: CGFloat
        public var outgoingOpacity: CGFloat
        public var duration: TimeInterval
        public var keepsOutgoingVisible: Bool

        public init(
            incomingOpacity: CGFloat,
            outgoingOpacity: CGFloat,
            duration: TimeInterval,
            keepsOutgoingVisible: Bool
        ) {
            self.incomingOpacity = incomingOpacity
            self.outgoingOpacity = outgoingOpacity
            self.duration = duration
            self.keepsOutgoingVisible = keepsOutgoingVisible
        }
    }

    public static func searchChromeFade(
        reducesMotion: Bool,
        holdsForLauncherFade: Bool,
        incomingIsFolderBackdrop: Bool
    ) -> SearchChromeFade {
        let incoming = incomingIsFolderBackdrop ? folderBackdropOpenOpacity : 1
        let snapReduced = shouldSnapSearchChromeForReducedMotion(
            reducesMotion: reducesMotion
        )
        let crossfade = !snapReduced && !holdsForLauncherFade && !incomingIsFolderBackdrop
        return SearchChromeFade(
            incomingOpacity: incoming,
            outgoingOpacity: crossfade ? 0 : 1,
            duration: crossfade ? searchTransitionDuration : 0,
            keepsOutgoingVisible: crossfade
        )
    }

    public static func searchChromeOutgoingAcceptsClicks(fadingOut: Bool) -> Bool {
        !fadingOut
    }

    /// CAAnimation keys for Direct opacity fades that must hold presentation
    /// with `fillMode = .backwards` (avoid animator() commit-frame flashes).
    public static let searchChromeFadeAnimationKey = "search-chrome-fade"
    public static let pageIndicatorFadeAnimationKey = "page-indicator-fade"
    public static let pageArrowPresenceAnimationKey = "page-arrow-presence"
    public static let footerHintFadeAnimationKey = "footer-hint-fade"

    /// Hidden navigation hint must not unhide at opacity 1 before a text-swap
    /// fade — that flashes the previous (or empty) line solid for a frame.
    public static func footerNavigationShouldClearOpacityBeforeUnhide(
        isHidden: Bool,
        textChanging: Bool
    ) -> Bool {
        isHidden && textChanging
    }

    /// A text-swap fade-out was cut off (quick type → clear): the label is still
    /// the old string but its model opacity is already 0. Same text again must
    /// fade back in, not stay invisible.
    public static func footerNavigationShouldRestoreOpacityWhenTextUnchanged(
        isHidden: Bool,
        textChanging: Bool,
        currentOpacity: CGFloat
    ) -> Bool {
        !isHidden && !textChanging && currentOpacity < 0.99
    }

    /// Hidden navigation hint with unchanged text can snap visible at full
    /// opacity (no swap animation).
    public static func footerNavigationShouldSnapUnhide(
        isHidden: Bool,
        textChanging: Bool
    ) -> Bool {
        isHidden && !textChanging
    }
    /// Catalog message / empty / skeleton / read-only status presence fades.
    public static let statusChromeFadeAnimationKey = "status-chrome-fade"

    /// Hidden empty / recovery / skeleton chrome must clear opacity before
    /// unhide — hide completion parks alpha at 1 while hidden, so revealing
    /// first would flash solid for a frame (same class as settings message).
    public static func statusChromeShouldClearOpacityBeforeUnhide(
        willShow: Bool,
        currentlyHidden: Bool
    ) -> Bool {
        willShow && currentlyHidden
    }

    /// A hide fade was interrupted (generation bump / rescan toggle): the view
    /// is still unhidden but presentation opacity is near 0. Another "show"
    /// must fade back up, not early-out and leave the chrome invisible.
    public static func statusChromeShouldRestoreOpacityWhenAlreadyShown(
        currentlyHidden: Bool,
        currentOpacity: CGFloat
    ) -> Bool {
        !currentlyHidden && currentOpacity < 0.99
    }

    /// Catalog status / read-only lines already on screen must crossfade when
    /// the copy changes (loading → search empty), not snap the new string.
    /// `animated` false (reduced motion / dismiss / snappy restore) snaps copy.
    public static func statusChromeShouldCrossfadeText(
        willShow: Bool,
        currentlyHidden: Bool,
        textChanging: Bool,
        animated: Bool = true
    ) -> Bool {
        animated && willShow && !currentlyHidden && textChanging
    }

    /// Read-only explanation is shown only when there is real copy to display.
    public static func statusChromeLabeledTextToShow(
        show: Bool,
        text: String
    ) -> String? {
        guard show else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Settings panel feedback line (rescan / apply / login). Same clock as
    /// status chrome; reveal clears opacity before unhide.
    public static let settingsMessageFadeDuration: TimeInterval = searchTransitionDuration
    public static let settingsMessageFadeAnimationKey = "settings-message-fade"

    public static func settingsMessageShouldShow(text: String) -> Bool {
        !text.isEmpty
    }

    /// VoiceOver should hear new feedback lines (rescan done, restored, errors)
    /// once; clearing or repeating the same line stays silent.
    public static func settingsMessageShouldAnnounce(text: String, previous: String) -> Bool {
        !text.isEmpty && text != previous
    }

    /// VoiceOver name for the settings feedback row (navigable static text).
    public static let settingsFeedbackAccessibilityLabelKey = "设置反馈"

    /// VoiceOver name for the incomplete-scan / read-only status line.
    public static let readOnlyStatusAccessibilityLabelKey = "整理状态"

    /// Tile accessibility help when open still works but drag/organize (and
    /// typically uninstall) is blocked by an incomplete or loading scan.
    /// TILE-AX-HELP-L10N-01: localize each catalog key. A caller-supplied
    /// reason is already display text and must not be looked up again.
    public static let tileOpenAppHelpKey = "按下以打开应用"
    public static let tileOpenFolderHelpKey = "按下以打开文件夹"
    public static let tileOpenAppBlockedFormatKey = "按下以打开应用。%@"
    public static let tileOpenFolderBlockedFormatKey = "按下以打开文件夹。%@"
    public static let tileBlockedUntilScanHelpKey = "暂时无法拖动整理或卸载，请先完成扫描"

    public static func tileAccessibilityHelp(
        isFolder: Bool,
        layoutEditingEnabled: Bool,
        layoutEditingExplanation: String?,
        localize: (String) -> String = { $0 }
    ) -> String {
        if layoutEditingEnabled {
            return localize(isFolder ? tileOpenFolderHelpKey : tileOpenAppHelpKey)
        }
        let reason = (layoutEditingExplanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked = reason.isEmpty ? localize(tileBlockedUntilScanHelpKey) : reason
        let format = localize(isFolder ? tileOpenFolderBlockedFormatKey : tileOpenAppBlockedFormatKey)
        return String(format: format, blocked)
    }

    /// Context menu「在访达中显示」(LaunchOS parity: reveal the source app).
    /// Only real on-disk `.app` bundles qualify. Folder tiles carry a synthetic
    /// `/<uuid>` URL and must never reveal. Reveal is read-only, so it stays
    /// available while layout editing is blocked (incomplete scan) and in search.
    public static func revealInFinderURL(for candidate: AppCandidate, isFolder: Bool) -> URL? {
        guard !isFolder, candidate.canonicalURL.isFileURL else { return nil }
        let url = candidate.canonicalURL.standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else { return nil }
        return url
    }

    /// SEARCH-CMD-RETURN-REVEAL-01 (Spotlight parity): ⌘↩ while a search is
    /// showing reveals the highlighted (or first) **app** hit in Finder instead
    /// of launching it. Return / Enter keypad, Command only (no Shift/Option/
    /// Control). Folder hits and IME composition never match. Does not page.
    public static func searchRevealShortcutMatches(
        keyCode: UInt16,
        commandOnly: Bool,
        isSearching: Bool,
        folderOpen: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        return commandOnly && isSearching && !folderOpen && !hasMarkedText
    }

    /// Reveal hands focus to Finder; the full-screen launcher would cover the
    /// new Finder window, so it dismisses first (same as a launch).
    public static let revealInFinderDismissesLauncher = true

    /// DOCK-DRAG-FILE-01. A layout drag of a real `.app` may also offer that
    /// file to another app (the Dock) as a link. Folders and synthetic URLs
    /// stay inside the launcher. This does not remove the icon or change pages.
    public enum LayoutDragOutsideOffer: Equatable, Sendable {
        case none
        case linkToApp(URL)
    }

    public static func layoutDragOutsideOffer(
        for candidate: AppCandidate?,
        isFolder: Bool
    ) -> LayoutDragOutsideOffer {
        guard let candidate,
              let url = revealInFinderURL(for: candidate, isFolder: isFolder) else {
            return .none
        }
        return .linkToApp(url)
    }

    /// The Dock is hidden while the launcher is up. An app-file drag is
    /// *eligible* to reveal it. The pointer still has to reach a screen edge
    /// (`shouldRevealDockForDragLocation`) so an in-grid reorder does not
    /// flash the Dock over the bottom row. Menu-bar hiding stays as it is.
    public static func shouldTemporarilyRevealDock(for offer: LayoutDragOutsideOffer) -> Bool {
        if case .linkToApp = offer { return true }
        return false
    }

    /// Points from the screen edge that arm a Dock reveal. Wider than a
    /// couple of pixels so the pointer can hit it, narrower than the footer
    /// (56 pt above the bottom) so page dots and the last icon row do not.
    public static let externalDragDockRevealEdgeInset: CGFloat = 12
    /// Once the Dock is out, keep it while the pointer is still over a typical
    /// Dock. Pulling back into the grid past this inset hides it again.
    public static let externalDragDockKeepVisibleInset: CGFloat = 96

    /// Reveal the Dock only for an app-file drag whose pointer is on the
    /// bottom or side edge of `screenFrame`. The top edge is the menu bar.
    /// `currentlyRevealed` widens the zone so the Dock does not flicker as
    /// soon as the pointer climbs onto it. Does not page.
    public static func shouldRevealDockForDragLocation(
        offer: LayoutDragOutsideOffer,
        pointerInScreen: CGPoint,
        screenFrame: CGRect,
        currentlyRevealed: Bool,
        revealInset: CGFloat = externalDragDockRevealEdgeInset,
        keepVisibleInset: CGFloat = externalDragDockKeepVisibleInset
    ) -> Bool {
        guard shouldTemporarilyRevealDock(for: offer) else { return false }
        guard screenFrame.width > 0, screenFrame.height > 0 else { return false }
        let inset = currentlyRevealed ? keepVisibleInset : revealInset
        guard inset > 0 else { return false }
        return pointerIsInExternalDragDockZone(
            pointerInScreen: pointerInScreen,
            screenFrame: screenFrame,
            inset: inset
        )
    }

    /// Search, folder title, and alias fields must not insert the `.fileURL`
    /// a layout drag attaches for the Dock.
    public static func launcherTextRejectsFileURLDrop(pasteboardHasFileURL: Bool) -> Bool {
        pasteboardHasFileURL
    }

    /// A file URL on the pasteboard at session start lets AppKit replace the
    /// custom drag image and its hotspot. An in-window drop then misses the
    /// icon center (merge) even though the pointer started on it. Attach the
    /// Dock link only after the pointer has left the launcher window. Does
    /// not page, and does not reveal the Dock by itself.
    public static func layoutDragPasteboardIncludesFileURL(
        offer: LayoutDragOutsideOffer,
        pointerInScreen: CGPoint,
        launcherWindowFrame: CGRect
    ) -> Bool {
        guard case .linkToApp = offer else { return false }
        guard launcherWindowFrame.width > 0, launcherWindowFrame.height > 0 else { return false }
        return !launcherWindowFrame.contains(pointerInScreen)
    }

    private static func pointerIsInExternalDragDockZone(
        pointerInScreen: CGPoint,
        screenFrame: CGRect,
        inset: CGFloat
    ) -> Bool {
        let nearX = pointerInScreen.x >= screenFrame.minX - inset
            && pointerInScreen.x <= screenFrame.maxX + inset
        let nearY = pointerInScreen.y >= screenFrame.minY - inset
            && pointerInScreen.y <= screenFrame.maxY + inset
        let nearBottom = pointerInScreen.y <= screenFrame.minY + inset
            && pointerInScreen.y >= screenFrame.minY - inset
            && nearX
        let nearLeft = pointerInScreen.x <= screenFrame.minX + inset
            && pointerInScreen.x >= screenFrame.minX - inset
            && nearY
        let nearRight = pointerInScreen.x >= screenFrame.maxX - inset
            && pointerInScreen.x <= screenFrame.maxX + inset
            && nearY
        return nearBottom || nearLeft || nearRight
    }

    /// Put Dock hiding back only when the launcher is still the surface on screen.
    public static func shouldRestoreDockHideAfterExternalDrag(
        launcherVisible: Bool,
        launcherDismissing: Bool
    ) -> Bool {
        launcherVisible && !launcherDismissing
    }

    /// Multi-select「在访达中显示」(BATCH-REVEAL-FINDER-01, Core).
    /// Title count: BATCH-REVEAL-COUNT-01 (`batchRevealMenuTitleFormatKey`).
    /// Returns on-disk `.app` URLs for selected **app** tiles in selection
    /// order when `anchorID` is in a ≥2 selection. Skips folders, missing
    /// keys, and non-qualifying candidates. Nil when selection is too small,
    /// anchor is outside the selection, or nothing qualifies. Does not touch
    /// layout, paging, or hidden keys.
    public static func revealInFinderURLs(
        selection: LauncherItemSelection,
        anchorID: UUID,
        in state: LayoutState,
        candidatesByKey: [String: AppCandidate]
    ) -> [URL]? {
        guard selection.count >= 2, selection.contains(anchorID) else { return nil }
        var urls: [URL] = []
        var seen = Set<URL>()
        for id in selection.orderedIDs {
            guard state.folders[id] == nil,
                  let key = state.appKeys[id],
                  let candidate = candidatesByKey[key],
                  let url = revealInFinderURL(for: candidate, isFolder: false),
                  seen.insert(url).inserted
            else { continue }
            urls.append(url)
        }
        return urls.isEmpty ? nil : urls
    }

    /// Grid / folder collection accessibility help while editing is blocked.
    public static func layoutCollectionAccessibilityHelp(
        layoutEditingEnabled: Bool,
        layoutEditingExplanation: String?,
        editableHelp: String
    ) -> String {
        if layoutEditingEnabled { return editableHelp }
        let reason = (layoutEditingExplanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "暂时无法拖动整理，请先完成扫描" : reason
    }

    /// After the last hidden app is restored the popup and Restore button
    /// disable. Keyboard focus must move on, not vanish with them.
    public static func settingsShouldMoveFocusAfterRestore(remainingHidden: Int) -> Bool {
        remainingHidden == 0
    }

    /// Escape closes the settings window (standard preferences behavior).
    public static let settingsEscapeClosesWindow = true

    /// Settings window presence (show/hide). Same clock as status/toast;
    /// park opacity before `orderFront`; restore interrupted hide from presentation.
    public static let settingsPresenceFadeDuration: TimeInterval = searchTransitionDuration
    public static let settingsPresenceFadeAnimationKey = "settings-presence-fade"

    public static func settingsPresenceShouldClearOpacityBeforeUnhide(
        willShow: Bool,
        currentlyVisible: Bool
    ) -> Bool {
        willShow && !currentlyVisible
    }

    public static func settingsPresenceShouldRestoreOpacityWhenAlreadyShown(
        currentlyVisible: Bool,
        currentOpacity: CGFloat
    ) -> Bool {
        currentlyVisible && currentOpacity < 0.99
    }

    /// Fresh appear starts at 0 (caller parks before orderFront). Interrupted
    /// hide/show continues from on-screen presentation.
    public static func settingsPresenceFadeFromOpacity(
        appearing: Bool,
        presentedOpacity: Float?,
        modelOpacity: Float
    ) -> Float {
        if appearing { return 0 }
        return presentedOpacity ?? modelOpacity
    }

    /// Re-show / opacity restore on an already-key settings window must not
    /// re-activate (would steal first responder / yank focus from launcher
    /// if both were somehow up). Fresh open or non-key window still takes key.
    public static func settingsPresenceShouldBecomeKeyOnShow(
        currentlyVisible: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        !(currentlyVisible && isKeyWindow)
    }


    /// Hidden empty label must clear opacity before unhide, or the first
    /// feedback line flashes solid for a frame.
    public static func settingsMessageShouldClearOpacityBeforeUnhide(
        willShow: Bool,
        currentlyHidden: Bool
    ) -> Bool {
        willShow && currentlyHidden
    }

    /// A hide/crossfade was interrupted: the feedback row is still unhidden
    /// but presentation opacity is near 0. Repeating the same line must fade
    /// back up (parity with statusChromeShouldRestoreOpacityWhenAlreadyShown /
    /// footer restoreInterruptedFooterFade), not early-out and stay invisible.
    public static func settingsMessageShouldRestoreOpacityWhenAlreadyShown(
        currentlyHidden: Bool,
        currentOpacity: CGFloat
    ) -> Bool {
        !currentlyHidden && currentOpacity < 0.99
    }


    /// Completions from an older fade must not clear or swap a newer line
    /// (rapid rescan / login / restore races).
    public static func settingsMessageFadeShouldApply(
        generation: UInt64,
        expected: UInt64
    ) -> Bool {
        generation == expected
    }
    public static let pageHostFadeAnimationKey = "page-host-fade"
    public static let pageHostSlideAnimationKey = "page-host-slide"
    public static let flyerSlideAnimationKey = "flyer-slide"
    public static let dissolvedGridFadeAnimationKey = "dissolved-grid-fade"
    public static let searchFieldWidth: CGFloat = 400

    /// Search top chrome (field pill + count + settings) stays quiet while
    /// folder chrome is open or still dissolving closed.
    public static func searchAdjacentChromeShouldShow(
        folderOpen: Bool,
        folderClosing: Bool
    ) -> Bool {
        !folderOpen && !folderClosing
    }

    /// Search-adjacent row (pill + count + settings). Own fade key so status /
    /// empty chrome generation bumps cannot cancel an interrupted adjacent hide
    /// (parity with footer restoreInterruptedFooterFade / status restore).
    public static let searchAdjacentChromeFadeAnimationKey = "search-adjacent-chrome-fade"

    public static func searchAdjacentChromeShouldClearOpacityBeforeUnhide(
        willShow: Bool,
        currentlyHidden: Bool
    ) -> Bool {
        statusChromeShouldClearOpacityBeforeUnhide(
            willShow: willShow,
            currentlyHidden: currentlyHidden
        )
    }

    public static func searchAdjacentChromeShouldRestoreOpacityWhenAlreadyShown(
        currentlyHidden: Bool,
        currentOpacity: CGFloat
    ) -> Bool {
        statusChromeShouldRestoreOpacityWhenAlreadyShown(
            currentlyHidden: currentlyHidden,
            currentOpacity: currentOpacity
        )
    }


    /// Beside the search field: result count while searching, grid item count when idle.
    public enum SearchCountLabelKind: Equatable, Sendable {
        case results
        case items
        /// SELECTED-COUNT-LABEL-01: multi-select non-empty on the main grid.
        case selected
    }

    public static func searchCountLabelKind(
        isSearching: Bool,
        folderOpen: Bool,
        folderClosing: Bool,
        selectionCount: Int = 0
    ) -> SearchCountLabelKind? {
        guard searchAdjacentChromeShouldShow(
            folderOpen: folderOpen,
            folderClosing: folderClosing
        ) else { return nil }
        if isSearching { return .results }
        // Selection chrome wins over the total-items count (main grid / folder).
        if selectionCount > 0 { return .selected }
        return .items
    }

    /// Count-label copy for SELECTED-COUNT-LABEL-01.
    public static let selectedCountLabelFormatKey = "已选 %d 项"

    /// SELECTION-A11Y-ANNOUNCE-01: VoiceOver when multi-select count changes.
    public static let selectionClearedAnnouncementKey = "已清除选择"

    public enum SelectionAnnouncementKind: Equatable, Sendable {
        case cleared
        case selected(Int)
    }

    /// Returns an announcement when `newCount` differs from `previousCount`.
    /// Clearing (→0) only announces if there was a prior selection.
    public static func selectionAnnouncementKind(
        previousCount: Int,
        newCount: Int
    ) -> SelectionAnnouncementKind? {
        let prev = max(previousCount, 0)
        let next = max(newCount, 0)
        guard prev != next else { return nil }
        if next == 0 {
            return prev > 0 ? .cleared : nil
        }
        return .selected(next)
    }

    public static let searchFieldHeight: CGFloat = 42
    public static let searchFieldCornerRadius: CGFloat = 21

    public struct DragLiftPresentation: Equatable, Sendable {
        public var scale: CGFloat
        public var shadowOpacity: CGFloat
        public var shadowRadius: CGFloat
        public var shadowOffset: CGSize
        public var contentSize: CGSize
        public var canvasSize: CGSize

        public func canvasFrame(centering source: CGRect) -> CGRect {
            CGRect(
                x: source.midX - canvasSize.width / 2,
                y: source.midY - canvasSize.height / 2,
                width: canvasSize.width,
                height: canvasSize.height
            )
        }

        public var contentOrigin: CGPoint {
            CGPoint(
                x: shadowRadius + max(0, -shadowOffset.width),
                y: shadowRadius + max(0, -shadowOffset.height)
            )
        }
    }

    /// Reduced motion: drag-lift snaps to the cell image (no scale / shadow travel).
    public static func shouldSnapDragLiftForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Reduced motion keeps the original cell image. The lift is scale plus shadow.
    public static func dragLiftPresentation(for sourceSize: CGSize, reducesMotion: Bool) -> DragLiftPresentation {
        let identity = DragLiftPresentation(
            scale: 1,
            shadowOpacity: 0,
            shadowRadius: 0,
            shadowOffset: .zero,
            contentSize: sourceSize,
            canvasSize: sourceSize
        )
        if shouldSnapDragLiftForReducedMotion(reducesMotion: reducesMotion) {
            return identity
        }
        guard sourceSize.width > 0, sourceSize.height > 0 else { return identity }
        let shadowRadius: CGFloat = 14
        let shadowOffset = CGSize(width: 0, height: -4)
        let contentSize = CGSize(
            width: sourceSize.width * dragLiftScale,
            height: sourceSize.height * dragLiftScale
        )
        let left = shadowRadius + max(0, -shadowOffset.width)
        let right = shadowRadius + max(0, shadowOffset.width)
        let bottom = shadowRadius + max(0, -shadowOffset.height)
        let top = shadowRadius + max(0, shadowOffset.height)
        return DragLiftPresentation(
            scale: dragLiftScale,
            shadowOpacity: dragLiftShadowOpacity,
            shadowRadius: shadowRadius,
            shadowOffset: shadowOffset,
            contentSize: contentSize,
            canvasSize: CGSize(
                width: contentSize.width + left + right,
                height: contentSize.height + bottom + top
            )
        )
    }

    /// Converts an NSCollectionView-style pre-removal drop index into the index
    /// to insert at after `source` has been taken out of the same list.
    public static func insertionIndexAfterRemovingSource(
        sourceIndex: Int?,
        proposedIndex: Int,
        countBeforeRemoval: Int
    ) -> Int {
        let proposed = min(max(proposedIndex, 0), max(countBeforeRemoval, 0))
        let adjusted: Int
        if let sourceIndex, sourceIndex < proposed {
            adjusted = proposed - 1
        } else {
            adjusted = proposed
        }
        let countAfter = countBeforeRemoval - (sourceIndex == nil ? 0 : 1)
        return min(max(adjusted, 0), max(countAfter, 0))
    }


    /// Absolute ordered-entry index for a gap on one grid page. `localIndex` is
    /// that page's collection-view index, including one past the last item.
    public static func topLevelDropIndex(page: Int, localIndex: Int, capacity: Int = pageCapacity) -> Int {
        let safeCapacity = max(capacity, 1)
        return max(page, 0) * safeCapacity + max(localIndex, 0)
    }

    /// Converts a visible-page gap into the pre-removal index expected by
    /// `applyDrop`. When the source is on an earlier page, removing it shifts
    /// the target page left by one, so compensate to keep the item on the page
    /// the user dropped it onto.
    public static func topLevelDropIndex(
        page: Int,
        localIndex: Int,
        sourceIndex: Int?,
        countBeforeRemoval: Int,
        capacity: Int = pageCapacity
    ) -> Int {
        let safeCapacity = max(capacity, 1)
        let target = topLevelDropIndex(page: page, localIndex: localIndex, capacity: safeCapacity)
        let sourcePage = sourceIndex.map { max($0, 0) / safeCapacity }
        let compensation = sourcePage.map { $0 < max(page, 0) ? 1 : 0 } ?? 0
        return min(target + compensation, max(countBeforeRemoval, 0))
    }

    /// Gap for a pointer that is on a cell but not in its merge center.
    /// The leading half inserts before that item; the trailing half inserts
    /// after it, including one past the last item. A zero-width cell stays put.
    public static func reorderGapIndex(
        hoveredItem: Int,
        pointerX: CGFloat,
        itemMinX: CGFloat,
        itemWidth: CGFloat,
        itemCount: Int
    ) -> Int {
        let limit = max(itemCount, 0)
        guard hoveredItem >= 0, itemWidth > 0 else {
            return min(max(hoveredItem, 0), limit)
        }
        let after = pointerX >= itemMinX + itemWidth / 2
        return min(hoveredItem + (after ? 1 : 0), limit)
    }

    /// Where a member goes when it is dragged out of a folder without a grid
    /// cell. It stays beside that folder instead of jumping to the last page.
    public static func topLevelIndexAfterFolder(_ folderID: UUID, in state: LayoutState) -> Int {
        if let index = state.orderedEntries.firstIndex(of: .folder(folderID)) {
            return index + 1
        }
        return state.orderedEntries.count
    }

    /// Page that holds the item a drop just placed on the grid. Nil when the
    /// drop only moved something inside a folder, so the grid page stays put.
    public static func pageContainingDrop(_ drop: LayoutDrop, in state: LayoutState) -> Int? {
        guard let id = topLevelLandingID(drop, in: state),
              let index = state.orderedEntries.firstIndex(where: { $0.id == id }) else { return nil }
        return pageIndex(containingEntryAt: index)
    }

    /// The grid entry to focus after `folderID` is gone. A remaining member
    /// keeps the folder's slot. An empty folder leaves whatever slid into that
    /// slot, or the previous item when the folder was last.
    public static func entryReplacingDissolvedFolder(
        folderID: UUID,
        previousEntries: [LauncherEntry],
        currentEntries: [LauncherEntry]
    ) -> UUID? {
        if currentEntries.contains(.folder(folderID)) { return folderID }
        guard let index = previousEntries.firstIndex(of: .folder(folderID)) else { return nil }
        if currentEntries.indices.contains(index) {
            return currentEntries[index].id
        }
        let previous = index - 1
        guard currentEntries.indices.contains(previous) else { return nil }
        return currentEntries[previous].id
    }

    /// Grid focus after folder chrome closes (Esc / dimmer / dissolve). Prefer
    /// the folder tile while it still exists; if it dissolved, the neighbor that
    /// took its slot (or the previous item when the folder was last). Nil only
    /// when the grid is empty.
    public static func folderCloseGridFocusID(
        pendingFolderID: UUID,
        previousEntries: [LauncherEntry],
        currentEntries: [LauncherEntry]
    ) -> UUID? {
        if let id = entryReplacingDissolvedFolder(
            folderID: pendingFolderID,
            previousEntries: previousEntries,
            currentEntries: currentEntries
        ) {
            return id
        }
        return currentEntries.first?.id
    }

    /// Apps that should fly out of an open folder when it breaks apart.
    /// Only members that landed on the grid. The icon still on the pointer
    /// is excluded: its drag image is already moving. Order follows the
    /// folder. A member that did not become a top-level app stays out.
    public static func appsScatteredFromDissolvedFolder(
        memberIDs: [UUID],
        draggedItemID: UUID?,
        currentEntries: [LauncherEntry]
    ) -> [UUID] {
        let topLevel = Set(currentEntries.compactMap { entry -> UUID? in
            if case .app(let id) = entry { return id }
            return nil
        })
        var seen = Set<UUID>()
        var scattered: [UUID] = []
        for id in memberIDs {
            guard seen.insert(id).inserted else { continue }
            guard id != draggedItemID, topLevel.contains(id) else { continue }
            scattered.append(id)
        }
        return scattered
    }

    private static func topLevelLandingID(_ drop: LayoutDrop, in state: LayoutState) -> UUID? {
        switch drop.destination {
        case .folderIndex:
            return nil
        case .topLevelIndex:
            switch drop.source {
            case .topLevel(let id):
                return id
            case .folderMember(_, let itemID):
                return itemID
            }
        case .merge(let target):
            guard case .topLevel(let targetID) = target else { return nil }
            if state.folders[targetID] != nil { return targetID }
            return state.folders.first { $0.value.itemIDs.contains(targetID) }?.key
        }
    }

    public struct DragReorderPreview: Equatable, Sendable {
        public var gapIndex: Int
        /// Visual slot for each item still in the list. The dragged item is nil.
        public var slotByItem: [Int?]
    }

    /// Where the other items sit while `sourceIndex` is held out of this list.
    /// `proposedIndex` is the collection view's pre-removal drop index. A nil
    /// result means there is no same-list gap to open.
    public static func dragReorderPreview(
        sourceIndex: Int?,
        proposedIndex: Int,
        count: Int
    ) -> DragReorderPreview? {
        guard let sourceIndex, count > 0, (0..<count).contains(sourceIndex) else { return nil }
        let gapIndex = insertionIndexAfterRemovingSource(
            sourceIndex: sourceIndex,
            proposedIndex: proposedIndex,
            countBeforeRemoval: count
        )
        var slotByItem = Array<Int?>(repeating: nil, count: count)
        var slot = 0
        for item in 0..<count where item != sourceIndex {
            if slot == gapIndex { slot += 1 }
            slotByItem[item] = slot
            slot += 1
        }
        return DragReorderPreview(gapIndex: gapIndex, slotByItem: slotByItem)
    }

    public static func itemSize(
        in viewport: CGSize,
        columns: Int = pageColumns,
        rows: Int = pageRows
    ) -> CGSize {
        let hSpacing: CGFloat = 12
        let vSpacing: CGFloat = 10
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 12
        // A fixed cell minimum can clip the fifth row on a compact display.
        let width = max(1, floor((max(viewport.width, 1) - horizontalInset - hSpacing * CGFloat(max(columns - 1, 0))) / CGFloat(max(columns, 1))))
        let height = max(1, floor((max(viewport.height, 1) - verticalInset - vSpacing * CGFloat(max(rows - 1, 0))) / CGFloat(max(rows, 1))))
        return CGSize(width: width, height: height)
    }

    public static func iconPointSize(in itemSize: CGSize) -> CGFloat {
        let widthLimited = itemSize.width * 0.58
        let heightLimited = itemSize.height - 40
        let preferred = min(84, max(60, floor(min(widthLimited, heightLimited))))
        return max(1, min(preferred, floor(heightLimited), floor(itemSize.width)))
    }

    /// How far the icon sits above the cell's center, in y-up points. The
    /// tile's centerY constraint uses the negation: AppKit applies a vertical
    /// constant from the top, so a constant of -14 lands the icon 14 points
    /// above center. The title sits under that icon.
    public static let iconCenterLift: CGFloat = 14

    /// The icon's place in a grid cell when the live tile cannot be measured.
    /// Same size and the same lift as the tile. Horizontally centered.
    public static func iconFrame(in cell: CGRect) -> CGRect {
        guard cell.width >= 1, cell.height >= 1,
              cell.origin.x.isFinite, cell.origin.y.isFinite,
              cell.size.width.isFinite, cell.size.height.isFinite else { return .zero }
        let iconSize = iconPointSize(in: cell.size)
        guard iconSize >= 1 else { return .zero }
        return CGRect(
            x: cell.midX - iconSize / 2,
            y: cell.midY + iconCenterLift - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
    }

    public static func folderDisplayColumns(forItemCount count: Int) -> Int {
        min(max(count, 1), folderColumns)
    }

    public static func preferredFolderPanelWidth(forItemCount count: Int) -> CGFloat {
        max(460, min(820, CGFloat(folderDisplayColumns(forItemCount: count)) * 160 + 32))
    }

    public static func shouldTurnPage(distance: CGFloat, velocity: CGFloat, pageWidth: CGFloat) -> Bool {
        abs(distance) >= max(40, pageWidth * pageTurnDistanceFraction) || abs(velocity) >= 480
    }

    public static func shouldTurnDiscretePage(accumulatedDelta: CGFloat) -> Bool {
        abs(accumulatedDelta) >= discretePageTurnThreshold
    }

    /// What to do when a page gesture ends and no transition is already running.
    /// Rubber-band only if the grid was actually pulled. A clamped step, or a
    /// finger-up after ignored motion, must not start another animation.
    public enum PageDragFinish: Equatable, Sendable {
        case ignore
        case settle
        case turn(Int)
    }

    public static func pageDragFinish(
        direction: Int?,
        isVisuallyDragging: Bool,
        currentPage: Int,
        pageCount: Int
    ) -> PageDragFinish {
        guard pageCount > 0 else { return .ignore }
        guard let direction else {
            return isVisuallyDragging ? .settle : .ignore
        }
        let target = pageIndex(
            movingBy: direction,
            from: currentPage,
            inFlightPage: nil,
            queuedPage: nil,
            pageCount: pageCount
        )
        if target == currentPage {
            return isVisuallyDragging ? .settle : .ignore
        }
        return .turn(target)
    }

    /// Which launch highlight to show after one open finishes.
    /// Keep the current highlight if that app is still opening. If it just
    /// finished and others remain, move to one of those. Clear when none remain.
    public enum LaunchHighlightChange: Equatable, Sendable {
        case keep
        case show(String?)
    }

    public static func launchHighlightChange(
        finishedKey: String,
        highlightedKey: String?,
        remainingKeys: Set<String>
    ) -> LaunchHighlightChange {
        if remainingKeys.isEmpty { return .show(nil) }
        guard highlightedKey == finishedKey else { return .keep }
        return .show(remainingKeys.sorted().first)
    }

    /// A successful open hides the launcher after a short delay. Showing it
    /// again during that wait — a hotkey during the dismiss animation, the
    /// Dock, or the menu — bumps the generation and cancels the late hide.
    /// Turning the preference off also keeps the launcher up. A failed open
    /// never asks this.
    public static func shouldDismissAfterSuccessfulLaunch(
        hidesAfterLaunch: Bool,
        launchGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        hidesAfterLaunch && launchGeneration == currentGeneration
    }

    /// Launchpad releases launcher chrome before asking Launch Services to open.
    /// Keeping `.hideDock` / `.hideMenuBar` across an async open wait blocked
    /// some Electron apps (for example Devin). When the preference is on,
    /// release those options on the click stack before the Finder-style open.
    public static func shouldReleasePresentationBeforeOpen(hidesAfterLaunch: Bool) -> Bool {
        hidesAfterLaunch
    }

    /// After a Finder-style open, clear「正在启动…」immediately. The dismiss fade
    /// must not gate that reload — otherwise the label sticks under the fade.
    public static func shouldForceReloadLaunchHighlightAfterImmediateOpen(
        isDismissing: Bool
    ) -> Bool {
        _ = isDismissing
        return true
    }

    /// preview.74–75: `collectionView.reloadItems` inside `setLaunchPending`
    /// before `/usr/bin/open` raised a swallowed ObjC inconsistency exception
    /// (Devin never reached "Launch open begin"). Highlight is restored via
    /// in-place tile updates; do **not** skip the feedback entirely.
    public static func shouldSkipLaunchPendingHighlightBeforeOpen() -> Bool {
        false
    }

    /// Launch pending UI must update visible tiles in place. Never call
    /// `NSCollectionView.reloadItems` / `reloadData` on the click stack before
    /// open — that path is what aborted Devin under preview.74.
    public static func shouldApplyLaunchPendingHighlightInPlaceOnly() -> Bool {
        true
    }

    /// What `Contents/Info.plist` says about a Mac bundle's executable.
    /// Gathered without `Bundle` or `NSWorkspace` — those entry points on the
    /// click stack can raise an ObjC exception that aborts the open (Devin).
    public enum OpenBundleExecutable: Equatable, Sendable {
        /// The file `/usr/bin/open` stops on. The plist string is used as-is:
        /// `open` does not trim it, so a name of spaces can be a real file.
        /// Symlinks are followed. A non-empty regular file with the execute
        /// bit is not format-checked: a script can be accepted by `open`,
        /// and sniffing Mach-O would reject it.
        public enum NamedFile: Equatable, Sendable {
            /// Nothing at the path, including a dangling symlink.
            case missing
            /// A directory, or a symlink to a directory.
            case directory
            /// A non-directory file the current user cannot execute.
            case notExecutable
            /// A fifo, socket, device, or other non-regular file. `open` can
            /// block on a fifo instead of exiting.
            case notRegularFile
            /// A regular file of size 0. Not a script; `open` reports an
            /// incorrect executable format.
            case emptyFile
            /// A non-empty regular file with the execute bit.
            case executableFile
        }

        /// No `Contents/Info.plist` node, including a dangling symlink.
        /// Not judged here. A node that exists but is not a property list
        /// is not this case: `open` uses the bundle filename instead.
        /// A missing node whose bundle-name file is a fifo is
        /// `.named(.notRegularFile)`, not this case.
        case notMacInfoPlist
        /// Bundle-filename lookup found nothing `open` will launch. The
        /// filename drops only the last extension (`Foo.bar.app` → `Foo.bar`).
        /// That happens when `CFBundleExecutable` is missing, `""`, or not a
        /// string — except a missing key whose `NSExecutable` is a non-empty
        /// string, which is a real filename instead of this fallback — and
        /// when a plist node exists but is not a property list. A
        /// whitespace-only string is a filename, not this case. A fifo
        /// bundle-name file is `.named(.notRegularFile)`, not this case.
        case absent
        /// The first existing file for a relative name, inside the bundle.
        /// `open` checks `Contents/MacOS`, then `Contents`, then the bundle
        /// root, and stops at the first path that exists.
        case named(NamedFile)
        /// The name is absolute. The file exists. `open` still reports an
        /// incorrect executable format, including when the path is this
        /// bundle's own binary.
        case absolute
        /// The first existing file is lexically outside the bundle. `open`
        /// reports an incorrect executable format even if that file can run.
        case outsideBundle
    }

    /// A Mac bundle whose Info.plist already shows `/usr/bin/open` cannot run
    /// it fails before spawn, so the click toasts「无法打开」without hiding.
    /// Relative names (including `./Tool`, `Sub/Tool`, and `../Resources/Tool`)
    /// are resolved under `Contents/MacOS`, then `Contents`, then the bundle
    /// root. The first path that exists wins, so a directory, a non-executable
    /// file, a zero-byte file, or a fifo there fails even when a later
    /// directory has a good binary. A fifo must not reach `open`: it does not
    /// return, and Launch Services stays stuck in `open()`. An absolute name,
    /// or a relative name whose first existing file sits outside the bundle,
    /// fails the same way. A missing `CFBundleExecutable` uses `NSExecutable`
    /// when that value is a non-empty string; `""` and non-strings use the
    /// bundle filename and do not consult `NSExecutable`. A plist node that
    /// exists but is not a property list uses that same bundle filename; if
    /// the file cannot run, the click fails before spawn. No plist node
    /// still goes to `/usr/bin/open`, except when that bundle filename is a
    /// fifo or other non-regular file: `open` then blocks in Launch Services.
    public static func shouldRejectOpenBeforeSpawn(executable: OpenBundleExecutable) -> Bool {
        switch executable {
        case .notMacInfoPlist, .named(.executableFile):
            return false
        case .absent, .absolute, .outsideBundle,
             .named(.missing), .named(.directory), .named(.notExecutable),
             .named(.notRegularFile), .named(.emptyFile):
            return true
        }
    }

    /// `/usr/bin/open` is spawned without waiting on the click stack. A later
    /// non-zero exit means Launch Services rejected the request after spawn.
    public static func shouldReportOpenProcessFailure(terminationStatus: Int32) -> Bool {
        terminationStatus != 0
    }

    /// A late `open` exit belongs to the click that spawned it. A newer click
    /// on the same app replaces that attempt. Applying the old non-zero exit
    /// would toast「无法打开」after the later request had already taken over.
    /// Status 0 is success and never applies. Attempt numbers start at 1.
    public static func shouldApplyDelayedOpenFailure(
        finishedAttempt: Int,
        latestAttempt: Int,
        terminationStatus: Int32
    ) -> Bool {
        shouldReportOpenProcessFailure(terminationStatus: terminationStatus)
            && finishedAttempt > 0
            && finishedAttempt == latestAttempt
    }

    /// Spawn returns before `/usr/bin/open` exits, and a hide for that click
    /// may already be in progress. Bring the launcher back only for the
    /// failure that still belongs to that click. A newer click, a successful
    /// exit, or a `show()` since the hide (generation bump) leaves the
    /// launcher where the user put it.
    public static func shouldReshowLauncherAfterDelayedOpenFailure(
        hidForThisLaunch: Bool,
        launchDismissGeneration: Int,
        currentDismissGeneration: Int,
        finishedAttempt: Int,
        latestAttempt: Int,
        terminationStatus: Int32
    ) -> Bool {
        hidForThisLaunch
            && launchDismissGeneration == currentDismissGeneration
            && shouldApplyDelayedOpenFailure(
                finishedAttempt: finishedAttempt,
                latestAttempt: latestAttempt,
                terminationStatus: terminationStatus
            )
    }

    /// Surface that late failure in the UI only while the launcher can still
    /// show a toast. A hide already in progress (or ordered out) relies on the
    /// deferred-toast path inside showToast instead.
    public static func shouldSurfaceDelayedOpenFailureWhileLauncherVisible(
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        !isDismissing && isVisible
    }

    /// `show()` while the fade is still up must leave the first responder
    /// where it is. The window is still key. Moving it ends the folder-title
    /// editor and saves the draft this fade was keeping, and it also drops
    /// an unfinished search. A launcher that is appearing, or that already
    /// gave up key, starts on the grid. The caller has to read key status
    /// before `NSApp.activate`, which makes the window key again.
    /// Opening settings from a visible launcher dismisses the grid so the
    /// settings window is not buried. Closing settings should bring that
    /// grid back only when we were the ones who hid it.
    public static func shouldHideLauncherToShowSettings(launcherVisible: Bool) -> Bool {
        launcherVisible
    }

    public static func shouldRestoreLauncherWhenSettingsCloses(
        didHideLauncherToShowSettings: Bool
    ) -> Bool {
        didHideLauncherToShowSettings
    }

    /// User brought the launcher back (hotkey/menu) while settings stayed open.
    /// Drop the restore flag so closing settings does not show() again.
    public static func shouldClearSettingsLauncherRestoreFlag(
        didHideLauncherToShowSettings: Bool,
        launcherVisible: Bool
    ) -> Bool {
        didHideLauncherToShowSettings && launcherVisible
    }

    /// Opening settings should not wait on the launcher dismiss fade — hand off
    /// with an immediate orderOut so the settings window can appear on this turn.
    public static func shouldAnimateLauncherHideForSettingsHandoff() -> Bool {
        false
    }

    /// Closing settings restores a launcher that was instant-hidden — skip the
    /// full appear fade/rise so gear → settings → close stays symmetric.
    public static func shouldAnimateLauncherShowForSettingsHandoff() -> Bool {
        false
    }

    /// Settings handoff restore must keep the in-progress search query. A
    /// normal hotkey/menu appear still clears it in prepareForPresentation.
    public static func shouldClearSearchQueryWhenPreparingPresentation(
        preservesQueryAcrossHandoff: Bool
    ) -> Bool {
        !preservesQueryAcrossHandoff
    }

    /// Instant hide for settings: remember if the search field held the keyboard
    /// so snappy restore can put typing focus back.
    public static func shouldParkSearchFocusForSettingsHandoff(
        searchHoldsKeyboardFocus: Bool
    ) -> Bool {
        searchHoldsKeyboardFocus
    }

    public static func shouldRestoreSearchFocusAfterSettingsHandoff(
        isSettingsHandoffRestore: Bool,
        searchHeldFocusBeforeHandoff: Bool
    ) -> Bool {
        isSettingsHandoffRestore && searchHeldFocusBeforeHandoff
    }

    /// Instant hide for settings: remember a non-empty query so snappy restore
    /// can keep the search-results host up (no grid flash before hits).
    public static func shouldParkSearchResultsChromeForSettingsHandoff(
        queryIsNonEmpty: Bool
    ) -> Bool {
        queryIsNonEmpty
    }

    public static func shouldRestoreSearchResultsChromeAfterSettingsHandoff(
        isSettingsHandoffRestore: Bool,
        hadNonEmptyQueryBeforeHandoff: Bool
    ) -> Bool {
        isSettingsHandoffRestore && hadNonEmptyQueryBeforeHandoff
    }

    /// prepareForPresentation keeping the query: land results chrome before
    /// the first restored frame.
    public static func shouldEnsureSearchResultsChromeWhenPreservingQuery(
        queryIsNonEmpty: Bool
    ) -> Bool {
        queryIsNonEmpty
    }

    /// Snappy settings restore with a parked non-empty query: page dots stay
    /// off (search passes pageCount 0) so grid dots do not flash under results.
    public static func shouldSuppressPageIndicatorAfterSettingsHandoff(
        isSettingsHandoffRestore: Bool,
        hadNonEmptyQueryBeforeHandoff: Bool
    ) -> Bool {
        isSettingsHandoffRestore && hadNonEmptyQueryBeforeHandoff
    }

    /// prepareForPresentation keeping a non-empty query: snap dots suppressed
    /// before the first restored frame.
    public static func shouldEnsurePageIndicatorSuppressedWhenPreservingQuery(
        queryIsNonEmpty: Bool
    ) -> Bool {
        queryIsNonEmpty
    }

    /// Snappy settings restore with a parked non-empty query: prev/next page
    /// arrows stay off so grid arrows do not flash under search results.
    public static func shouldSuppressPageArrowsAfterSettingsHandoff(
        isSettingsHandoffRestore: Bool,
        hadNonEmptyQueryBeforeHandoff: Bool
    ) -> Bool {
        isSettingsHandoffRestore && hadNonEmptyQueryBeforeHandoff
    }

    /// prepareForPresentation keeping a non-empty query: snap arrows off
    /// before the first restored frame.
    public static func shouldEnsurePageArrowsSuppressedWhenPreservingQuery(
        queryIsNonEmpty: Bool
    ) -> Bool {
        queryIsNonEmpty
    }

    /// Snappy settings restore with a parked non-empty query: footer shows
    /// search chrome (no drag / grid nav hint flash under results).
    public static func shouldSnapSearchFooterChromeAfterSettingsHandoff(
        isSettingsHandoffRestore: Bool,
        hadNonEmptyQueryBeforeHandoff: Bool
    ) -> Bool {
        isSettingsHandoffRestore && hadNonEmptyQueryBeforeHandoff
    }

    /// prepareForPresentation keeping a non-empty query: land search footer
    /// chrome before the first restored frame.
    public static func shouldEnsureSearchFooterChromeWhenPreservingQuery(
        queryIsNonEmpty: Bool
    ) -> Bool {
        queryIsNonEmpty
    }

    /// Snappy settings restore with a parked non-empty query: count + settings
    /// stay search-visible (results count, not idle grid item count).
    public static func shouldSnapSearchAdjacentChromeAfterSettingsHandoff(
        isSettingsHandoffRestore: Bool,
        hadNonEmptyQueryBeforeHandoff: Bool
    ) -> Bool {
        isSettingsHandoffRestore && hadNonEmptyQueryBeforeHandoff
    }

    /// prepareForPresentation keeping a non-empty query: land search-adjacent
    /// chrome before the first restored frame.
    public static func shouldEnsureSearchAdjacentChromeWhenPreservingQuery(
        queryIsNonEmpty: Bool
    ) -> Bool {
        queryIsNonEmpty
    }

    /// Esc cleared a search that had a focused result: put the keyboard on
    /// that same entry in the grid instead of the blank root view.
    public static func shouldRestoreGridFocusAfterClearingSearch(
        hadFocusedSearchResult: Bool
    ) -> Bool {
        hadFocusedSearchResult
    }

    /// Esc cleared a search while the field (not a result) held focus: land on
    /// the first tile of the current grid page instead of the blank root.
    public static func shouldFocusFirstGridItemAfterClearingSearch(
        hadFocusedSearchResult: Bool
    ) -> Bool {
        !hadFocusedSearchResult
    }

    /// Search field emptied (built-in clear / delete-all) while a query was
    /// active: leave the empty field and land on the current page's first tile.
    public static func shouldFocusFirstGridItemAfterSearchQueryEmptied(
        wasSearching: Bool,
        isSearchingNow: Bool
    ) -> Bool {
        wasSearching && !isSearchingNow
    }

    /// System NSSearchField cancel ended searching (custom clearButton removed).
    /// If the field still holds focus and the grid is showing, land on the
    /// first tile — covers cancel when text-change already emptied the query.
    public static func shouldFocusFirstGridItemAfterSearchFieldDidEndSearching(
        isSearching: Bool,
        searchHoldsKeyboardFocus: Bool
    ) -> Bool {
        !isSearching && searchHoldsKeyboardFocus
    }

    /// After a non-empty query yields hits, the first hit is the keyboard-open
    /// target while the search field keeps first responder (typing uninterrupted).
    /// Not searching / no hits clears. When `previousHighlightID` is still in
    /// the list it is kept (arrow navigation); pass nil after a query edit to
    /// pin the first hit.
    public static func searchKeyboardHighlightID(
        isSearching: Bool,
        presentedIDs: [UUID],
        previousHighlightID: UUID?
    ) -> UUID? {
        guard isSearching, !presentedIDs.isEmpty else { return nil }
        if let previousHighlightID, presentedIDs.contains(previousHighlightID) {
            return previousHighlightID
        }
        return presentedIDs.first
    }

    /// Arrow-down / arrow-up while the search field stays first responder.
    /// Moves the keyboard-open highlight within presented hits; does not page.
    public static func searchKeyboardHighlightIDMoving(
        from current: UUID?,
        in presentedIDs: [UUID],
        by delta: Int
    ) -> UUID? {
        guard !presentedIDs.isEmpty else { return nil }
        if delta == 0 {
            return searchKeyboardHighlightID(
                isSearching: true,
                presentedIDs: presentedIDs,
                previousHighlightID: current
            )
        }
        if let current, let idx = presentedIDs.firstIndex(of: current) {
            let next = min(max(idx + delta, 0), presentedIDs.count - 1)
            return presentedIDs[next]
        }
        // No highlight yet: Down → first, Up → last.
        return delta > 0 ? presentedIDs.first : presentedIDs.last
    }

    /// Focus-fill chrome when the tile is first responder or the search
    /// keyboard-open highlight (field still holds the caret).
    public static func tileShowsKeyboardFocusChrome(
        isFirstResponder: Bool,
        isSearchKeyboardHighlighted: Bool
    ) -> Bool {
        isFirstResponder || isSearchKeyboardHighlighted
    }

    /// Deliberate Tab from the search field: hand real first responder to the
    /// keyboard-open highlight (or first hit). Marked IME text must not move FR.
    public static func shouldHandOffSearchFieldTabToHit(
        isSearching: Bool,
        hasHits: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        isSearching && hasHits && !hasMarkedText
    }

    /// Target id for Tab handoff from the search field.
    public static func searchFieldTabHandoffTargetID(
        highlightID: UUID?,
        presentedIDs: [UUID]
    ) -> UUID? {
        guard !presentedIDs.isEmpty else { return nil }
        if let highlightID, presentedIDs.contains(highlightID) {
            return highlightID
        }
        return presentedIDs.first
    }

    /// Shift-Tab from the first search hit returns to the field (natural reverse
    /// of Tab handoff). Other collections keep their own leave-list policy.
    public static func shouldReturnSearchHitBacktabToField(
        isSearchCollection: Bool,
        tabDirection: Int
    ) -> Bool {
        isSearchCollection && tabDirection < 0
    }

    public static func shouldKeepLauncherFocusWhenShown(isAppearing: Bool, isKey: Bool) -> Bool {
        !isAppearing && isKey
    }

    /// What the hotkey and the menu-bar item do next. The window stays
    /// visible during the dismiss animation, but that next action shows it
    /// again. The Dock uses the same choice and only performs `.show`, so a
    /// Dock click never hides a launcher that is already up.
    public enum LauncherVisibilityToggle: Equatable, Sendable {
        case show
        case hide
    }

    public static func visibilityToggle(isVisible: Bool, isDismissing: Bool) -> LauncherVisibilityToggle {
        if isDismissing || !isVisible { return .show }
        return .hide
    }

    /// Pixel inset from a screen edge that counts as a hot-corner hit.
    /// Slightly larger than a single pixel for usability; still conflicts with
    /// a system Mission Control corner on the same display corner.
    public static let hotCornerHitThreshold: CGFloat = 5

    /// Which configured corner (if any) contains `point` in Cocoa global coords
    /// (origin bottom-left, same as `NSEvent.mouseLocation` / `NSScreen.frame`).
    public static func hotCorner(
        at point: CGPoint,
        screenFrame: CGRect,
        threshold: CGFloat = hotCornerHitThreshold
    ) -> LauncherHotCorner? {
        guard threshold >= 0, screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let inLeft = point.x <= screenFrame.minX + threshold
        let inRight = point.x >= screenFrame.maxX - threshold
        let inBottom = point.y <= screenFrame.minY + threshold
        let inTop = point.y >= screenFrame.maxY - threshold
        if inLeft && inTop { return .topLeft }
        if inRight && inTop { return .topRight }
        if inLeft && inBottom { return .bottomLeft }
        if inRight && inBottom { return .bottomRight }
        return nil
    }

    /// First matching corner across displays (mouse may sit on any screen).
    /// A corner where another display continues the desktop (the pointer
    /// passes through it on the way to that display) is ignored, so only
    /// real outer corners fire. A single display behaves as before.
    public static func hotCorner(
        at point: CGPoint,
        screenFrames: [CGRect],
        threshold: CGFloat = hotCornerHitThreshold
    ) -> LauncherHotCorner? {
        for (index, frame) in screenFrames.enumerated() {
            guard let hit = hotCorner(at: point, screenFrame: frame, threshold: threshold) else { continue }
            var others = screenFrames
            others.remove(at: index)
            if isHotCornerOpenToAdjacentDisplay(hit, of: frame, otherFrames: others) { continue }
            return hit
        }
        return nil
    }

    /// True when a display touches `frame` right past `corner`, horizontally
    /// or vertically, so the pointer is not pinned there.
    public static func isHotCornerOpenToAdjacentDisplay(
        _ corner: LauncherHotCorner,
        of frame: CGRect,
        otherFrames: [CGRect]
    ) -> Bool {
        guard corner.isEnabled, !otherFrames.isEmpty else { return false }
        let probe: CGFloat = 0.5
        let isLeft = corner == .topLeft || corner == .bottomLeft
        let isTop = corner == .topLeft || corner == .topRight
        let cornerX = isLeft ? frame.minX : frame.maxX
        let cornerY = isTop ? frame.maxY : frame.minY
        let insideX = isLeft ? cornerX + probe : cornerX - probe
        let insideY = isTop ? cornerY - probe : cornerY + probe
        let outsideX = isLeft ? cornerX - probe : cornerX + probe
        let outsideY = isTop ? cornerY + probe : cornerY - probe
        let sideways = CGPoint(x: outsideX, y: insideY)
        let vertical = CGPoint(x: insideX, y: outsideY)
        return otherFrames.contains { $0.contains(sideways) || $0.contains(vertical) }
    }

    /// Edge-trigger: fire only when the pointer newly enters `configured`.
    /// Seeding `previousHit` to the current hit on monitor start avoids a
    /// spurious toggle if the cursor is already in that corner.
    public static func shouldFireHotCorner(
        configured: LauncherHotCorner,
        previousHit: LauncherHotCorner?,
        currentHit: LauncherHotCorner?
    ) -> Bool {
        guard configured.isEnabled else { return false }
        guard currentHit == configured else { return false }
        return previousHit != configured
    }


    /// Hot-corner show/hide must use the same animated launcher presence fade
    /// as the hotkey (`park` + `animateLauncherPresence` from presentation).
    /// Never the settings-handoff snappy path (animated: false), and never
    /// retune page indicator/arrows as a side effect of the corner trigger.
    public static func shouldAnimateLauncherPresenceForHotCorner() -> Bool {
        true
    }

    /// Hot corner must not snap paging chrome (indicator/arrows/footer) the way
    /// settings handoff does — that is a paging-adjacent risk and unrelated.
    public static func shouldSnapPagingChromeForHotCornerTrigger() -> Bool {
        false
    }


    /// Menu-bar title for that same choice. The menu writes it when it opens
    /// and must write it again if show or hide happens while the menu is up.
    /// A stale「隐藏」during the fade would bring the launcher back.
    // MARK: - Menu chrome titles (MENU-CHROME-TITLES-01)

    /// App menu + status-item menu titles (not grid context menus).
    public enum MenuChromeCopy {
        public static let settingsTitleKey = "设置…"
        public static let quitAppTitleKey = "退出 LaunchIcon"
        public static let quitTitleKey = "退出"
        public static let editMenuTitleKey = "编辑"
        public static let selectAllTitleKey = "全选"
        public static let pasteTitleKey = "粘贴"

        public static func settingsTitle(localize: (String) -> String = { $0 }) -> String {
            localize(settingsTitleKey)
        }

        public static func quitAppTitle(localize: (String) -> String = { $0 }) -> String {
            localize(quitAppTitleKey)
        }

        public static func quitTitle(localize: (String) -> String = { $0 }) -> String {
            localize(quitTitleKey)
        }

        public static func editMenuTitle(localize: (String) -> String = { $0 }) -> String {
            localize(editMenuTitleKey)
        }

        public static func selectAllTitle(localize: (String) -> String = { $0 }) -> String {
            localize(selectAllTitleKey)
        }

        public static func pasteTitle(localize: (String) -> String = { $0 }) -> String {
            localize(pasteTitleKey)
        }

        /// Same label as empty-chrome / read-only rescan buttons.
        public static func reloadCatalogTitle(localize: (String) -> String = { $0 }) -> String {
            CatalogEmptyChromeCopy.reloadButtonTitle(localize: localize)
        }
    }

    // STATUS-ITEM-CLICK-01 — left click toggles; right/Control-click opens menu.
    // STATUS-ITEM-OPTION-SETTINGS-01 — Option+left click opens Settings.
    // STATUS-ITEM-NONPOINTER-MENU-01 — no mouse event (VoiceOver / keyboard) opens the menu.
    public enum StatusItemPointerKind: Equatable, Sendable {
        case primary
        case secondary
        /// Activation without a mouse event. Opens the menu so Settings and Quit
        /// stay reachable from VoiceOver or the keyboard.
        case nonPointer
    }

    public enum StatusItemButtonAction: Equatable, Sendable {
        case toggle
        case showMenu
        case openSettings
    }

    public static func statusItemButtonAction(
        for pointer: StatusItemPointerKind,
        optionDown: Bool = false
    ) -> StatusItemButtonAction {
        switch pointer {
        case .secondary, .nonPointer:
            return .showMenu
        case .primary where optionDown:
            return .openSettings
        case .primary:
            return .toggle
        }
    }

    public static func statusItemToggleTitle(isVisible: Bool, isDismissing: Bool) -> String {
        switch visibilityToggle(isVisible: isVisible, isDismissing: isDismissing) {
        case .show:
            return "显示 LaunchIcon"
        case .hide:
            return "隐藏 LaunchIcon"
        }
    }


    /// Arming dismiss (fade still on screen) must refresh the status-menu
    /// toggle immediately — an already-open menu can still show「隐藏」until
    /// the next `menuWillOpen`. Same for cancelling dismiss mid-fade.
    public static func shouldRefreshStatusItemToggleTitleOnDismissArm() -> Bool {
        true
    }

    public static func shouldRefreshStatusItemToggleTitleOnDismissCancel(
        wasDismissing: Bool
    ) -> Bool {
        wasDismissing
    }


    /// The dismiss animation leaves the window on screen. Keys during that
    /// wait must not page, search, or edit. The global hotkey is not a window
    /// key event, so it can still bring the launcher back.
    public static func shouldSuspendLauncherKeyboard(isDismissing: Bool) -> Bool {
        isDismissing
    }

    /// A suspended key equivalent has to be consumed. Declining it lets the
    /// main menu open Settings or quit while the launcher is still fading.
    /// The Carbon hotkey does not go through this path.
    public static func shouldConsumeLauncherKeyEquivalent(isDismissing: Bool) -> Bool {
        shouldSuspendLauncherKeyboard(isDismissing: isDismissing)
    }

    /// A trackpad or mouse-wheel gesture that is already moving must not turn
    /// a page or scroll search results and folder members under the dismiss
    /// fade. The window ignores new mouse events. Scroll events still in
    /// flight use this rule. It is not an edge-to-page gesture.
    public static func shouldAcceptContentScroll(isDismissing: Bool) -> Bool {
        !isDismissing
    }

    /// Grid paging uses the same dismiss rule as search and folder scrolling.
    /// A wheel step waiting out its quiet period uses it too.
    public static func shouldAcceptPagingGesture(isDismissing: Bool) -> Bool {
        shouldAcceptContentScroll(isDismissing: isDismissing)
    }

    /// A press that started on an icon, folder, or Settings can still deliver
    /// mouseUp during the fade, or after the window has ordered out. That
    /// release must not open anything. A click while the launcher is up still
    /// counts, including a release after `show()` cancels the fade.
    public static func shouldAcceptPointerActivation(isDismissing: Bool, isVisible: Bool) -> Bool {
        isVisible && !isDismissing
    }

    /// Empty space behind an open folder closes that folder. Empty space with
    /// no folder hides the launcher. The mouse-up is still delivered during
    /// the fade so a drag image can end. Applying it would close the folder
    /// and, while the title is being edited, save the draft when focus leaves.
    /// A click while the launcher is up still closes the folder or dismisses.
    public static func shouldApplyBackgroundRelease(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldAcceptPointerActivation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The search field's clear button finishes on mouse-up. That release is
    /// still delivered during the fade so a drag image can end, and it would
    /// empty the query under the animation. Typing is already dropped.
    /// Showing the launcher again keeps the text that was already there.
    public static func shouldApplySearchFieldEdit(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldAcceptPointerActivation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The search cell can report a frame flipped inside the window, and a
    /// field editor that is not on screen reports a null frame. Clicks and
    /// typeText then miss the field. Prefer the view's own screen frame when
    /// it has a real size. Does not page.
    public static func accessibilityFrameOnScreen(
        viewFrameInScreen: CGRect,
        reportedFrame: CGRect
    ) -> CGRect {
        if viewFrameInScreen.width > 1, viewFrameInScreen.height > 1,
           viewFrameInScreen.origin.x.isFinite, viewFrameInScreen.origin.y.isFinite {
            return viewFrameInScreen
        }
        if reportedFrame.width > 1, reportedFrame.height > 1,
           reportedFrame.origin.x.isFinite, reportedFrame.origin.y.isFinite,
           !reportedFrame.isNull, !reportedFrame.isInfinite {
            return reportedFrame
        }
        return .zero
    }

    /// XCUI types into the application element. A borderless panel can leave
    /// that frame null, so the text event never finds a display. Prefer the
    /// key window's screen frame, then any other visible window. Does not page.
    public static func applicationAccessibilityFrame(
        keyWindowFrame: CGRect?,
        otherVisibleWindowFrames: [CGRect],
        reportedFrame: CGRect
    ) -> CGRect {
        var candidates: [CGRect] = []
        if let keyWindowFrame { candidates.append(keyWindowFrame) }
        candidates.append(contentsOf: otherVisibleWindowFrames)
        for candidate in candidates {
            let resolved = accessibilityFrameOnScreen(
                viewFrameInScreen: candidate,
                reportedFrame: .null
            )
            if resolved.width > 1, resolved.height > 1 { return resolved }
        }
        return accessibilityFrameOnScreen(viewFrameInScreen: .zero, reportedFrame: reportedFrame)
    }

    /// What to do with a pointer event once the launcher is fading or gone.
    /// A press that starts then is dropped. A left-button drag or release
    /// still has to be delivered: the drag image ends on mouseUp, and the
    /// drop is refused separately. Opening is refused by
    /// `shouldAcceptPointerActivation`.
    public enum LauncherInactivePointerEvent: Equatable, Sendable {
        case press
        case leftDrag
        case leftRelease
        case otherButton
    }

    public static func shouldDeliverPointerEventWhileInactive(
        _ event: LauncherInactivePointerEvent
    ) -> Bool {
        switch event {
        case .leftDrag, .leftRelease:
            return true
        case .press, .otherButton:
            return false
        }
    }

    /// The alias alert is application-modal, so the launcher cannot order out
    /// until it returns. A dismiss that starts while the alert is up cancels
    /// it, the same way Escape would. Save has already returned by then, so
    /// that alias is kept.
    public static func shouldAbandonAliasPromptOnDismiss(isPrompting: Bool) -> Bool {
        isPrompting
    }

    /// The icon context menu tracks in its own window, so ignoring mouse
    /// events on the launcher does not close it. A choice after dismiss has
    /// started would hide an app or open the alias alert. Only a menu that is
    /// actually tracking is cancelled. The status-item menu is not this one.
    public static func shouldCancelIconContextMenuOnDismiss(isTracking: Bool) -> Bool {
        isTracking
    }

    /// Hide and alias are layout edits. They still apply when the launcher is
    /// up. They do not apply while it is fading, already gone, or while
    /// dismiss is cancelling the menu — that cancel must not count as a choice.
    public static func shouldApplyIconContextMenuAction(
        isDismissing: Bool,
        isVisible: Bool,
        isCancellingMenu: Bool
    ) -> Bool {
        !isCancellingMenu && shouldAcceptPointerActivation(
            isDismissing: isDismissing,
            isVisible: isVisible
        )
    }

    /// A drag can still be on the cursor while the launcher fades. Releasing
    /// then must not reorder or merge. The drag image may stay until the
    /// pointer comes up; the layout does not change.
    public static func shouldAcceptLayoutDrop(isDismissing: Bool) -> Bool {
        !isDismissing
    }

    /// A session that already exists still receives moves so its image can
    /// end. A press that has not crossed the drag threshold must not start
    /// one while the launcher is fading or already gone: the icon is blanked
    /// until that session ends, and the session would track under a window
    /// that is leaving. The launcher being up can still start a drag,
    /// including after `show()` cancels the fade.
    public static func shouldBeginLayoutDrag(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldAcceptPointerActivation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The merge ring and the reorder gap stay on screen until something
    /// clears them. Doing that while the fade is still up snaps the tiles
    /// back to the grid before the window leaves. Clear when the launcher is
    /// up again, or when the window is already hidden so the next appearance
    /// does not flash the old gap. A drag that is still down is the caller's
    /// concern: this only says the picture may change.
    public static func shouldClearDropHighlight(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldCommitRestoredGridPage(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// A new folder stays invisible until the merge flight ends, then fades
    /// and scales in. That reveal can start while the launcher is fading, so
    /// the tile pops in under the fade. Commit the final opacity and scale
    /// when the launcher is up again, or when the window is already hidden,
    /// so the next appearance does not flash an invisible folder. While the
    /// fade is on screen, leave the tile on the frame it has already reached.
    public static func shouldCommitFolderLanding(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldClearDropHighlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The merge image keeps flying until the flight ends, then it is removed.
    /// That flight can still be on screen when the launcher fades, or the drag
    /// session can end during the fade and start one. Either one moves an icon
    /// under the fade. Hold only while that fade is up. A hidden window does
    /// not hold: the image is removed so the next appearance does not flash it.
    /// Same condition as holding a toast.
    public static func shouldHoldMergeFlight(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldToastDismissal(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Play a flight that has not started only while the launcher is up.
    /// A hidden window must not start one. A flight that already started is
    /// held by `shouldHoldMergeFlight` instead of advancing.
    public static func shouldAdvanceMergeFlight(isDismissing: Bool, isVisible: Bool) -> Bool {
        isVisible && !shouldHoldMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Reduced motion: merge flyer snaps off (no 0.12s opacity half-fade).
    /// Full motion still dissolves over the merge flight clock.
    public static func shouldSnapMergeFlyerForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Duration of the reduced-motion merge flyer dismiss. Zero so Direct
    /// removes the flyer at once instead of half-fading.
    public static func mergeReducedFadeDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapMergeFlyerForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return 0.12
    }

    /// Changing reduced motion snaps a merge flight that is already running.
    /// Reduced motion has no flyer fade (snap remove), and turning motion
    /// back on does not finish the old flight either. Both end by removing
    /// the image. A launcher fade that is still on screen is holding the
    /// frame already drawn, so this snap waits. Same hold as the flight. A
    /// flight that has not started is left alone.
    public static func shouldSnapInFlightMergeFlight(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Reduced motion: new-folder landing snaps (no 0.12s opacity half-fade).
    public static func shouldSnapFolderCreatedForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Duration of the reduced-motion new-folder reveal. Zero so Direct snaps
    /// instead of half-fading; full motion uses spring / dissolve clocks.
    public static func folderCreatedFadeDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapFolderCreatedForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return 0.12
    }

    /// Reduced motion used to fade a new folder in over 0.12s instead of
    /// springing. That reveal now snaps when allowed. Reveal only while the
    /// launcher is up. A hidden window, or a cancelled reveal, shows the
    /// folder at full opacity. Same condition as starting a merge flight.
    public static func shouldAnimateReducedMotionFolderLanding(
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        shouldAdvanceMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Each landing is its own tile. A later one must not drop the earlier
    /// hold: every tracked landing whose token still matches is pinned while
    /// the fade is up. An untracked layer is left alone, because nothing
    /// would finish a freeze. A hidden window, or a cancelled fade, commits
    /// instead of pinning.
    public static func shouldPinTrackedFolderLanding(
        isTracked: Bool,
        tokenMatches: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        isTracked
            && tokenMatches
            && !shouldCommitFolderLanding(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Changing reduced motion snaps a folder landing that is already running.
    /// Reduced motion has no fade (snap), and turning motion back on does not
    /// finish the old spring either. Both land on full opacity and scale.
    /// A launcher fade that is still on screen is holding the frame already
    /// drawn, so this snap waits. Same commit as the landing. A tile that is
    /// not landing is left alone.
    public static func shouldSnapInFlightFolderLanding(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldCommitFolderLanding(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The launcher fades itself in or out, and the card rises or drops, for
    /// a fraction of a second. Reduced motion is a shorter fade and no card
    /// travel. Changing the setting used to let that fade and rise finish.
    /// While the dismiss is still on screen, keep the frame already drawn
    /// instead of jumping to the end or playing the rest. A hidden window,
    /// or a launcher that is up, snaps. Same condition as holding a toast.
    /// Layer keys for the launcher window fade / card rise (Direct).
    public static let launcherPresenceFadeAnimationKey = "launcherFade"
    public static let launcherPresenceRiseAnimationKey = "launcherRise"
    /// Fresh appear rises from this translation (points); hide settles slightly below.
    public static let launcherPresenceAppearRiseOffset: CGFloat = -8
    public static let launcherPresenceHideRiseOffset: CGFloat = -4

    /// Opacity the presence fade should hold with `fillMode.backwards`.
    /// Fresh appear always starts at 0 (caller parks before `orderFront`).
    /// Cancelled dismiss / hide continues from the on-screen presentation.
    public static func launcherPresenceFadeFromOpacity(
        visible: Bool,
        appearing: Bool,
        presentedOpacity: Float?,
        modelOpacity: Float
    ) -> Float {
        if visible && appearing { return 0 }
        return presentedOpacity ?? modelOpacity
    }


    /// Reduced motion: launcher show/hide/hotkey/hot-corner presence snaps
    /// (opacity + resting card transform) — no opacity half-fade and no rise.
    public static func shouldSnapLauncherPresenceForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Duration of the presence opacity/rise flight. Zero when reduced motion
    /// snaps so dismiss `Task.sleep` does not wait on a half-fade.
    public static func launcherPresenceFadeDuration(
        visible: Bool,
        reducesMotion: Bool
    ) -> TimeInterval {
        if shouldSnapLauncherPresenceForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return visible ? 0.22 : 0.15
    }


    public static func shouldHoldInFlightLauncherPresence(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldInFlightToastFade(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Snap a launcher fade or card rise that is already running. Reduced
    /// motion has no card travel, and turning motion back on does not finish
    /// the old fade or rise either. The opacity and position already stored
    /// on the layer are the end. A dismiss that is still on screen is holding
    /// the frame already drawn, so this snap waits. Nothing that is not
    /// animating is the caller's concern.
    public static func shouldSnapInFlightLauncherPresence(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldInFlightLauncherPresence(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The drag image is drawn once, when the pointer crosses the drag
    /// threshold. Reduced motion keeps the original cell image. A lift that
    /// is already showing used to stay scaled, with its shadow, after the
    /// setting changed. Drop that lift. Turning motion back on does not add
    /// a lift to a drag already in hand. A dismiss that is still on screen
    /// keeps the picture already drawn. No drag is the caller's concern.
    public static func shouldDropInFlightDragLift(
        isDismissing: Bool,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Bool {
        shouldSnapDragLiftForReducedMotion(reducesMotion: reducesMotion)
            && shouldSnapInFlightLauncherPresence(
                isDismissing: isDismissing,
                isVisible: isVisible
            )
    }

    /// The folder panel fades and scales as it opens or closes. The grid
    /// behind it dims and shrinks while the panel opens. Those animations can
    /// still be running when the launcher fades, so the panel keeps moving
    /// under the fade, and a close can finish by hiding the panel outright.
    /// Hold only while the fade is up. A hidden window, or a cancelled fade,
    /// commits the end state instead of replaying it. Same condition as
    /// holding the merge flight.
    public static func shouldHoldFolderChromeAnimation(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Settled picture of the grid behind an open folder. Reduced motion is
    /// opacity only: full scale, no blur. A closed folder is the untouched grid.
    public struct FolderBackdropStyle: Equatable, Sendable {
        public var opacity: CGFloat
        public var scale: CGFloat
        public var blurs: Bool

        public init(opacity: CGFloat, scale: CGFloat, blurs: Bool) {
            self.opacity = opacity
            self.scale = scale
            self.blurs = blurs
        }
    }

    /// The scrim, the grid's brightness, and the backdrop blur on a close that
    /// shrinks into the icon. The panel stays readable, then dissolves. Those
    /// layers used to lift on the travel curve, so the grid was already bright
    /// and sharp while the panel was still solid. They now use the panel's
    /// late dissolve (`wholeCellMergeFlightOpacity`). Scale stays on the
    /// travel curve, so the icons grow back while the folder is still veiling
    /// them. An open, reduced motion, and a centered pop keep one curve.
    public static func folderCloseVeilUsesLateDissolve(tracksIcon: Bool, closing: Bool) -> Bool {
        tracksIcon && closing
    }

    /// Reduced motion: folder backdrop (grid veil) open/close snaps — no
    /// 0.12s opacity half-fade. Full motion still fades with scale/blur.
    public static func shouldSnapFolderBackdropForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Duration of the backdrop opacity/scale/blur flight. Zero when reduced
    /// motion snaps. Otherwise prefers a tracked panel motion duration, else
    /// the fallback chrome clock.
    public static func folderBackdropFadeDuration(
        reducesMotion: Bool,
        motionDuration: TimeInterval?
    ) -> TimeInterval {
        if shouldSnapFolderBackdropForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return motionDuration ?? folderChromeFallbackDuration
    }

    public static func folderBackdropStyle(open: Bool, reducesMotion: Bool) -> FolderBackdropStyle {
        guard open else {
            return FolderBackdropStyle(opacity: 1, scale: 1, blurs: false)
        }
        return FolderBackdropStyle(
            opacity: folderBackdropOpenOpacity,
            scale: reducesMotion ? 1 : folderBackdropOpenScale,
            blurs: !reducesMotion
        )
    }

    /// How the grid behind a folder scales. The layer anchor is the view
    /// origin, and the transform is `scale * point + shift`. A shift measured
    /// from the window center leaves a folder in the middle sliding toward
    /// that corner. The shift is the focus itself times `(1 - scale)`, so the
    /// icon stays put. Close travels back along the same shift. `focus` is in
    /// `bounds`. A missing focus, reduced motion, or a closed folder does not
    /// shift. A focus outside the bounds is clamped to the edge.
    public struct FolderBackdropRecede: Equatable, Sendable {
        public var scale: CGFloat
        public var translationX: CGFloat
        public var translationY: CGFloat

        public init(scale: CGFloat, translationX: CGFloat, translationY: CGFloat) {
            self.scale = scale
            self.translationX = translationX
            self.translationY = translationY
        }
    }

    public static func folderBackdropRecede(
        open: Bool,
        reducesMotion: Bool,
        bounds: CGRect,
        focus: CGPoint?
    ) -> FolderBackdropRecede {
        let style = folderBackdropStyle(open: open, reducesMotion: reducesMotion)
        guard !reducesMotion,
              style.scale != 1,
              let focus,
              usableChromeFrame(bounds),
              focus.x.isFinite, focus.y.isFinite else {
            return FolderBackdropRecede(scale: style.scale, translationX: 0, translationY: 0)
        }
        let clamped = CGPoint(
            x: min(max(focus.x, bounds.minX), bounds.maxX),
            y: min(max(focus.y, bounds.minY), bounds.maxY)
        )
        let shift = 1 - style.scale
        return FolderBackdropRecede(
            scale: style.scale,
            translationX: clamped.x * shift,
            translationY: clamped.y * shift
        )
    }

    /// Collapsed pose of the folder panel. Open starts here and close ends
    /// here, so the panel leaves and returns along the same path. When the
    /// folder preview is on screen, that pose sits on the preview: scale
    /// around the panel center, then translate so the scaled center lands on
    /// the preview. The length matches the merge flight (0.34s). Reduced
    /// motion is a short fade with no transform. A missing or unusable
    /// preview keeps the old centered 0.92 pop so a folder we cannot see
    /// does not fly in from nowhere.
    public struct FolderChromeCollapse: Equatable, Sendable {
        public var scale: CGFloat
        public var translationX: CGFloat
        public var translationY: CGFloat
        public var animatesTransform: Bool
        /// Panel opacity at the start of an open. 1 keeps the panel visible
        /// while it travels out of the icon. The dimmer still fades. Close
        /// always fades the panel to 0 so hiding it does not pop.
        public var panelOpacity: CGFloat
        public var duration: TimeInterval
        public var tracksIcon: Bool
        /// Corner radius on the panel layer at the collapsed pose. The layer
        /// scales with the panel, so this is larger than the plate's radius.
        /// After the scale it matches the plate. A pose that does not sit on
        /// the plate keeps `folderPanelCornerRadius`.
        public var collapsedCornerRadius: CGFloat

        public init(
            scale: CGFloat,
            translationX: CGFloat,
            translationY: CGFloat,
            animatesTransform: Bool,
            panelOpacity: CGFloat,
            duration: TimeInterval,
            tracksIcon: Bool,
            collapsedCornerRadius: CGFloat
        ) {
            self.scale = scale
            self.translationX = translationX
            self.translationY = translationY
            self.animatesTransform = animatesTransform
            self.panelOpacity = panelOpacity
            self.duration = duration
            self.tracksIcon = tracksIcon
            self.collapsedCornerRadius = collapsedCornerRadius
        }
    }

    /// Full-size folder panel. The preview plate is rounder for its size.
    /// `folderPreviewPlateCornerFraction` is the plate's radius over its side,
    /// the same fraction the tile fills.
    public static let folderPanelCornerRadius: CGFloat = 22
    public static let folderPreviewPlateCornerFraction: CGFloat = 0.24

    public static let folderChromeTravelDuration: TimeInterval = 0.34
    /// Cubic control points of a tracked open and of the grid recede.
    /// Leave quickly, then settle. A reversed close fades the plate back out
    /// on this same curve, so it stays complementary with the panel.
    public static let folderChromeTravelX1: CGFloat = 0.22
    public static let folderChromeTravelY1: CGFloat = 0.7
    public static let folderChromeTravelX2: CGFloat = 0.3
    public static let folderChromeTravelY2: CGFloat = 1
    public static let folderChromeFallbackDuration: TimeInterval = 0.22
    /// Reduced motion snaps panel open/close (no opacity half-fade). Kept as a
    /// named token so collapse/dissolve helpers share one duration policy.
    public static let folderChromeReducedDuration: TimeInterval = 0
    public static let folderChromeFallbackScale: CGFloat = 0.92
    public static let folderChromeMinimumScale: CGFloat = 0.12
    public static let folderChromeMaximumScale: CGFloat = 0.86

    /// Reduced motion: folder panel open/close snaps (no 0.12s opacity half-fade).
    public static func shouldSnapFolderChromeForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Duration carried on reduced-motion chrome collapse / dissolve. Zero so
    /// Direct parks then snaps instead of half-fading.
    public static func folderChromeFadeDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapFolderChromeForReducedMotion(reducesMotion: reducesMotion) {
            return folderChromeReducedDuration
        }
        return folderChromeFallbackDuration
    }

    public static func folderChromeCollapse(
        panelFrame: CGRect,
        iconFrame: CGRect?,
        reducesMotion: Bool
    ) -> FolderChromeCollapse {
        if shouldSnapFolderChromeForReducedMotion(reducesMotion: reducesMotion) {
            return FolderChromeCollapse(
                scale: 1,
                translationX: 0,
                translationY: 0,
                animatesTransform: false,
                panelOpacity: 0,
                duration: folderChromeFadeDuration(reducesMotion: true),
                tracksIcon: false,
                collapsedCornerRadius: folderPanelCornerRadius
            )
        }
        let fallback = FolderChromeCollapse(
            scale: folderChromeFallbackScale,
            translationX: 0,
            translationY: 0,
            animatesTransform: true,
            panelOpacity: 0,
            duration: folderChromeFallbackDuration,
            tracksIcon: false,
            collapsedCornerRadius: folderPanelCornerRadius
        )
        guard let iconFrame, usableChromeFrame(panelFrame), usableChromeFrame(iconFrame) else {
            return fallback
        }
        let raw = min(iconFrame.width / panelFrame.width, iconFrame.height / panelFrame.height)
        let scale = min(max(raw, folderChromeMinimumScale), folderChromeMaximumScale)
        let iconSide = min(iconFrame.width, iconFrame.height)
        return FolderChromeCollapse(
            scale: scale,
            translationX: iconFrame.midX - panelFrame.midX,
            translationY: iconFrame.midY - panelFrame.midY,
            animatesTransform: true,
            panelOpacity: 1,
            duration: folderChromeTravelDuration,
            tracksIcon: true,
            collapsedCornerRadius: folderPanelCollapsedCornerRadius(
                scale: scale,
                iconSide: iconSide,
                tracksIcon: true
            )
        )
    }

    /// Layer corner radius at the collapsed pose. Dividing the plate radius
    /// by the scale puts the scaled corner on the plate. A full-size panel,
    /// a bad scale, or a pose that does not track the icon stays at 22.
    public static func folderPanelCollapsedCornerRadius(
        scale: CGFloat,
        iconSide: CGFloat,
        tracksIcon: Bool
    ) -> CGFloat {
        guard tracksIcon,
              scale.isFinite, scale > 0, scale < 1,
              iconSide.isFinite, iconSide >= 1 else {
            return folderPanelCornerRadius
        }
        let expanded = iconSide * folderPreviewPlateCornerFraction / scale
        guard expanded.isFinite, expanded > 0 else { return folderPanelCornerRadius }
        return expanded
    }

    /// The preview plate relative to the panel that grows out of it.
    /// `resting` draws the plate solid. `borrowed` is the open flight and the
    /// time the folder stays open. `returning` is the close flight: the plate
    /// is drawn at `folderPreviewPlateReturnOpacity` until the close lands.
    /// `yielding` is that close reversed: the plate fades back out on
    /// `folderChromeTravelProgress` while the panel fades back in.
    public enum FolderPreviewPlatePhase: Equatable, Sendable {
        case resting
        case borrowed
        case returning
        case yielding
    }

    /// The open panel is that same rounded plate, grown up. Drawing the small
    /// one under the flight stacks two copies. Hide it while the folder is
    /// opening and while it stays open. The close draws it again, on the
    /// opacity the panel is giving up, so the panel dissolves into the plate.
    /// A reversed close keeps drawing it while it fades back out (`yielding`).
    /// Reduced motion and a centered pop never leave the plate, so they keep
    /// drawing it solid. An immediate close has already landed (`resting`).
    public static func shouldHideFolderPreviewPlate(
        tracksIcon: Bool,
        phase: FolderPreviewPlatePhase
    ) -> Bool {
        tracksIcon && phase == .borrowed
    }

    /// Clock time 0...1 along a tracked open, mapped through
    /// `folderChromeTravel*`. Ease-out: halfway through the clock, most of
    /// the visual change is done. A non-finite clock stays at the start.
    public static func folderChromeTravelProgress(at time: CGFloat) -> CGFloat {
        guard time.isFinite else { return 0 }
        let time = min(max(time, 0), 1)
        if time == 0 || time == 1 { return time }
        let parameter = unitBezierParameter(
            forX: time, x1: folderChromeTravelX1, x2: folderChromeTravelX2
        )
        return unitBezierComponent(parameter, c1: folderChromeTravelY1, c2: folderChromeTravelY2)
    }

    /// Linear clock 0...1 for the preview plate, measured to the frame about
    /// to draw. A timer that waits a full interval first lands on the steep
    /// part of a reversed close, so the plate jumps while the panel has
    /// already moved. 0 is the opacity the fade started from. 1 has arrived.
    /// A bad clock stays at the start. A duration that is not positive has
    /// already finished once any time has passed.
    public static func previewPlateFadeTime(elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard elapsed.isFinite, duration.isFinite else { return 0 }
        guard duration > 0 else { return elapsed > 0 ? 1 : 0 }
        return CGFloat(min(max(elapsed / duration, 0), 1))
    }

    /// Opacity of the preview plate while the panel shrinks back onto it.
    /// The panel fades on `wholeCellMergeFlightOpacity` and stays readable
    /// until it is sitting on the icon. The plate takes the opacity the panel
    /// gives up, so the two meet instead of the plate popping on after the
    /// panel is already gone. Clock time is 0...1 over `folderChromeTravelDuration`.
    /// 0 draws nothing. 1 is the resting plate. A non-finite clock stays hidden.
    /// Reduced motion and a close that does not track the icon do not use this.
    public static func folderPreviewPlateReturnOpacity(at time: CGFloat) -> CGFloat {
        guard time.isFinite else { return 0 }
        return 1 - wholeCellMergeFlightOpacity(at: time)
    }

    /// Same dissolve, starting from the opacity already on screen. A fresh
    /// close passes 0, because the plate was hidden. A close that interrupts
    /// a reversed open passes the opacity still drawn, so the plate does not
    /// snap off and fade back up. 1 is the resting plate. A non-finite start
    /// or clock stays hidden.
    public static func folderPreviewPlateReturnOpacity(from start: CGFloat, at time: CGFloat) -> CGFloat {
        guard start.isFinite, time.isFinite else { return 0 }
        let origin = min(max(start, 0), 1)
        return origin + (1 - origin) * folderPreviewPlateReturnOpacity(at: time)
    }

    /// Opacity while a close is reversed into an open. `start` is the plate
    /// already on screen. The panel fades back up on `folderChromeTravelProgress`,
    /// and the plate gives that same progress back, so the two stay
    /// complementary when they began that way. Clock time is 0...1 over the
    /// open duration. 0 hides the plate. A non-finite start or clock stays hidden.
    /// Reduced motion does not yield: that path draws the plate solid.
    public static func folderPreviewPlateYieldOpacity(from start: CGFloat, at time: CGFloat) -> CGFloat {
        guard start.isFinite, time.isFinite else { return 0 }
        let origin = min(max(start, 0), 1)
        return origin * (1 - folderChromeTravelProgress(at: time))
    }

    /// Shift stored after an origin-anchored scale, so the panel center lands
    /// on `center + translation`. AppKit pins the layer on the view origin.
    /// A bare scale would shrink toward that corner. `(1 - scale)` times the
    /// bounds center keeps the center put, and `translation` then carries it
    /// onto the folder icon. The layer matrix has to store this shift itself
    /// (`scale * point + shift`). Multiplying the shift by the scale misses
    /// the icon. A bad scale or panel size does not shift.
    public static func folderPanelCollapseShift(
        scale: CGFloat,
        translationX: CGFloat,
        translationY: CGFloat,
        panelBounds: CGRect
    ) -> CGPoint {
        guard scale.isFinite, scale > 0,
              translationX.isFinite, translationY.isFinite,
              usableChromeFrame(panelBounds) else { return .zero }
        return CGPoint(
            x: translationX + (1 - scale) * panelBounds.midX,
            y: translationY + (1 - scale) * panelBounds.midY
        )
    }

    private static func usableChromeFrame(_ frame: CGRect) -> Bool {
        guard frame.width >= 1, frame.height >= 1 else { return false }
        return [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
    }

    /// Where one leftover icon flies when a folder breaks apart. The source
    /// is its icon inside the open folder. The destination is its icon on
    /// the grid. The length matches the merge flight.
    public struct FolderDissolveIconPlacement: Equatable, Sendable {
        public var itemID: UUID
        public var source: CGRect
        public var destination: CGRect

        public init(itemID: UUID, source: CGRect, destination: CGRect) {
            self.itemID = itemID
            self.source = source
            self.destination = destination
        }
    }

    public struct FolderDissolveFlight: Equatable, Sendable {
        public var itemID: UUID
        public var source: CGRect
        public var destination: CGRect
        public var duration: TimeInterval

        public init(itemID: UUID, source: CGRect, destination: CGRect, duration: TimeInterval) {
            self.itemID = itemID
            self.source = source
            self.destination = destination
            self.duration = duration
        }
    }

    public static let folderDissolveFlightDuration: TimeInterval = folderChromeTravelDuration

    /// Reduced motion: folder-dissolve icon scatter snaps (no flyer travel).
    public static func shouldSnapDissolveScatterForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Scatter flight duration. Zero when reduced motion snaps.
    public static func dissolveScatterTravelDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapDissolveScatterForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return folderDissolveFlightDuration
    }

    /// Fly leftover icons from the open folder back onto the grid. Reduced
    /// motion does not travel. An unusable frame, a repeated id, or a hop
    /// shorter than a point stays put, so an icon that is already home does
    /// not flicker. Icons start together; a stagger would break the one gesture.
    public static func folderDissolveFlights(
        placements: [FolderDissolveIconPlacement],
        reducesMotion: Bool
    ) -> [FolderDissolveFlight] {
        guard !shouldSnapDissolveScatterForReducedMotion(reducesMotion: reducesMotion) else {
            return []
        }
        var seen = Set<UUID>()
        var flights: [FolderDissolveFlight] = []
        for placement in placements {
            guard seen.insert(placement.itemID).inserted else { continue }
            guard usableChromeFrame(placement.source), usableChromeFrame(placement.destination) else { continue }
            guard !framesNearlyEqual(placement.source, placement.destination) else { continue }
            flights.append(FolderDissolveFlight(
                itemID: placement.itemID,
                source: placement.source,
                destination: placement.destination,
                duration: dissolveScatterTravelDuration(reducesMotion: false)
            ))
        }
        return flights
    }

    /// The folder is gone, so the panel cannot shrink back into a preview.
    /// It fades and settles by the same amount the grid was scaled, while
    /// the leftover icon flies to its cell. Same length as that flight.
    /// Reduced motion is the short fade with no scale.
    public static func folderDissolveChrome(reducesMotion: Bool) -> FolderChromeCollapse {
        if shouldSnapFolderChromeForReducedMotion(reducesMotion: reducesMotion) {
            return FolderChromeCollapse(
                scale: 1,
                translationX: 0,
                translationY: 0,
                animatesTransform: false,
                panelOpacity: 0,
                duration: folderChromeFadeDuration(reducesMotion: true),
                tracksIcon: false,
                collapsedCornerRadius: folderPanelCornerRadius
            )
        }
        return FolderChromeCollapse(
            scale: folderBackdropOpenScale,
            translationX: 0,
            translationY: 0,
            animatesTransform: true,
            panelOpacity: 0,
            duration: folderDissolveFlightDuration,
            tracksIcon: false,
            collapsedCornerRadius: folderPanelCornerRadius
        )
    }

    /// A dissolve flight only while the launcher is up and motion is allowed.
    /// The launcher fade must not grow a new flight underneath it. A hidden
    /// window shows the grid already in place.
    public static func shouldPlayFolderDissolveScatter(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        !shouldSnapDissolveScatterForReducedMotion(reducesMotion: reducesMotion)
            && isVisible
            && !isDismissing
    }

    /// A flight completion is already on the main thread. Hopping to the next
    /// turn leaves the flying picture sitting on the cell. Commit on this turn.
    /// A callback that is not on the main thread still has to hop.
    public static func flightLandingCommitsOnThisTurn(isMainThread: Bool) -> Bool {
        isMainThread
    }

    private static func framesNearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    /// Mini icons inside a folder preview. The tile draws this same 3×3, so a
    /// flight can leave the pixels that are already on screen. At most nine,
    /// row-major, top row first. `well` is the rounded plate. A plate that
    /// cannot hold a 1pt glyph draws none.
    public static let folderPreviewGlyphColumns = 3
    public static let folderPreviewGlyphCapacity = 9
    public static let folderPreviewGlyphInset: CGFloat = 5
    public static let folderPreviewGlyphGap: CGFloat = 2

    public static func folderPreviewGlyphFrames(well: CGRect, count: Int) -> [CGRect] {
        guard count > 0, usableChromeFrame(well) else { return [] }
        let tile = floor((well.width - folderPreviewGlyphInset * 2 - folderPreviewGlyphGap * 2) / CGFloat(folderPreviewGlyphColumns))
        guard tile >= 1 else { return [] }
        let shown = min(count, folderPreviewGlyphCapacity)
        var frames: [CGRect] = []
        frames.reserveCapacity(shown)
        let stride = tile + folderPreviewGlyphGap
        for index in 0..<shown {
            let column = index % folderPreviewGlyphColumns
            let row = index / folderPreviewGlyphColumns
            frames.append(CGRect(
                x: well.minX + folderPreviewGlyphInset + CGFloat(column) * stride,
                y: well.maxY - folderPreviewGlyphInset - tile - CGFloat(row) * stride,
                width: tile,
                height: tile
            ))
        }
        return frames
    }

    /// One mini icon flying from the preview plate into its cell in the open
    /// folder. The length matches the panel growing out of that plate.
    public struct FolderPreviewGlyphPlacement: Equatable, Sendable {
        public var itemID: UUID
        public var source: CGRect
        public var destination: CGRect

        public init(itemID: UUID, source: CGRect, destination: CGRect) {
            self.itemID = itemID
            self.source = source
            self.destination = destination
        }
    }

    public struct FolderPreviewGlyphFlight: Equatable, Sendable {
        public var itemID: UUID
        public var source: CGRect
        public var destination: CGRect
        public var duration: TimeInterval

        public init(itemID: UUID, source: CGRect, destination: CGRect, duration: TimeInterval) {
            self.itemID = itemID
            self.source = source
            self.destination = destination
            self.duration = duration
        }
    }

    public static let folderPreviewGlyphFlightDuration: TimeInterval = folderChromeTravelDuration

    /// Reduced motion: folder-preview glyph fly-in/return snaps (no flyer travel).
    public static func shouldSnapFolderPreviewGlyphForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Glyph flight duration. Zero when reduced motion snaps.
    public static func folderPreviewGlyphTravelDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapFolderPreviewGlyphForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return folderPreviewGlyphFlightDuration
    }

    /// Fly the preview glyphs into the open folder. Reduced motion does not
    /// travel. An unusable frame, a repeated id, or a hop shorter than a
    /// point stays put. Icons start together; a stagger would break the one gesture.
    public static func folderPreviewGlyphFlights(
        placements: [FolderPreviewGlyphPlacement],
        reducesMotion: Bool
    ) -> [FolderPreviewGlyphFlight] {
        guard !shouldSnapFolderPreviewGlyphForReducedMotion(reducesMotion: reducesMotion) else {
            return []
        }
        var seen = Set<UUID>()
        var flights: [FolderPreviewGlyphFlight] = []
        for placement in placements {
            guard seen.insert(placement.itemID).inserted else { continue }
            guard usableChromeFrame(placement.source), usableChromeFrame(placement.destination) else { continue }
            guard !framesNearlyEqual(placement.source, placement.destination) else { continue }
            flights.append(FolderPreviewGlyphFlight(
                itemID: placement.itemID,
                source: placement.source,
                destination: placement.destination,
                duration: folderPreviewGlyphTravelDuration(reducesMotion: false)
            ))
        }
        return flights
    }

    /// Glyphs fly only when the panel itself is growing out of the preview.
    /// A centered pop has no plate to leave. The launcher fade must not grow
    /// a new flight underneath it. Reduced motion snaps (no flyers).
    public static func shouldPlayFolderPreviewGlyphFlight(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool,
        tracksIcon: Bool
    ) -> Bool {
        tracksIcon
            && !shouldSnapFolderPreviewGlyphForReducedMotion(reducesMotion: reducesMotion)
            && isVisible
            && !isDismissing
    }

    /// Fly the open folder's icons back onto the preview plate. `source` is
    /// the cell, `destination` is the glyph. Same clock and the same skips as
    /// the flight in, so the two trips are one path. Reduced motion, a bad
    /// frame, a repeated id, or a hop under a point stays in the panel.
    public static func folderPreviewGlyphReturnFlights(
        placements: [FolderPreviewGlyphPlacement],
        reducesMotion: Bool
    ) -> [FolderPreviewGlyphFlight] {
        folderPreviewGlyphFlights(placements: placements, reducesMotion: reducesMotion)
    }

    /// Return only when the panel is shrinking back into the preview. A
    /// centered pop, a dissolve, and a launcher fade have no plate to land on.
    /// Same gate as the flight in: a plate you can leave is a plate you can
    /// come back to.
    public static func shouldPlayFolderPreviewGlyphReturn(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool,
        tracksIcon: Bool
    ) -> Bool {
        shouldPlayFolderPreviewGlyphFlight(
            reducesMotion: reducesMotion,
            isDismissing: isDismissing,
            isVisible: isVisible,
            tracksIcon: tracksIcon
        )
    }

    /// An icon past the nine preview slots has nowhere on the plate to land.
    /// Closing sinks it into the center. That fade is the whole-cell dissolve
    /// (`wholeCellMergeFlightOpacity`), so it stays readable until it arrives.
    /// Opening brings the same icon back out, and that fade shares the flight
    /// ease so the icon is visible while it travels to its cell.
    public static func folderOverflowIconFadeSharesFlightEase(returningToPlate: Bool) -> Bool {
        !returningToPlate
    }

    /// An icon past the nine preview slots has no glyph to fly in with.
    /// It used to stay hidden for the whole open, then pop on at the end.
    /// It now fades in on the whole-cell dissolve, so it is still hidden
    /// halfway through the open and appears as the folder settles. 0 is
    /// hidden. A close does not use this fade.
    public static func folderOverflowIconRevealOpacity(at time: CGFloat) -> CGFloat {
        1 - wholeCellMergeFlightOpacity(at: time)
    }

    /// Only the opening flight fades those icons in. Closing leaves icons
    /// that are already in the panel alone. Reversing an open hides the
    /// ones that had not landed.
    public static func shouldFadeFolderOverflowIconsIn(opening: Bool) -> Bool {
        opening
    }

    /// CAAnimation key for Direct's overflow open fade (icon + title).
    public static let folderOverflowOpenFadeAnimationKey = "overflow-open-fade"

    /// Two app icons becoming a folder. The icon that was already on the grid
    /// lands in `destinations[0]`, the one that was dropped in `destinations[1]`.
    /// Those rects are the preview plate's first two glyphs. The clock matches
    /// the other folder flights, with no stagger. Reduced motion does not
    /// travel. Both icons have to move: a short hop, a bad frame, or fewer
    /// than two slots lands nowhere, and the caller keeps the older flight
    /// onto the whole cell. Extra slots are ignored. A new folder only has
    /// these two icons.
    public struct FolderMergePreviewLanding: Equatable, Sendable {
        public var source: CGRect
        public var destination: CGRect
        public var duration: TimeInterval

        public init(source: CGRect, destination: CGRect, duration: TimeInterval) {
            self.source = source
            self.destination = destination
            self.duration = duration
        }
    }

    /// Reduced motion: folder-merge preview landings snap (no flyer travel).
    public static func shouldSnapFolderMergePreviewForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Merge-preview landing duration. Zero when reduced motion snaps.
    public static func folderMergePreviewTravelDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapFolderMergePreviewForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return folderChromeTravelDuration
    }

    public static func folderMergePreviewLandings(
        resident: CGRect,
        incoming: CGRect,
        destinations: [CGRect],
        reducesMotion: Bool
    ) -> [FolderMergePreviewLanding] {
        guard !shouldSnapFolderMergePreviewForReducedMotion(reducesMotion: reducesMotion),
              destinations.count >= 2 else { return [] }
        let pairs = [(resident, destinations[0]), (incoming, destinations[1])]
        guard pairs.allSatisfy({ source, destination in
            usableChromeFrame(source)
                && usableChromeFrame(destination)
                && !framesNearlyEqual(source, destination)
        }) else { return [] }
        let duration = folderMergePreviewTravelDuration(reducesMotion: false)
        return pairs.map { source, destination in
            FolderMergePreviewLanding(
                source: source,
                destination: destination,
                duration: duration
            )
        }
    }

    /// A new folder's plate used to jump from hidden to solid on the first
    /// frame, while the two icons were still full size. It now fades in over
    /// the early part of the same flight and is solid before the icons land.
    /// Clock time is 0...1 over `folderChromeTravelDuration`. The ease is the
    /// icon flight's: quick at first, then settled. Reduced motion does not
    /// use this path.
    public static let folderMergePlateRevealFraction: CGFloat = 0.45
    public static let folderMergePlateRevealX1: CGFloat = 0.22
    public static let folderMergePlateRevealY1: CGFloat = 0.7
    public static let folderMergePlateRevealX2: CGFloat = 0.3
    public static let folderMergePlateRevealY2: CGFloat = 1

    public static func folderMergePlateRevealOpacity(at time: CGFloat) -> CGFloat {
        let time = min(max(time, 0), 1)
        if time == 0 { return 0 }
        let span = folderMergePlateRevealFraction
        if span <= 0 || time >= span { return 1 }
        let local = time / span
        let parameter = unitBezierParameter(
            forX: local, x1: folderMergePlateRevealX1, x2: folderMergePlateRevealX2
        )
        return unitBezierComponent(
            parameter, c1: folderMergePlateRevealY1, c2: folderMergePlateRevealY2
        )
    }

    /// How long the plate fade runs. The rest of the flight keeps it solid.
    public static func folderMergePlateRevealDuration(flight: TimeInterval) -> TimeInterval {
        guard flight > 0 else { return 0 }
        return flight * TimeInterval(folderMergePlateRevealFraction)
    }

    /// Scale of a new folder's tile at the first frame of the plate fade.
    /// The tile used to appear at full size and only fade. It now grows to 1
    /// on that same fade, and is full size before the icons land. Closer than
    /// a shrink-from-nothing: the visible part of the fade is short.
    public static let folderMergePlateRevealScaleStart: CGFloat = 0.8

    /// Shift applied after the scale that keeps `iconCenter` fixed while an
    /// origin-anchored tile grows from `folderMergePlateRevealScaleStart` to 1.
    /// AppKit pins a view's layer on its origin, so a shift measured from the
    /// tile center would slide the plate toward that corner. The transform is
    /// `scale * point + shift`. Positive is up and to the right. A non-finite
    /// center does not shift.
    public static func folderMergePlateRevealTranslation(iconCenter: CGPoint) -> CGPoint {
        originPinnedScaleTranslation(point: iconCenter, scale: folderMergePlateRevealScaleStart)
    }

    /// Shift that keeps `point` fixed while an origin-anchored layer scales.
    /// The transform is `scale * point + shift`. A non-finite point, or a
    /// scale that is not a positive finite number, does not shift.
    public static func originPinnedScaleTranslation(point: CGPoint, scale: CGFloat) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite, scale.isFinite, scale > 0 else { return .zero }
        let factor = 1 - scale
        return CGPoint(x: point.x * factor, y: point.y * factor)
    }

    /// One app dropped onto a folder that already exists. The plate already
    /// shows `glyphsBefore` mini icons. After the drop it shows `glyphsAfter`.
    /// The new icon is appended, so it occupies the first new slot. Icons
    /// already on the plate stay put. A plate that does not grow by exactly
    /// one glyph has no empty slot. Nine is full. The caller sinks that icon
    /// into the plate's center instead of flying it onto the whole cell.
    public static func folderIncomingPreviewSlotIndex(glyphsBefore: Int, glyphsAfter: Int) -> Int? {
        guard glyphsBefore >= 0,
              glyphsAfter == glyphsBefore + 1,
              glyphsAfter <= folderPreviewGlyphCapacity else { return nil }
        return glyphsBefore
    }

    /// Reduced motion: folder incoming-preview slot/center landings snap (no flyer travel).
    public static func shouldSnapFolderIncomingPreviewForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Incoming-preview landing duration. Zero when reduced motion snaps.
    public static func folderIncomingPreviewTravelDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapFolderIncomingPreviewForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return folderChromeTravelDuration
    }

    /// The dropped icon flies into that empty preview slot. The clock matches
    /// the other folder flights. Reduced motion does not travel. A short hop
    /// or a bad frame lands nowhere, and the caller keeps the older flight
    /// onto the whole cell.
    public static func folderIncomingPreviewLanding(
        incoming: CGRect,
        destination: CGRect,
        reducesMotion: Bool
    ) -> FolderMergePreviewLanding? {
        guard !shouldSnapFolderIncomingPreviewForReducedMotion(reducesMotion: reducesMotion) else {
            return nil
        }
        guard usableChromeFrame(incoming),
              usableChromeFrame(destination),
              !framesNearlyEqual(incoming, destination) else { return nil }
        return FolderMergePreviewLanding(
            source: incoming,
            destination: destination,
            duration: folderIncomingPreviewTravelDuration(reducesMotion: false)
        )
    }

    /// How far a full plate pulls an incoming icon in from each edge.
    /// Leaving a little over a quarter of the plate keeps the icon going
    /// into the middle, not covering the plate or landing on one glyph.
    public static let folderPreviewPlateCenterInsetFraction: CGFloat = 0.36

    /// The square at the middle of `well` that a full plate sinks an icon
    /// into. Nil when the plate cannot be measured. The result stays centered
    /// on the plate, in the same coordinate space.
    public static func folderPreviewPlateCenterFrame(well: CGRect) -> CGRect? {
        guard usableChromeFrame(well) else { return nil }
        let insetX = floor(well.width * folderPreviewPlateCenterInsetFraction)
        let insetY = floor(well.height * folderPreviewPlateCenterInsetFraction)
        let frame = well.insetBy(dx: insetX, dy: insetY)
        guard usableChromeFrame(frame) else { return nil }
        return frame
    }

    /// The dropped icon shrinks into the middle of a plate that has no empty
    /// slot. Same clock as the other folder flights. Reduced motion does not
    /// travel. A bad frame or a hop under a point lands nowhere, and the
    /// caller keeps the older flight onto the whole cell. The plate does not
    /// gain a glyph, so the icon dissolves as it settles. That fade is
    /// `wholeCellMergeFlightOpacity`, not the flight ease: sharing the ease
    /// made the icon faint before it reached the center.
    public static func folderIncomingPreviewCenterLanding(
        incoming: CGRect,
        well: CGRect,
        reducesMotion: Bool
    ) -> FolderMergePreviewLanding? {
        guard !shouldSnapFolderIncomingPreviewForReducedMotion(reducesMotion: reducesMotion),
              let destination = folderPreviewPlateCenterFrame(well: well),
              usableChromeFrame(incoming),
              !framesNearlyEqual(incoming, destination) else { return nil }
        return FolderMergePreviewLanding(
            source: incoming,
            destination: destination,
            duration: folderIncomingPreviewTravelDuration(reducesMotion: false)
        )
    }

    /// Fade for a merge that cannot land in a preview slot, so the icon flies
    /// onto the whole cell instead. The old fade shared the flight's ease-out
    /// and was already faint before the icon arrived (about a tenth left at
    /// the halfway mark). This one stays readable while the icon travels,
    /// then dissolves as the flight settles onto the cell. Clock time is
    /// 0...1 over `folderChromeTravelDuration`. Reduced motion does not use
    /// it: that path is a short fade with no travel.
    public static let wholeCellMergeFadeX1: CGFloat = 0.55
    public static let wholeCellMergeFadeY1: CGFloat = 0
    public static let wholeCellMergeFadeX2: CGFloat = 0.82
    public static let wholeCellMergeFadeY2: CGFloat = 0.28

    /// 1 is fully visible. Halfway through the clock the icon is still mostly
    /// there; the dissolve happens in the last part of the flight.
    public static func wholeCellMergeFlightOpacity(at time: CGFloat) -> CGFloat {
        let time = min(max(time, 0), 1)
        if time == 0 { return 1 }
        if time == 1 { return 0 }
        let parameter = unitBezierParameter(
            forX: time, x1: wholeCellMergeFadeX1, x2: wholeCellMergeFadeX2
        )
        let progress = unitBezierComponent(
            parameter, c1: wholeCellMergeFadeY1, c2: wholeCellMergeFadeY2
        )
        return 1 - progress
    }

    /// A whole-cell merge used to reveal the new folder at 60% of the flight.
    /// The flying icon is still about four fifths visible then, so the folder
    /// stacked on a second clear layer. Hold the folder until the icon has
    /// fallen through this opacity, then hand the folder the opacity the icon
    /// is giving up. The folder is solid when the icon is gone. Reduced
    /// motion does not use this curve: that path is the short fade.
    public static let wholeCellMergeFolderRevealIconOpacity: CGFloat = 0.78

    /// 0 hides the folder. 1 is fully visible. Before the icon drops through
    /// `wholeCellMergeFolderRevealIconOpacity` this stays 0, including at 60%
    /// of the flight. Clock time is 0...1 over `folderChromeTravelDuration`.
    public static func wholeCellMergeFolderRevealOpacity(at time: CGFloat) -> CGFloat {
        let icon = wholeCellMergeFlightOpacity(at: time)
        let gate = wholeCellMergeFolderRevealIconOpacity
        guard icon < gate, gate > 0 else { return icon <= 0 ? 1 : 0 }
        return (gate - icon) / gate
    }

    /// First clock, in 0...1, where the flying icon has reached the gate and
    /// the folder may start to appear. The scale spring waits for this. The
    /// opacity curve already stays at 0 until then.
    public static func wholeCellMergeFolderRevealFraction() -> CGFloat {
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if wholeCellMergeFlightOpacity(at: mid) > wholeCellMergeFolderRevealIconOpacity {
                low = mid
            } else {
                high = mid
            }
        }
        return high
    }

    /// Scale of a new whole-cell folder at the moment it is still hidden.
    /// It eases to 1 on the same curve as the fade, and reaches 1 when the
    /// icon is gone. The old spring started at 0.86 and kept moving for about
    /// half a second after that. This start is closer, because the visible
    /// part of the fade is only the last stretch of the flight.
    public static let wholeCellMergeFolderScaleStart: CGFloat = 0.94

    /// 1 is full size. While the folder opacity is still 0, including at 60%
    /// of the flight, the scale stays at `wholeCellMergeFolderScaleStart`.
    public static func wholeCellMergeFolderScale(at time: CGFloat) -> CGFloat {
        let start = wholeCellMergeFolderScaleStart
        let reveal = wholeCellMergeFolderRevealOpacity(at: time)
        return start + (1 - start) * reveal
    }

    /// Equal inset used when a whole-cell merge shrinks around the cell
    /// center. 0.18 on each side leaves 64% of the cell. The destination
    /// below keeps this scale and moves the anchor up onto the icon.
    public static let wholeCellMergeInsetFraction: CGFloat = 0.18

    /// Where a merge flyer ends when no preview slot can be measured.
    /// Insetting the cell equally shrank the picture into the geometric
    /// middle, below the folder icon. This uses the same scale, around the
    /// icon's center, so the icon in the picture stays put and the rest of
    /// the cell closes in on it. Reduced motion does not travel and does not
    /// call this. A cell that cannot be measured is returned unchanged.
    public static func wholeCellMergeDestination(in cell: CGRect) -> CGRect {
        guard cell.width >= 1, cell.height >= 1,
              cell.origin.x.isFinite, cell.origin.y.isFinite,
              cell.size.width.isFinite, cell.size.height.isFinite else { return cell }
        let fraction = min(max(wholeCellMergeInsetFraction, 0), 0.49)
        let scale = 1 - 2 * fraction
        guard scale > 0, scale < 1 else { return cell }
        let icon = iconFrame(in: cell)
        guard icon.width >= 1, icon.height >= 1 else {
            return cell.insetBy(dx: cell.width * fraction, dy: cell.height * fraction)
        }
        let anchor = CGPoint(x: icon.midX, y: icon.midY)
        let size = CGSize(width: cell.width * scale, height: cell.height * scale)
        let midX = anchor.x + (cell.midX - anchor.x) * scale
        let midY = anchor.y + (cell.midY - anchor.y) * scale
        return CGRect(
            x: midX - size.width / 2,
            y: midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Reduced motion: drop-landing start/flight snaps (no travel from lift).
    public static func shouldSnapDropLandingForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Flight duration. Zero when reduced motion snaps so Direct commits
    /// the cell immediately instead of running a flyer.
    public static func dropLandingTravelDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapDropLandingForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return dropLandingFlightDuration
    }

    /// Where the released drag picture already is. The drag image is the cell
    /// plus the lift (scale and shadow). The flight has to leave from that
    /// picture, not from the smaller cell, or the icon pops when the drag
    /// image is removed. Reduced motion has no lift, so this is the cell.
    /// A cell that cannot be measured is returned unchanged.
    public static func dropLandingStartFrame(cell: CGRect, reducesMotion: Bool) -> CGRect {
        guard usableChromeFrame(cell) else { return cell }
        let presentation = dragLiftPresentation(
            for: cell.size,
            reducesMotion: shouldSnapDropLandingForReducedMotion(reducesMotion: reducesMotion)
        )
        let canvas = presentation.canvasFrame(centering: cell)
        return CGRect(
            origin: CGPoint(
                x: canvas.minX + presentation.contentOrigin.x,
                y: canvas.minY + presentation.contentOrigin.y
            ),
            size: presentation.contentSize
        )
    }

    /// Where a merge flyer starts once the drag image is gone. The picture in
    /// hand is the lifted cell, same as a reorder. Leaving from the resting
    /// cell pops that scale off before the flight. Reduced motion never
    /// lifted, so this is the cell. A cell that cannot be measured is unchanged.
    public static func mergeFlightSourceFrame(cell: CGRect, reducesMotion: Bool) -> CGRect {
        dropLandingStartFrame(cell: cell, reducesMotion: reducesMotion)
    }

    /// The icon's place inside the lifted drag picture. `icon` and `cell` are
    /// the resting frames, in one coordinate space. The drag image draws the
    /// whole cell into the lifted rect, so the icon keeps its fraction of that
    /// rect. A preview flight that starts on the resting icon pops down to
    /// that size when the drag image goes away. Reduced motion never lifted.
    /// A frame that cannot be measured returns `icon`.
    public static func iconFrameInLiftedDrag(icon: CGRect, cell: CGRect, reducesMotion: Bool) -> CGRect {
        guard !reducesMotion else { return icon }
        guard usableChromeFrame(icon), usableChromeFrame(cell) else { return icon }
        let lifted = dropLandingStartFrame(cell: cell, reducesMotion: false)
        guard usableChromeFrame(lifted) else { return icon }
        let sx = lifted.width / cell.width
        let sy = lifted.height / cell.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return icon }
        return CGRect(
            x: lifted.minX + (icon.minX - cell.minX) * sx,
            y: lifted.minY + (icon.minY - cell.minY) * sy,
            width: icon.width * sx,
            height: icon.height * sy
        )
    }

    /// The icon let go onto a grid or folder slot. Same clock as the other
    /// folder flights. Reduced motion does not travel. A bad frame or a hop
    /// under a point stays put, and the caller shows the cell immediately.
    /// A merge has its own flight; this is the reorder and the move in or
    /// out of an open folder.
    public struct DropLandingFlight: Equatable, Sendable {
        public var source: CGRect
        public var destination: CGRect
        public var duration: TimeInterval

        public init(source: CGRect, destination: CGRect, duration: TimeInterval) {
            self.source = source
            self.destination = destination
            self.duration = duration
        }
    }

    public static let dropLandingFlightDuration: TimeInterval = folderChromeTravelDuration

    /// The lift shadow is drawn into the drag image. The flyer is only the
    /// cell, so the shadow used to vanish on the frame the drag image left.
    /// It now fades across the early part of this flight and is gone before
    /// the icon sits in the cell. Clock time is 0...1 over
    /// `dropLandingFlightDuration`. The ease is the flight's: quick at first,
    /// then settled. 0 draws no shadow. The value at 0 is
    /// `dragLiftShadowOpacity`. A non-finite clock keeps that lift shadow.
    /// Reduced motion does not travel and does not use this.
    public static let dropLandingShadowFadeFraction: CGFloat = 0.45

    public static func dropLandingShadowOpacity(at time: CGFloat) -> CGFloat {
        guard time.isFinite else { return dragLiftShadowOpacity }
        let time = min(max(time, 0), 1)
        if time == 0 { return dragLiftShadowOpacity }
        let span = dropLandingShadowFadeFraction
        if span <= 0 || time >= span { return 0 }
        let local = time / span
        let parameter = unitBezierParameter(
            forX: local, x1: folderChromeTravelX1, x2: folderChromeTravelX2
        )
        let faded = unitBezierComponent(
            parameter, c1: folderChromeTravelY1, c2: folderChromeTravelY2
        )
        return dragLiftShadowOpacity * (1 - faded)
    }

    /// How long the shadow fade runs. The rest of the flight keeps it off.
    public static func dropLandingShadowFadeDuration(flight: TimeInterval) -> TimeInterval {
        guard flight > 0 else { return 0 }
        return flight * TimeInterval(dropLandingShadowFadeFraction)
    }

    /// The icon dropped onto a folder was lifted, so its preview flyer keeps
    /// the drag shadow and fades it on `dropLandingShadowOpacity`. The icon
    /// already on the grid was not lifted. A shadow on that one would appear
    /// from nothing. Reduced motion never lifted.
    public static func shouldFadeIncomingMergeShadow(isIncoming: Bool, reducesMotion: Bool) -> Bool {
        isIncoming && !reducesMotion
    }

    public static func dropLandingFlight(
        from source: CGRect,
        to destination: CGRect,
        reducesMotion: Bool
    ) -> DropLandingFlight? {
        guard !shouldSnapDropLandingForReducedMotion(reducesMotion: reducesMotion),
              usableChromeFrame(source),
              usableChromeFrame(destination),
              !framesNearlyEqual(source, destination) else { return nil }
        return DropLandingFlight(
            source: source,
            destination: destination,
            duration: dropLandingTravelDuration(reducesMotion: false)
        )
    }

    /// A reorder flight only while the launcher is up. The fade must not
    /// grow a new one underneath it. A hidden window shows the cell in place.
    /// Reduced motion snaps (no flyer).
    public static func shouldPlayDropLanding(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        !shouldSnapDropLandingForReducedMotion(reducesMotion: reducesMotion)
            && shouldPlayFolderDissolveScatter(
                reducesMotion: false,
                isDismissing: isDismissing,
                isVisible: isVisible
            )
    }

    /// Same hold as the merge flight. The drag session can end during the
    /// fade, and a picture already in the air must stay on the frame drawn.
    public static func shouldHoldDropLanding(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    public static func shouldAdvanceDropLanding(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldAdvanceMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    public static func shouldSnapInFlightDropLanding(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldSnapInFlightMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Changing reduced motion restyles an open folder's backdrop. A launcher
    /// fade that is still on screen is holding the frame already drawn, so
    /// the restyle waits. A hidden window, or a cancelled fade, applies it.
    /// Same hold as the folder panel.
    public static func shouldApplyFolderBackdropStyle(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldFolderChromeAnimation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Changing reduced motion snaps a folder open or close that is already
    /// running. Reduced motion is a shorter fade with no scale, and turning
    /// motion back on does not finish the old one either. An opening panel
    /// lands fully open. A closing panel is removed. A launcher fade that is
    /// still on screen is holding the frame already drawn, so this snap waits.
    /// Same hold as the folder panel. A settled panel is not animating.
    public static func shouldSnapInFlightFolderChromeAnimation(
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        !shouldHoldFolderChromeAnimation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Search and the grid crossfade when a query starts or clears. That fade
    /// can still be on screen when the launcher fades, so one surface keeps
    /// appearing underneath. Hold only while the fade is up. A hidden window,
    /// or a cancelled fade, shows the incoming surface at full opacity instead
    /// of replaying the crossfade. Same condition as holding the folder panel.
    public static func shouldHoldSearchChromeAnimation(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldFolderChromeAnimation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Changing reduced motion snaps a search or grid crossfade that is
    /// already running. Reduced motion has no fade, and turning motion back
    /// on does not finish the old one either. A launcher fade that is still
    /// on screen is holding the frame already drawn, so this snap waits.
    /// Same hold as the crossfade.
    public static func shouldSnapInFlightSearchChromeFade(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldSearchChromeAnimation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Dragging the last app out of a folder fades the grid back in. That fade
    /// can still be on screen when the launcher fades, so the tiles keep
    /// appearing underneath. Hold only while the fade is up. A hidden window,
    /// or a cancelled fade, shows the grid at full opacity instead of
    /// replaying the fade. Same condition as holding the search crossfade.
    public static func shouldHoldDissolvedGridFade(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldSearchChromeAnimation(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Reduced motion: dissolved-folder grid fade-in snaps (no 0.12s half-fade).
    /// Full motion still fades the grid back in over `dissolvedGridFadeDuration`.
    public static func shouldSnapDissolvedGridFadeForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Duration of the grid fade-in after a folder dissolves. Zero when
    /// reduced motion snaps so the tiles appear at once.
    public static func dissolvedGridFadeDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapDissolvedGridFadeForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return 0.22
    }

    /// Changing reduced motion snaps a dissolved-folder fade that is already
    /// running. Reduced motion has no fade, and turning motion back on does
    /// not finish the old one either. Both land on a fully opaque grid. A
    /// launcher fade that is still on screen is holding the frame already
    /// drawn, so this snap waits. Same hold as the fade.
    public static func shouldSnapInFlightDissolvedGridFade(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldDissolvedGridFade(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// A page turn slides the two hosts until the animation ends. Ignoring the
    /// completion still lets those hosts travel to the destination under the
    /// fade. Hold only while the fade is up. A hidden window, or a cancelled
    /// fade, lands on the restored page instead of replaying the slide. Same
    /// condition as holding the dissolved-folder fade.
    public static func shouldHoldPageSlide(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldDissolvedGridFade(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Changing reduced motion snaps a page slide that is already running.
    /// Reduced motion has no slide, and turning motion back on does not
    /// finish the old one either. A launcher fade that is still on screen is
    /// holding the frame already drawn, so this snap waits. Same hold as the
    /// slide. The destination is already in the model; the caller lands there.
    public static func shouldSnapInFlightPageSlide(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldPageSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    // MARK: - Visual effect registries (fade-deferred apply vs Reduce Motion snap)
    //
    // These two ordered lists used to live as parallel hand-maintained call
    // sites in `LauncherRootView`. Keep the historical order exactly; only
    // the dispatch indirection is new. Direct switches on each slot.

    /// Work held during a launcher fade, applied when the fade ends/cancels.
    public enum DeferredVisualSlot: String, CaseIterable, Equatable, Sendable {
        case dropHighlightClear
        case folderLanding
        case mergeFlight
        case folderChrome
        case searchChrome
        case dissolvedGridFade
        case launchFeedback
        case dragLiftDrop
        case pageDragRest
        case contentScrollRest
        case pageButtonHover
        case toastFade
        case dropLanding
    }

    /// Historical order of `applyDeferredVisualState()` — do not reorder.
    /// `dropLanding` is appended: a reorder flight held by the fade.
    public static let deferredVisualStateOrder: [DeferredVisualSlot] = [
        .dropHighlightClear,
        .folderLanding,
        .mergeFlight,
        .folderChrome,
        .searchChrome,
        .dissolvedGridFade,
        .launchFeedback,
        .dragLiftDrop,
        .pageDragRest,
        .contentScrollRest,
        .pageButtonHover,
        .toastFade,
        .dropLanding
    ]

    /// Work snapped when the effective Reduce Motion preference changes.
    public enum ReducedMotionSnapSlot: String, CaseIterable, Equatable, Sendable {
        case pageButtonHover
        case folderBackdrop
        case toastFade
        case searchChrome
        case dissolvedGridFade
        case pageSlide
        case launchFeedback
        case folderChrome
        case mergeFlight
        case folderLanding
        case launcherPresence
        case dragLiftDrop
        case pageDragRest
        case contentScrollRest
        case reloadVisibleCollections
        case reorderSlideLand
        case dropLanding
    }

    /// Historical order of `applyCurrentReducedMotion()` snaps — do not reorder.
    /// `dropLanding` is appended: a reorder flight already in the air.
    public static let reducedMotionSnapOrder: [ReducedMotionSnapSlot] = [
        .pageButtonHover,
        .folderBackdrop,
        .toastFade,
        .searchChrome,
        .dissolvedGridFade,
        .pageSlide,
        .launchFeedback,
        .folderChrome,
        .mergeFlight,
        .folderLanding,
        .launcherPresence,
        .dragLiftDrop,
        .pageDragRest,
        .contentScrollRest,
        .reloadVisibleCollections,
        .reorderSlideLand,
        .dropLanding
    ]

    /// App and system preferences can change independently. Only a change in
    /// their effective result should interrupt an animation already in flight.
    public static func shouldApplyReducedMotionChange(previousEffective: Bool, currentEffective: Bool) -> Bool {
        previousEffective != currentEffective
    }

    /// A finger drag writes the page offset directly. It is not the slide
    /// animation. Reduced motion used to keep that offset, the fade, and the
    /// moving page dots until the finger came up. Follow the finger only when
    /// motion is on and the launcher fade is not holding the frame. The
    /// gesture itself still counts, so the release can still turn the page.
    public static func shouldFollowPageDrag(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        !reducesMotion && shouldSnapInFlightPageSlide(
            isDismissing: isDismissing,
            isVisible: isVisible
        )
    }

    /// Reduced motion turned on while a finger drag had already pulled the
    /// pages. Put them back on the current page. Turning motion back on does
    /// not play a catch-up slide; the next drag event follows again. A
    /// launcher fade that is still on screen keeps the frame already drawn.
    /// Same hold as the page slide. A drag that never moved is the caller's
    /// concern.
    public static func shouldRestInFlightPageDrag(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        reducesMotion && shouldSnapInFlightPageSlide(
            isDismissing: isDismissing,
            isVisible: isVisible
        )
    }

    /// Reduced motion removes the stretch past a list's ends, not the
    /// system-controlled inertia after the finger lifts. Keep the current
    /// elasticity while the launcher fade is holding the frame.
    public static func shouldAllowContentElasticity(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        !reducesMotion && shouldSnapInFlightPageSlide(
            isDismissing: isDismissing,
            isVisible: isVisible
        )
    }

    /// Reduced motion turned on while a list was still coasting or stretched
    /// past the end. Pin it. Turning motion back on does not finish that
    /// coast. A launcher fade that is still on screen keeps the frame
    /// already drawn. Same hold as the page slide. A list that is already
    /// still is the caller's concern.
    public static func shouldRestInFlightContentScroll(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        reducesMotion && shouldSnapInFlightPageSlide(
            isDismissing: isDismissing,
            isVisible: isVisible
        )
    }

    /// Pressing an icon scales it down and back in about 0.09s. That scale
    /// can still be on screen when the launcher fades. Hold only while the
    /// fade is up. A hidden window, or a cancelled fade, returns the icon to
    /// its normal scale instead of replaying the pulse. Same condition as
    /// holding the page slide.
    public static func shouldHoldLaunchFeedback(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldPageSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Do not start that pulse during the fade. Reduced motion snaps (no
    /// scale travel). The "正在启动…" label is separate and is not a scale.
    /// The scale is 1 → `launchPressScale` → 1. Each half is
    /// `launchPressHalfDuration`, so the whole press is about 0.09s.
    /// The layer anchor is the view origin. Pair the scale with
    /// `originPinnedScaleTranslation` or the icon slides toward that corner.
    public static let launchPressScale: CGFloat = 0.93
    public static let launchPressHalfDuration: TimeInterval = 0.045
    /// CAAnimation key for Direct's tile launch-press pulse.
    public static let launchFeedbackAnimationKey = "launch-feedback"

    /// Reduced motion: launch-press scale feedback snaps to resting identity
    /// (no 1→0.93→1 pulse / half-fade travel).
    public static func shouldSnapLaunchPressForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Half-duration of the press pulse. Zero when reduced motion snaps so
    /// Direct does not schedule a scale flight.
    public static func launchPressPulseHalfDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapLaunchPressForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return launchPressHalfDuration
    }

    /// Do not start that pulse during the fade. Reduced motion snaps instead.
    public static func shouldPlayLaunchFeedback(isDismissing: Bool, reducesMotion: Bool) -> Bool {
        !isDismissing && !shouldSnapLaunchPressForReducedMotion(reducesMotion: reducesMotion)
    }

    /// Changing reduced motion snaps a press pulse that is already running.
    /// Reduced motion has none, and turning motion back on does not finish
    /// the old one either. A launcher fade that is still on screen is holding
    /// the scale already drawn, so this snap waits. Same hold as the pulse.
    /// The icon returns to its normal scale.
    public static func shouldSnapInFlightLaunchFeedback(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldLaunchFeedback(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Neighbors ease toward a drag gap for about 0.18s. The target is the
    /// gap immediately, and the picture follows on the frame about to draw.
    /// That slide can still be running when the launcher fades, so icons
    /// keep sliding under it.
    /// Hold only while the fade is up. A hidden window, or a cancelled fade,
    /// jumps to the gap if the drag is still down, or back to the cell if the
    /// drag has ended. The slide is not replayed. Same condition as holding
    /// the launch pulse.
    public static func shouldHoldReorderSlide(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldLaunchFeedback(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Reduced motion: neighbor reorder slide snaps to the gap (no 0.18s spring).
    public static func shouldSnapReorderSlideForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Duration policy for the reorder spring. Zero when reduced motion snaps.
    public static func reorderSlideSpringDuration(reducesMotion: Bool) -> TimeInterval {
        if shouldSnapReorderSlideForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return reorderSlideDuration
    }

    /// Do not start that slide during the fade. Reduced motion snaps instead.
    public static func shouldAnimateReorderSlide(
        isDismissing: Bool,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Bool {
        !shouldSnapReorderSlideForReducedMotion(reducesMotion: reducesMotion)
            && !shouldHoldReorderSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Drag-reorder layout frames can be empty for a turn. Snapping neighbors
    /// to that provisional gap and then easing on the next turn flashes them.
    /// Hold the translation already presented until frames are usable.
    public static func shouldHoldReorderPresentationUntilFramesReady(
        animated: Bool,
        framesUsable: Bool
    ) -> Bool {
        animated && !framesUsable
    }

    public static func reorderFramesUsable(
        slot: Int,
        itemIndex: Int,
        fromFrame: CGRect,
        toFrame: CGRect
    ) -> Bool {
        if slot == itemIndex { return true }
        guard fromFrame.size.width > 0, fromFrame.size.height > 0,
              toFrame.size.width > 0, toFrame.size.height > 0 else { return false }
        return fromFrame != toFrame
    }

    /// Changing reduced motion snaps a reorder slide that is already running.
    /// Reduced motion is already on the gap, and turning motion back on does
    /// not finish the old slide either. A launcher fade that is still on
    /// screen is holding the frame already drawn, so this snap waits. Same
    /// hold as the slide. The gap is already the target; the caller lands there.
    public static func shouldSnapInFlightReorderSlide(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldReorderSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The page arrows fade while the pointer is over them. That fade can
    /// still be running when the launcher fades, and a mouse exit during the
    /// fade would start another. Hold only while the fade is up. A hidden
    /// window, or a cancelled fade, snaps to the arrow's real visibility
    /// instead of replaying the fade. Same condition as holding the reorder slide.
    public static func shouldHoldPageButtonHover(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldReorderSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Reduced motion: page-arrow hover opacity snaps (no 0.2s half-fade).
    /// Does not retune page-turn, swipe, or indicator transitions.
    public static func shouldSnapPageButtonHoverForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Do not start that fade during the launcher fade, while the window is
    /// already hidden, or when the user asked for less motion. Reduced motion
    /// snaps to hover or focus. The unreduced fade is hover ease-out only —
    /// not the page slide.
    public static func shouldAnimatePageButtonHover(
        isDismissing: Bool,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Bool {
        !shouldSnapPageButtonHoverForReducedMotion(reducesMotion: reducesMotion)
            && isVisible
            && !shouldHoldPageButtonHover(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Hover on a page arrow. The old fade was the system default: it eased
    /// in, so the first moments barely moved, and the plate was cleared in
    /// the same turn the arrow started leaving. Keep its prompt ease-out
    /// separate from the longer page slide, and keep the plate painted. The
    /// control opacity carries the plate, so the two leave together.
    public static let pageButtonHoverFadeDuration: TimeInterval = 0.2

    /// Hover opacity flight only. Zero when reduced motion snaps; full motion
    /// keeps `pageButtonHoverFadeDuration`. Not used by page-turn / presence.
    public static func pageButtonHoverOpacityFadeDuration(
        reducesMotion: Bool
    ) -> TimeInterval {
        if shouldSnapPageButtonHoverForReducedMotion(reducesMotion: reducesMotion) {
            return 0
        }
        return pageButtonHoverFadeDuration
    }

    public static let pageButtonHoverShownOpacity: CGFloat = 0.9
    public static let pageButtonHoverPlateAlpha: CGFloat = 0.22
    public static let pageButtonHoverCurveX1: CGFloat = 0.2
    public static let pageButtonHoverCurveY1: CGFloat = 0.8
    public static let pageButtonHoverCurveX2: CGFloat = 0.2
    public static let pageButtonHoverCurveY2: CGFloat = 1

    public struct PageButtonHoverFade: Equatable, Sendable {
        public var opacity: CGFloat
        public var plateAlpha: CGFloat
        public var duration: TimeInterval

        public init(opacity: CGFloat, plateAlpha: CGFloat, duration: TimeInterval) {
            self.opacity = opacity
            self.plateAlpha = plateAlpha
            self.duration = duration
        }
    }

    public static func pageButtonHoverFade(shown: Bool) -> PageButtonHoverFade {
        PageButtonHoverFade(
            opacity: shown ? pageButtonHoverShownOpacity : 0,
            plateAlpha: pageButtonHoverPlateAlpha,
            duration: pageButtonHoverFadeDuration
        )
    }

    /// The plate and arrow are up for a pointer hover, a drag sitting on the
    /// arrow, or keyboard focus. A drag does not turn the page by itself.
    /// The turn still waits `pageButtonDragHoverDelay`. The arrow's own area
    /// is the only target, so this is not an edge-of-grid page.
    public static let pageButtonDragHoverDelay: TimeInterval = 0.5

    public static func pageButtonHoverShown(
        pointerInside: Bool,
        dragInside: Bool,
        focused: Bool
    ) -> Bool {
        pointerInside || dragInside || focused
    }

    /// Clock time 0...1 along a hover fade. Appearing goes hidden to shown.
    /// Leaving goes shown to hidden. The plate alpha stays painted for the
    /// whole fade; only the control opacity hides it. The first slice of the
    /// hover clock must already move, independent of the page slide's pace.
    public static func pageButtonHoverSample(
        appearing: Bool,
        time: CGFloat
    ) -> (controlOpacity: CGFloat, plateAlpha: CGFloat) {
        let bounded = min(max(time, 0), 1)
        let parameter = unitBezierParameter(
            forX: bounded, x1: pageButtonHoverCurveX1, x2: pageButtonHoverCurveX2
        )
        let progress = unitBezierComponent(
            parameter, c1: pageButtonHoverCurveY1, c2: pageButtonHoverCurveY2
        )
        let control = appearing
            ? pageButtonHoverShownOpacity * progress
            : pageButtonHoverShownOpacity * (1 - progress)
        return (control, pageButtonHoverPlateAlpha)
    }

    /// `orderOut` resigns the field editor, and AppKit then commits its text.
    /// A folder title still in that editor is a draft and must be abandoned
    /// the same way Escape abandons it. Return has already ended editing, so
    /// a finished name stays. Call this only at `orderOut`: a `show()` during
    /// the fade cancels the hide and should keep the draft.
    public static func shouldAbandonFolderRenameOnOrderOut(isEditingTitle: Bool) -> Bool {
        isEditingTitle
    }

    /// Losing key ends the field editor before `orderOut`. Settings, another
    /// app, or a window on another display can take key while the launcher is
    /// still visible, and AppKit commits the title on the way out. A name
    /// still being edited is a draft. Return has already closed the editor.
    /// `show()` during the fade does not resign key, so that draft stays.
    public static func shouldAbandonFolderRenameOnResignKey(isEditingTitle: Bool) -> Bool {
        isEditingTitle
    }

    /// Open/close chrome keys that mean the panel is still traveling or
    /// fading. Reduced motion skips scale but keeps the fade — the title must
    /// stay non-clickable and AX-hidden until that fade lands.
    public static let folderTitleBlockingChromeAnimationKeys: Set<String> = [
        "folderOpenScale",
        "folderCloseScale",
        "folderOpenFade",
        "folderCloseFade"
    ]

    /// Open/close chrome still traveling or fading (scale and/or fade).
    /// Shared by title pointer/AX and folder-member focus fill.
    public static func folderPanelChromeInFlight(
        isAnimatingClose: Bool,
        panelAnimationKeys: [String]
    ) -> Bool {
        if isAnimatingClose { return true }
        return panelAnimationKeys.contains {
            folderTitleBlockingChromeAnimationKeys.contains($0)
        }
    }

    /// Focused folder-member keyboard fill vs panel chrome flight.
    /// In flight → idle (0), matching title pointer/AX gates; after land → 8%.
    public static func folderMemberFocusFillAlpha(
        focused: Bool,
        panelChromeInFlight: Bool
    ) -> CGFloat {
        tileChromeFillAlpha(
            isLaunching: false,
            isDropTarget: false,
            focused: focused,
            selected: false,
            folderPanelChromeInFlight: panelChromeInFlight
        )
    }


    /// Pointer editing (and AX advertisement without an editor) wait until
    /// open/close chrome has landed. A keyboard field editor already up stays
    /// exposed through `folderTitleAccessibilityHidden`.
    /// Who holds the keyboard when folder open chrome lands.
    public enum FolderOpenFocusOwner: Equatable, Sendable {
        /// Grid / search / window — not inside the folder overlay.
        case outsideOverlay
        /// A folder member tile (or its descendant).
        case memberTile
        /// Title field / field editor / close button.
        case titleOrClose
        /// Overlay chrome that is not a deliberate control (collection, panel).
        case otherOverlayChrome
    }

    /// What to do with keyboard focus after open chrome lands.
    public enum FolderOpenFocusHandoff: Equatable, Sendable {
        /// Move focus to the first member tile.
        case focusFirstMember
        /// Keep the focused member; re-apply focus fill now that chrome is idle.
        case refreshMemberChrome
        /// Leave title / close alone.
        case preserveControl
    }

    /// Title and close keep the keyboard; stray overlay chrome does not steal
    /// the first-member handoff. A member already focused only needs a chrome refresh.
    public static func folderOpenFocusHandoff(
        owner: FolderOpenFocusOwner
    ) -> FolderOpenFocusHandoff {
        switch owner {
        case .outsideOverlay, .otherOverlayChrome:
            return .focusFirstMember
        case .memberTile:
            return .refreshMemberChrome
        case .titleOrClose:
            return .preserveControl
        }
    }

    /// Grid focus after close waits for close chrome to land (mirror open).
    /// Snap/immediate close still goes through the land callback on the same turn.
    public static func folderCloseShouldRestoreGridFocusOnChromeLand(
        restoreFocusRequested: Bool
    ) -> Bool {
        restoreFocusRequested
    }

    /// Open chrome landed and the folder has no members: put the keyboard on
    /// the title (rename / VoiceOver) instead of leaving focus nowhere or on
    /// an empty collection view. Non-empty folders keep first-member-only.
    public static func folderOpenEmptyFocusesTitle(memberCount: Int) -> Bool {
        memberCount == 0
    }

    /// After title edit ends: first member when present; empty folders prefer
    /// the title over an empty collection view (then close as last resort).
    public enum FolderTitleEndFocusTarget: Equatable, Sendable {
        case firstMember
        case title
        case close
    }

    public static func folderTitleEndFocusTarget(memberCount: Int) -> FolderTitleEndFocusTarget {
        memberCount > 0 ? .firstMember : .title
    }

    /// Folder overlay members and close refuse new Tab/keyboard focus while
    /// open/close chrome travels — same window as the title keyboard gate —
    /// so Tab cannot land on members before first-member handoff (or after
    /// close starts, before grid restore lands).
    public static func folderOverlayKeyboardFocusAvailable(
        panelChromeInFlight: Bool
    ) -> Bool {
        !panelChromeInFlight
    }

    /// Key-view *list* omits overlay controls only while closing (grid loop
    /// owns Tab). During open the list stays so the loop is ready when chrome
    /// lands and members begin accepting focus again.
    public static func folderOverlayKeyViewsShouldIncludeControls(
        isAnimatingClose: Bool
    ) -> Bool {
        !isAnimatingClose
    }

    public static func folderTitlePointerEditingAvailable(
        isAnimatingClose: Bool,
        panelAnimationKeys: [String]
    ) -> Bool {
        !folderPanelChromeInFlight(
            isAnimatingClose: isAnimatingClose,
            panelAnimationKeys: panelAnimationKeys
        )
    }

    /// Match hit-testing: advertise the title only when a click could begin
    /// editing, or when a keyboard editor is already active.
    public static func folderTitleAccessibilityHidden(
        baseHidden: Bool,
        hasFieldEditor: Bool,
        pointerEditingAvailable: Bool
    ) -> Bool {
        baseHidden || (!hasFieldEditor && !pointerEditingAvailable)
    }

    /// Tab/keyboard focus waits for the same chrome landing as pointer edits.
    /// An editor already up stays focusable so Escape/Return still work mid-close.
    public static func folderTitleKeyboardFocusAvailable(
        hasFieldEditor: Bool,
        pointerEditingAvailable: Bool
    ) -> Bool {
        hasFieldEditor || pointerEditingAvailable
    }

    /// Losing key ends the search field editor. Unfinished pinyin is dropped
    /// without a text-change callback, so the result list would keep matching
    /// a query the field no longer shows. Confirmed characters stay. A field
    /// that is not composing does not need another filter.
    public static func shouldDiscardSearchCompositionOnResignKey(hasMarkedText: Bool) -> Bool {
        hasMarkedText
    }

    /// Clicking or tabbing away inside this window also drops unfinished
    /// pinyin without a text-change callback, and the window stays key so
    /// `resignKey` does not run. Refilter only when the list was built from a
    /// different string than the field kept. A click that does not change the
    /// query must not reload: that reload used to eat the click that opens a hit.
    public static func shouldRefilterSearchAfterFieldEditorEnds(
        appliedQuery: String,
        committedQuery: String
    ) -> Bool {
        appliedQuery != committedQuery
    }

    /// That refilter waits a turn so the click which ended editing still hits
    /// its tile. The turn can land while the launcher is fading or already
    /// gone. Reloading then jumps the result list under the fade, and a
    /// `show()` that cancels the fade can open whichever tile the reload left
    /// behind. Skip it and try again only when the launcher is up. A later
    /// appearance clears the query itself.
    public static func shouldApplyDeferredSearchRefilter(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldApplySearchFieldEdit(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Blank-area and folder date/color sorts finish after a background read.
    /// Hide bumps `currentToken`, so that result does not rewrite the layout
    /// while the launcher is fading or gone, and does not land on the next
    /// open. Settings paths that await the read do not use this token.
    /// Does not page.
    public static func shouldApplyDeferredGridRearrange(
        isDismissing: Bool,
        isVisible: Bool,
        startedToken: UInt64,
        currentToken: UInt64
    ) -> Bool {
        startedToken == currentToken && isVisible && !isDismissing
    }

    /// The catalog search index is built off the main thread. It can finish
    /// during the fade, or after the window has already ordered out. The
    /// query did not change, so the field-editor refilter will not retry.
    /// Reloading still jumps the result list. Refresh only while the launcher
    /// is up. The next appearance clears the query instead.
    public static func shouldRefreshInstalledSearchIndex(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldApplyDeferredSearchRefilter(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Shift-Tab from the search field waits a turn so the field editor can
    /// finish first. That turn can land during the fade. Resigning then drops
    /// marked pinyin and reloads the result list, and the focus move lands on
    /// a row the reload may have replaced. Do it only while the launcher is
    /// up. A fresh appearance clears the query instead.
    public static func shouldApplyDeferredSearchBacktab(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldApplyDeferredSearchRefilter(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// A catalog scan can finish during the fade, or after the window has
    /// ordered out. Reloading then jumps the grid or the result list under
    /// the fade. The new model can land immediately. Present it only while
    /// the launcher is up. A fresh appearance presents before the window
    /// is shown, so the first frame is already the new catalog.
    public static func shouldPresentCatalogWhileLauncherIsUp(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldApplyDeferredSearchRefilter(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The read-only label, recovery buttons, and drag hint follow that scan.
    /// Changing them while the launcher is fading rewrites the chrome under
    /// the fade even though the grid is waiting. Show them with the catalog.
    /// A fresh appearance applies them before the first frame.
    public static func shouldPresentCatalogChromeWhileLauncherIsUp(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldPresentCatalogWhileLauncherIsUp(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// A launch that started while the launcher was up can finish during the
    /// fade. Clearing or moving the highlight reloads the visible tiles.
    /// Do that only while the launcher is up. The id can change immediately.
    /// A fresh appearance reloads before the first frame.
    public static func shouldPresentLaunchHighlightWhileLauncherIsUp(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldPresentCatalogWhileLauncherIsUp(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Icon decode finishes off the main thread and can land during the fade.
    /// Swapping the placeholder jumps that tile under the fade. Apply the
    /// image only once the dismiss animation is over. A hidden window can
    /// take the image immediately, so the next appearance does not flash the
    /// placeholder. Visibility is not an input: the window is still visible
    /// throughout the fade.
    public static func shouldApplyLoadedIcon(isDismissing: Bool) -> Bool {
        !isDismissing
    }

    /// The desktop thumbnail is decoded off the main thread. It can finish
    /// during the fade and replace the wallpaper under it. Wait out the fade,
    /// and let a hidden window take the image immediately. Same rule as a
    /// decoded app icon.
    public static func shouldApplyDesktopBackground(isDismissing: Bool) -> Bool {
        shouldApplyLoadedIcon(isDismissing: isDismissing)
    }

    /// A toast can be requested during the fade, or after the window has
    /// ordered out. Showing it then fades a bubble in under the dismiss
    /// animation. An auto-dismiss timer would also run while nobody can see
    /// the bubble. Present only while the launcher is up. A fresh appearance
    /// presents before the first frame, so the timer starts then.
    public static func shouldPresentToastWhileLauncherIsUp(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldPresentCatalogWhileLauncherIsUp(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// An already-visible toast can reach its timer during the fade. Its own
    /// fade then fights the launcher fade. Animate the dismissal only while
    /// the launcher is up.
    public static func shouldAnimateToastDismissal(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldPresentToastWhileLauncherIsUp(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Hold that dismissal through the fade. A hidden window does not hold:
    /// the toast is removed immediately so the next appearance does not flash
    /// a bubble whose time already elapsed.
    public static func shouldHoldToastDismissal(isDismissing: Bool, isVisible: Bool) -> Bool {
        isDismissing && isVisible
    }

    /// A toast can already be fading in or out when the launcher fades. That
    /// fade keeps running underneath, and a hide completion can remove the
    /// bubble before the window leaves. Hold only while the launcher fade is
    /// up. A hidden window, or a cancelled fade, snaps to the end instead of
    /// replaying it. Same condition as holding a dismissal that has not started.
    public static func shouldHoldInFlightToastFade(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldToastDismissal(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Changing reduced motion snaps a toast that is already fading. Reduced
    /// motion has no fade, and turning motion back on does not finish the
    /// old one either. A launcher fade that is still on screen is holding
    /// the frame already drawn, so this snap waits. Same hold as the fade.
    public static func shouldSnapInFlightToastFade(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldInFlightToastFade(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Toast show/hide opacity travel. Matches the former animator() duration.
    public static let toastFadeDuration: TimeInterval = 0.12
    /// CAAnimation key for Direct toast opacity fades (presentation-backed).
    public static let toastFadeAnimationKey = "toast-fade"

    /// Hidden toast must clear opacity before unhide (parity with status /
    /// settings feedback / footer), or the first frame flashes solid.
    public static func toastShouldClearOpacityBeforeUnhide(
        willShow: Bool,
        currentlyHidden: Bool
    ) -> Bool {
        willShow && currentlyHidden
    }

    /// Hide fade interrupted (newer toast / generation bump): still unhidden
    /// but near-transparent. Fade back from presentation — do not snap to 0
    /// then up (blink), matching status/footer/settings restore.
    public static func toastShouldRestoreOpacityWhenAlreadyShown(
        currentlyHidden: Bool,
        currentOpacity: CGFloat
    ) -> Bool {
        !currentlyHidden && currentOpacity < 0.99
    }


    /// VoiceOver: announce a toast once per distinct message. Repeating the
    /// same progress line (or re-presenting it while still visible) stays quiet.
    public static func toastShouldAnnounce(
        message: String,
        previousAnnounced: String,
        toastWasHidden: Bool
    ) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if toastWasHidden { return true }
        return trimmed != previousAnnounced
    }

    /// Progress / sticky toasts use medium; fleeting errors stay high.
    public static func toastAnnouncementPriority(autoDismiss: Bool) -> Bool {
        // true → high; false (progress) → medium. Mapped at the call site.
        autoDismiss
    }

    /// An open folder is modal and owns the card. A toast already on screen
    /// would float above the veil — dismiss it when the folder starts opening.
    public static func shouldDismissToastWhenOpeningFolder(isToastVisible: Bool) -> Bool {
        isToastVisible
    }

    /// While a folder is open or its close chrome is still traveling, a new
    /// toast would sit above the veil. Defer until folder chrome is quiet.
    public static func shouldPresentToastWhileFolderChromeQuiet(
        folderOpen: Bool,
        folderClosing: Bool
    ) -> Bool {
        !folderOpen && !folderClosing
    }

    /// One mouse-wheel step. `holdDelay` is set when the step is real but the
    /// quiet period since the previous step has not elapsed. The caller must
    /// deliver that single direction when the delay ends; further steps in the
    /// same quiet period replace it instead of stacking.
    public struct DiscreteScrollTurn: Equatable, Sendable {
        public var accumulatedDelta: CGFloat
        public var direction: Int?
        public var holdDelay: TimeInterval?

        public init(accumulatedDelta: CGFloat, direction: Int?, holdDelay: TimeInterval?) {
            self.accumulatedDelta = accumulatedDelta
            self.direction = direction
            self.holdDelay = holdDelay
        }
    }

    public static func discreteScrollTurn(
        accumulatedDelta: CGFloat,
        incomingDelta: CGFloat,
        now: TimeInterval,
        lastScroll: TimeInterval?,
        lastTurn: TimeInterval,
        quietPeriod: TimeInterval
    ) -> DiscreteScrollTurn {
        var accumulated = accumulatedDelta
        if let lastScroll, now - lastScroll > quietPeriod {
            accumulated = 0
        }
        accumulated += incomingDelta
        guard shouldTurnDiscretePage(accumulatedDelta: accumulated) else {
            return DiscreteScrollTurn(accumulatedDelta: accumulated, direction: nil, holdDelay: nil)
        }
        let direction = accumulated < 0 ? 1 : -1
        let elapsed = now - lastTurn
        if elapsed >= quietPeriod {
            return DiscreteScrollTurn(accumulatedDelta: 0, direction: direction, holdDelay: nil)
        }
        return DiscreteScrollTurn(
            accumulatedDelta: 0,
            direction: direction,
            holdDelay: quietPeriod - elapsed
        )
    }

    public static func pageCount(forEntryCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (count + pageCapacity - 1) / pageCapacity
    }

    public static func pageIndex(containingEntryAt index: Int) -> Int {
        guard index >= 0 else { return 0 }
        return index / pageCapacity
    }

    public static func entries(onPage page: Int, from entries: [LauncherEntry]) -> [LauncherEntry] {
        let start = page * pageCapacity
        guard page >= 0, start < entries.count else { return [] }
        return Array(entries[start..<min(start + pageCapacity, entries.count)])
    }

    /// Top-level entry ids on `page` only (Command-A / current-page select-all).
    /// Does not include other pages or folder members.
    public static func itemIDs(onPage page: Int, from entries: [LauncherEntry]) -> [UUID] {
        self.entries(onPage: page, from: entries).map(\.id)
    }

    public enum GridKeyboardDirection: Equatable, Sendable {
        case left, right, up, down
    }

    /// Arrow keys only. Page Up (116) and Page Down (121) stay on the paging path.
    public static func gridKeyboardDirection(forKeyCode keyCode: UInt16) -> GridKeyboardDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    /// Next slot inside one grid. Nil means the edge of that grid: the caller
    /// must not turn a page. `columns` is the row width — main grid and search
    /// use `pageColumns`; a folder uses `folderDisplayColumns`.
    public static func gridKeyboardNeighborSlot(
        from slot: Int,
        count: Int,
        columns: Int,
        direction: GridKeyboardDirection
    ) -> Int? {
        guard columns > 0, count > 0, slot >= 0, slot < count else { return nil }
        switch direction {
        case .left:
            guard slot % columns != 0 else { return nil }
            return slot - 1
        case .right:
            let next = slot + 1
            guard next < count, next % columns != 0 else { return nil }
            return next
        case .up:
            let next = slot - columns
            guard next >= 0 else { return nil }
            return next
        case .down:
            let next = slot + columns
            guard next < count else { return nil }
            return next
        }
    }

    /// Shift held alone. Command, Option, and Control keep their own paths,
    /// including main-grid left/right paging.
    public static func gridKeyboardExtendsSelection(
        shift: Bool,
        command: Bool,
        option: Bool,
        control: Bool
    ) -> Bool {
        shift && !command && !option && !control
    }

    /// Shift+arrow selection inside one grid. `consumesKey` is false only for
    /// left/right when `walksLeftRight` is false, so the main grid can still page.
    /// An edge consumes the key and leaves the selection where it is.
    public struct GridKeyboardShiftStep: Equatable, Sendable {
        public var selection: LauncherItemSelection
        public var focusID: UUID?
        public var consumesKey: Bool

        public init(selection: LauncherItemSelection, focusID: UUID?, consumesKey: Bool) {
            self.selection = selection
            self.focusID = focusID
            self.consumesKey = consumesKey
        }
    }

    public static func gridKeyboardShiftStep(
        focusedID: UUID,
        slot: Int,
        presentedOrder: [UUID],
        columns: Int,
        direction: GridKeyboardDirection,
        walksLeftRight: Bool,
        current: LauncherItemSelection
    ) -> GridKeyboardShiftStep {
        if !walksLeftRight && (direction == .left || direction == .right) {
            return GridKeyboardShiftStep(selection: current, focusID: nil, consumesKey: false)
        }
        let count = presentedOrder.count
        guard let neighbor = gridKeyboardNeighborSlot(
            from: slot,
            count: count,
            columns: columns,
            direction: direction
        ), presentedOrder.indices.contains(neighbor) else {
            return GridKeyboardShiftStep(selection: current, focusID: focusedID, consumesKey: true)
        }
        var base = current
        if base.rangeAnchorID == nil {
            let ids = base.contains(focusedID) ? base.orderedIDs : base.orderedIDs + [focusedID]
            base = LauncherItemSelection(orderedIDs: ids, rangeAnchorID: focusedID)
        }
        let next = LauncherItemSelection.applyingRange(
            to: presentedOrder[neighbor],
            presentedOrder: presentedOrder,
            current: base
        )
        return GridKeyboardShiftStep(
            selection: next,
            focusID: presentedOrder[neighbor],
            consumesKey: true
        )
    }

    /// Slot to focus on the destination page. `previousSlot` is nil when focus
    /// was not on a grid tile. Nil means the destination has no tile to focus.
    public static func focusSlot(previousSlot: Int?, itemCount: Int) -> Int? {
        guard let previousSlot, previousSlot >= 0, itemCount > 0 else { return nil }
        if previousSlot < itemCount { return previousSlot }
        return itemCount - 1
    }

    /// Absolute page a repeated turn should request. While a transition is in
    /// flight, further steps continue from the queued or in-flight page so a
    /// second press is not swallowed by the page still on screen.
    public static func pageIndex(
        movingBy direction: Int,
        from currentPage: Int,
        inFlightPage: Int?,
        queuedPage: Int?,
        pageCount: Int
    ) -> Int {
        guard pageCount > 0 else { return 0 }
        let base = queuedPage ?? inFlightPage ?? currentPage
        return min(max(base + direction, 0), pageCount - 1)
    }

    /// Page the previous/next buttons should reflect. A queued turn wins, then
    /// the in-flight target, otherwise the page still on screen.
    public static func pagingControlPage(currentPage: Int, inFlightPage: Int?, queuedPage: Int?) -> Int {
        queuedPage ?? inFlightPage ?? currentPage
    }

    /// Grid page to show again after the launcher is hidden. A queued turn wins,
    /// then the in-flight target. Pages that no longer exist clamp to the last one.
    public static func pageToRestore(
        currentPage: Int,
        inFlightPage: Int?,
        queuedPage: Int?,
        pageCount: Int
    ) -> Int {
        guard pageCount > 0 else { return 0 }
        let requested = queuedPage ?? inFlightPage ?? currentPage
        return min(max(requested, 0), pageCount - 1)
    }

    /// Reloading that restored page jumps the tiles. Do it when the window is
    /// already hidden, so the next frame is the restored page, or when a fade
    /// was cancelled and the launcher is up again. While the fade is still on
    /// screen, `shouldHoldPageSlide` pins the hosts instead. A hidden window
    /// still commits, even if the dismiss flag has not cleared yet.
    public static func shouldCommitRestoredGridPage(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldPageSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// One backspace while a search result or chrome control is focused.
    /// Drops the last extended grapheme, not a UTF-16 code unit.
    public static func searchQueryDeletingLastCharacter(_ query: String) -> String {
        guard !query.isEmpty else { return query }
        return String(query.dropLast())
    }

    /// Caret is at the end, as when a result or chrome control has the keyboard.
    /// Trailing spaces are removed together with the word or punctuation before
    /// them. "one two" becomes "one ", and "hello," becomes "hello".
    public static func searchQueryDeletingLastWord(_ query: String) -> String {
        guard !query.isEmpty else { return query }
        var end = query.endIndex

        func kind(at index: String.Index) -> Int {
            let character = query[index]
            if character.isWhitespace || character.isNewline { return 0 }
            if character.isLetter || character.isNumber { return 1 }
            return 2
        }

        var cursor = query.index(before: end)
        if kind(at: cursor) == 0 {
            while cursor > query.startIndex {
                let before = query.index(before: cursor)
                if kind(at: before) != 0 { break }
                cursor = before
            }
            if cursor == query.startIndex { return "" }
            end = cursor
        }

        let tokenKind = kind(at: query.index(before: end))
        var start = end
        while start > query.startIndex {
            let before = query.index(before: start)
            if kind(at: before) != tokenKind { break }
            start = before
        }
        return String(query[..<start])
    }

    /// Typing another letter from a result or a chrome control continues the
    /// query. It must not replace the letters already there.
    public static func searchQueryAppending(_ query: String, _ characters: String) -> String {
        query + characters
    }

    /// A letter typed on the grid opens search. `.interpret` hands that event
    /// to the text input system. Calling the field editor's `keyDown` walks
    /// back through the search field, which calls the editor again, and the
    /// root view starts another route until the stack overflows.
    /// `.consume` is a route that is already in progress: swallow it.
    /// `.ignore` leaves the key to the caller. Does not page.
    public enum SearchGridKeyRoute: Equatable, Sendable {
        case ignore
        case consume
        case interpret
    }

    public static func searchGridKeyRoute(
        folderOpen: Bool,
        commandOrControl: Bool,
        hasPrintableCharacter: Bool,
        alreadyRouting: Bool
    ) -> SearchGridKeyRoute {
        if alreadyRouting { return .consume }
        guard !folderOpen, !commandOrControl, hasPrintableCharacter else { return .ignore }
        return .interpret
    }

    /// `characters` on a synthesized key can be empty while the letter sits
    /// in `charactersIgnoringModifiers`. A single ASCII letter or digit is
    /// still the query text. Anything else stays on the raw string so an
    /// input method can own it. Does not page.
    public static func searchGridTypedCharacters(raw: String, ignoringModifiers: String) -> String {
        if raw.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) {
            return raw
        }
        guard ignoringModifiers.count == 1,
              let scalar = ignoringModifiers.unicodeScalars.first,
              scalar.isASCII,
              Character(scalar).isLetter || Character(scalar).isNumber else {
            return raw
        }
        return ignoringModifiers
    }

    /// What to write into the search field after the text input system has
    /// seen a grid letter. Marked pinyin stays in the editor. A letter the
    /// editor did not take is appended, because writing it only into the
    /// editor during that same event does not show up in the field. An editor
    /// string that the field has not committed yet is copied across. Does not page.
    public enum SearchGridKeyCommit: Equatable, Sendable {
        case keepEditor
        case replace(String)
    }

    public static func searchGridKeyCommit(
        before: String,
        editorAfter: String,
        hadMarkedText: Bool,
        hasMarkedText: Bool,
        typed: String,
        committed: String
    ) -> SearchGridKeyCommit {
        if hasMarkedText || hadMarkedText { return .keepEditor }
        if editorAfter == before {
            return .replace(searchQueryAppending(before, typed))
        }
        if committed != editorAfter {
            return .replace(editorAfter)
        }
        return .keepEditor
    }

    /// The field editor's string includes pinyin that is still marked.
    /// `stringValue` does not, so a composition would otherwise filter nothing.
    public static func searchQuery(committed: String, editing: String?) -> String {
        editing ?? committed
    }

    /// Drop an unfinished composition from a title. The range is UTF-16, the
    /// same unit `NSText` uses, so a mark around an emoji does not split it
    /// when the indexes are in range. A bad range leaves the text unchanged.
    public static func textByRemovingMarkedRange(
        _ text: String,
        utf16Location: Int,
        utf16Length: Int
    ) -> String {
        guard utf16Length > 0, utf16Location >= 0 else { return text }
        let ns = text as NSString
        let end = utf16Location + utf16Length
        guard end >= utf16Location, end <= ns.length else { return text }
        return ns.replacingCharacters(in: NSRange(location: utf16Location, length: utf16Length), with: "")
    }

    /// Whether a search scroll position still belongs to this query.
    /// Case, accents, fullwidth letters, and spaces (once two letters remain)
    /// do not change the hits, so they must not send the list back to the top.
    /// A real change does.
    public static func searchScrollQueryKey(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let compact = String(trimmed.filter { !$0.isWhitespace })
        if compact.count >= 2 { return compact }
        return trimmed
    }

    /// Horizontal inset that centers a short search result row under the field.
    /// Full rows and empty results keep `minimumInset` on both sides so dense
    /// search stays on the same seven-column grid as the home pages.
    public static func searchSectionHorizontalInset(
        itemCount: Int,
        columns: Int = pageColumns,
        itemWidth: CGFloat,
        interitemSpacing: CGFloat,
        viewportWidth: CGFloat,
        minimumInset: CGFloat = 8
    ) -> CGFloat {
        guard itemCount > 0, itemCount < max(columns, 1), itemWidth > 0 else {
            return minimumInset
        }
        let rowWidth = CGFloat(itemCount) * itemWidth
            + CGFloat(max(itemCount - 1, 0)) * interitemSpacing
        let width = max(viewportWidth, 1)
        return max(minimumInset, floor((width - rowWidth) / 2))
    }

    /// Keep a scroll offset inside the document after results get shorter.
    /// A query change still belongs at the start; this only clamps.
    public static func clampedScrollOffset(
        _ offset: CGFloat,
        documentLength: CGFloat,
        viewportLength: CGFloat
    ) -> CGFloat {
        let limit = max(0, documentLength - viewportLength)
        return min(max(offset, 0), limit)
    }

    /// Page Up/Down while a folder or the search list is open scrolls that list.
    /// Nil leaves the main grid on its existing page path.
    public enum VerticalPageKeyTarget: Equatable, Sendable {
        case folderScroll
        case searchScroll
    }

    public static func verticalPageKeyTarget(
        folderOpen: Bool,
        searching: Bool
    ) -> VerticalPageKeyTarget? {
        if folderOpen { return .folderScroll }
        if searching { return .searchScroll }
        return nil
    }

    /// One full viewport toward or away from the start of a scrolled list.
    /// The result stays inside the document, including when it cannot move.
    public static func scrolledPageOffset(
        current: CGFloat,
        documentLength: CGFloat,
        viewportLength: CGFloat,
        forward: Bool
    ) -> CGFloat {
        let step = max(viewportLength, 0)
        let next = forward ? current + step : current - step
        return clampedScrollOffset(
            next,
            documentLength: documentLength,
            viewportLength: viewportLength
        )
    }

    /// Offset that puts the whole item inside the viewport when it fits.
    /// An item already fully inside stays put. Nearest-edge scrolling leaves
    /// a cell hanging off the clip, so keyboard focus looks off-screen.
    /// An item taller than the viewport stays when it already spans the
    /// clip; otherwise the nearer end comes on screen. Does not page.
    public static func scrollOffsetRevealingItem(
        current: CGFloat,
        viewportLength: CGFloat,
        documentLength: CGFloat,
        itemMin: CGFloat,
        itemLength: CGFloat
    ) -> CGFloat {
        let viewport = max(viewportLength, 0)
        let length = max(itemLength, 0)
        let itemMax = itemMin + length
        var offset = current
        if length <= viewport {
            if itemMax > offset + viewport {
                offset = itemMax - viewport
            }
            if itemMin < offset {
                offset = itemMin
            }
        } else if itemMax <= offset {
            offset = itemMax - viewport
        } else if itemMin >= offset + viewport {
            offset = itemMin
        }
        return clampedScrollOffset(
            offset,
            documentLength: max(documentLength, 0),
            viewportLength: viewport
        )
    }

    /// Key-view scrolling asks for a tiny rect on the focused edge. That leaves
    /// the rest of a folder or search cell outside the clip. Ask for the whole
    /// cell when its bounds are real. A zero or non-finite bounds keeps the
    /// requested rect. Does not page.
    public static func scrollRectRevealingFocusedCell(cellBounds: CGRect, requested: CGRect) -> CGRect {
        guard cellBounds.width > 1, cellBounds.height > 1,
              cellBounds.origin.x.isFinite, cellBounds.origin.y.isFinite else {
            return requested
        }
        return cellBounds
    }

    public static func visiblePageIndices(pageCount: Int, selectedPage: Int, maxVisible: Int = pageIndicatorLimit) -> [Int] {
        guard pageCount > 0 else { return [] }
        if pageCount <= maxVisible { return Array(0..<pageCount) }
        let start = min(max(0, selectedPage - maxVisible / 2), pageCount - maxVisible)
        return Array(start..<(start + maxVisible))
    }

    /// Dots only appear when there are at least two pages. Search passes 0.
    public static func pageIndicatorShouldShow(pageCount: Int) -> Bool {
        pageCount >= 2
    }

    /// Entering search (or dropping below two pages) fades the dots with the
    /// same clock as the search/grid crossfade. Reduced motion and a launcher
    /// fade that is holding the frame snap instead.
    public static func shouldAnimatePageIndicatorVisibility(
        pageCount: Int,
        currentlyShown: Bool,
        reducesMotion: Bool,
        holdsForLauncherFade: Bool
    ) -> Bool {
        let shouldShow = pageIndicatorShouldShow(pageCount: pageCount)
        return shouldAnimatePagingChromeVisibility(
            shouldShow: shouldShow,
            currentlyShown: currentlyShown,
            reducesMotion: reducesMotion,
            holdsForLauncherFade: holdsForLauncherFade
        )
    }

    /// Previous/next arrows share the search/grid fade clock with page dots.
    public static func pageArrowShouldShow(hasMultiplePages: Bool, atUnavailableEdge: Bool) -> Bool {
        hasMultiplePages && !atUnavailableEdge
    }

    public static func shouldAnimatePageArrowVisibility(
        shouldShow: Bool,
        currentlyShown: Bool,
        reducesMotion: Bool,
        holdsForLauncherFade: Bool
    ) -> Bool {
        shouldAnimatePagingChromeVisibility(
            shouldShow: shouldShow,
            currentlyShown: currentlyShown,
            reducesMotion: reducesMotion,
            holdsForLauncherFade: holdsForLauncherFade
        )
    }

    /// Reduced motion: footer chrome / drag-hint presence snaps (opacity only;
    /// not page-turn, swipe, or indicator selection).
    public static func shouldSnapFooterChromeVisibilityForReducedMotion(
        reducesMotion: Bool
    ) -> Bool {
        reducesMotion
    }

    /// Shared gate for page dots and page arrows when search (or page count)
    /// makes them appear or disappear. Also used by footer chrome / drag-hint
    /// presence fades. Reduced motion snaps (no opacity travel).
    public static func shouldAnimatePagingChromeVisibility(
        shouldShow: Bool,
        currentlyShown: Bool,
        reducesMotion: Bool,
        holdsForLauncherFade: Bool
    ) -> Bool {
        guard shouldShow != currentlyShown else { return false }
        if shouldSnapFooterChromeVisibilityForReducedMotion(reducesMotion: reducesMotion) {
            return false
        }
        return !holdsForLauncherFade
    }

    /// Drag-hint label sits beside the page dots. Search and a closed layout hide it.
    public static func footerDragHintShouldShow(
        isSearching: Bool,
        folderOpen: Bool,
        isLayoutEditingEnabled: Bool,
        hasEntries: Bool
    ) -> Bool {
        !isSearching && !folderOpen && isLayoutEditingEnabled && hasEntries
    }

    /// Whole footer (hints + page dots) hides while a folder is open.
    public static func footerChromeShouldShow(folderOpen: Bool) -> Bool {
        !folderOpen
    }

    public static func pageIndicatorSlots(
        pageCount: Int,
        selectedPage: Int,
        maxVisible: Int = pageIndicatorLimit
    ) -> [PageIndicatorSlot] {
        let pages = visiblePageIndices(
            pageCount: pageCount,
            selectedPage: selectedPage,
            maxVisible: maxVisible
        )
        guard let first = pages.first, let last = pages.last else { return [] }
        var slots: [PageIndicatorSlot] = []
        if first > 0 { slots.append(.ellipsis) }
        slots.append(contentsOf: pages.map(PageIndicatorSlot.page))
        if last < pageCount - 1 { slots.append(.ellipsis) }
        return slots
    }

    /// Which layout a finished scan should reconcile into. The first scan has an
    /// empty in-memory layout and must keep the file. After that, unsaved edits
    /// are newer than the file and must not be replaced by it.
    public static func layoutBaseForCatalogReload(memory: LayoutState, stored: LayoutState) -> LayoutState {
        func hasContent(_ state: LayoutState) -> Bool {
            !state.orderedEntries.isEmpty
                || !state.folders.isEmpty
                || !state.appKeys.isEmpty
                || !state.hiddenAppKeys.isEmpty
                || !state.appAliases.isEmpty
        }
        if !hasContent(memory) { return stored }
        if !hasContent(stored) { return memory }
        if memory.updatedAt >= stored.updatedAt { return memory }
        return stored
    }

    /// A reconcile that dropped apps on an untrusted custom root must not become
    /// the newer layout. `layoutBaseForCatalogReload` prefers memory when its
    /// timestamp is greater than or equal to the file.
    public static func layoutKeepingStoredNewerThanUnsafeReconcile(
        reconciled: LayoutState,
        stored: LayoutState
    ) -> LayoutState {
        var layout = reconciled
        layout.updatedAt = stored.updatedAt.addingTimeInterval(-1)
        return layout
    }

    /// A user-selected cached list stays visible until a complete scan can
    /// replace it. A partial or empty retry must not erase that recovery view.
    public static func shouldReplaceCachedCatalog(isShowingCache: Bool, newScanPersistable: Bool) -> Bool {
        !isShowingCache || newScanPersistable
    }

    public static func reconcile(candidates: [AppCandidate], into state: LayoutState) -> LayoutState {
        var state = state
        let previousState = state
        let visibleCandidates = candidates.filter { !state.hiddenAppKeys.contains($0.deduplicationKey) }
        let isFreshLayout = state.orderedEntries.isEmpty && state.appKeys.isEmpty && state.folders.isEmpty
        let orderedCandidates = isFreshLayout
            ? visibleCandidates.filter(isSystemApplication) + visibleCandidates.filter { !isSystemApplication($0) }
            : visibleCandidates
        let liveKeys = Set(visibleCandidates.map(\.deduplicationKey))
        let deadIDs = Set(state.appKeys.compactMap { liveKeys.contains($0.value) ? nil : $0.key })
        for folderID in Array(state.folders.keys) {
            guard var folder = state.folders[folderID] else { continue }
            var seenMemberKeys = Set<String>()
            folder.itemIDs.removeAll { itemID in
                guard !deadIDs.contains(itemID), let key = state.appKeys[itemID] else { return true }
                return !seenMemberKeys.insert(key).inserted
            }
            if folder.id != folderID {
                folder = LauncherFolder(
                    id: folderID, name: folder.name,
                    itemIDs: folder.itemIDs, createdAt: folder.createdAt
                )
            }
            state.folders[folderID] = folder
        }
        for folderID in Array(state.folders.keys).sorted(by: { $0.uuidString < $1.uuidString })
        where state.appKeys[folderID] != nil {
            guard let folder = state.folders.removeValue(forKey: folderID) else { continue }
            let repairedID = uniqueFolderID(in: state)
            state.folders[repairedID] = LauncherFolder(
                id: repairedID,
                name: folder.name,
                itemIDs: folder.itemIDs,
                createdAt: folder.createdAt
            )
            state.orderedEntries = state.orderedEntries.map { entry in
                guard case .folder(folderID) = entry else { return entry }
                return .folder(repairedID)
            }
        }
        for folderID in Array(state.folders.keys) {
            dissolveIfNeeded(folderID, in: &state)
        }

        let recordedAppIDs = Set(state.appKeys.keys)
        let liveFolderIDs = Set(state.folders.keys)
        var seenEntries = Set<LauncherEntry>()
        state.orderedEntries.removeAll { entry in
            switch entry {
            case .app(let id):
                if deadIDs.contains(id) || !recordedAppIDs.contains(id) { return true }
            case .folder(let id):
                if !liveFolderIDs.contains(id) { return true }
            }
            return !seenEntries.insert(entry).inserted
        }
        for id in deadIDs {
            state.appKeys.removeValue(forKey: id)
        }

        for folderID in state.folders.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where !state.orderedEntries.contains(.folder(folderID)) {
            state.orderedEntries.append(.folder(folderID))
        }
        var placedKeys = Set<String>()
        var duplicateAppIDs = Set<UUID>()
        var uniqueEntries: [LauncherEntry] = []
        for entry in state.orderedEntries {
            switch entry {
            case .app(let id):
                guard let key = state.appKeys[id] else { continue }
                guard placedKeys.insert(key).inserted else {
                    duplicateAppIDs.insert(id)
                    continue
                }
                uniqueEntries.append(entry)
            case .folder(let id):
                guard var folder = state.folders[id] else { continue }
                folder.itemIDs.removeAll { itemID in
                    guard let key = state.appKeys[itemID] else { return true }
                    if !placedKeys.insert(key).inserted {
                        duplicateAppIDs.insert(itemID)
                        return true
                    }
                    return false
                }
                if folder.itemIDs.count > 1 {
                    state.folders[id] = folder
                    uniqueEntries.append(entry)
                } else {
                    state.folders[id] = nil
                    if let remaining = folder.itemIDs.first { uniqueEntries.append(.app(remaining)) }
                }
            }
        }
        state.orderedEntries = uniqueEntries
        let retainedAppIDs = Set(uniqueEntries.compactMap { entry -> UUID? in
            if case .app(let id) = entry { return id }
            return nil
        }).union(state.folders.values.flatMap(\.itemIDs))
        for id in duplicateAppIDs.subtracting(retainedAppIDs) {
            state.appKeys.removeValue(forKey: id)
        }

        let placedIDs = Set(state.orderedEntries.map(\.id))
            .union(state.folders.values.flatMap(\.itemIDs))
        var knownKeys = Set(placedIDs.compactMap { state.appKeys[$0] })
        for candidate in orderedCandidates where !knownKeys.contains(candidate.deduplicationKey) {
            let id = state.appKeys.first { $0.value == candidate.deduplicationKey }?.key ?? UUID()
            state.appKeys[id] = candidate.deduplicationKey
            state.orderedEntries.append(.app(id))
            knownKeys.insert(candidate.deduplicationKey)
        }

        let referencedAppIDs = Set(state.orderedEntries.compactMap { entry -> UUID? in
            guard case .app(let id) = entry else { return nil }
            return id
        }).union(state.folders.values.flatMap(\.itemIDs))
        state.appKeys = state.appKeys.filter { referencedAppIDs.contains($0.key) }

        if state != previousState {
            state.updatedAt = .now
        }
        return state
    }


    /// One-shot top-level grid rearrange (settings). Folder membership is unchanged.
    public enum GridRearrangeSort: String, Equatable, Sendable {
        /// Localized display name (alias wins); folders use folder name.
        case byName
        /// System apps first, then everything else; name within each group.
        case byKind

        /// SETTINGS-REARRANGE-BUTTONS-COPY-01 — Settings button (no ellipsis).
        public var settingsButtonTitleKey: String {
            switch self {
            case .byName: return "按名称排列"
            case .byKind: return "按类型排列"
            }
        }

        /// Short AX help on the Settings button (confirm sheet uses informativeTextKey).
        public var settingsAccessibilityHelpKey: String {
            switch self {
            case .byName:
                return "按显示名称重新排列主屏幕图标；文件夹内应用不变"
            case .byKind:
                return "系统应用在前，其余按名称；文件夹内应用不变"
            }
        }
    }

    /// Confirm before one-key top-level rearrange. Cancel is first so Return/Esc
    /// do not apply. Matches uninstall force-quit / related-cleanup alert policy.
    /// ALIAS-FOLDER-PROMPT-COPY-01 — app alias sheet (Save first; Esc → Cancel).
    public enum AppAliasPromptAlert {
        public static let saveIsFirstButton = true
        public static let messageTextKey = "设置应用别名"
        public static let informativeTextKey = "别名会用于显示和搜索；留空可恢复原名称。"
        public static let saveButtonTitleKey = "保存"
        public static let cancelButtonTitleKey = "取消"
        public static let accessibilityLabelFormatKey = "%@ 的别名"

        public static func messageText(localize: (String) -> String = { $0 }) -> String {
            localize(messageTextKey)
        }

        public static func informativeText(localize: (String) -> String = { $0 }) -> String {
            localize(informativeTextKey)
        }

        public static func saveButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(saveButtonTitleKey)
        }

        public static func cancelButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(cancelButtonTitleKey)
        }

        public static func accessibilityLabel(
            appDisplayName: String,
            localize: (String) -> String = { $0 }
        ) -> String {
            String(format: localize(accessibilityLabelFormatKey), appDisplayName)
        }
    }

    /// ALIAS-FOLDER-PROMPT-COPY-01 — folder rename sheet (Save first; Esc → Cancel).
    public enum FolderRenamePromptAlert {
        public static let saveIsFirstButton = true
        public static let messageTextKey = "重命名文件夹"
        public static let informativeTextKey = "留空会保留原名称。"
        public static let placeholderKey = "新建文件夹"
        public static let accessibilityLabelKey = "文件夹名称"
        public static let saveButtonTitleKey = "保存"
        public static let cancelButtonTitleKey = "取消"

        public static func messageText(localize: (String) -> String = { $0 }) -> String {
            localize(messageTextKey)
        }

        public static func informativeText(localize: (String) -> String = { $0 }) -> String {
            localize(informativeTextKey)
        }

        public static func placeholder(localize: (String) -> String = { $0 }) -> String {
            localize(placeholderKey)
        }

        public static func accessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(accessibilityLabelKey)
        }

        public static func saveButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(saveButtonTitleKey)
        }

        public static func cancelButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(cancelButtonTitleKey)
        }
    }

    /// FOLDER-EMPTY-NAME-FALLBACK-01 — blank folder titles show the same
    /// localized「新建文件夹」as the rename placeholder (menus + toasts).
    public static func emptyFolderDisplayName(
        localize: (String) -> String = { $0 }
    ) -> String {
        FolderRenamePromptAlert.placeholder(localize: localize)
    }

    public static func displayName(
        forFolderNamed name: String,
        localize: (String) -> String = { $0 }
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? emptyFolderDisplayName(localize: localize) : trimmed
    }

    public enum GridRearrangeConfirmAlert {
        public static let cancelIsFirstButton = true
        public static let messageTextKey = "重新排列主屏幕图标？"
        public static func informativeTextKey(sort: GridRearrangeSort) -> String {
            switch sort {
            case .byName:
                return "将按显示名称重排顶层图标；文件夹内应用不变。可在「恢复上次备份」撤销。"
            case .byKind:
                return "将把系统应用排在前面，其余按名称；文件夹内应用不变。可在「恢复上次备份」撤销。"
            }
        }
        public static let cancelButtonTitleKey = "取消"
        public static let confirmButtonTitleKey = "重新排列"
        public static let cancelAccessibilityHelpKey = "取消，不改变当前布局"
        public static let confirmAccessibilityHelpKey = "确认后重排顶层图标；可用恢复上次备份撤销"
    }

    /// Confirm before restoring the last automatic layout backup. Cancel first
    /// so Return/Esc do not apply (parity with rearrange confirm).
    public enum LayoutRestoreBackupConfirmAlert {
        public static let cancelIsFirstButton = true
        public static let messageTextKey = "恢复上次备份？"
        public static let informativeTextKey = "将用自动保存前的布局替换当前主屏幕；再次点「恢复上次备份」可撤销本次恢复。"
        public static let cancelButtonTitleKey = "取消"
        public static let confirmButtonTitleKey = "恢复备份"
        public static let cancelAccessibilityHelpKey = "取消，保留当前布局"
        public static let confirmAccessibilityHelpKey = "确认后恢复上次自动备份；再次恢复可撤销"
    }

    /// Confirm before importing a layout JSON over the live grid. Cancel first
    /// (parity with rearrange / restore-backup confirms). Shown after the open
    /// panel returns a file.
    public enum LayoutImportConfirmAlert {
        public static let cancelIsFirstButton = true
        public static let messageTextKey = "导入布局？"
        public static let informativeTextKey = "将用所选 JSON 与当前应用列表合并后替换主屏幕布局。导入前会自动备份，可用「恢复上次备份」撤销。"
        public static let cancelButtonTitleKey = "取消"
        public static let confirmButtonTitleKey = "导入"
        public static let cancelAccessibilityHelpKey = "取消，不导入文件"
        public static let confirmAccessibilityHelpKey = "确认后导入所选布局；可用恢复上次备份撤销"
    }

    // MARK: - Launch / layout-persist feedback (LAUNCH-FEEDBACK-COPY-01)

    /// Open failure toasts, in-tile launching title, and layout save failure toast.
    public enum LaunchFeedbackCopy {
        public static let timedOutFormatKey = "打开“%@”超时"
        public static let cannotOpenFormatKey = "无法打开“%@”"
        public static let launchingTitleKey = "正在启动…"
        public static let layoutSaveFailedKey = "布局未保存，请检查磁盘空间或文件权限"

        public static func timedOutMessage(displayName: String, localize: (String) -> String = { $0 }) -> String {
            String(format: localize(timedOutFormatKey), displayName)
        }

        public static func cannotOpenMessage(displayName: String, localize: (String) -> String = { $0 }) -> String {
            String(format: localize(cannotOpenFormatKey), displayName)
        }

        public static func openFailureMessage(
            displayName: String,
            timedOut: Bool,
            localize: (String) -> String = { $0 }
        ) -> String {
            if timedOut {
                return timedOutMessage(displayName: displayName, localize: localize)
            }
            return cannotOpenMessage(displayName: displayName, localize: localize)
        }

        public static func launchingTitle(localize: (String) -> String = { $0 }) -> String {
            localize(launchingTitleKey)
        }

        public static func layoutSaveFailed(localize: (String) -> String = { $0 }) -> String {
            localize(layoutSaveFailedKey)
        }
    }

    /// SETTINGS-MAINTENANCE-LAYOUT-CHROME-COPY-01 — Settings maintenance /
    /// layout-I/O button chrome (not Launchpad import dialogs).
    public enum SettingsMaintenanceChromeCopy {
        public static let rescanButtonTitleKey = "重新扫描"
        public static let rescanAccessibilityHelpKey = "重新扫描 Applications 文件夹"
        public static let leftoversButtonTitleKey = "残留文件…"
        public static let leftoversAccessibilityLabelKey = "残留文件"
        public static let leftoversAccessibilityHelpKey =
            "查找已卸载应用留在用户资料库中的文件，确认后移到废纸篓"
        public static let leftoversCancelTitleKey = "取消查找"
        public static let leftoversCancelAccessibilityHelpKey =
            "取消正在进行的残留文件查找或清理"

        public static func rescanButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(rescanButtonTitleKey)
        }
        public static func rescanAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
            localize(rescanAccessibilityHelpKey)
        }
        public static func leftoversButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(leftoversButtonTitleKey)
        }
        public static func leftoversAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(leftoversAccessibilityLabelKey)
        }
        public static func leftoversAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
            localize(leftoversAccessibilityHelpKey)
        }
        public static func leftoversCancelTitle(localize: (String) -> String = { $0 }) -> String {
            localize(leftoversCancelTitleKey)
        }
        public static func leftoversCancelAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
            localize(leftoversCancelAccessibilityHelpKey)
        }
    }

    public enum SettingsLayoutIOChromeCopy {
        public static let exportButtonTitleKey = "导出布局…"
        public static let exportAccessibilityLabelKey = "导出布局"
        public static let exportAccessibilityHelpKey = "将当前主屏幕布局导出为 JSON 文件"
        public static let importButtonTitleKey = "导入布局…"
        public static let importAccessibilityLabelKey = "导入布局"
        public static let importAccessibilityHelpKey = "从 JSON 文件导入布局并与当前应用列表合并"
        public static let restoreBackupButtonTitleKey = "恢复上次备份"
        public static let restoreBackupAccessibilityHelpKey =
            "恢复最近一次自动保存前的布局；再次恢复可撤销"
        public static let restoreBackupAvailableToolTipKey = "恢复最近一次自动保存前的布局"
        public static let restoreBackupUnavailableToolTipKey = "尚无自动备份（修改布局后会生成）"

        public static func exportButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(exportButtonTitleKey)
        }
        public static func exportAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(exportAccessibilityLabelKey)
        }
        public static func exportAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
            localize(exportAccessibilityHelpKey)
        }
        public static func importButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(importButtonTitleKey)
        }
        public static func importAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(importAccessibilityLabelKey)
        }
        public static func importAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
            localize(importAccessibilityHelpKey)
        }
        public static func restoreBackupButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(restoreBackupButtonTitleKey)
        }
        public static func restoreBackupAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
            localize(restoreBackupAccessibilityHelpKey)
        }
        public static func restoreBackupToolTip(
            available: Bool,
            localize: (String) -> String = { $0 }
        ) -> String {
            localize(available ? restoreBackupAvailableToolTipKey : restoreBackupUnavailableToolTipKey)
        }
    }

    /// LAYOUT-IO-OUTCOME-COPY-01 — Settings export/import/Launchpad/restore
    /// outcome strings (and host-unavailable fallbacks). No paging.
    public enum LayoutIOOutcomeCopy {
        public static let exportSucceededKey = "布局已导出"
        public static let exportUnsupportedSchemaKey = "布局版本不受支持，无法导出"
        public static let exportFailedKey = "导出布局失败"
        public static let exportUnavailableKey = "当前无法导出布局"

        public static let importUnsupportedSchemaKey = "布局版本不受支持，无法导入"
        public static let importUnreadableFileKey = "无法读取布局文件"
        public static let importUnavailableKey = "当前无法导入布局"
        public static let layoutEditingBlockedKey = "暂时无法整理，请查看主界面提示"
        public static let layoutUpdatedToastKey = "布局已更新"

        public static let launchpadEmptyKey = "启动台数据库里没有应用"
        public static let launchpadUnreadableKey = "无法读取启动台数据库"
        public static let launchpadDefaultFolderNameKey = "文件夹"

        public static let restoreNoBackupKey = "没有可用备份"
        public static let restoreUnsupportedSchemaKey = "备份版本不受支持，无法恢复"
        public static let restoreUnreadableKey = "无法读取备份"
        public static let restoreUnavailableKey = "当前无法恢复备份"

        public static func exportSucceeded(localize: (String) -> String = { $0 }) -> String {
            localize(exportSucceededKey)
        }
        public static func exportUnsupportedSchema(localize: (String) -> String = { $0 }) -> String {
            localize(exportUnsupportedSchemaKey)
        }
        public static func exportFailed(localize: (String) -> String = { $0 }) -> String {
            localize(exportFailedKey)
        }
        public static func exportUnavailable(localize: (String) -> String = { $0 }) -> String {
            localize(exportUnavailableKey)
        }

        public static func importUnsupportedSchema(localize: (String) -> String = { $0 }) -> String {
            localize(importUnsupportedSchemaKey)
        }
        public static func importUnreadableFile(localize: (String) -> String = { $0 }) -> String {
            localize(importUnreadableFileKey)
        }
        public static func importUnavailable(localize: (String) -> String = { $0 }) -> String {
            localize(importUnavailableKey)
        }
        public static func layoutEditingBlocked(localize: (String) -> String = { $0 }) -> String {
            localize(layoutEditingBlockedKey)
        }
        public static func layoutUpdatedToast(localize: (String) -> String = { $0 }) -> String {
            localize(layoutUpdatedToastKey)
        }

        public static func launchpadEmpty(localize: (String) -> String = { $0 }) -> String {
            localize(launchpadEmptyKey)
        }
        public static func launchpadUnreadable(localize: (String) -> String = { $0 }) -> String {
            localize(launchpadUnreadableKey)
        }
        public static func launchpadDefaultFolderName(localize: (String) -> String = { $0 }) -> String {
            localize(launchpadDefaultFolderNameKey)
        }

        public static func restoreNoBackup(localize: (String) -> String = { $0 }) -> String {
            localize(restoreNoBackupKey)
        }
        public static func restoreUnsupportedSchema(localize: (String) -> String = { $0 }) -> String {
            localize(restoreUnsupportedSchemaKey)
        }
        public static func restoreUnreadable(localize: (String) -> String = { $0 }) -> String {
            localize(restoreUnreadableKey)
        }
        public static func restoreUnavailable(localize: (String) -> String = { $0 }) -> String {
            localize(restoreUnavailableKey)
        }
    }

    /// LAYOUT-EDITING-STATUS-COPY-01 — why layout editing is off / rescan feedback.
    public enum LayoutEditingStatusCopy {
        public static let scanningExplanationKey = "正在扫描应用，暂时无法整理"
        public static let scanCancelledExplanationKey = "应用扫描已取消，请重新扫描"
        public static let cachedCatalogExplanationKey = "正在显示上次应用列表；重新扫描后可整理"
        public static let layoutUnreadableExplanationKey = "布局文件无法读取，暂时无法整理；原文件已保留"
        public static let incompleteScanExplanationKey = "应用扫描不完整，暂时无法整理；请重新扫描"
        /// CUSTOM-ROOT-SCAN-LIMIT-01 — soft notice; editing stays open.
        public static let truncatedCustomRootExplanationKey = "部分应用目录过大，仅扫描了靠前的应用；可缩小目录后重新扫描"
        /// MISSING-ROOT-NOTICE-01 — soft notice when a user root is offline; editing stays open.
        public static let unavailableCustomRootExplanationKey = "部分应用目录当前不可用，已保留其中的应用位置；可在重新接入后扫描"
        public static let defaultBlockedExplanationKey = "应用列表正在加载或不完整，暂时无法整理"
        public static let rescanSucceededKey = "重新扫描完成"
        public static let rearrangeUnavailableKey = "当前无法重新排列"

        public static func scanningExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(scanningExplanationKey)
        }
        public static func scanCancelledExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(scanCancelledExplanationKey)
        }
        public static func cachedCatalogExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(cachedCatalogExplanationKey)
        }
        public static func layoutUnreadableExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(layoutUnreadableExplanationKey)
        }
        public static func incompleteScanExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(incompleteScanExplanationKey)
        }
        public static func truncatedCustomRootExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(truncatedCustomRootExplanationKey)
        }
        public static func unavailableCustomRootExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(unavailableCustomRootExplanationKey)
        }
        public static func defaultBlockedExplanation(localize: (String) -> String = { $0 }) -> String {
            localize(defaultBlockedExplanationKey)
        }
        public static func rescanSucceeded(localize: (String) -> String = { $0 }) -> String {
            localize(rescanSucceededKey)
        }
        public static func rearrangeUnavailable(localize: (String) -> String = { $0 }) -> String {
            localize(rearrangeUnavailableKey)
        }
    }

    public static func gridRearrangeToastMessage(sort: GridRearrangeSort) -> String {
        switch sort {
        case .byName: return "已按名称重新排列"
        case .byKind: return "已按类型重新排列"
        }
    }

    /// Reorders only `orderedEntries`. Does not touch folder `itemIDs`, aliases,
    /// or paging. Stable for equal names via UUID string.
    public static func rearrangeTopLevelEntries(
        in state: LayoutState,
        catalog: [AppCandidate],
        sort: GridRearrangeSort
    ) -> LayoutState {
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        func kindRank(for entry: LauncherEntry) -> Int {
            switch entry {
            case .folder:
                return 1
            case .app(let id):
                guard let key = state.appKeys[id], let candidate = byKey[key] else { return 2 }
                return isSystemApplication(candidate) ? 0 : 1
            }
        }
        func displayName(for entry: LauncherEntry) -> String {
            switch entry {
            case .folder(let id):
                return state.folders[id]?.name ?? id.uuidString
            case .app(let id):
                guard let key = state.appKeys[id] else { return id.uuidString }
                if let alias = state.appAliases[key], !alias.isEmpty { return alias }
                return byKey[key]?.displayName ?? id.uuidString
            }
        }
        func tieBreak(_ entry: LauncherEntry) -> String {
            entry.id.uuidString
        }

        var next = state
        next.orderedEntries.sort { lhs, rhs in
            if sort == .byKind {
                let lk = kindRank(for: lhs)
                let rk = kindRank(for: rhs)
                if lk != rk { return lk < rk }
            }
            let nameOrder = displayName(for: lhs).localizedStandardCompare(displayName(for: rhs))
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return tieBreak(lhs) < tieBreak(rhs)
        }
        if next.orderedEntries != state.orderedEntries {
            next.updatedAt = .now
        }
        return next
    }

    public static let sortFolderByNameMenuTitleKey = "按名称排列文件夹内应用"
    public static let sortFolderByNameToastKey = "已按名称排列文件夹内应用"
    public static let sortFolderAlreadySortedToastKey = "文件夹内应用已按名称排列"
    // FOLDER-SORT-AX-HELP-01
    public static let sortFolderByNameAccessibilityHelpKey = "只调整这个文件夹内的顺序，主屏幕不变"

    public static func sortFolderByNameAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(sortFolderByNameAccessibilityHelpKey)
    }

    public static func sortFolderByColorAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(sortFolderByColorAccessibilityHelpKey)
    }

    /// Folder context menu「按名称排列文件夹内应用」. Reorders only that
    /// folder's `itemIDs` (alias → catalog name → UUID). Returns nil when the
    /// folder is missing or already in order. Top-level entries and paging
    /// are untouched.
    public static func sortingFolderMembersByName(
        _ folderID: UUID,
        in state: LayoutState,
        catalog: [AppCandidate]
    ) -> LayoutState? {
        guard let folder = state.folders[folderID], folder.itemIDs.count > 1 else { return nil }
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        func name(_ id: UUID) -> String {
            guard let key = state.appKeys[id] else { return id.uuidString }
            if let alias = state.appAliases[key], !alias.isEmpty { return alias }
            return byKey[key]?.displayName ?? id.uuidString
        }
        let names = Dictionary(folder.itemIDs.map { ($0, name($0)) }, uniquingKeysWith: { first, _ in first })
        let sorted = folder.itemIDs.sorted { lhs, rhs in
            let order = names[lhs, default: ""].localizedStandardCompare(names[rhs, default: ""])
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.uuidString < rhs.uuidString
        }
        guard sorted != folder.itemIDs else { return nil }
        var next = state
        next.folders[folderID]?.itemIDs = sorted
        next.updatedAt = .now
        return next
    }

    private static func isSystemApplication(_ candidate: AppCandidate) -> Bool {
        let path = candidate.canonicalURL.path
        return path.hasPrefix("/System/Applications/")
            || path.hasPrefix("/System/Cryptexes/App/System/Applications/")
            || path.hasPrefix("/System/Volumes/Preboot/Cryptexes/App/System/Applications/")
    }

    public static func searchableApps(in state: LayoutState, catalog: [AppCandidate]) -> [AppCandidate] {
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        var apps: [AppCandidate] = []
        var seen = Set<UUID>()
        var seenKeys = Set<String>()

        func appendApp(id: UUID) {
            guard let key = state.appKeys[id],
                  let candidate = byKey[key],
                  seen.insert(id).inserted,
                  seenKeys.insert(key).inserted else { return }
            apps.append(candidate)
        }

        for entry in state.orderedEntries {
            switch entry {
            case .app(let id):
                appendApp(id: id)
            case .folder(let id):
                for itemID in state.folders[id]?.itemIDs ?? [] {
                    appendApp(id: itemID)
                }
            }
        }
        return apps
    }

    /// Deduplication keys of apps that sit on the top-level grid (not inside a folder).
    /// Used so search can prefer those hits when match ranks tie.
    public static func topLevelAppDeduplicationKeys(in state: LayoutState) -> Set<String> {
        var keys = Set<String>()
        for entry in state.orderedEntries {
            guard case .app(let id) = entry, let key = state.appKeys[id] else { continue }
            keys.insert(key)
        }
        return keys
    }

    /// Apps in layout order, with each folder name inserted where that folder sits.
    /// Members stay in the same order `searchableApps` already uses.
    public static func searchHits(in state: LayoutState, catalog: [AppCandidate]) -> [LauncherSearchHit] {
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        var hits: [LauncherSearchHit] = []
        var seen = Set<UUID>()
        var seenKeys = Set<String>()

        func appendApp(id: UUID) {
            guard let key = state.appKeys[id],
                  let candidate = byKey[key],
                  seen.insert(id).inserted,
                  seenKeys.insert(key).inserted else { return }
            hits.append(.app(candidate))
        }

        for entry in state.orderedEntries {
            switch entry {
            case .app(let id):
                appendApp(id: id)
            case .folder(let id):
                if let folder = state.folders[id] {
                    hits.append(.folder(id, folder.name))
                    for itemID in folder.itemIDs {
                        appendApp(id: itemID)
                    }
                }
            }
        }
        return hits
    }

    /// Which centered empty chrome the grid area should show (PRD §2.7).
    /// Search no-matches uses the grid area — not status-line only.
    public enum LauncherEmptyChromeKind: Equatable, Sendable {
        /// Catalog has no apps (rescan / cache actions).
        case catalogUnavailable
        /// User cancelled the first scan.
        case catalogCancelled
        /// Non-empty catalog, active search, zero hits (Esc clears).
        case searchNoMatches
    }

    /// Decide empty chrome for the grid viewport. `nil` means hide empty chrome
    /// (loading skeleton / status message / normal grid or results).
    public static func emptyChromeKind(
        isSearching: Bool,
        presentedIsEmpty: Bool,
        catalogIsEmpty: Bool,
        isCatalogLoading: Bool,
        catalogScanCancelled: Bool
    ) -> LauncherEmptyChromeKind? {
        if isCatalogLoading, catalogIsEmpty { return nil }
        if catalogIsEmpty {
            return catalogScanCancelled ? .catalogCancelled : .catalogUnavailable
        }
        if isSearching, presentedIsEmpty {
            return .searchNoMatches
        }
        return nil
    }

    /// Search no-matches hint when the query names apps the user hid (P1 隐藏/恢复):
    /// a hidden app never shows in results, so say where it went.
    public enum SearchHiddenMatchHint: Equatable, Sendable {
        case none
        case one(name: String)
        case several(count: Int)

        public static let oneFormatKey = "“%@”已隐藏，可在设置中恢复"
        public static let severalFormatKey = "%d 个匹配的应用已隐藏，可在设置中恢复"
    }


    // MARK: - Catalog empty / preparing chrome (CATALOG-EMPTY-PREPARING-CHROME-01)

    /// User-visible copy for preparing status + centered empty chrome (catalog /
    /// cancelled / search no-matches) and the shared rescan / cached-list buttons.
    public enum CatalogEmptyChromeCopy {
        public static let preparingMessageKey = "正在准备应用…"
        public static let catalogUnavailableTitleKey = "未找到可用的应用"
        public static let catalogUnavailableDetailKey = "请确认应用位于 Applications 文件夹，然后重新扫描。"
        public static let catalogUnavailableHelpKey = "重新扫描标准 Applications 文件夹"
        public static let catalogCancelledTitleKey = "扫描已取消"
        public static let catalogCancelledDetailKey = "应用扫描已取消，请重新扫描。"
        public static let catalogCancelledHelpKey = "重新扫描应用"
        public static let searchNoMatchesTitleKey = "未找到匹配的应用"
        public static let searchNoMatchesDefaultDetailKey = "按 Esc 清除搜索"
        public static let reloadButtonTitleKey = "重新扫描"
        public static let useCachedButtonTitleKey = "使用上次应用列表"
        public static let useCachedHelpKey = "使用本机上次完整扫描的应用列表；整理功能暂不可用"
        public static let rescanRestoreHelpKey = "重新扫描应用并恢复可整理的列表"

        public struct Content: Equatable, Sendable {
            public let title: String
            public let detail: String
            public let help: String
            public let showActions: Bool
        }

        public static func preparingMessage(localize: (String) -> String = { $0 }) -> String {
            localize(preparingMessageKey)
        }

        public static func reloadButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(reloadButtonTitleKey)
        }

        public static func useCachedButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(useCachedButtonTitleKey)
        }

        public static func useCachedHelp(localize: (String) -> String = { $0 }) -> String {
            localize(useCachedHelpKey)
        }

        public static func rescanRestoreHelp(localize: (String) -> String = { $0 }) -> String {
            localize(rescanRestoreHelpKey)
        }

        public static func defaultReloadHelp(localize: (String) -> String = { $0 }) -> String {
            localize(catalogUnavailableHelpKey)
        }

        /// Title / detail / help / whether rescan+cache actions show for a kind.
        /// Pass `searchDetail` for search no-matches when a hidden-match hint
        /// replaces the default Esc line.
        public static func content(
            for kind: LauncherEmptyChromeKind,
            searchDetail: String? = nil,
            localize: (String) -> String = { $0 }
        ) -> Content {
            switch kind {
            case .catalogCancelled:
                return Content(
                    title: localize(catalogCancelledTitleKey),
                    detail: localize(catalogCancelledDetailKey),
                    help: localize(catalogCancelledHelpKey),
                    showActions: true
                )
            case .catalogUnavailable:
                return Content(
                    title: localize(catalogUnavailableTitleKey),
                    detail: localize(catalogUnavailableDetailKey),
                    help: localize(catalogUnavailableHelpKey),
                    showActions: true
                )
            case .searchNoMatches:
                return Content(
                    title: localize(searchNoMatchesTitleKey),
                    detail: searchDetail ?? localize(searchNoMatchesDefaultDetailKey),
                    help: localize(catalogUnavailableHelpKey),
                    showActions: false
                )
            }
        }
    }


    // MARK: - Search / count / settings chrome (SEARCH-FIELD-CHROME-01)

    /// Search field, result/item/selection count labels, footer Esc hints, and
    /// the top-bar settings button. Esc-clear reuses CatalogEmptyChromeCopy.
    public enum SearchFieldChromeCopy {
        public static let searchPlaceholderKey = "搜索应用"
        public static let searchHelpKey = "按应用名称或 Bundle ID 搜索"
        public static let clearSearchKey = "清除搜索"
        public static let clearSearchHelpKey = "清除搜索并返回应用网格"
        public static let escReturnKey = "Esc 返回"
        public static let escReturnWithPagingKey = "← → 翻页 · Esc 返回"
        public static let resultsFormatKey = "%d 个结果"
        public static let resultsAccessibilityKey = "搜索结果数量"
        public static let selectedAccessibilityKey = "已选数量"
        public static let itemsFormatKey = "%d 个项目"
        public static let itemsAccessibilityKey = "应用数量"
        public static let settingsKey = "设置"
        public static let settingsHelpKey = "打开 LaunchIcon 设置"

        public static func searchPlaceholder(localize: (String) -> String = { $0 }) -> String {
            localize(searchPlaceholderKey)
        }

        public static func searchAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(searchPlaceholderKey)
        }

        public static func searchHelp(localize: (String) -> String = { $0 }) -> String {
            localize(searchHelpKey)
        }

        public static func clearSearchLabel(localize: (String) -> String = { $0 }) -> String {
            localize(clearSearchKey)
        }

        public static func clearSearchHelp(localize: (String) -> String = { $0 }) -> String {
            localize(clearSearchHelpKey)
        }

        /// Same string as empty-search detail ("按 Esc 清除搜索").
        public static func escClearSearch(localize: (String) -> String = { $0 }) -> String {
            localize(CatalogEmptyChromeCopy.searchNoMatchesDefaultDetailKey)
        }

        public static func footerNavigationText(
            isSearching: Bool,
            pageCount: Int,
            localize: (String) -> String = { $0 }
        ) -> String {
            if isSearching { return escClearSearch(localize: localize) }
            if pageCount > 1 { return localize(escReturnWithPagingKey) }
            return localize(escReturnKey)
        }

        public static func resultsCountText(count: Int, localize: (String) -> String = { $0 }) -> String {
            String(format: localize(resultsFormatKey), count)
        }

        public static func resultsAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(resultsAccessibilityKey)
        }

        public static func selectedAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(selectedAccessibilityKey)
        }

        public static func itemsCountText(count: Int, localize: (String) -> String = { $0 }) -> String {
            String(format: localize(itemsFormatKey), count)
        }

        public static func itemsAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(itemsAccessibilityKey)
        }

        public static func settingsLabel(localize: (String) -> String = { $0 }) -> String {
            localize(settingsKey)
        }

        public static func settingsHelp(localize: (String) -> String = { $0 }) -> String {
            localize(settingsHelpKey)
        }
    }

    // MARK: - Footer / toast chrome (FOOTER-DRAG-HINT-01)

    /// Footer drag-hint strings and toast dismiss chrome. Multi-page hint is
    /// copy only — does not change paging / edge-cross behavior.
    public enum FooterChromeCopy {
        public static let dragHintKey = "拖拽整理"
        public static let dragHintMultiPageKey = "拖拽整理 · 悬停左右边缘跨页"
        public static let toastCloseKey = "关闭提示"

        public static func dragHint(pageCount: Int, localize: (String) -> String = { $0 }) -> String {
            if pageCount > 1 { return localize(dragHintMultiPageKey) }
            return localize(dragHintKey)
        }

        public static func toastCloseLabel(localize: (String) -> String = { $0 }) -> String {
            localize(toastCloseKey)
        }
    }


    /// FOLDER-DROP-CHROME-COPY-01 — drop-target / nest-reject / open-folder grid chrome.
    public enum FolderDropChromeCopy {
        public static let nestRejectToastKey = "不能将文件夹放入另一个文件夹"
        public static let dropOnFolderHelpKey = "拖放到此文件夹"
        public static let dropToMergeHelpKey = "拖放到此以合并"
        public static let folderMembersLabelKey = "文件夹中的应用"

        public static func nestRejectToast(localize: (String) -> String = { $0 }) -> String {
            localize(nestRejectToastKey)
        }

        public static func dropTargetHelp(isFolder: Bool, localize: (String) -> String = { $0 }) -> String {
            localize(isFolder ? dropOnFolderHelpKey : dropToMergeHelpKey)
        }

        public static func folderMembersLabel(localize: (String) -> String = { $0 }) -> String {
            localize(folderMembersLabelKey)
        }
    }

    public static func searchHiddenMatchHint(query: String, hiddenNames: [String]) -> SearchHiddenMatchHint {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .none }
        let matches = hiddenNames.filter {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
        switch matches.count {
        case 0: return .none
        case 1: return .one(name: matches[0])
        default: return .several(count: matches.count)
        }
    }

    /// Folder that currently contains `appID` on the home grid, if any.
    /// Used by search results to show where a member hit lives.
    public static func containingFolderName(forAppID appID: UUID, in state: LayoutState) -> String? {
        for folder in state.folders.values where folder.itemIDs.contains(appID) {
            let trimmed = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : folder.name
        }
        return nil
    }

    /// Two-line search title: primary app/alias name, optional folder context.
    /// Empty / whitespace folder names omit the secondary line.
    public static func searchHitTitle(
        displayName: String,
        containingFolderName: String?
    ) -> String {
        let primary = displayName
        guard let raw = containingFolderName else { return primary }
        let folder = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return primary }
        return primary + "\n" + folder
    }

    /// Accessibility / tooltip for a search app hit that lives in a folder.
    public static func searchHitAccessibilityLabel(
        displayName: String,
        containingFolderName: String?
    ) -> String {
        guard let raw = containingFolderName else { return displayName }
        let folder = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return displayName }
        return displayName + "，" + folder
    }

    /// Folder titles always keep a visible label. Whitespace-only or empty
    /// drafts resolve back to `previous` (same rule `renameFolder` applies).
    public static func resolvedFolderName(draft: String, previous: String) -> String {
        let trimmed = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return trimmed.isEmpty ? previous : trimmed
    }

    /// Finder/Launchpad-style rename: select the whole name when editing begins
    /// so the next keystroke replaces it. Clicks after that place the caret.
    public static let folderTitleSelectsAllOnBeginEditing = true

    /// Alias alert rename: same select-all-on-begin policy as folder titles.
    public static let aliasSelectsAllOnBeginEditing = true

    /// Quiet edit affordance under the folder name (white hairline strength).
    public static let folderTitleEditUnderlineAlpha: CGFloat = 0.55
    public static let folderTitleEditUnderlineFadeAnimationKey = "folder-title-edit-underline"
    /// Alias alert field uses the same fade clock / strength as the folder title.
    public static let aliasEditUnderlineFadeAnimationKey = "alias-edit-underline"
    public static let folderTitleEditUnderlineFadeDuration: TimeInterval = searchTransitionDuration
    public static let aliasEditUnderlineFadeDuration: TimeInterval = searchTransitionDuration

    public static func shouldAnimateFolderTitleEditUnderline(
        fromOpacity: Float,
        toOpacity: Float,
        reducesMotion: Bool
    ) -> Bool {
        guard !reducesMotion else { return false }
        return abs(fromOpacity - toOpacity) > 0.004
    }

    /// Pointer rename needs a double-click. Single-click does not open the
    /// field editor (avoids accidental renames). Keyboard Tab/focus still edits.
    public static func folderTitleShouldBeginEditingFromPointer(clickCount: Int) -> Bool {
        clickCount >= 2
    }

    /// UI Automation often fails to coalesce double-clicks onto NSTextField.
    /// Test fixtures (`LAUNCHICON_TEST_LAYOUT_PATH`) may treat a single press
    /// as rename-begin; production stays double-click only.
    public static func folderTitleShouldBeginEditingFromPointer(
        clickCount: Int,
        allowSingleClickBegin: Bool
    ) -> Bool {
        if allowSingleClickBegin, clickCount >= 1 { return true }
        return folderTitleShouldBeginEditingFromPointer(clickCount: clickCount)
    }

    /// UI Automation can deliver a double-click as two `mouseDown` events each
    /// with `clickCount == 1` (no AppKit click-count coalescing). Treat a
    /// second press inside the system double-click interval like clickCount ≥ 2.
    public static func folderTitleShouldBeginEditingFromPointer(
        clickCount: Int,
        secondsSincePreviousPointerDown: TimeInterval?,
        doubleClickInterval: TimeInterval,
        allowSingleClickBegin: Bool = false
    ) -> Bool {
        if folderTitleShouldBeginEditingFromPointer(
            clickCount: clickCount,
            allowSingleClickBegin: allowSingleClickBegin
        ) {
            return true
        }
        guard clickCount == 1,
              let elapsed = secondsSincePreviousPointerDown,
              doubleClickInterval > 0 else { return false }
        return elapsed >= 0 && elapsed <= doubleClickInterval
    }

    /// Pointer down outside the title while a rename is active cancels the
    /// draft (same as Escape). The close button still commits via its action.
    public static func folderTitleShouldCancelEditingOnOutsideClick(
        isEditing: Bool,
        clickIsOnTitle: Bool
    ) -> Bool {
        isEditing && !clickIsOnTitle
    }

    /// After a rename ends (Return commit, Escape cancel, or outside-click
    /// cancel), prefer the first folder member for keyboard focus. Landing on
    /// the empty collection view skips the focus fill and leaves Tab odd.
    public static let folderTitleFocusesFirstMemberAfterEndingEdit = true

    public static func renameFolder(_ id: UUID, to name: String, in state: LayoutState) -> LayoutState {
        var state = state
        guard var folder = state.folders[id] else { return state }
        let resolved = resolvedFolderName(draft: name, previous: folder.name)
        guard folder.name != resolved else { return state }
        folder.name = resolved
        state.folders[id] = folder
        state.updatedAt = .now
        return state
    }

    public static func setAlias(_ alias: String, forApplicationKey key: String, in state: LayoutState) -> LayoutState {
        var state = state
        let trimmed = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !key.isEmpty else { return state }
        guard state.appAliases[key] != (trimmed.isEmpty ? nil : trimmed) else { return state }
        if trimmed.isEmpty {
            state.appAliases.removeValue(forKey: key)
        } else {
            state.appAliases[key] = trimmed
        }
        state.updatedAt = .now
        return state
    }

    /// Clears alias and hidden marks for apps a truncated scan confirmed are
    /// gone. Visible slots are `reconcile`'s job (those keys are not in the
    /// retained catalog). An empty set does not touch `updatedAt`.
    public static func removingConfirmedAbsentCatalogIdentity(
        _ keys: Set<String>,
        from state: LayoutState
    ) -> LayoutState {
        guard !keys.isEmpty else { return state }
        var next = state
        let hiddenBefore = next.hiddenAppKeys
        next.hiddenAppKeys.subtract(keys)
        var changed = next.hiddenAppKeys != hiddenBefore
        for key in keys where next.appAliases.removeValue(forKey: key) != nil {
            changed = true
        }
        guard changed else { return state }
        next.updatedAt = .now
        return next
    }

    /// Removes a successfully trashed app from layout identity (not a hide).
    /// Clears alias and hidden marks so Settings cannot "restore" a missing bundle.
    public static func forgetUninstalledApplication(withKey key: String, in state: LayoutState) -> LayoutState {
        guard !key.isEmpty else { return state }
        var state = state
        state.hiddenAppKeys.remove(key)
        state.appAliases.removeValue(forKey: key)
        let removedIDs = Set(state.appKeys.compactMap { $0.value == key ? $0.key : nil })
        state.orderedEntries.removeAll { entry in
            if case .app(let id) = entry { return removedIDs.contains(id) }
            return false
        }
        for folderID in Array(state.folders.keys) {
            state.folders[folderID]?.itemIDs.removeAll { removedIDs.contains($0) }
            dissolveIfNeeded(folderID, in: &state)
        }
        for id in removedIDs {
            state.appKeys.removeValue(forKey: id)
        }
        state.updatedAt = .now
        return state
    }

    /// Top-level entry ids (apps + folders) plus every folder member id.
    /// Selection chrome may cover folder tiles and members; prune against this set.
    public static func presentSelectableItemIDs(in state: LayoutState) -> Set<UUID> {
        var ids = Set(state.orderedEntries.map(\.id))
        ids.formUnion(state.folders.values.flatMap(\.itemIDs))
        return ids
    }

    /// Drop selection ids that left the layout (hide, uninstall, reconcile, dissolve).
    public static func prunedItemSelection(
        _ selection: LauncherItemSelection,
        in state: LayoutState
    ) -> LauncherItemSelection {
        selection.pruningAbsent(from: presentSelectableItemIDs(in: state))
    }

    /// Toast after hiding from the context menu (Settings can restore).
    public static let hideApplicationToastHelpKey = "可在设置的「隐藏的应用」中恢复"

    public static let hideApplicationToastMessageFormatKey = "已隐藏“%@”"

    public static func hideApplicationToastMessage(displayName: String) -> String {
        String(format: hideApplicationToastMessageFormatKey, displayName)
    }

    /// Plural toast after hiding several selected apps from the context menu.
    public static let hideSelectedApplicationsToastMessageFormatKey = "已隐藏 %d 个应用"
    /// BATCH-MENU-COUNTS-01: multi-select hide menu title (parity with「卸载 N 个应用…」).
    public static let batchHideMenuTitleFormatKey = "隐藏 %d 个应用"
    /// BATCH-MENU-COUNTS-01: multi-select「移入新建文件夹（N）」.
    public static let batchNewFolderMenuTitleFormatKey = "移入新建文件夹（%d）"
    /// BATCH-REVEAL-COUNT-01: multi-select「在访达中显示（N）」.
    public static let batchRevealMenuTitleFormatKey = "在访达中显示（%d）"

    public static func hideSelectedApplicationsToastMessage(count: Int) -> String {
        String(format: hideSelectedApplicationsToastMessageFormatKey, max(count, 0))
    }

    /// App keys for batch hide, in selection order. Skips folder tiles and unknown ids.
    public static func appKeysForBatchHide(
        selection: LauncherItemSelection,
        in state: LayoutState
    ) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for id in selection.orderedIDs {
            guard state.folders[id] == nil,
                  let key = state.appKeys[id],
                  seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }

    /// Top-level app ids eligible for "move selection into new folder", selection order.
    public static func topLevelAppIDsForBatchFolder(
        selection: LauncherItemSelection,
        in state: LayoutState
    ) -> [UUID] {
        let topLevelApps = Set(state.orderedEntries.compactMap { entry -> UUID? in
            if case .app(let id) = entry { return id }
            return nil
        })
        var unique: [UUID] = []
        var seen = Set<UUID>()
        for id in selection.orderedIDs where topLevelApps.contains(id) && seen.insert(id).inserted {
            unique.append(id)
        }
        return unique
    }

    /// Hide several apps in one layout pass (compose of single-key hide).
    public static func hideApplications(withKeys keys: [String], in state: LayoutState) -> LayoutState {
        var state = state
        var seen = Set<String>()
        for key in keys where !key.isEmpty && seen.insert(key).inserted {
            state = hideApplication(withKey: key, in: state)
        }
        return state
    }

    /// Build a new folder from ≥2 top-level apps. Preserves `orderedAppIDs` order inside the folder.
    /// Inserts the folder at the earliest former index among those apps.
    public static func createFolderFromTopLevelApps(
        orderedAppIDs: [UUID],
        in state: LayoutState,
        name: String
    ) -> Result<(state: LayoutState, folderID: UUID), LayoutMutationError> {
        var seen = Set<UUID>()
        var apps: [UUID] = []
        for id in orderedAppIDs where seen.insert(id).inserted {
            guard state.orderedEntries.contains(.app(id)) else { return .failure(.missingSource) }
            guard state.folders[id] == nil else { return .failure(.nestedFolder) }
            apps.append(id)
        }
        guard apps.count >= 2 else { return .failure(.missingSource) }

        var state = state
        var removalIndices: [Int] = []
        for id in apps {
            guard let index = state.orderedEntries.firstIndex(of: .app(id)) else {
                return .failure(.missingSource)
            }
            removalIndices.append(index)
        }
        let insertAt = removalIndices.min() ?? 0
        for index in removalIndices.sorted(by: >) {
            state.orderedEntries.remove(at: index)
        }
        let folderID = uniqueFolderID(in: state)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = trimmed.isEmpty ? "新建文件夹" : trimmed
        state.folders[folderID] = LauncherFolder(id: folderID, name: folderName, itemIDs: apps)
        state.orderedEntries.insert(.folder(folderID), at: min(insertAt, state.orderedEntries.count))
        state.updatedAt = .now
        return .success((state, folderID))
    }


    /// Open-folder member context menu「移出文件夹」(LaunchOS parity).
    public static let removeFromFolderMenuTitleKey = "移出文件夹"
    /// Toast after「移出文件夹」; %@ is the folder name.
    public static let removeFromFolderToastFormatKey = "已移出“%@”"
    /// The menu item only appears while the folder keeps at least two
    /// members afterwards, so the open folder is never dissolved under the
    /// pointer (a two-app folder uses「解散文件夹」instead).
    public static let removeFromFolderMinimumMembers = 3

    /// Moves `appID` out of `folderID` to the grid slot right after that
    /// folder. Nil when the app is not a member or the folder would be left
    /// with fewer than two members.
    public static func removingAppFromFolder(
        _ appID: UUID,
        folderID: UUID,
        in state: LayoutState
    ) -> LayoutState? {
        guard let folder = state.folders[folderID],
              folder.itemIDs.contains(appID),
              folder.itemIDs.count >= removeFromFolderMinimumMembers,
              state.orderedEntries.contains(.folder(folderID)) else { return nil }
        var next = state
        next.folders[folderID]?.itemIDs.removeAll { $0 == appID }
        let index = topLevelIndexAfterFolder(folderID, in: next)
        next.orderedEntries.insert(.app(appID), at: index)
        return next
    }

    /// BATCH-REMOVE-FROM-FOLDER-01: open-folder multi-select「移出 N 个应用」.
    public static let batchRemoveFromFolderMenuTitleFormatKey = "移出 %d 个应用"
    /// Toast after batch remove; %d is the count.
    public static let batchRemoveFromFolderToastFormatKey = "已移出 %d 个应用"

    /// Members of `folderID` that are in `selection`, folder order. Nil unless
    /// ≥2 eligible **and** the folder would keep ≥2 members afterwards.
    public static func appIDsForBatchRemoveFromFolder(
        selection: LauncherItemSelection,
        folderID: UUID,
        in state: LayoutState
    ) -> [UUID]? {
        guard let folder = state.folders[folderID],
              state.orderedEntries.contains(.folder(folderID)) else { return nil }
        let ordered = folder.itemIDs.filter { selection.contains($0) }
        guard ordered.count >= 2,
              folder.itemIDs.count - ordered.count >= 2 else { return nil }
        return ordered
    }

    /// Moves several members out of `folderID` to consecutive slots right
    /// after that folder (folder member order). Nil when fewer than two ids
    /// qualify or the folder would drop below two members.
    public static func removingAppsFromFolder(
        _ appIDs: [UUID],
        folderID: UUID,
        in state: LayoutState
    ) -> LayoutState? {
        guard let folder = state.folders[folderID],
              state.orderedEntries.contains(.folder(folderID)) else { return nil }
        let removeSet = Set(appIDs)
        let ordered = folder.itemIDs.filter { removeSet.contains($0) }
        guard ordered.count >= 2,
              folder.itemIDs.count - ordered.count >= 2 else { return nil }
        var next = state
        next.folders[folderID]?.itemIDs.removeAll { removeSet.contains($0) }
        var index = topLevelIndexAfterFolder(folderID, in: next)
        for id in ordered {
            next.orderedEntries.insert(.app(id), at: index)
            index += 1
        }
        return next
    }

    /// Context menu「移到文件夹」(LaunchOS parity): existing folders in layout
    /// order. Only a **top-level** app qualifies — folder members, folder tiles
    /// and unknown ids get an empty list (menu hidden). A blank name stays
    /// empty so Direct can show the localized「新建文件夹」fallback.
    public static func moveToFolderMenuTargets(
        forAppID appID: UUID,
        in state: LayoutState
    ) -> [FolderMenuTarget] {
        guard state.folders[appID] == nil, state.orderedEntries.contains(.app(appID)) else { return [] }
        return state.orderedEntries.compactMap { entry in
            guard case .folder(let id) = entry, let folder = state.folders[id] else { return nil }
            let trimmed = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return FolderMenuTarget(id: id, name: trimmed)
        }
    }

    /// Menu move of one top-level app into an existing folder (appended last,
    /// same as dropping onto the folder centre). Never nests folders.
    public static func moveTopLevelApp(
        _ appID: UUID,
        toFolder folderID: UUID,
        in state: LayoutState
    ) -> Result<LayoutState, LayoutMutationError> {
        guard state.folders[appID] == nil else { return .failure(.nestedFolder) }
        guard state.orderedEntries.contains(.app(appID)) else { return .failure(.missingSource) }
        guard state.folders[folderID] != nil else { return .failure(.missingTarget) }
        return applyDrop(
            LayoutDrop(source: .topLevel(appID), destination: .merge(.topLevel(folderID))),
            to: state
        )
    }

    public static let moveToFolderToastMessageFormatKey = "已移到「%@」"

    /// Multi-select「移到文件夹」: when the right-clicked app belongs to a
    /// selection of ≥2 top-level apps, the menu moves the whole selection
    /// (selection order). Nil → single-app move. Pages are irrelevant here:
    /// the grid does not follow the moved icons.
    public static func batchMoveToFolderAppIDs(
        selection: LauncherItemSelection,
        anchorAppID: UUID,
        in state: LayoutState
    ) -> [UUID]? {
        let apps = topLevelAppIDsForBatchFolder(selection: selection, in: state)
        guard apps.count >= 2, apps.contains(anchorAppID) else { return nil }
        return apps
    }

    public static let batchMoveToFolderToastMessageFormatKey = "已把 %d 个应用移到「%@」"

    /// Folder context menu「解散文件夹」(LaunchOS "ungroup"): members replace
    /// the folder tile in place, in folder order. Duplicates and ids already on
    /// the grid are skipped. Nil when the folder is missing or not top-level.
    public static func dissolveFolder(_ folderID: UUID, in state: LayoutState) -> LayoutState? {
        guard let folder = state.folders[folderID],
              let index = state.orderedEntries.firstIndex(of: .folder(folderID)) else { return nil }
        var state = state
        let onGrid = Set(state.orderedEntries.compactMap { entry -> UUID? in
            if case .app(let id) = entry { return id }
            return nil
        })
        var seen = Set<UUID>()
        let members = folder.itemIDs.filter { !onGrid.contains($0) && seen.insert($0).inserted }
        state.orderedEntries.replaceSubrange(index...index, with: members.map { LauncherEntry.app($0) })
        state.folders[folderID] = nil
        state.updatedAt = .now
        return state
    }

    /// Focus after a menu dissolve: the entry now in the folder's slot (first
    /// member). Nil when that would land on another page, so the menu action
    /// never pages the grid.
    public static func focusIDAfterMenuDissolve(
        folderID: UUID,
        previousEntries: [LauncherEntry],
        currentEntries: [LauncherEntry]
    ) -> UUID? {
        guard let folderIndex = previousEntries.firstIndex(of: .folder(folderID)),
              let id = entryReplacingDissolvedFolder(
                folderID: folderID,
                previousEntries: previousEntries,
                currentEntries: currentEntries
              ),
              let index = currentEntries.firstIndex(where: { $0.id == id }),
              pageIndex(containingEntryAt: index) == pageIndex(containingEntryAt: folderIndex) else { return nil }
        return id
    }

    public static let dissolveFolderToastMessageFormatKey = "已解散「%@」"

    // MARK: Batch dissolve selected folders (BATCH-DISSOLVE-FOLDERS-01)

    /// Top-level folder ids in `selection` (selection order, de-duped).
    /// Nil unless `anchorID` is in a ≥2 selection that contains ≥2 folders.
    public static func folderIDsForBatchDissolve(
        selection: LauncherItemSelection,
        anchorID: UUID,
        in state: LayoutState
    ) -> [UUID]? {
        guard selection.count > 1, selection.contains(anchorID) else { return nil }
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for id in selection.orderedIDs {
            guard state.folders[id] != nil,
                  state.orderedEntries.contains(.folder(id)),
                  seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        guard ids.count >= 2, ids.contains(anchorID) else { return nil }
        return ids
    }

    /// Dissolve each folder in order via `dissolveFolder`. Nil when nothing changes.
    public static func dissolvingFolders(
        _ folderIDs: [UUID],
        in state: LayoutState
    ) -> LayoutState? {
        guard !folderIDs.isEmpty else { return nil }
        var next = state
        var changed = false
        for id in folderIDs {
            if let dissolved = dissolveFolder(id, in: next) {
                next = dissolved
                changed = true
            }
        }
        return changed ? next : nil
    }

    public static let batchDissolveFoldersMenuTitleFormatKey = "解散 %d 个文件夹…"
    public static let batchDissolveFoldersConfirmTitleKey = "解散选中的文件夹？"
    public static let batchDissolveFoldersConfirmInfoFormatKey = "%d 个文件夹里的应用会放回各自文件夹所在的位置。"
    /// UNGROUP-ALL-CONFIRM-COPY-01 — blank-area「解散所有文件夹」confirm.
    public static let ungroupAllFoldersConfirmTitleKey = "解散所有文件夹？"
    /// Same body as batch dissolve; keep one source of truth.
    public static var ungroupAllFoldersConfirmInfoFormatKey: String {
        batchDissolveFoldersConfirmInfoFormatKey
    }
    /// Destructive confirm button shared by batch dissolve / ungroup-all.
    public static let dissolveConfirmButtonTitleKey = "解散"

    public static func ungroupAllFoldersConfirmTitle(
        localize: (String) -> String = { $0 }
    ) -> String {
        localize(ungroupAllFoldersConfirmTitleKey)
    }

    public static func ungroupAllFoldersConfirmInformativeText(
        folderCount: Int,
        localize: (String) -> String = { $0 }
    ) -> String {
        String(format: localize(ungroupAllFoldersConfirmInfoFormatKey), folderCount)
    }

    public static func dissolveConfirmCancelButtonTitle(
        localize: (String) -> String = { $0 }
    ) -> String {
        AppBatchUninstallPlan.confirmCancelButtonTitle(localize: localize)
    }

    public static func dissolveConfirmDestructiveButtonTitle(
        localize: (String) -> String = { $0 }
    ) -> String {
        localize(dissolveConfirmButtonTitleKey)
    }
    public static let batchDissolveFoldersAccessibilityHelpKey = "把所选文件夹里的应用放回各自位置"

    // MARK: Batch move selected folders to edge (BATCH-SELECTED-FOLDERS-EDGE-01)

    /// Move only the given top-level folders to the start or end of the grid,
    /// preserving relative order among those folders and among everything else.
    /// Nil when fewer than 2 valid top-level folders would move, or order unchanged.
    public static func movingSelectedFoldersToEdge(
        folderIDs: [UUID],
        atStart: Bool,
        in state: LayoutState
    ) -> LayoutState? {
        let wanted = Set(folderIDs)
        guard wanted.count >= 2 else { return nil }
        var selected: [LauncherEntry] = []
        var rest: [LauncherEntry] = []
        var seen = Set<UUID>()
        for entry in state.orderedEntries {
            if case .folder(let id) = entry,
               wanted.contains(id),
               state.folders[id] != nil,
               seen.insert(id).inserted {
                selected.append(entry)
            } else {
                rest.append(entry)
            }
        }
        guard selected.count >= 2 else { return nil }
        let reordered = atStart ? selected + rest : rest + selected
        guard reordered != state.orderedEntries else { return nil }
        var next = state
        next.orderedEntries = reordered
        next.updatedAt = .now
        return next
    }

    public static let selectedFoldersMovedToStartMenuTitleKey = "所选文件夹移到最前"
    public static let selectedFoldersMovedToEndMenuTitleKey = "所选文件夹移到最后"
    public static let selectedFoldersMovedToStartToastFormatKey = "已将 %d 个文件夹移到最前"
    public static let selectedFoldersMovedToEndToastFormatKey = "已将 %d 个文件夹移到最后"
    public static let selectedFoldersMovedToEdgeAccessibilityHelpKey = "只移动选中的文件夹，其它图标相对顺序不变"


    // MARK: Batch move selected apps to edge (BATCH-SELECTED-APPS-EDGE-01)

    /// Top-level app ids in `selection` (selection order, de-duped).
    /// Nil unless `anchorID` is in a ≥2 selection that contains ≥2 top-level
    /// apps, and the anchor itself is one of those apps.
    public static func appIDsForBatchEdgeMove(
        selection: LauncherItemSelection,
        anchorID: UUID,
        in state: LayoutState
    ) -> [UUID]? {
        guard selection.count > 1, selection.contains(anchorID) else { return nil }
        let topLevelApps = Set(state.orderedEntries.compactMap { entry -> UUID? in
            if case .app(let id) = entry { return id }
            return nil
        })
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for id in selection.orderedIDs where topLevelApps.contains(id) && seen.insert(id).inserted {
            ids.append(id)
        }
        guard ids.count >= 2, ids.contains(anchorID) else { return nil }
        return ids
    }

    /// Move only the given top-level apps to the start or end of the grid,
    /// preserving relative order among those apps and among everything else.
    /// Nil when fewer than 2 valid top-level apps would move, or order unchanged.
    public static func movingSelectedAppsToEdge(
        appIDs: [UUID],
        atStart: Bool,
        in state: LayoutState
    ) -> LayoutState? {
        let wanted = Set(appIDs)
        guard wanted.count >= 2 else { return nil }
        var selected: [LauncherEntry] = []
        var rest: [LauncherEntry] = []
        var seen = Set<UUID>()
        for entry in state.orderedEntries {
            if case .app(let id) = entry,
               wanted.contains(id),
               seen.insert(id).inserted {
                selected.append(entry)
            } else {
                rest.append(entry)
            }
        }
        guard selected.count >= 2 else { return nil }
        let reordered = atStart ? selected + rest : rest + selected
        guard reordered != state.orderedEntries else { return nil }
        var next = state
        next.orderedEntries = reordered
        next.updatedAt = .now
        return next
    }

    public static let selectedAppsMovedToStartMenuTitleKey = "所选应用移到最前"
    public static let selectedAppsMovedToEndMenuTitleKey = "所选应用移到最后"
    public static let selectedAppsMovedToStartToastFormatKey = "已将 %d 个应用移到最前"
    public static let selectedAppsMovedToEndToastFormatKey = "已将 %d 个应用移到最后"
    public static let selectedAppsMovedToEdgeAccessibilityHelpKey = "只移动选中的应用，其它图标相对顺序不变"


    // MARK: Blank-area move selected top-level entries (BATCH-BLANK-SELECTED-EDGE-01)

    /// Top-level entry ids (apps + folders) in `selection`, selection order.
    public static func topLevelEntryIDsInSelection(
        selection: LauncherItemSelection,
        in state: LayoutState
    ) -> [UUID] {
        let topLevel = Set(state.orderedEntries.map(\.id))
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for id in selection.orderedIDs where topLevel.contains(id) && seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    /// Move the given top-level entries (apps and/or folders) to the start or
    /// end, preserving relative order among them and among the rest.
    /// Nil when fewer than 2 valid ids would move, or order unchanged.
    public static func movingSelectedTopLevelEntriesToEdge(
        entryIDs: [UUID],
        atStart: Bool,
        in state: LayoutState
    ) -> LayoutState? {
        let wanted = Set(entryIDs)
        guard wanted.count >= 2 else { return nil }
        var selected: [LauncherEntry] = []
        var rest: [LauncherEntry] = []
        var seen = Set<UUID>()
        for entry in state.orderedEntries {
            if wanted.contains(entry.id), seen.insert(entry.id).inserted {
                selected.append(entry)
            } else {
                rest.append(entry)
            }
        }
        guard selected.count >= 2 else { return nil }
        let reordered = atStart ? selected + rest : rest + selected
        guard reordered != state.orderedEntries else { return nil }
        var next = state
        next.orderedEntries = reordered
        next.updatedAt = .now
        return next
    }

    public static let blankSelectedMovedToStartMenuTitleKey = "所选项目移到最前"
    public static let blankSelectedMovedToEndMenuTitleKey = "所选项目移到最后"
    public static let blankSelectedMovedToStartToastFormatKey = "已将 %d 个项目移到最前"
    public static let blankSelectedMovedToEndToastFormatKey = "已将 %d 个项目移到最后"
    public static let blankSelectedMovedToEdgeAccessibilityHelpKey = "只移动当前多选的图标，其它相对顺序不变"


    /// Blank-area ungroup-all / folders-to-edge (and other `commitReorganizedLayout`
    /// paths): drop multi-select so chrome does not keep stale folder ids.
    public static func shouldClearSelectionAfterReorganize(selectionCount: Int) -> Bool {
        selectionCount > 0
    }


    // MARK: Blank-area context menu (LaunchOS parity: settings / reorganize / quit)

    /// Right-click on empty grid space. Never while searching, inside an open
    /// folder, during a drag, while a page turn is in flight, or while the
    /// launcher is leaving — the menu must not race paging or drop code.
    public static func showsBlankAreaContextMenu(
        isSearching: Bool,
        folderOpen: Bool,
        isDragging: Bool,
        isPaging: Bool,
        isDismissing: Bool
    ) -> Bool {
        !isSearching && !folderOpen && !isDragging && !isPaging && !isDismissing
    }

    /// Wallpaper / empty-grid left click: clear multi-select instead of
    /// dismissing when something is selected (Escape parity; Launchpad-like).
    /// Marquee activation, folder dimmer, and paging gates stay in Direct.
    public static func shouldClearSelectionInsteadOfDismiss(selectionCount: Int) -> Bool {
        selectionCount > 0
    }

    /// Entering search from the idle grid: drop multi-select so result tiles
    /// do not keep grid-selection chrome. Leaving search / ⌘A-in-search stay
    /// on existing Direct paths.
    public static func shouldClearSelectionWhenEnteringSearch(
        wasSearching: Bool,
        isSearchingNow: Bool,
        selectionCount: Int
    ) -> Bool {
        !wasSearching && isSearchingNow && selectionCount > 0
    }

    /// Hide / hotkey / launch-dismiss: drop multi-select so the next show
    /// starts with empty chrome. Esc and blank-click already clear before
    /// dismiss; this covers paths that hide while selection remains.
    public static func shouldClearSelectionOnDismiss(selectionCount: Int) -> Bool {
        selectionCount > 0
    }

    /// Opening Settings: drop multi-select so chrome does not linger under the
    /// settings window; Esc-clear / blank-clear paths stay unchanged.
    public static func shouldClearSelectionWhenOpeningSettings(selectionCount: Int) -> Bool {
        selectionCount > 0
    }

    /// Opening a folder panel: drop grid multi-select so chrome does not
    /// linger under the veil; folder members start unselected. Closing
    /// still uses existing prune / Esc paths.
    public static func shouldClearSelectionWhenOpeningFolder(selectionCount: Int) -> Bool {
        selectionCount > 0
    }

    /// Closing a folder panel: drop any multi-select (often folder members)
    /// so grid chrome does not keep orphan highlights after the veil lifts.
    public static func shouldClearSelectionWhenClosingFolder(selectionCount: Int) -> Bool {
        selectionCount > 0
    }

    /// Layout editing turned off (scan incomplete / read-only): drop
    /// multi-select because batch rearrange menus are unavailable.
    public static func shouldClearSelectionWhenLayoutEditingDisabled(
        wasEnabled: Bool,
        isEnabledNow: Bool,
        selectionCount: Int
    ) -> Bool {
        wasEnabled && !isEnabledNow && selectionCount > 0
    }

    /// 「解散所有文件夹」: every top-level folder is replaced in place by its
    /// members (same rule as the folder menu). Nil when there is no folder.
    public static func ungroupAllFolders(in state: LayoutState) -> LayoutState? {
        let folderIDs = state.orderedEntries.compactMap { entry -> UUID? in
            if case .folder(let id) = entry, state.folders[id] != nil { return id }
            return nil
        }
        guard !folderIDs.isEmpty else { return nil }
        var next = state
        for id in folderIDs {
            if let dissolved = dissolveFolder(id, in: next) {
                next = dissolved
            }
        }
        return next
    }

    /// 「文件夹移到最前/最后」: stable partition of top-level entries; apps
    /// and folders each keep their relative order. Nil when nothing moves.
    public static func movingFoldersToEdge(atStart: Bool, in state: LayoutState) -> LayoutState? {
        let folders = state.orderedEntries.filter { if case .folder = $0 { return true }; return false }
        let apps = state.orderedEntries.filter { if case .folder = $0 { return false }; return true }
        let reordered = atStart ? folders + apps : apps + folders
        guard !folders.isEmpty, reordered != state.orderedEntries else { return nil }
        var next = state
        next.orderedEntries = reordered
        next.updatedAt = .now
        return next
    }

    public static func topLevelFolderCount(in state: LayoutState) -> Int {
        state.orderedEntries.reduce(0) { count, entry in
            if case .folder(let id) = entry, state.folders[id] != nil { return count + 1 }
            return count
        }
    }

    public static let ungroupAllFoldersToastMessageFormatKey = "已解散 %d 个文件夹"

    /// Blank-area「整理布局 ▸ 按名称/按类型排列…」reuses the settings one-shot
    /// rearrange. Disabled (false) when the sort would not move anything.
    public static func rearrangeWouldChange(
        in state: LayoutState,
        catalog: [AppCandidate],
        sort: GridRearrangeSort
    ) -> Bool {
        rearrangeTopLevelEntries(in: state, catalog: catalog, sort: sort).orderedEntries != state.orderedEntries
    }

    public static func blankAreaRearrangeMenuTitleKey(sort: GridRearrangeSort) -> String {
        switch sort {
        case .byName: return "按名称排列…"
        case .byKind: return "按类型排列…"
        }
    }
    public static let foldersMovedToStartToastKey = "文件夹已移到最前"
    public static let foldersMovedToEndToastKey = "文件夹已移到最后"

    /// Top-level apps from `selection` that sit on the same page as `folderID`
    /// and can be batch-moved into that existing folder (excludes the folder id).
    /// Empty when the folder is missing or not on a page with other selected apps.
    public static func topLevelAppIDsForBatchMoveIntoFolder(
        selection: LauncherItemSelection,
        folderID: UUID,
        in state: LayoutState
    ) -> [UUID] {
        guard state.folders[folderID] != nil,
              let folderIndex = state.orderedEntries.firstIndex(of: .folder(folderID)) else {
            return []
        }
        let page = pageIndex(containingEntryAt: folderIndex)
        let pageIDs = Set(itemIDs(onPage: page, from: state.orderedEntries))
        guard pageIDs.contains(folderID) else { return [] }
        return topLevelAppIDsForBatchFolder(selection: selection, in: state)
            .filter { $0 != folderID && pageIDs.contains($0) }
    }

    /// Multi-select drag onto an existing folder tile: batch when the dragged
    /// app is in the selection and ≥2 same-page top-level apps would move.
    public static func shouldBatchMoveSelectionIntoFolder(
        selection: LauncherItemSelection,
        draggedID: UUID,
        folderID: UUID,
        in state: LayoutState
    ) -> Bool {
        guard state.folders[folderID] != nil else { return false }
        guard selection.contains(draggedID) else { return false }
        let apps = topLevelAppIDsForBatchMoveIntoFolder(
            selection: selection,
            folderID: folderID,
            in: state
        )
        return apps.count >= 2 && apps.contains(draggedID)
    }

    /// Same-page top-level apps for a new folder from multi-select drop onto an
    /// **app** tile: drop target first, then selected apps (selection order).
    /// Excludes folders; empty when target is missing or is already a folder.
    public static func topLevelAppIDsForBatchCreateFolder(
        selection: LauncherItemSelection,
        targetAppID: UUID,
        in state: LayoutState
    ) -> [UUID] {
        guard state.folders[targetAppID] == nil,
              state.orderedEntries.contains(.app(targetAppID)),
              let targetIndex = state.orderedEntries.firstIndex(of: .app(targetAppID)) else {
            return []
        }
        let page = pageIndex(containingEntryAt: targetIndex)
        let pageIDs = Set(itemIDs(onPage: page, from: state.orderedEntries))
        guard pageIDs.contains(targetAppID) else { return [] }

        var apps: [UUID] = [targetAppID]
        var seen: Set<UUID> = [targetAppID]
        for id in topLevelAppIDsForBatchFolder(selection: selection, in: state)
        where pageIDs.contains(id) && seen.insert(id).inserted {
            apps.append(id)
        }
        return apps
    }

    /// Multi-select drag onto an **app** tile: batch-create a folder when the
    /// dragged app is selected and ≥1 other same-page selected app will join
    /// (plus the drop target). Single-item selection stays on `applyDrop` merge.
    public static func shouldBatchCreateFolderFromSelection(
        selection: LauncherItemSelection,
        draggedID: UUID,
        targetAppID: UUID,
        in state: LayoutState
    ) -> Bool {
        guard draggedID != targetAppID else { return false }
        guard selection.contains(draggedID) else { return false }
        guard state.folders[targetAppID] == nil else { return false }
        guard state.orderedEntries.contains(.app(targetAppID)) else { return false }
        guard state.orderedEntries.contains(.app(draggedID)),
              state.folders[draggedID] == nil else { return false }
        guard let targetIndex = state.orderedEntries.firstIndex(of: .app(targetAppID)) else {
            return false
        }
        let page = pageIndex(containingEntryAt: targetIndex)
        let pageIDs = Set(itemIDs(onPage: page, from: state.orderedEntries))
        let selectedOnPage = topLevelAppIDsForBatchFolder(selection: selection, in: state)
            .filter { pageIDs.contains($0) && $0 != targetAppID }
        // Need dragged + at least one other selected app on the page (not only clear single merge).
        guard selectedOnPage.contains(draggedID), selectedOnPage.count >= 2 else { return false }
        let apps = topLevelAppIDsForBatchCreateFolder(
            selection: selection,
            targetAppID: targetAppID,
            in: state
        )
        return apps.count >= 3 && apps.contains(draggedID) && apps.contains(targetAppID)
    }

    /// Append top-level apps into an existing folder (selection / call order).
    /// Folder tile stays; apps leave the top-level grid. Skips ids already inside.
    public static func moveTopLevelApps(
        _ orderedAppIDs: [UUID],
        intoFolder folderID: UUID,
        in state: LayoutState
    ) -> Result<LayoutState, LayoutMutationError> {
        guard state.folders[folderID] != nil else { return .failure(.missingTarget) }
        guard state.orderedEntries.contains(.folder(folderID)) else {
            return .failure(.missingTarget)
        }

        var seen = Set<UUID>()
        var apps: [UUID] = []
        for id in orderedAppIDs where seen.insert(id).inserted {
            guard id != folderID else { continue }
            guard state.folders[id] == nil else { return .failure(.nestedFolder) }
            guard state.orderedEntries.contains(.app(id)) else {
                return .failure(.missingSource)
            }
            if state.folders[folderID]?.itemIDs.contains(id) == true { continue }
            apps.append(id)
        }
        guard !apps.isEmpty else { return .success(state) }

        var state = state
        for id in apps {
            guard let index = state.orderedEntries.firstIndex(of: .app(id)) else {
                return .failure(.missingSource)
            }
            _ = state.orderedEntries.remove(at: index)
            guard var folder = state.folders[folderID] else { return .failure(.missingTarget) }
            if !folder.itemIDs.contains(id) {
                folder.itemIDs.append(id)
                state.folders[folderID] = folder
            }
        }
        state.updatedAt = .now
        return .success(state)
    }

    /// Multi-select group reorder (MULTI-DRAG-REORDER-CORE-01 + WIRE-01).
    /// Moves ≥2 **top-level** entries (apps and/or folders) as one contiguous
    /// block to `insertAt` in `orderedEntries` (`0...count`, same as
    /// `reorderGapIndex`). Block order follows current grid order among the
    /// selected ids (not click order). Nil when any id is missing/not
    /// top-level, `insertAt` is out of range, fewer than two distinct ids, or
    /// the move would leave `orderedEntries` unchanged. Does not touch folder
    /// membership, aliases, hidden keys, or paging.
    /// MULTI-DRAG-BADGE-01: count for the drag-image badge when the drag
    /// source is part of a multi-selection of top-level items. Nil when the
    /// badge should stay hidden (single selection, folder-member drag, or
    /// drag source not in the selection). Does not touch paging.
    public static func multiDragBadgeCount(
        selection: LauncherItemSelection,
        draggedID: UUID,
        in state: LayoutState
    ) -> Int? {
        guard selection.contains(draggedID), selection.count >= 2 else { return nil }
        let topLevel = Set(state.orderedEntries.map(\.id))
        let ids = selection.orderedIDs.filter { topLevel.contains($0) }
        guard ids.count >= 2, ids.contains(draggedID) else { return nil }
        return ids.count
    }

    /// MULTI-DRAG-REORDER-WIRE-01: same-page top-level ids (apps + folders)
    /// eligible for group reorder. Grid membership only; Core still sorts the
    /// moving block by current `orderedEntries` order. Empty when the drop
    /// gap is off the dragged item's page, selection has fewer than two
    /// same-page top-level ids, or the drag source is not in the selection.
    public static func topLevelIDsForBatchReorder(
        selection: LauncherItemSelection,
        draggedID: UUID,
        insertAt: Int,
        in state: LayoutState
    ) -> [UUID] {
        guard selection.contains(draggedID) else { return [] }
        guard let dragIndex = state.orderedEntries.firstIndex(where: { $0.id == draggedID }) else {
            return []
        }
        let page = pageIndex(containingEntryAt: dragIndex)
        let pageStart = page * pageCapacity
        let pageEnd = min((page + 1) * pageCapacity, state.orderedEntries.count)
        guard insertAt >= pageStart, insertAt <= pageEnd else { return [] }
        let pageIDs = Set(itemIDs(onPage: page, from: state.orderedEntries))
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for id in selection.orderedIDs where pageIDs.contains(id) && seen.insert(id).inserted {
            ids.append(id)
        }
        guard ids.count >= 2, ids.contains(draggedID) else { return [] }
        return ids
    }

    /// True when a multi-select gap drop should move the whole same-page block.
    public static func shouldBatchReorderSelection(
        selection: LauncherItemSelection,
        draggedID: UUID,
        insertAt: Int,
        in state: LayoutState
    ) -> Bool {
        let ids = topLevelIDsForBatchReorder(
            selection: selection,
            draggedID: draggedID,
            insertAt: insertAt,
            in: state
        )
        return ids.count >= 2 && ids.contains(draggedID)
    }

    /// MULTI-DRAG-REORDER-CORE-01: move ≥2 top-level entries as one block.
    public static func reorderingTopLevelSelection(
        _ orderedIDs: [UUID],
        insertAt: Int,
        in state: LayoutState
    ) -> LayoutState? {
        var seen = Set<UUID>()
        var unique: [UUID] = []
        for id in orderedIDs where seen.insert(id).inserted {
            unique.append(id)
        }
        guard unique.count >= 2 else { return nil }
        guard (0...state.orderedEntries.count).contains(insertAt) else { return nil }

        var indexByID: [UUID: Int] = [:]
        var entryByID: [UUID: LauncherEntry] = [:]
        for (index, entry) in state.orderedEntries.enumerated() {
            indexByID[entry.id] = index
            entryByID[entry.id] = entry
        }
        for id in unique {
            guard indexByID[id] != nil, entryByID[id] != nil else { return nil }
        }

        // Visual group: keep relative grid order inside the block.
        let sortedIDs = unique.sorted { indexByID[$0]! < indexByID[$1]! }
        let block = sortedIDs.map { entryByID[$0]! }
        let removalIndices = sortedIDs.map { indexByID[$0]! }.sorted()

        var next = state
        var insert = insertAt
        for index in removalIndices.reversed() {
            next.orderedEntries.remove(at: index)
            if index < insert { insert -= 1 }
        }
        insert = min(max(insert, 0), next.orderedEntries.count)
        next.orderedEntries.insert(contentsOf: block, at: insert)
        guard next.orderedEntries != state.orderedEntries else { return nil }
        next.updatedAt = .now
        return next
    }

    /// After a tile is hidden, put keyboard on the next remaining id, else the previous.
    public static func focusItemIDAfterHiding(
        hiddenID: UUID,
        remainingIDs: [UUID],
        previousOrderedIDs: [UUID]
    ) -> UUID? {
        guard !remainingIDs.isEmpty else { return nil }
        if let index = previousOrderedIDs.firstIndex(of: hiddenID) {
            let after = previousOrderedIDs[(index + 1)...].first { remainingIDs.contains($0) }
            if let after { return after }
            let before = previousOrderedIDs[..<index].reversed().first { remainingIDs.contains($0) }
            if let before { return before }
        }
        return remainingIDs.first
    }

    public static func hideApplication(withKey key: String, in state: LayoutState) -> LayoutState {
        guard !key.isEmpty else { return state }
        var state = state
        state.hiddenAppKeys.insert(key)
        let hiddenIDs = Set(state.appKeys.compactMap { $0.value == key ? $0.key : nil })
        state.orderedEntries.removeAll { entry in
            if case .app(let id) = entry { return hiddenIDs.contains(id) }
            return false
        }
        for folderID in Array(state.folders.keys) {
            state.folders[folderID]?.itemIDs.removeAll { hiddenIDs.contains($0) }
            dissolveIfNeeded(folderID, in: &state)
        }
        for id in hiddenIDs {
            state.appKeys.removeValue(forKey: id)
        }
        state.updatedAt = .now
        return state
    }

    public static func restoreApplication(withKey key: String, in state: LayoutState) -> LayoutState {
        var state = state
        guard state.hiddenAppKeys.remove(key) != nil else { return state }
        state.updatedAt = .now
        return state
    }

    /// Settings「全部恢复」: un-hide every hidden app in one layout change
    /// (one backup, one write). Nil when nothing is hidden. Callers reconcile
    /// afterwards so the apps reappear at the end, like a single restore.
    public static func restoringAllHiddenApplications(in state: LayoutState) -> LayoutState? {
        guard !state.hiddenAppKeys.isEmpty else { return nil }
        var state = state
        state.hiddenAppKeys.removeAll()
        state.updatedAt = .now
        return state
    }

    public static let restoreAllHiddenButtonTitleKey = "全部恢复"
    public static let restoreAllHiddenAccessibilityHelpKey = "把所有隐藏的应用放回启动器"
    public static let restoredAllHiddenMessageFormatKey = "已恢复 %d 个应用"
    /// Shown only with two or more hidden apps; one app uses the plain「恢复」.
    public static func settingsShowsRestoreAllHidden(hiddenCount: Int) -> Bool { hiddenCount >= 2 }

    /// SETTINGS-HIDDEN-APPS-CHROME-COPY-01 — Settings hidden-apps row chrome.
    public enum SettingsHiddenAppsChromeCopy {
        public static let rowTitleKey = "隐藏的应用"
        public static let emptyPopupTitleKey = "没有隐藏的应用"
        public static let restoreButtonTitleKey = "恢复"
        public static let restoreAccessibilityLabelKey = "恢复所选应用"
        public static let restoreAccessibilityHelpKey = "把隐藏的应用放回启动器"
        public static let restoreUnavailableKey = "当前无法恢复该应用，请等待扫描完成后重试。"
        public static let restoredGenericKey = "已恢复应用"
        /// Same wording as blank-area restore toast.
        public static let restoredNamedFormatKey = "已恢复“%@”"

        public static func rowTitle(localize: (String) -> String = { $0 }) -> String {
            localize(rowTitleKey)
        }
        public static func emptyPopupTitle(localize: (String) -> String = { $0 }) -> String {
            localize(emptyPopupTitleKey)
        }
        public static func restoreButtonTitle(localize: (String) -> String = { $0 }) -> String {
            localize(restoreButtonTitleKey)
        }
        public static func restoreAccessibilityLabel(localize: (String) -> String = { $0 }) -> String {
            localize(restoreAccessibilityLabelKey)
        }
        public static func restoreAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
            localize(restoreAccessibilityHelpKey)
        }
        public static func restoreUnavailable(localize: (String) -> String = { $0 }) -> String {
            localize(restoreUnavailableKey)
        }
        public static func restoredGeneric(localize: (String) -> String = { $0 }) -> String {
            localize(restoredGenericKey)
        }
        public static func restoredNamed(
            displayName: String,
            localize: (String) -> String = { $0 }
        ) -> String {
            String(format: localize(restoredNamedFormatKey), displayName)
        }
    }

    /// Blank-area「隐藏的应用 ▸」: at most this many names; the rest live in Settings.
    public static let blankAreaHiddenAppsMenuLimit = 20
    public static let blankAreaSelectAllMenuTitleKey = "选择本页全部"
    /// Blank-area「清除选择」when multi-select chrome is non-empty.
    public static let blankAreaClearSelectionMenuTitleKey = "清除选择"
    public static let blankAreaHiddenAppsMenuTitleKey = "隐藏的应用"
    public static let blankAreaHiddenAppsMoreTitleKey = "在设置中查看全部…"
    public static let restoredHiddenAppToastFormatKey = "已恢复“%@”"

    /// Items to list (input order) and whether a「在设置中查看全部…」row is needed.
    public static func blankAreaHiddenAppsMenuEntries<Element>(_ hidden: [Element]) -> (shown: [Element], hasMore: Bool) {
        let limit = max(0, blankAreaHiddenAppsMenuLimit)
        return (Array(hidden.prefix(limit)), hidden.count > limit)
    }

    public static func applyDrop(
        _ drop: LayoutDrop,
        to state: LayoutState,
        newFolderName: String = "新建文件夹"
    ) -> Result<LayoutState, LayoutMutationError> {
        switch drop.destination {
        case .topLevelIndex(let index):
            return moveToTopLevel(source: drop.source, index: index, in: state)
        case .merge(let target):
            return merge(source: drop.source, onto: target, in: state, newFolderName: newFolderName)
        case .folderIndex(let folderID, let index):
            return moveIntoFolder(source: drop.source, folderID: folderID, index: index, in: state)
        }
    }

    private static func moveToTopLevel(source: LayoutItemRef, index: Int, in state: LayoutState) -> Result<LayoutState, LayoutMutationError> {
        var state = state
        let sourceIndex: Int? = {
            if case .topLevel(let id) = source {
                return state.orderedEntries.firstIndex(where: { $0.id == id })
            }
            return nil
        }()
        let insertAt = insertionIndexAfterRemovingSource(
            sourceIndex: sourceIndex,
            proposedIndex: index,
            countBeforeRemoval: state.orderedEntries.count
        )
        if sourceIndex == insertAt { return .success(state) }
        switch extract(source, from: &state) {
        case .failure(let error):
            return .failure(error)
        case .success(let entry):
            state.orderedEntries.insert(entry, at: min(insertAt, state.orderedEntries.count))
            state.updatedAt = .now
            return .success(state)
        }
    }

    private static func moveIntoFolder(
        source: LayoutItemRef,
        folderID: UUID,
        index: Int,
        in state: LayoutState
    ) -> Result<LayoutState, LayoutMutationError> {
        if case .topLevel(let id) = source, state.folders[id] != nil {
            return .failure(.nestedFolder)
        }
        if case .topLevel(let id) = source, id == folderID {
            return .failure(.cannotDropOnSelf)
        }

        var state = state
        let sourceAppID: UUID
        switch source {
        case .topLevel(let id):
            guard case .app = state.orderedEntries.first(where: { $0.id == id }) else {
                return .failure(state.folders[id] == nil ? .missingSource : .nestedFolder)
            }
            sourceAppID = id
        case .folderMember(_, let itemID):
            sourceAppID = itemID
        }

        if case .folderMember(let currentFolder, _) = source, currentFolder == folderID {
            guard var folder = state.folders[folderID],
                  let from = folder.itemIDs.firstIndex(of: sourceAppID) else {
                return .failure(.missingSource)
            }
            let insertAt = insertionIndexAfterRemovingSource(
                sourceIndex: from,
                proposedIndex: index,
                countBeforeRemoval: folder.itemIDs.count
            )
            if from == insertAt { return .success(state) }
            folder.itemIDs.remove(at: from)
            folder.itemIDs.insert(sourceAppID, at: min(insertAt, folder.itemIDs.count))
            state.folders[folderID] = folder
            state.updatedAt = .now
            return .success(state)
        }

        guard let folder = state.folders[folderID] else { return .failure(.missingTarget) }

        let insertAt = insertionIndexAfterRemovingSource(
            sourceIndex: nil,
            proposedIndex: index,
            countBeforeRemoval: folder.itemIDs.count
        )
        switch extract(source, from: &state) {
        case .failure(let error):
            return .failure(error)
        case .success(let entry):
            guard case .app(let appID) = entry else { return .failure(.nestedFolder) }
            guard var liveFolder = state.folders[folderID] else { return .failure(.missingTarget) }
            liveFolder.itemIDs.insert(appID, at: min(insertAt, liveFolder.itemIDs.count))
            state.folders[folderID] = liveFolder
            state.updatedAt = .now
            return .success(state)
        }
    }

    private static func merge(source: LayoutItemRef, onto target: LayoutItemRef, in state: LayoutState, newFolderName: String) -> Result<LayoutState, LayoutMutationError> {
        guard source != target else { return .failure(.cannotDropOnSelf) }
        if isFolder(source, in: state) {
            return .failure(.nestedFolder)
        }

        switch target {
        case .folderMember:
            return .failure(.nestedFolder)
        case .topLevel(let targetID):
            if state.folders[targetID] != nil {
                return add(source: source, toFolder: targetID, in: state)
            }
            return createFolder(from: source, ontoApp: targetID, in: state, name: newFolderName)
        }
    }

    private static func add(source: LayoutItemRef, toFolder folderID: UUID, in state: LayoutState) -> Result<LayoutState, LayoutMutationError> {
        var state = state
        guard state.folders[folderID] != nil else { return .failure(.missingTarget) }
        switch extract(source, from: &state) {
        case .failure(let error):
            return .failure(error)
        case .success(let entry):
            guard case .app(let appID) = entry else { return .failure(.nestedFolder) }
            guard var liveFolder = state.folders[folderID] else { return .failure(.missingTarget) }
            if liveFolder.itemIDs.contains(appID) { return .failure(.cannotDropOnSelf) }
            liveFolder.itemIDs.append(appID)
            state.folders[folderID] = liveFolder
            state.updatedAt = .now
            return .success(state)
        }
    }

    private static func createFolder(from source: LayoutItemRef, ontoApp targetID: UUID, in state: LayoutState, name: String) -> Result<LayoutState, LayoutMutationError> {
        guard state.orderedEntries.contains(.app(targetID)) || folderContains(targetID, in: state) else {
            return .failure(.missingTarget)
        }
        if isFolder(.topLevel(targetID), in: state) {
            return .failure(.nestedFolder)
        }

        var state = state
        let targetIndex = state.orderedEntries.firstIndex(of: .app(targetID))
        switch extract(source, from: &state) {
        case .failure(let error):
            return .failure(error)
        case .success(let entry):
            guard case .app(let sourceID) = entry else { return .failure(.nestedFolder) }
            guard sourceID != targetID else { return .failure(.cannotDropOnSelf) }

            let folderID = uniqueFolderID(in: state)
            let insertionIndex: Int
            if let remainingIndex = state.orderedEntries.firstIndex(of: .app(targetID)) {
                state.orderedEntries.remove(at: remainingIndex)
                insertionIndex = remainingIndex
            } else if let targetIndex {
                insertionIndex = min(targetIndex, state.orderedEntries.count)
            } else {
                return .failure(.missingTarget)
            }

            let folder = LauncherFolder(id: folderID, name: name, itemIDs: [targetID, sourceID])
            state.folders[folderID] = folder
            state.orderedEntries.insert(.folder(folderID), at: min(insertionIndex, state.orderedEntries.count))
            state.updatedAt = .now
            return .success(state)
        }
    }

    private static func extract(_ source: LayoutItemRef, from state: inout LayoutState) -> Result<LauncherEntry, LayoutMutationError> {
        switch source {
        case .topLevel(let id):
            guard let index = state.orderedEntries.firstIndex(where: { $0.id == id }) else {
                return .failure(.missingSource)
            }
            return .success(state.orderedEntries.remove(at: index))
        case .folderMember(let folderID, let itemID):
            guard var folder = state.folders[folderID],
                  let memberIndex = folder.itemIDs.firstIndex(of: itemID) else {
                return .failure(.missingSource)
            }
            folder.itemIDs.remove(at: memberIndex)
            state.folders[folderID] = folder
            dissolveIfNeeded(folderID, in: &state)
            return .success(.app(itemID))
        }
    }

    private static func dissolveIfNeeded(_ folderID: UUID, in state: inout LayoutState) {
        guard let folder = state.folders[folderID], folder.itemIDs.count <= 1 else { return }
        guard let folderIndex = state.orderedEntries.firstIndex(of: .folder(folderID)) else {
            state.folders[folderID] = nil
            return
        }
        if let remaining = folder.itemIDs.first {
            state.orderedEntries[folderIndex] = .app(remaining)
        } else {
            state.orderedEntries.remove(at: folderIndex)
        }
        state.folders[folderID] = nil
    }

    private static func isFolder(_ ref: LayoutItemRef, in state: LayoutState) -> Bool {
        switch ref {
        case .folderMember:
            return false
        case .topLevel(let id):
            return state.folders[id] != nil
        }
    }

    private static func folderContains(_ itemID: UUID, in state: LayoutState) -> Bool {
        state.folders.values.contains { $0.itemIDs.contains(itemID) }
    }

    private static func uniqueFolderID(in state: LayoutState) -> UUID {
        var id = UUID()
        while state.appKeys[id] != nil || state.folders[id] != nil {
            id = UUID()
        }
        return id
    }
}

// MARK: - Category sort (CATEGORY-SORT-CORE-01)

/// Coarse groups for `LSApplicationCategoryType`. Raw value is the sort rank.
public enum AppCategoryGroup: Int, CaseIterable, Comparable, Sendable {
    case productivity
    case developerTools
    case creativity
    case entertainment
    case social
    case utilities
    case games
    case education
    case lifestyle
    case other

    public static func < (lhs: AppCategoryGroup, rhs: AppCategoryGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Maps an Info.plist `LSApplicationCategoryType` value. Unknown or missing → `.other`.
    public static func group(forCategoryType categoryType: String?) -> AppCategoryGroup {
        let prefix = "public.app-category."
        guard let raw = categoryType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.hasPrefix(prefix) else { return .other }
        let name = String(raw.dropFirst(prefix.count))
        if name == "games" || name.hasSuffix("-games") { return .games }
        switch name {
        case "business", "productivity", "finance":
            return .productivity
        case "developer-tools":
            return .developerTools
        case "graphics-design", "photography", "video":
            return .creativity
        case "entertainment", "music", "news":
            return .entertainment
        case "social-networking":
            return .social
        case "utilities":
            return .utilities
        case "education", "reference", "books":
            return .education
        case "lifestyle", "healthcare-fitness", "medical", "sports", "travel", "weather":
            return .lifestyle
        default:
            return .other
        }
    }

    /// Localization key (zh source) for a future section label / toast.
    public var titleKey: String {
        switch self {
        case .productivity: return "效率与办公"
        case .developerTools: return "开发工具"
        case .creativity: return "创意设计"
        case .entertainment: return "影音娱乐"
        case .social: return "社交"
        case .utilities: return "实用工具"
        case .games: return "游戏"
        case .education: return "教育与参考"
        case .lifestyle: return "生活"
        case .other: return "其他"
        }
    }
}

extension LauncherLayout {
    /// Reads `LSApplicationCategoryType` from the bundle's Info.plist (or the
    /// first wrapped iOS app's). Read on demand so `AppCandidate` and the catalog
    /// cache stay unchanged.
    public static func applicationCategoryType(forAppAt url: URL) -> String? {
        func category(inPlist plistURL: URL) -> String? {
            guard let info = NSDictionary(contentsOf: plistURL) as? [String: Any],
                  let value = info["LSApplicationCategoryType"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        if let value = category(inPlist: url.appendingPathComponent("Contents/Info.plist")) {
            return value
        }
        let wrapper = url.appendingPathComponent("Wrapper", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: wrapper, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for child in children.sorted(by: { $0.path < $1.path }) where child.pathExtension.lowercased() == "app" {
            if let value = category(inPlist: child.appendingPathComponent("Info.plist")) {
                return value
            }
        }
        return nil
    }

    /// Reorders top-level entries by category group, then by display name
    /// (alias wins), then UUID. Folders go after every app group. Like
    /// `rearrangeTopLevelEntries`, it never touches folder contents, aliases,
    /// or paging. `categoryType` is injected so tests avoid the filesystem.
    public static func rearrangeTopLevelEntriesByCategory(
        in state: LayoutState,
        catalog: [AppCandidate],
        categoryType: (AppCandidate) -> String? = { applicationCategoryType(forAppAt: $0.canonicalURL) }
    ) -> LayoutState {
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        var groupCache: [UUID: Int] = [:]
        func rank(for entry: LauncherEntry) -> Int {
            if let cached = groupCache[entry.id] { return cached }
            let value: Int
            switch entry {
            case .folder:
                value = AppCategoryGroup.allCases.count
            case .app(let id):
                if let key = state.appKeys[id], let candidate = byKey[key] {
                    value = AppCategoryGroup.group(forCategoryType: categoryType(candidate)).rawValue
                } else {
                    value = AppCategoryGroup.other.rawValue
                }
            }
            groupCache[entry.id] = value
            return value
        }
        func displayName(for entry: LauncherEntry) -> String {
            switch entry {
            case .folder(let id):
                return state.folders[id]?.name ?? id.uuidString
            case .app(let id):
                guard let key = state.appKeys[id] else { return id.uuidString }
                if let alias = state.appAliases[key], !alias.isEmpty { return alias }
                return byKey[key]?.displayName ?? id.uuidString
            }
        }
        // Precompute ranks so the (possibly disk-reading) provider runs once per app.
        for entry in state.orderedEntries { _ = rank(for: entry) }

        var next = state
        next.orderedEntries.sort { lhs, rhs in
            let lr = rank(for: lhs)
            let rr = rank(for: rhs)
            if lr != rr { return lr < rr }
            let nameOrder = displayName(for: lhs).localizedStandardCompare(displayName(for: rhs))
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if next.orderedEntries != state.orderedEntries {
            next.updatedAt = .now
        }
        return next
    }
}

// MARK: - Marquee selection model (MARQUEE-CORE-01, Core only, not wired)

/// Rubber-band selection on the empty wallpaper of the *current page*.
/// Pure geometry + policy; Direct wiring is deferred. Paging is never driven
/// by a marquee: it is clamped to the visible page and never auto-scrolls.
public enum LauncherMarquee {
    /// Same threshold as the tile's item-drag start, so a plain click on the
    /// wallpaper (which dismisses the launcher) is never stolen by a marquee.
    public static let activationDistance: CGFloat = 8

    public enum Modifier: Equatable, Sendable {
        /// No modifier: hits replace the selection.
        case replace
        /// Shift: hits are added to the selection captured at mouse-down.
        case extend
        /// Command: hits flip membership relative to the mouse-down selection.
        case toggle
    }

    public struct ItemFrame: Equatable, Sendable {
        public let id: UUID
        public let frame: CGRect
        public init(id: UUID, frame: CGRect) {
            self.id = id
            self.frame = frame
        }
    }

    /// Command wins over Shift (matches the click model: ⌘ toggles).
    public static func modifier(command: Bool, shift: Bool) -> Modifier {
        if command { return .toggle }
        if shift { return .extend }
        return .replace
    }

    /// Whether a left-button press may *arm* a marquee. It still only starts
    /// after `hasActivated`. Main grid only (no search list, no open folder).
    public static func canArm(
        buttonNumber: Int,
        clickCount: Int,
        startsOnBlankArea: Bool,
        isSearching: Bool,
        folderOpen: Bool,
        isDragging: Bool,
        isPaging: Bool,
        isDismissing: Bool,
        isPromptingForAlias: Bool
    ) -> Bool {
        buttonNumber == 0 && clickCount == 1 && startsOnBlankArea
            && !isSearching && !folderOpen && !isDragging && !isPaging
            && !isDismissing && !isPromptingForAlias
    }

    public static func hasActivated(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= activationDistance
    }

    /// Standardized rect between two points (any drag direction).
    public static func rect(from start: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    /// Clamps the marquee to the visible page so it can never imply paging.
    public static func clamped(_ rect: CGRect, to pageBounds: CGRect) -> CGRect {
        let minX = max(rect.minX, pageBounds.minX)
        let minY = max(rect.minY, pageBounds.minY)
        let maxX = min(rect.maxX, pageBounds.maxX)
        let maxY = min(rect.maxY, pageBounds.maxY)
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Ids whose icon frame overlaps the marquee, in presented order. A thin
    /// (zero-width/height) marquee still hits frames it crosses; touching an
    /// edge only does not count.
    public static func hitIDs(in marquee: CGRect, items: [ItemFrame]) -> [UUID] {
        items.compactMap { item in
            let f = item.frame
            guard f.width > 0, f.height > 0 else { return nil }
            let overlaps = marquee.maxX > f.minX && marquee.minX < f.maxX
                && marquee.maxY > f.minY && marquee.minY < f.maxY
            return overlaps ? item.id : nil
        }
    }

    /// Live selection while dragging. Always derived from `base` (the
    /// selection captured at mouse-down) so shrinking the rect deselects.
    public static func selection(
        base: LauncherItemSelection,
        hits: [UUID],
        modifier: Modifier
    ) -> LauncherItemSelection {
        switch modifier {
        case .replace:
            return LauncherItemSelection(orderedIDs: hits, rangeAnchorID: hits.first)
        case .extend:
            let added = hits.filter { !base.contains($0) }
            return LauncherItemSelection(
                orderedIDs: base.orderedIDs + added,
                rangeAnchorID: base.rangeAnchorID ?? hits.first
            )
        case .toggle:
            let hitSet = Set(hits)
            let kept = base.orderedIDs.filter { !hitSet.contains($0) }
            let added = hits.filter { !base.contains($0) }
            let ids = kept + added
            let anchor = base.rangeAnchorID.flatMap { ids.contains($0) ? $0 : nil } ?? added.first
            return LauncherItemSelection(orderedIDs: ids, rangeAnchorID: anchor)
        }
    }

    /// A release after an activated marquee must not count as a wallpaper
    /// click (which would dismiss the launcher).
    public static func suppressesDismissOnRelease(didActivate: Bool) -> Bool {
        didActivate
    }
}

// MARK: - Layout import hardening (LAYOUT-IMPORT-HARDENING-01)

extension LauncherLayout {
    /// Folder-name / alias limits used by the in-app editors.
    public static let maximumFolderNameLength = 40
    public static let maximumAliasLength = 60

    /// Replaces each run of newlines/tabs/other control characters with one space,
    /// trims, and clamps to `limit` characters.
    public static func sanitizedImportedName(_ raw: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasControl = false
        for scalar in raw.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
            if isControl {
                // A run of control characters becomes one space; ordinary
                // spaces typed by the user are kept as-is.
                if !lastWasControl { scalars.append(" ") }
                lastWasControl = true
            } else {
                scalars.append(scalar)
                lastWasControl = false
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }

    /// Cleans user-editable strings in an imported file. Structure is left to
    /// `reconcile`; `updatedAt` is not bumped, and a clean file is unchanged.
    public static func sanitizedImportedLayout(_ state: LayoutState) -> LayoutState {
        var next = state
        for (id, folder) in state.folders {
            let name = sanitizedImportedName(folder.name, limit: maximumFolderNameLength)
            if name != folder.name {
                var cleaned = folder
                cleaned.name = name
                next.folders[id] = cleaned
            }
        }
        var aliases: [String: String] = [:]
        for (key, alias) in state.appAliases where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = sanitizedImportedName(alias, limit: maximumAliasLength)
            if !cleaned.isEmpty { aliases[key] = cleaned }
        }
        next.appAliases = aliases
        next.hiddenAppKeys = state.hiddenAppKeys.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return next
    }

    /// How an imported layout lines up with the apps installed *here*. For a
    /// later confirm/warning in Direct (not wired yet).
    public struct LayoutImportAssessment: Equatable, Sendable {
        /// Distinct app keys in the file that match an installed app.
        public let matchedAppCount: Int
        /// Distinct app keys in the file with no installed app (dropped by reconcile).
        public let unmatchedAppCount: Int
        public let folderCount: Int
        /// Installed apps the file would hide.
        public let hiddenInstalledAppCount: Int
        public let installedAppCount: Int

        /// File names apps but none are installed here (e.g. another Mac):
        /// importing would effectively reset the grid.
        public var looksForeign: Bool { matchedAppCount == 0 && unmatchedAppCount > 0 }
        /// Every installed app would be hidden → empty grid.
        public var hidesEverything: Bool { installedAppCount > 0 && hiddenInstalledAppCount >= installedAppCount }
        public var needsExtraConfirmation: Bool { looksForeign || hidesEverything }
    }

    public static func layoutImportAssessment(
        imported: LayoutState,
        catalog: [AppCandidate]
    ) -> LayoutImportAssessment {
        let installedKeys = Set(catalog.map(\.deduplicationKey))
        let fileKeys = Set(imported.appKeys.values)
        let matched = fileKeys.intersection(installedKeys).count
        return LayoutImportAssessment(
            matchedAppCount: matched,
            unmatchedAppCount: fileKeys.count - matched,
            folderCount: imported.folders.count,
            hiddenInstalledAppCount: imported.hiddenAppKeys.intersection(installedKeys).count,
            installedAppCount: installedKeys.count
        )
    }
}

// MARK: - Folder name suggestion (FOLDER-NAME-SUGGEST-CORE-01, not wired)

extension AppCategoryGroup {
    /// iOS / LaunchOS style default name when a folder is created from apps:
    /// the shared category title when at least two apps all map to the same
    /// group other than `.other`. Nil → keep the existing「新建文件夹」default.
    public static func suggestedFolderNameKey(forCategoryTypes categoryTypes: [String?]) -> String? {
        guard categoryTypes.count >= 2 else { return nil }
        let groups = Set(categoryTypes.map { group(forCategoryType: $0) })
        guard groups.count == 1, let only = groups.first, only != .other else { return nil }
        return only.titleKey
    }
}

// MARK: - Layout change summary (LAYOUT-CHANGE-SUMMARY-CORE-01, not wired)

/// What would change when `old` is replaced by `new` (import confirmation,
/// undo toasts). Apps are matched by app key, not tile UUID, because an
/// imported file may carry different ids; folders are matched by id.
public struct LayoutChangeSummary: Equatable, Sendable {
    /// Keys that change container (top level ↔ folder, or another folder).
    public var appsChangingContainer = 0
    /// Keys only present in `new` / only in `old` (placed tiles only).
    public var appsAdded = 0
    public var appsRemoved = 0
    /// Relative order of top-level apps/folders present in both differs.
    public var topLevelOrderChanged = false
    public var foldersAdded = 0
    public var foldersRemoved = 0
    public var foldersRenamed = 0
    public var newlyHidden = 0
    public var newlyShown = 0
    /// Alias added, removed or edited.
    public var aliasesChanged = 0

    public init() {}

    public var isEmpty: Bool { self == LayoutChangeSummary() }

    /// One clause of the post-import message. `count == nil` → plain key.
    public struct Detail: Equatable, Sendable {
        public let key: String
        public let count: Int?
    }

    public static let importedMessageKey = "布局已导入"
    /// "%@" = clauses joined by「、」.
    public static let importedWithDetailsFormatKey = "布局已导入：%@"
    public static let detailsTruncatedFormatKey = "%@等"
    public static let restoredMessageKey = "已恢复上次备份"
    public static let restoredWithDetailsFormatKey = "已恢复上次备份：%@"
    /// Second import confirm: preview of what the grid would lose/gain.
    public static let importPreviewFormatKey = "导入后的变化：%@"

    /// Non-zero changes in a fixed, user-relevant order (moves first).
    public var details: [Detail] {
        var out: [Detail] = []
        func add(_ key: String, _ n: Int) { if n > 0 { out.append(Detail(key: key, count: n)) } }
        add("%d 个应用换了位置", appsChangingContainer)
        if topLevelOrderChanged { out.append(Detail(key: "图标顺序已调整", count: nil)) }
        add("新增 %d 个文件夹", foldersAdded)
        add("移除 %d 个文件夹", foldersRemoved)
        add("%d 个文件夹改名", foldersRenamed)
        add("隐藏 %d 个应用", newlyHidden)
        add("显示 %d 个应用", newlyShown)
        add("%d 个别名变化", aliasesChanged)
        add("新增 %d 个应用", appsAdded)
        add("移除 %d 个应用", appsRemoved)
        return out
    }

    /// First `limit` details for a one-line status; `truncated` when more exist.
    public func importedMessageDetails(limit: Int = 3) -> (details: [Detail], truncated: Bool) {
        let all = details
        let n = max(0, limit)
        return (Array(all.prefix(n)), all.count > n)
    }
}

extension LauncherLayout {
    private enum PlacementContainer: Hashable {
        case topLevel
        case folder(UUID)
    }

    private static func placements(of state: LayoutState) -> (byKey: [String: PlacementContainer], topLevelTokens: [String]) {
        var byKey: [String: PlacementContainer] = [:]
        var tokens: [String] = []
        for entry in state.orderedEntries {
            switch entry {
            case .app(let id):
                guard let key = state.appKeys[id], byKey[key] == nil else { continue }
                byKey[key] = .topLevel
                tokens.append("app:" + key)
            case .folder(let folderID):
                guard let folder = state.folders[folderID] else { continue }
                tokens.append("folder:" + folderID.uuidString)
                for id in folder.itemIDs {
                    guard let key = state.appKeys[id], byKey[key] == nil else { continue }
                    byKey[key] = .folder(folderID)
                }
            }
        }
        return (byKey, tokens)
    }

    public static func layoutChangeSummary(from old: LayoutState, to new: LayoutState) -> LayoutChangeSummary {
        var summary = LayoutChangeSummary()
        let before = placements(of: old)
        let after = placements(of: new)
        for (key, container) in after.byKey {
            if let previous = before.byKey[key] {
                if previous != container { summary.appsChangingContainer += 1 }
            } else {
                summary.appsAdded += 1
            }
        }
        summary.appsRemoved = before.byKey.keys.filter { after.byKey[$0] == nil }.count

        let common = Set(before.topLevelTokens).intersection(after.topLevelTokens)
        summary.topLevelOrderChanged =
            before.topLevelTokens.filter(common.contains) != after.topLevelTokens.filter(common.contains)

        let oldFolders = Set(old.orderedEntries.compactMap { entry -> UUID? in
            if case .folder(let id) = entry, old.folders[id] != nil { return id }
            return nil
        })
        let newFolders = Set(new.orderedEntries.compactMap { entry -> UUID? in
            if case .folder(let id) = entry, new.folders[id] != nil { return id }
            return nil
        })
        summary.foldersAdded = newFolders.subtracting(oldFolders).count
        summary.foldersRemoved = oldFolders.subtracting(newFolders).count
        summary.foldersRenamed = oldFolders.intersection(newFolders).filter {
            old.folders[$0]?.name != new.folders[$0]?.name
        }.count

        summary.newlyHidden = new.hiddenAppKeys.subtracting(old.hiddenAppKeys).count
        summary.newlyShown = old.hiddenAppKeys.subtracting(new.hiddenAppKeys).count
        let aliasKeys = Set(old.appAliases.keys).union(new.appAliases.keys)
        summary.aliasesChanged = aliasKeys.filter { old.appAliases[$0] != new.appAliases[$0] }.count
        return summary
    }
}

// MARK: - Import confirmation kind (LAYOUT-IMPORT-CONFIRM-CORE-01, not wired)

/// Which confirmation an import should show, combining the catalog
/// assessment with the diff against the current layout. Direct still owns
/// the existing confirm alert; this only picks the variant and extra copy.
public enum LayoutImportConfirmation: Equatable, Sendable {
    /// File equals the current layout: skip the alert, show `messageKey` as a toast.
    case unchanged
    /// Existing confirmation, no extra warning.
    case standard
    /// None of the file's apps are installed here.
    case warnForeign
    /// Every installed app would be hidden.
    case warnHidesEverything

    public var messageKey: String? {
        switch self {
        case .unchanged: return "导入的布局与当前布局相同"
        case .standard: return nil
        case .warnForeign: return "该布局中的应用都未安装在这台 Mac 上，导入后图标将按默认方式排列。"
        case .warnHidesEverything: return "该布局会隐藏所有应用，导入后启动台将为空。"
        }
    }

    public var showsAlert: Bool { self != .unchanged }

    /// Warning variants need a second, cancel-first confirm after the file is read.
    public var needsSecondConfirm: Bool { self == .warnForeign || self == .warnHidesEverything }
    public static let secondConfirmTitleKey = "仍要导入这份布局？"
    public static let secondConfirmButtonTitleKey = "仍然导入"
    public static let cancelledMessageKey = "已取消导入"
}

extension LauncherLayout {
    /// What committing `imported` would change, as seen after reconcile.
    /// nil while the catalog is still empty (cannot be judged).
    public static func layoutImportChangeSummary(
        imported: LayoutState,
        current: LayoutState,
        catalog: [AppCandidate]
    ) -> LayoutChangeSummary? {
        guard !catalog.isEmpty else { return nil }
        return layoutChangeSummary(from: current, to: reconcile(candidates: catalog, into: imported))
    }

    /// Live-catalog convenience used by Direct. An empty catalog (still
    /// scanning) cannot be judged, so it falls back to `.standard`.
    public static func layoutImportConfirmation(
        imported: LayoutState,
        current: LayoutState,
        catalog: [AppCandidate]
    ) -> LayoutImportConfirmation {
        guard !catalog.isEmpty else { return .standard }
        let assessment = layoutImportAssessment(imported: imported, catalog: catalog)
        let reconciled = reconcile(candidates: catalog, into: imported)
        let summary = layoutChangeSummary(from: current, to: reconciled)
        return layoutImportConfirmation(assessment: assessment, summary: summary)
    }

    public static func layoutImportConfirmation(
        assessment: LayoutImportAssessment,
        summary: LayoutChangeSummary
    ) -> LayoutImportConfirmation {
        if summary.isEmpty { return .unchanged }
        if assessment.hidesEverything { return .warnHidesEverything }
        if assessment.looksForeign { return .warnForeign }
        return .standard
    }
}

// MARK: - Category rearrange copy (BLANK-AREA-CATEGORY-SORT-01)

extension LauncherLayout {
    /// Copy for the blank-area 「按分类排列…」 item. Kept separate from
    /// `GridRearrangeSort` so existing exhaustive switches stay untouched.
    public enum CategoryRearrangeCopy {
        public static let menuTitleKey = "按分类排列…"
        /// SETTINGS-REARRANGE-BUTTONS-COPY-01 — Settings button (no ellipsis).
        public static let settingsButtonTitleKey = "按分类排列"
        public static let settingsAccessibilityHelpKey = "按应用分类分组，组内按名称；文件夹内应用不变"
        public static let informativeTextKey = "将按应用分类（效率、开发、创意、影音等）分组，组内按名称，文件夹排在最后；文件夹内应用不变。可在「恢复上次备份」撤销。"
        public static let toastKey = "已按分类重新排列"
        /// The menu item stays enabled: computing "would change" needs one
        /// Info.plist read per app, which must not run on every right-click.
        public static let menuItemAlwaysEnabled = true
    }
}

// MARK: - Suggested name for 「移入新建文件夹」 (FOLDER-NAME-SUGGEST-WIRE-01)

extension LauncherLayout {
    /// Upper bound on Info.plist reads for one suggestion; larger selections
    /// keep the plain「新建文件夹」 default.
    public static let suggestedFolderNameMaximumApps = 40

    /// Category title key shared by every app in `appIDs`, or nil (unknown
    /// id, missing candidate, mixed/other categories, <2 or too many apps).
    public static func suggestedFolderNameKey(
        forAppIDs appIDs: [UUID],
        in state: LayoutState,
        catalog: [AppCandidate],
        categoryType: (AppCandidate) -> String? = { applicationCategoryType(forAppAt: $0.canonicalURL) }
    ) -> String? {
        guard appIDs.count >= 2, appIDs.count <= suggestedFolderNameMaximumApps else { return nil }
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        var firstGroup: AppCategoryGroup?
        var types: [String?] = []
        for id in appIDs {
            guard let key = state.appKeys[id], let candidate = byKey[key] else { return nil }
            let type = categoryType(candidate)
            let group = AppCategoryGroup.group(forCategoryType: type)
            // Stop reading plists as soon as the answer is known to be nil.
            if group == .other { return nil }
            if let firstGroup, firstGroup != group { return nil }
            firstGroup = group
            types.append(type)
        }
        return AppCategoryGroup.suggestedFolderNameKey(forCategoryTypes: types)
    }
}

// MARK: - Date rearrange (DATE-REARRANGE-CORE-01, Core only, not wired)

/// Which per-app date drives a one-shot「按添加时间 / 按上次打开时间」rearrange.
/// Kept apart from `GridRearrangeSort` so existing exhaustive switches stay untouched.
public enum AppDateRearrangeKind: String, CaseIterable, Equatable, Sendable {
    /// When the bundle landed in its folder (Spotlight `kMDItemDateAdded`,
    /// falling back to the file system's added-to-directory / creation date).
    case dateAdded
    /// Spotlight `kMDItemLastUsedDate`; apps never opened have no date.
    case lastOpened

    public var menuTitleKey: String {
        switch self {
        case .dateAdded: return "按添加时间排列…"
        case .lastOpened: return "按上次打开时间排列…"
        }
    }

    /// Settings button (no ellipsis; matches 按名称/按分类/按颜色).
    public var settingsButtonTitleKey: String {
        switch self {
        case .dateAdded: return "按添加时间排列"
        case .lastOpened: return "按上次打开时间排列"
        }
    }

    /// Folder context menu. Members only; the folder tile stays in its slot.
    public var folderMenuTitleKey: String {
        switch self {
        case .dateAdded: return "按添加时间排列文件夹内应用"
        case .lastOpened: return "按上次打开时间排列文件夹内应用"
        }
    }

    public var folderToastKey: String {
        switch self {
        case .dateAdded: return "已按添加时间排列文件夹内应用"
        case .lastOpened: return "已按上次打开时间排列文件夹内应用"
        }
    }

    public var folderAlreadySortedToastKey: String {
        switch self {
        case .dateAdded: return "文件夹内应用已按添加时间排列"
        case .lastOpened: return "文件夹内应用已按上次打开时间排列"
        }
    }

    public var folderAccessibilityHelpKey: String {
        switch self {
        case .dateAdded: return "只按添加时间调整这个文件夹内的顺序，主屏幕不变"
        case .lastOpened: return "只按上次打开时间调整这个文件夹内的顺序，主屏幕不变"
        }
    }

    /// Shown while Spotlight dates are read off the main actor.
    public static let progressToastKey = "正在读取应用时间…"

    public func folderAccessibilityHelp(localize: (String) -> String = { $0 }) -> String {
        localize(folderAccessibilityHelpKey)
    }

    public var informativeTextKey: String {
        switch self {
        case .dateAdded:
            return "将把最近添加的应用排在前面，无法确定时间的应用在其后，文件夹排在最后；文件夹内应用不变。可在「恢复上次备份」撤销。"
        case .lastOpened:
            return "将把最近打开过的应用排在前面，从未打开的应用在其后，文件夹排在最后；文件夹内应用不变。可在「恢复上次备份」撤销。"
        }
    }

    public var toastKey: String {
        switch self {
        case .dateAdded: return "已按添加时间重新排列"
        case .lastOpened: return "已按上次打开时间重新排列"
        }
    }
}

extension LauncherLayout {
    /// Best-effort date for `kind`, read on demand (never cached in the catalog).
    /// Returns nil when Spotlight and the file system both have nothing.
    public static func applicationDate(_ kind: AppDateRearrangeKind, forAppAt url: URL) -> Date? {
        let item = MDItemCreate(kCFAllocatorDefault, url.path as NSString)
        switch kind {
        case .dateAdded:
            if let item, let date = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date {
                return date
            }
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            return values?.addedToDirectoryDate ?? values?.creationDate
        case .lastOpened:
            guard let item else { return nil }
            return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
    }

    /// Spotlight / file-system dates off the main actor, one lookup per app.
    /// Callers apply the map on the main actor. Does not touch paging.
    public static func applicationDates(
        _ kind: AppDateRearrangeKind,
        for candidates: [AppCandidate]
    ) async -> [String: Date] {
        let snapshot = candidates
        return await Task.detached(priority: .userInitiated) {
            var out: [String: Date] = [:]
            var seen = Set<String>()
            for candidate in snapshot {
                let key = candidate.deduplicationKey
                guard seen.insert(key).inserted else { continue }
                if let date = LauncherLayout.applicationDate(kind, forAppAt: candidate.canonicalURL) {
                    out[key] = date
                }
            }
            return out
        }.value
    }

    /// Reorders top-level entries newest-first by `kind`; apps without a date
    /// follow (by name, alias wins), then ids missing from the catalog, and
    /// folders go last (by name); UUID breaks
    /// ties. Like the other rearranges it only touches `orderedEntries` —
    /// never folder contents, aliases, hidden apps, or paging — and leaves
    /// `updatedAt` alone when nothing moves. `date` runs once per top-level app.
    public static func rearrangeTopLevelEntriesByDate(
        _ kind: AppDateRearrangeKind,
        in state: LayoutState,
        catalog: [AppCandidate],
        date: ((AppCandidate) -> Date?)? = nil
    ) -> LayoutState {
        let provider = date ?? { applicationDate(kind, forAppAt: $0.canonicalURL) }
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        // tier 0 = dated app, 1 = undated app, 2 = unresolved app id, 3 = folder.
        var keys: [UUID: (tier: Int, date: Date?, name: String)] = [:]
        for entry in state.orderedEntries where keys[entry.id] == nil {
            switch entry {
            case .folder(let id):
                keys[id] = (3, nil, state.folders[id]?.name ?? id.uuidString)
            case .app(let id):
                guard let key = state.appKeys[id], let candidate = byKey[key] else {
                    keys[id] = (2, nil, id.uuidString)
                    continue
                }
                let alias = state.appAliases[key]
                let name = (alias?.isEmpty == false ? alias : nil) ?? candidate.displayName
                let value = provider(candidate)
                keys[id] = (value == nil ? 1 : 0, value, name)
            }
        }
        var next = state
        next.orderedEntries.sort { lhs, rhs in
            let l = keys[lhs.id]!, r = keys[rhs.id]!
            if l.tier != r.tier { return l.tier < r.tier }
            if let ld = l.date, let rd = r.date, ld != rd { return ld > rd }
            let nameOrder = l.name.localizedStandardCompare(r.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if next.orderedEntries != state.orderedEntries {
            next.updatedAt = .now
        }
        return next
    }
}

public extension LauncherLayout {
    /// Whether a tile hides its name label. The "hide app names" preference
    /// applies to the grid and open folders only: search results keep names
    /// (they carry the folder context line), and a tile showing
    /// 「正在启动…」 keeps its label so the launch feedback stays readable.
    /// Uses `isHidden`, never alpha, so merge / open-flight fades are untouched.
    static func tileTitleHidden(hidesAppNames: Bool, inSearchResults: Bool, isLaunching: Bool) -> Bool {
        hidesAppNames && !inSearchResults && !isLaunching
    }

    /// Split app / folder name preferences (LaunchOS parity): an app tile
    /// follows `hidesAppNames`, a folder tile follows `hidesFolderNames`.
    /// Same search / launching exceptions as above.
    static func tileTitleHidden(
        hidesAppNames: Bool,
        hidesFolderNames: Bool,
        isFolder: Bool,
        inSearchResults: Bool,
        isLaunching: Bool
    ) -> Bool {
        tileTitleHidden(
            hidesAppNames: isFolder ? hidesFolderNames : hidesAppNames,
            inSearchResults: inSearchResults,
            isLaunching: isLaunching
        )
    }
}

public extension LauncherLayout {
    /// Launchpad-style "new app" dot. Keys that a catalog reload added to
    /// `reconciled` and that `previous` neither placed nor hid. A fresh
    /// `previous` (first launch, unreadable layout) marks nothing, so the
    /// whole catalog never lights up at once.
    static func newlyAddedAppKeys(previous: LayoutState, reconciled: LayoutState) -> Set<String> {
        guard !previous.appKeys.isEmpty else { return [] }
        let known = Set(previous.appKeys.values).union(previous.hiddenAppKeys)
        return Set(reconciled.appKeys.values).subtracting(known)
    }

    /// The dot shows on grid / folder app tiles only. Search results already
    /// carry a folder context line, and「正在启动…」replaces the name.
    static func showsNewAppBadge(isNew: Bool, isFolder: Bool, inSearchResults: Bool, isLaunching: Bool) -> Bool {
        isNew && !isFolder && !inSearchResults && !isLaunching
    }
}

/// Average icon color used by the one-shot「按颜色排列」rearrange (HSB, 0…1).
public struct IconColorSample: Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    /// Grays, whites, and near-blacks group after the colored icons.
    public var isChromatic: Bool { saturation >= 0.25 && brightness >= 0.25 }

    /// Twelve hue families starting at red (reds just below 360° wrap to 0).
    public var hueFamily: Int {
        let shifted = (hue + 1.0 / 24.0).truncatingRemainder(dividingBy: 1)
        return min(11, max(0, Int((shifted < 0 ? shifted + 1 : shifted) * 12)))
    }
}

public extension LauncherLayout {
    enum ColorRearrangeCopy {
        public static let menuTitleKey = "按颜色排列…"
        /// Settings button (no ellipsis; matches 按名称/按类型/按分类).
        public static let settingsButtonTitleKey = "按颜色排列"
        public static let informativeTextKey = "将按图标主色（红、橙、黄、绿、蓝、紫）排列应用，黑白灰图标在其后，文件夹排在最后；文件夹内应用不变。可在「恢复上次备份」撤销。"
        public static let toastKey = "已按颜色重新排列"
        public static let progressToastKey = "正在读取图标颜色…"
    }

    /// Reorders top-level entries by icon color family (red → purple, darker
    /// shades after brighter ones within a family), then achromatic icons
    /// (light → dark), then apps with no sample (by name), unresolved ids,
    /// and folders last (by name); UUID breaks ties. Only `orderedEntries`
    /// change — never folder contents, aliases, hidden apps, or paging —
    /// and `updatedAt` stays put when nothing moves.
    static func rearrangeTopLevelEntriesByColor(
        in state: LayoutState,
        catalog: [AppCandidate],
        color: (AppCandidate) -> IconColorSample?
    ) -> LayoutState {
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        // tier 0 = chromatic, 1 = achromatic, 2 = no sample, 3 = unresolved, 4 = folder.
        var keys: [UUID: (tier: Int, family: Int, brightness: Double, name: String)] = [:]
        for entry in state.orderedEntries where keys[entry.id] == nil {
            switch entry {
            case .folder(let id):
                keys[id] = (4, 0, 0, state.folders[id]?.name ?? id.uuidString)
            case .app(let id):
                guard let key = state.appKeys[id], let candidate = byKey[key] else {
                    keys[id] = (3, 0, 0, id.uuidString)
                    continue
                }
                let alias = state.appAliases[key]
                let name = (alias?.isEmpty == false ? alias : nil) ?? candidate.displayName
                guard let sample = color(candidate) else {
                    keys[id] = (2, 0, 0, name)
                    continue
                }
                keys[id] = sample.isChromatic
                    ? (0, sample.hueFamily, sample.brightness, name)
                    : (1, 0, sample.brightness, name)
            }
        }
        var next = state
        next.orderedEntries.sort { lhs, rhs in
            let l = keys[lhs.id]!, r = keys[rhs.id]!
            if l.tier != r.tier { return l.tier < r.tier }
            if l.family != r.family { return l.family < r.family }
            // Quantize so near-identical shades fall back to name order.
            let lb = Int((l.brightness * 10).rounded()), rb = Int((r.brightness * 10).rounded())
            if lb != rb { return lb > rb }
            let nameOrder = l.name.localizedStandardCompare(r.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if next.orderedEntries != state.orderedEntries {
            next.updatedAt = .now
        }
        return next
    }
}

public extension LauncherLayout {
    static let sortFolderByColorMenuTitleKey = "按颜色排列文件夹内应用"
    static let sortFolderByColorToastKey = "已按颜色排列文件夹内应用"
    static let sortFolderAlreadyColorSortedToastKey = "文件夹内应用已按颜色排列"
    public static let sortFolderByColorAccessibilityHelpKey = "只按图标颜色调整这个文件夹内的顺序，主屏幕不变"

    /// Folder context menu「按颜色排列文件夹内应用」: same order as the
    /// top-level color rearrange (hue family → brighter first → achromatic
    /// light→dark → unsampled → unresolved, name/UUID tiebreak) applied to
    /// that folder's `itemIDs` only. Returns nil when the folder is missing,
    /// has fewer than two members, or is already in color order. Top-level
    /// entries and paging are untouched.
    static func sortingFolderMembersByColor(
        _ folderID: UUID,
        in state: LayoutState,
        catalog: [AppCandidate],
        color: (AppCandidate) -> IconColorSample?
    ) -> LayoutState? {
        guard let folder = state.folders[folderID], folder.itemIDs.count > 1 else { return nil }
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        // tier 0 = chromatic, 1 = achromatic, 2 = no sample, 3 = unresolved.
        var keys: [UUID: (tier: Int, family: Int, brightness: Int, name: String)] = [:]
        for id in folder.itemIDs where keys[id] == nil {
            guard let key = state.appKeys[id], let candidate = byKey[key] else {
                keys[id] = (3, 0, 0, id.uuidString)
                continue
            }
            let alias = state.appAliases[key]
            let name = (alias?.isEmpty == false ? alias : nil) ?? candidate.displayName
            guard let sample = color(candidate) else {
                keys[id] = (2, 0, 0, name)
                continue
            }
            let brightness = Int((sample.brightness * 10).rounded())
            keys[id] = sample.isChromatic ? (0, sample.hueFamily, brightness, name) : (1, 0, brightness, name)
        }
        let sorted = folder.itemIDs.sorted { lhs, rhs in
            let l = keys[lhs]!, r = keys[rhs]!
            if l.tier != r.tier { return l.tier < r.tier }
            if l.family != r.family { return l.family < r.family }
            if l.brightness != r.brightness { return l.brightness > r.brightness }
            let order = l.name.localizedStandardCompare(r.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.uuidString < rhs.uuidString
        }
        guard sorted != folder.itemIDs else { return nil }
        var next = state
        next.folders[folderID]?.itemIDs = sorted
        next.updatedAt = .now
        return next
    }

    /// Folder context menu date sort (FOLDER-DATE-SORT-01). Newest dated
    /// members first, then undated members by alias/name, then ids missing
    /// from the catalog. Returns nil when the folder is missing, has fewer
    /// than two members, or is already in that order. Top-level entries and
    /// paging stay untouched. `date` runs once per resolvable member.
    static func sortingFolderMembersByDate(
        _ kind: AppDateRearrangeKind,
        folderID: UUID,
        in state: LayoutState,
        catalog: [AppCandidate],
        date: (AppCandidate) -> Date?
    ) -> LayoutState? {
        guard let folder = state.folders[folderID], folder.itemIDs.count > 1 else { return nil }
        let byKey = AppCandidate.firstByDeduplicationKey(catalog)
        // tier 0 = dated, 1 = undated, 2 = unresolved. No nested folders.
        var keys: [UUID: (tier: Int, date: Date?, name: String)] = [:]
        for id in folder.itemIDs where keys[id] == nil {
            guard let key = state.appKeys[id], let candidate = byKey[key] else {
                keys[id] = (2, nil, id.uuidString)
                continue
            }
            let alias = state.appAliases[key]
            let name = (alias?.isEmpty == false ? alias : nil) ?? candidate.displayName
            let value = date(candidate)
            keys[id] = (value == nil ? 1 : 0, value, name)
        }
        let sorted = folder.itemIDs.sorted { lhs, rhs in
            let l = keys[lhs]!, r = keys[rhs]!
            if l.tier != r.tier { return l.tier < r.tier }
            if let ld = l.date, let rd = r.date, ld != rd { return ld > rd }
            let order = l.name.localizedStandardCompare(r.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.uuidString < rhs.uuidString
        }
        guard sorted != folder.itemIDs else { return nil }
        var next = state
        next.folders[folderID]?.itemIDs = sorted
        next.updatedAt = .now
        return next
    }
}
