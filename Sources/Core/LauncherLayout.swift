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
    public static let pageTurnDistanceFraction: CGFloat = 0.18
    public static let discretePageTurnThreshold: CGFloat = 3
    public static let dragLiftScale: CGFloat = 1.06
    public static let dragLiftShadowOpacity: CGFloat = 0.18
    public static let reorderSlideDuration: TimeInterval = 0.18
    /// Open-folder backdrop. Reduced motion keeps this opacity and drops the scale and blur.
    public static let folderBackdropOpenOpacity: CGFloat = 0.45
    public static let folderBackdropOpenScale: CGFloat = 0.96
    /// PRD `motion.fast`: search results appear or the grid returns.
    public static let searchTransitionDuration: TimeInterval = 0.12
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
    /// gap immediately, and a timer moves the picture. That timer can still
    /// be running when the launcher fades, so icons keep sliding under it.
    /// Hold only while the fade is up. A hidden window, or a cancelled fade,
    /// jumps to the gap if the drag is still down, or back to the cell if the
    /// drag has ended. The ease is not replayed. Same condition as holding
    /// the launch pulse.
    public static func shouldHoldReorderSlide(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldLaunchFeedback(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Do not start that ease during the fade. Reduced motion never eases.
    public static func shouldAnimateReorderSlide(
        isDismissing: Bool,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Bool {
        !reducesMotion && !shouldHoldReorderSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Changing reduced motion snaps a reorder ease that is already running.
    /// Reduced motion is already on the gap, and turning motion back on does
    /// not finish the old ease either. A launcher fade that is still on
    /// screen is holding the frame already drawn, so this snap waits. Same
    /// hold as the ease. The gap is already the target; the caller lands there.
    public static func shouldSnapInFlightReorderSlide(isDismissing: Bool, isVisible: Bool) -> Bool {
        !shouldHoldReorderSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// The page arrows fade in while the pointer is over them. That fade is
    /// about a quarter of a second, so it can still be running when the
    /// launcher fades, and a mouse exit during the fade would start another.
    /// Hold only while the fade is up. A hidden window, or a cancelled fade,
    /// snaps to the arrow's real visibility instead of replaying the fade.
    /// Same condition as holding the reorder slide.
    public static func shouldHoldPageButtonHover(isDismissing: Bool, isVisible: Bool) -> Bool {
        shouldHoldReorderSlide(isDismissing: isDismissing, isVisible: isVisible)
    }

    /// Do not start that fade during the launcher fade, while the window is
    /// already hidden, or when the user asked for less motion. Reduced motion
    /// snaps to hover or focus. The unreduced fade stays the system default.
    public static func shouldAnimatePageButtonHover(
        isDismissing: Bool,
        isVisible: Bool,
        reducesMotion: Bool
    ) -> Bool {
        !reducesMotion
            && isVisible
            && !shouldHoldPageButtonHover(isDismissing: isDismissing, isVisible: isVisible)
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
