import Foundation

extension LauncherLayout {
    /// KEYBOARD-COMMAND-REGISTRY-01. One table for the first-wave chords
    /// (⌘Z, the ⌘⌥ letter and arrow series, and ⌘⌫ / ⌘⇧⌫). Each entry
    /// wraps an existing `command*` gate. Try-order matches
    /// `performKeyEquivalent`. The same chord in the same context must
    /// resolve to at most one command.
    public enum KeyboardCommand: String, Equatable, Sendable, CaseIterable {
        case openSettings
        case focusSearch
        case dismissLauncher
        case copyFocusedApp
        case selectAllOnPage
        case undoLayout
        case selectEveryTopLevelEntry
        case shiftMMovesSelectionIntoFolder
        case shiftNCreatesFolder
        case optionNSortsFocusedFolder
        case optionNSortsOpenFolder
        case optionCSortsFocusedFolder
        case optionCSortsOpenFolder
        case optionRRearrangesGridByName
        case optionKRearrangesGridByKind
        case optionKSortsOpenFolderByKind
        case optionGRearrangesGridByCategory
        case optionGSortsOpenFolderByCategory
        case shiftCRearrangesGridByColor
        case optionBTogglesBrowseAxis
        case optionUUngroupsAllFolders
        case shiftURestoresAllHidden
        case reloadCatalog
        case shiftHHidesFocusedApp
        case removeFromOpenFolder
        case dissolveClosedFolder
        case uninstallApp
        case shiftReturnRevealsSelection
        case revealSearchHit
        case revealFocusedTile
        case shiftVerticalMovesFocusedFolderMember
        case shiftVerticalSelectionEdge
        case optionVerticalNudgesFocusedFolderMember
        case optionVerticalMovesFoldersToEdge
        case commandUpClosesOpenFolder
        case commandDownOpensFocusedFolder
        case optionShiftHorizontalMovesFocusedEntryToAdjacentPage
        case optionHorizontalNudgesFocusedFolderMember
        case shiftHorizontalMovesFocusedFolderMember
        case optionHorizontalNudgesFocusedEntry
        case shiftHorizontalMovesFocusedEntry
        case commandArrowPaging
        case escapeCancels
        case spaceActivatesFocusedItem
        case arrowExtendsSelection
        case arrowWalksGrid
        case shiftHomeEndExtendsSelection
        case homeEndJumpsInGrid
        case f2RenamesFocusedClosedFolder
        case f2RenamesFocusedAppAlias
        case pageUpDownScrollsOpenList
        case pageUpDownPagesGrid
    }

    /// Keyboard event plus the context `performKeyEquivalent` already
    /// feeds into the existing gates.
    public struct KeyboardProbe: Equatable, Sendable {
        public var character: String?
        public var keyCode: UInt16
        public var command: Bool
        public var shift: Bool
        public var option: Bool
        public var control: Bool
        public var isSearching: Bool
        public var isEditingText: Bool
        public var folderOpen: Bool
        public var layoutEditingEnabled: Bool
        public var acceptsAction: Bool
        public var isPaging: Bool
        public var focusedIsFolder: Bool
        public var focusedIsApp: Bool
        public var focusedIsRemovableMember: Bool
        public var focusedIsInSelection: Bool
        public var selectedTopLevelCount: Int
        public var selectedTopLevelAppCount: Int
        public var selectedFolderCount: Int
        public var selectedMemberCount: Int
        public var selectedAppCount: Int
        public var batchRemovalAllowed: Bool
        public var batchDissolveAllowed: Bool
        public var samplingInFlight: Bool
        public var selectedCount: Int
        public var isEditingFolderTitle: Bool
        public var hasMarkedText: Bool
        public var canRevealInFinder: Bool
        public var pageFlipHorizontal: Bool
        public var pageCount: Int

        public init(
            character: String? = nil,
            keyCode: UInt16 = 0,
            command: Bool = false,
            shift: Bool = false,
            option: Bool = false,
            control: Bool = false,
            isSearching: Bool = false,
            isEditingText: Bool = false,
            folderOpen: Bool = false,
            layoutEditingEnabled: Bool = true,
            acceptsAction: Bool = true,
            isPaging: Bool = false,
            focusedIsFolder: Bool = false,
            focusedIsApp: Bool = false,
            focusedIsRemovableMember: Bool = false,
            focusedIsInSelection: Bool = false,
            selectedTopLevelCount: Int = 0,
            selectedTopLevelAppCount: Int = 0,
            selectedFolderCount: Int = 0,
            selectedMemberCount: Int = 0,
            selectedAppCount: Int = 0,
            batchRemovalAllowed: Bool = false,
            batchDissolveAllowed: Bool = false,
            samplingInFlight: Bool = false,
            selectedCount: Int = 0,
            isEditingFolderTitle: Bool = false,
            hasMarkedText: Bool = false,
            canRevealInFinder: Bool = false,
            pageFlipHorizontal: Bool = true,
            pageCount: Int = 1
        ) {
            self.character = character
            self.keyCode = keyCode
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
            self.isSearching = isSearching
            self.isEditingText = isEditingText
            self.folderOpen = folderOpen
            self.layoutEditingEnabled = layoutEditingEnabled
            self.acceptsAction = acceptsAction
            self.isPaging = isPaging
            self.focusedIsFolder = focusedIsFolder
            self.focusedIsApp = focusedIsApp
            self.focusedIsRemovableMember = focusedIsRemovableMember
            self.focusedIsInSelection = focusedIsInSelection
            self.selectedTopLevelCount = selectedTopLevelCount
            self.selectedTopLevelAppCount = selectedTopLevelAppCount
            self.selectedFolderCount = selectedFolderCount
            self.selectedMemberCount = selectedMemberCount
            self.selectedAppCount = selectedAppCount
            self.batchRemovalAllowed = batchRemovalAllowed
            self.batchDissolveAllowed = batchDissolveAllowed
            self.samplingInFlight = samplingInFlight
            self.selectedCount = selectedCount
            self.isEditingFolderTitle = isEditingFolderTitle
            self.hasMarkedText = hasMarkedText
            self.canRevealInFinder = canRevealInFinder
            self.pageFlipHorizontal = pageFlipHorizontal
            self.pageCount = pageCount
        }
    }

    /// Dispatch order for the first wave, matching `performKeyEquivalent`.
    public static let registeredKeyboardCommands: [KeyboardCommand] = [
        .openSettings,
        .focusSearch,
        .dismissLauncher,
        .copyFocusedApp,
        .selectAllOnPage,
        .undoLayout,
        .selectEveryTopLevelEntry,
        .shiftMMovesSelectionIntoFolder,
        .shiftNCreatesFolder,
        .optionNSortsFocusedFolder,
        .optionNSortsOpenFolder,
        .optionCSortsFocusedFolder,
        .optionCSortsOpenFolder,
        .optionRRearrangesGridByName,
        .optionKRearrangesGridByKind,
        .optionKSortsOpenFolderByKind,
        .optionGRearrangesGridByCategory,
        .optionGSortsOpenFolderByCategory,
        .shiftCRearrangesGridByColor,
        .optionBTogglesBrowseAxis,
        .optionUUngroupsAllFolders,
        .shiftURestoresAllHidden,
        .reloadCatalog,
        .shiftHHidesFocusedApp,
        .removeFromOpenFolder,
        .dissolveClosedFolder,
        .uninstallApp,
        .shiftReturnRevealsSelection,
        .revealSearchHit,
        .revealFocusedTile,
        .shiftVerticalMovesFocusedFolderMember,
        .shiftVerticalSelectionEdge,
        .optionVerticalNudgesFocusedFolderMember,
        .optionVerticalMovesFoldersToEdge,
        .commandUpClosesOpenFolder,
        .commandDownOpensFocusedFolder,
        .optionShiftHorizontalMovesFocusedEntryToAdjacentPage,
        .optionHorizontalNudgesFocusedFolderMember,
        .shiftHorizontalMovesFocusedFolderMember,
        .optionHorizontalNudgesFocusedEntry,
        .shiftHorizontalMovesFocusedEntry,
        .commandArrowPaging,
        .escapeCancels,
        .spaceActivatesFocusedItem,
        .arrowExtendsSelection,
        .arrowWalksGrid,
        .shiftHomeEndExtendsSelection,
        .homeEndJumpsInGrid,
        .f2RenamesFocusedClosedFolder,
        .f2RenamesFocusedAppAlias,
        .pageUpDownScrollsOpenList,
        .pageUpDownPagesGrid,
    ]

    public static func keyboardCommand(
        _ command: KeyboardCommand,
        matches probe: KeyboardProbe
    ) -> Bool {
        switch command {
        case .openSettings:
            return commandCommaOpensSettings(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control
            )
        case .focusSearch:
            return commandFFocusesSearch(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control
            )
        case .dismissLauncher:
            return commandWDismissesLauncher(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText
            )
        case .copyFocusedApp:
            return commandCCopiesFocusedApp(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText
            )
        case .selectAllOnPage:
            return commandASelectsCurrentPageIcons(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText
            )
        case .undoLayout:
            return commandZUndoesKeyboardLayout(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                isPaging: probe.isPaging
            )
        case .selectEveryTopLevelEntry:
            return commandShiftASelectsEveryTopLevelEntry(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .shiftMMovesSelectionIntoFolder:
            return commandShiftMMovesSelectionIntoFolder(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .shiftNCreatesFolder:
            return commandShiftNCreatesFolder(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                selectedTopLevelAppCount: probe.selectedTopLevelAppCount
            )
        case .optionNSortsFocusedFolder:
            return commandOptionNSortsFocusedFolder(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                focusedIsFolder: probe.focusedIsFolder
            )
        case .optionNSortsOpenFolder:
            return commandOptionNSortsOpenFolder(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .optionCSortsFocusedFolder:
            return commandOptionCSortsFocusedFolderByColor(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                samplingInFlight: probe.samplingInFlight,
                focusedIsFolder: probe.focusedIsFolder
            )
        case .optionCSortsOpenFolder:
            return commandOptionCSortsOpenFolderByColor(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                samplingInFlight: probe.samplingInFlight
            )
        case .optionRRearrangesGridByName:
            return commandOptionRRearrangesGridByName(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .optionKRearrangesGridByKind:
            return commandOptionKRearrangesGridByKind(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .optionKSortsOpenFolderByKind:
            return commandOptionKSortsOpenFolderByKind(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .optionGRearrangesGridByCategory:
            return commandOptionGRearrangesGridByCategory(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .optionGSortsOpenFolderByCategory:
            return commandOptionGSortsOpenFolderByCategory(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .shiftCRearrangesGridByColor:
            return commandShiftCRearrangesGridByColor(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .optionBTogglesBrowseAxis:
            return commandOptionBTogglesBrowseAxis(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .optionUUngroupsAllFolders:
            return commandOptionUUngroupsAllFolders(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .shiftURestoresAllHidden:
            return commandShiftURestoresAllHiddenApplications(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .reloadCatalog:
            return commandRReloadsCatalog(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            )
        case .shiftHHidesFocusedApp:
            return commandShiftHHidesFocusedApp(
                character: probe.character,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                focusedIsApp: probe.focusedIsApp,
                focusedIsInSelection: probe.focusedIsInSelection,
                batchHideCount: probe.selectedAppCount
            ) != nil
        case .removeFromOpenFolder:
            return commandDeleteFolderRemoval(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                focusedIsRemovableMember: probe.focusedIsRemovableMember,
                selectedMemberCount: probe.selectedMemberCount,
                batchRemovalAllowed: probe.batchRemovalAllowed
            ) != nil
        case .dissolveClosedFolder:
            return commandDeleteDissolvesClosedFolder(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                folderOpen: probe.folderOpen,
                isSearching: probe.isSearching,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                focusedIsFolder: probe.focusedIsFolder,
                selectedFolderCount: probe.selectedFolderCount,
                batchDissolveAllowed: probe.batchDissolveAllowed
            ) != nil
        case .uninstallApp:
            return commandShiftDeleteUninstallsFocusedApp(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                focusedIsApp: probe.focusedIsApp,
                focusedIsInSelection: probe.focusedIsInSelection,
                selectedAppCount: probe.selectedAppCount
            ) != nil
        case .shiftReturnRevealsSelection:
            return commandShiftReturnRevealsSelection(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                selectedCount: probe.selectedCount
            )
        case .revealSearchHit:
            let commandOnly = probe.command && !probe.shift && !probe.option && !probe.control
            return searchRevealShortcutMatches(
                keyCode: probe.keyCode,
                commandOnly: commandOnly,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                hasMarkedText: probe.hasMarkedText
            )
        case .revealFocusedTile:
            let commandOnly = probe.command && !probe.shift && !probe.option && !probe.control
            // Search still wins while a query is showing, same as performKeyEquivalent.
            return gridTileCommandReturnReveals(
                keyCode: probe.keyCode,
                commandOnly: commandOnly,
                canRevealInFinder: probe.canRevealInFinder
            ) && !searchRevealShortcutMatches(
                keyCode: probe.keyCode,
                commandOnly: commandOnly,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                hasMarkedText: probe.hasMarkedText
            )
        case .shiftVerticalMovesFocusedFolderMember:
            return commandShiftVerticalMovesFocusedFolderMemberToEdge(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .shiftVerticalSelectionEdge:
            return commandShiftVerticalSelectionEdge(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                selectedTopLevelCount: probe.selectedTopLevelCount
            ) != nil
        case .optionVerticalNudgesFocusedFolderMember:
            return commandOptionVerticalNudgesFocusedFolderMember(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .optionVerticalMovesFoldersToEdge:
            return commandOptionVerticalMovesFoldersToEdge(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .commandUpClosesOpenFolder:
            return commandUpClosesOpenFolder(
                keyCode: probe.keyCode,
                commandOnly: probe.command && !probe.shift && !probe.option && !probe.control,
                folderOpen: probe.folderOpen,
                isEditingFolderTitle: probe.isEditingFolderTitle,
                hasMarkedText: probe.hasMarkedText
            )
        case .commandDownOpensFocusedFolder:
            return commandDownOpensFocusedFolder(
                keyCode: probe.keyCode,
                commandOnly: probe.command && !probe.shift && !probe.option && !probe.control,
                focusedIsFolder: probe.focusedIsFolder,
                folderAlreadyOpen: probe.folderOpen,
                isSearching: probe.isSearching
            )
        case .optionShiftHorizontalMovesFocusedEntryToAdjacentPage:
            return commandOptionShiftHorizontalMovesFocusedEntryToAdjacentPage(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .optionHorizontalNudgesFocusedFolderMember:
            return commandOptionHorizontalNudgesFocusedFolderMember(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .shiftHorizontalMovesFocusedFolderMember:
            return commandShiftHorizontalMovesFocusedFolderMemberToEdge(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .optionHorizontalNudgesFocusedEntry:
            return commandOptionHorizontalNudgesFocusedEntry(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .shiftHorizontalMovesFocusedEntry:
            return commandShiftHorizontalMovesFocusedEntryToEdge(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging
            ) != nil
        case .commandArrowPaging:
            let commandOnly = probe.command && !probe.shift && !probe.option && !probe.control
            // Close / open-folder still win. The handler also refuses search,
            // an open folder, and a single page; it still calls movePage.
            return CommandArrowPaging.pageTurnDirection(
                keyCode: probe.keyCode,
                commandOnly: commandOnly,
                pageFlipHorizontal: probe.pageFlipHorizontal
            ) != nil
                && !probe.folderOpen
                && !probe.isSearching
                && probe.pageCount > 1
                && !commandDownOpensFocusedFolder(
                    keyCode: probe.keyCode,
                    commandOnly: commandOnly,
                    focusedIsFolder: probe.focusedIsFolder,
                    folderAlreadyOpen: probe.folderOpen,
                    isSearching: probe.isSearching
                )
        case .escapeCancels:
            return commandEscapeCancelsOrDismisses(keyCode: probe.keyCode)
        case .spaceActivatesFocusedItem:
            return spaceActivatesFocusedItem(character: probe.character)
        case .arrowExtendsSelection:
            return arrowExtendsSelection(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control
            )
        case .arrowWalksGrid:
            return arrowWalksGrid(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control
            )
        case .shiftHomeEndExtendsSelection:
            return commandShiftHomeEndExtendsSelection(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control
            )
        case .homeEndJumpsInGrid:
            return commandHomeEndJumpsInGrid(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control
            )
        case .f2RenamesFocusedClosedFolder:
            return f2RenamesFocusedClosedFolder(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                focusedIsFolder: probe.focusedIsFolder
            )
        case .f2RenamesFocusedAppAlias:
            return f2RenamesFocusedAppAlias(
                keyCode: probe.keyCode,
                command: probe.command,
                shift: probe.shift,
                option: probe.option,
                control: probe.control,
                isEditingText: probe.isEditingText,
                layoutEditingEnabled: probe.layoutEditingEnabled,
                acceptsAction: probe.acceptsAction,
                isPaging: probe.isPaging,
                focusedIsApp: probe.focusedIsApp
            )
        case .pageUpDownScrollsOpenList:
            return commandPageUpDownScrollsOpenList(
                keyCode: probe.keyCode,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen
            )
        case .pageUpDownPagesGrid:
            return commandPageUpDownPagesGrid(
                keyCode: probe.keyCode,
                isSearching: probe.isSearching,
                folderOpen: probe.folderOpen
            )
        }
    }

    public static func matchingKeyboardCommands(
        _ probe: KeyboardProbe
    ) -> [KeyboardCommand] {
        registeredKeyboardCommands.filter { keyboardCommand($0, matches: probe) }
    }

    public static func resolveKeyboardCommand(
        _ probe: KeyboardProbe
    ) -> KeyboardCommand? {
        matchingKeyboardCommands(probe).first
    }
}
