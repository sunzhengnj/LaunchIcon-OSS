import Foundation

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

public enum LayoutMutationError: Error, Equatable, Sendable {
    case missingSource
    case missingTarget
    case nestedFolder
    case cannotDropOnSelf
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
    public static let pageTurnCurveX1: CGFloat = 0.2
    public static let pageTurnCurveY1: CGFloat = 0.8
    public static let pageTurnCurveX2: CGFloat = 0.2
    public static let pageTurnCurveY2: CGFloat = 1
    /// How far a finger must travel, as a fraction of the page, before the
    /// page turns. A fast flick can still turn below this. This is not how
    /// far the pages slide.
    public static let pageTurnDistanceFraction: CGFloat = 0.18
    /// How far the pages follow a finger, as a fraction of the page width at
    /// a full-width drag. A full pull still docks the incoming page. Arrow
    /// and keyboard turns do not use this.
    public static let pageDragSlideFraction: CGFloat = 0.18
    /// Arrow, keyboard, and page-dot turns. The old jump used the drag
    /// fraction, so the fade finished before the page had moved enough to
    /// read as a turn. Same ease-out as the drag. The drag-to-turn threshold
    /// stays `pageTurnDistanceFraction`.
    public static let discretePageSlideFraction: CGFloat = 0.36
    public static let discretePageTurnThreshold: CGFloat = 3
    public static let dragLiftScale: CGFloat = 1.06
    public static let dragLiftShadowOpacity: CGFloat = 0.18
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
        let crossfade = !reducesMotion && !holdsForLauncherFade && !incomingIsFolderBackdrop
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
    public static let searchFieldWidth: CGFloat = 400
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
        guard !reducesMotion, sourceSize.width > 0, sourceSize.height > 0 else { return identity }
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

    /// Menu-bar title for that same choice. The menu writes it when it opens
    /// and must write it again if show or hide happens while the menu is up.
    /// A stale「隐藏」during the fade would bring the launcher back.
    public static func statusItemToggleTitle(isVisible: Bool, isDismissing: Bool) -> String {
        switch visibilityToggle(isVisible: isVisible, isDismissing: isDismissing) {
        case .show:
            return "显示 LaunchIcon"
        case .hide:
            return "隐藏 LaunchIcon"
        }
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

    /// Changing reduced motion snaps a merge flight that is already running.
    /// Reduced motion is a short fade, and turning motion back on does not
    /// finish the old flight either. Both end by removing the image. A
    /// launcher fade that is still on screen is holding the frame already
    /// drawn, so this snap waits. Same hold as the flight. A flight that has
    /// not started is left alone.
    public static func shouldSnapInFlightMergeFlight(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldMergeFlight(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Reduced motion fades a new folder in over 0.12s instead of springing.
    /// The model opacity is already 1, so the landing hold used to miss it
    /// and the fade kept running under the launcher fade. Play that fade only
    /// while the launcher is up. A hidden window, or a cancelled fade, shows
    /// the folder at full opacity. Same condition as starting a merge flight.
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
    /// Reduced motion is a short fade, and turning motion back on does not
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
        reducesMotion && shouldSnapInFlightLauncherPresence(
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
    public static let folderChromeReducedDuration: TimeInterval = 0.12
    public static let folderChromeFallbackScale: CGFloat = 0.92
    public static let folderChromeMinimumScale: CGFloat = 0.12
    public static let folderChromeMaximumScale: CGFloat = 0.86

    public static func folderChromeCollapse(
        panelFrame: CGRect,
        iconFrame: CGRect?,
        reducesMotion: Bool
    ) -> FolderChromeCollapse {
        if reducesMotion {
            return FolderChromeCollapse(
                scale: 1,
                translationX: 0,
                translationY: 0,
                animatesTransform: false,
                panelOpacity: 0,
                duration: folderChromeReducedDuration,
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

    /// Fly leftover icons from the open folder back onto the grid. Reduced
    /// motion does not travel. An unusable frame, a repeated id, or a hop
    /// shorter than a point stays put, so an icon that is already home does
    /// not flicker. Icons start together; a stagger would break the one gesture.
    public static func folderDissolveFlights(
        placements: [FolderDissolveIconPlacement],
        reducesMotion: Bool
    ) -> [FolderDissolveFlight] {
        guard !reducesMotion else { return [] }
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
                duration: folderDissolveFlightDuration
            ))
        }
        return flights
    }

    /// The folder is gone, so the panel cannot shrink back into a preview.
    /// It fades and settles by the same amount the grid was scaled, while
    /// the leftover icon flies to its cell. Same length as that flight.
    /// Reduced motion is the short fade with no scale.
    public static func folderDissolveChrome(reducesMotion: Bool) -> FolderChromeCollapse {
        if reducesMotion {
            return FolderChromeCollapse(
                scale: 1,
                translationX: 0,
                translationY: 0,
                animatesTransform: false,
                panelOpacity: 0,
                duration: folderChromeReducedDuration,
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
        !reducesMotion && isVisible && !isDismissing
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

    /// Fly the preview glyphs into the open folder. Reduced motion does not
    /// travel. An unusable frame, a repeated id, or a hop shorter than a
    /// point stays put. Icons start together; a stagger would break the one gesture.
    public static func folderPreviewGlyphFlights(
        placements: [FolderPreviewGlyphPlacement],
        reducesMotion: Bool
    ) -> [FolderPreviewGlyphFlight] {
        guard !reducesMotion else { return [] }
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
                duration: folderPreviewGlyphFlightDuration
            ))
        }
        return flights
    }

    /// Glyphs fly only when the panel itself is growing out of the preview.
    /// A centered pop has no plate to leave. The launcher fade must not grow
    /// a new flight underneath it.
    public static func shouldPlayFolderPreviewGlyphFlight(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool,
        tracksIcon: Bool
    ) -> Bool {
        tracksIcon && !reducesMotion && isVisible && !isDismissing
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

    public static func folderMergePreviewLandings(
        resident: CGRect,
        incoming: CGRect,
        destinations: [CGRect],
        reducesMotion: Bool
    ) -> [FolderMergePreviewLanding] {
        guard !reducesMotion, destinations.count >= 2 else { return [] }
        let pairs = [(resident, destinations[0]), (incoming, destinations[1])]
        guard pairs.allSatisfy({ source, destination in
            usableChromeFrame(source)
                && usableChromeFrame(destination)
                && !framesNearlyEqual(source, destination)
        }) else { return [] }
        return pairs.map { source, destination in
            FolderMergePreviewLanding(
                source: source,
                destination: destination,
                duration: folderChromeTravelDuration
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

    /// The dropped icon flies into that empty preview slot. The clock matches
    /// the other folder flights. Reduced motion does not travel. A short hop
    /// or a bad frame lands nowhere, and the caller keeps the older flight
    /// onto the whole cell.
    public static func folderIncomingPreviewLanding(
        incoming: CGRect,
        destination: CGRect,
        reducesMotion: Bool
    ) -> FolderMergePreviewLanding? {
        guard !reducesMotion else { return nil }
        guard usableChromeFrame(incoming),
              usableChromeFrame(destination),
              !framesNearlyEqual(incoming, destination) else { return nil }
        return FolderMergePreviewLanding(
            source: incoming,
            destination: destination,
            duration: folderChromeTravelDuration
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
        guard !reducesMotion,
              let destination = folderPreviewPlateCenterFrame(well: well),
              usableChromeFrame(incoming),
              !framesNearlyEqual(incoming, destination) else { return nil }
        return FolderMergePreviewLanding(
            source: incoming,
            destination: destination,
            duration: folderChromeTravelDuration
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

    /// Where the released drag picture already is. The drag image is the cell
    /// plus the lift (scale and shadow). The flight has to leave from that
    /// picture, not from the smaller cell, or the icon pops when the drag
    /// image is removed. Reduced motion has no lift, so this is the cell.
    /// A cell that cannot be measured is returned unchanged.
    public static func dropLandingStartFrame(cell: CGRect, reducesMotion: Bool) -> CGRect {
        guard usableChromeFrame(cell) else { return cell }
        let presentation = dragLiftPresentation(for: cell.size, reducesMotion: reducesMotion)
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
        guard !reducesMotion,
              usableChromeFrame(source),
              usableChromeFrame(destination),
              !framesNearlyEqual(source, destination) else { return nil }
        return DropLandingFlight(
            source: source,
            destination: destination,
            duration: dropLandingFlightDuration
        )
    }

    /// A reorder flight only while the launcher is up. The fade must not
    /// grow a new one underneath it. A hidden window shows the cell in place.
    public static func shouldPlayDropLanding(
        reducesMotion: Bool,
        isDismissing: Bool,
        isVisible: Bool
    ) -> Bool {
        shouldPlayFolderDissolveScatter(
            reducesMotion: reducesMotion,
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

    /// Changing reduced motion snaps a dissolved-folder fade that is already
    /// running. Reduced motion uses a shorter fade, and turning motion back
    /// on does not finish the old one either. Both land on a fully opaque
    /// grid. A launcher fade that is still on screen is holding the frame
    /// already drawn, so this snap waits. Same hold as the fade.
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

    /// Do not start that pulse during the fade. Reduced motion has none.
    /// The "正在启动…" label is separate and is not a scale.
    /// The scale is 1 → `launchPressScale` → 1. Each half is
    /// `launchPressHalfDuration`, so the whole press is about 0.09s.
    /// The layer anchor is the view origin. Pair the scale with
    /// `originPinnedScaleTranslation` or the icon slides toward that corner.
    public static let launchPressScale: CGFloat = 0.93
    public static let launchPressHalfDuration: TimeInterval = 0.045

    /// Do not start that pulse during the fade. Reduced motion has none.
    public static func shouldPlayLaunchFeedback(isDismissing: Bool, reducesMotion: Bool) -> Bool {
        !isDismissing && !reducesMotion
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

    /// Do not start that slide during the fade. Reduced motion never slides.
    public static func shouldAnimateReorderSlide(
        isDismissing: Bool,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Bool {
        !reducesMotion && !shouldHoldReorderSlide(isDismissing: isDismissing, isVisible: isVisible)
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

    /// Do not start that fade during the launcher fade, while the window is
    /// already hidden, or when the user asked for less motion. Reduced motion
    /// snaps to hover or focus. The unreduced fade is the page-turn ease-out
    /// below, not the system ease-in.
    public static func shouldAnimatePageButtonHover(
        isDismissing: Bool,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Bool {
        !reducesMotion
            && isVisible
            && !shouldHoldPageButtonHover(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Hover on a page arrow. The old fade was the system default: it eased
    /// in, so the first moments barely moved, and the plate was cleared in
    /// the same turn the arrow started leaving. This one uses the page-turn
    /// ease-out (`pageTurnCurveProgress`) and keeps the plate painted. The
    /// control opacity carries the plate, so the two leave together.
    public static let pageButtonHoverFadeDuration: TimeInterval = 0.2
    public static let pageButtonHoverShownOpacity: CGFloat = 0.9
    public static let pageButtonHoverPlateAlpha: CGFloat = 0.22

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
    /// whole fade; only the control opacity hides it. Sampling the page-turn
    /// curve means the first slice of the clock already moves.
    public static func pageButtonHoverSample(
        appearing: Bool,
        time: CGFloat
    ) -> (controlOpacity: CGFloat, plateAlpha: CGFloat) {
        let progress = pageTurnCurveProgress(time)
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

    public static func visiblePageIndices(pageCount: Int, selectedPage: Int, maxVisible: Int = pageIndicatorLimit) -> [Int] {
        guard pageCount > 0 else { return [] }
        if pageCount <= maxVisible { return Array(0..<pageCount) }
        let start = min(max(0, selectedPage - maxVisible / 2), pageCount - maxVisible)
        return Array(start..<(start + maxVisible))
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

    public static func renameFolder(_ id: UUID, to name: String, in state: LayoutState) -> LayoutState {
        var state = state
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty, var folder = state.folders[id], folder.name != trimmed else { return state }
        folder.name = trimmed
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
