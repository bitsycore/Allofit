import SwiftUI
import AppKit

// Actions the results table asks its owner to perform on a set of records.
enum ResultAction {
	case primary              // double-click / Return (open or reveal, per Settings)
	case open                 // open with the default app
	case openWith(URL)        // open with a specific app
	case reveal               // reveal in Finder
	case quickLook            // Quick Look panel
	case copyFiles            // copy the files themselves
	case copyNames            // copy names, one per line
	case copyPaths            // copy full paths, one per line
	case trash                // move to Trash
	case authorize            // stage an unreadable file through an admin prompt
}

// ResultsTable shows every search result in a native NSTableView. Only the
// rows on screen get views, so the list isn't capped: a query matching the
// whole index scrolls as smoothly as one matching ten files. It also gives
// Finder-accurate drag and drop (file URLs on the pasteboard), column
// order / width / visibility autosave, and Finder-style keyboard shortcuts.
struct ResultsTable: NSViewRepresentable {

	// all results, already filtered and sorted
	let records: ResultList
	// bumped by the search model whenever records change (cheap identity)
	let version: Int
	// what to emphasize in names / folders
	let highlights: SearchEngine.Highlights
	// false to show plain text (Settings > General)
	let highlightEnabled: Bool
	// selected record ids
	@Binding var selection: Set<FileRecord.ID>
	// active sort, driven by header clicks
	@Binding var sort: FileSortDescriptor
	// true when the record isn't readable without authorization
	let needsAuthorization: (FileRecord) -> Bool
	// runs an action on records
	let perform: (ResultAction, Set<FileRecord.ID>) -> Void

	// column identifiers, also the autosave keys
	static let kNameColumn = NSUserInterfaceItemIdentifier("name")
	static let kPathColumn = NSUserInterfaceItemIdentifier("path")
	static let kSizeColumn = NSUserInterfaceItemIdentifier("size")
	static let kCreatedColumn = NSUserInterfaceItemIdentifier("created")
	static let kModifiedColumn = NSUserInterfaceItemIdentifier("modified")

	// creates the coordinator acting as data source and delegate
	func makeCoordinator() -> Coordinator {
		return Coordinator(self)
	}

	// builds the scroll view, table and columns
	func makeNSView(context inContext: Context) -> NSScrollView {
		let vTable = ResultsNSTableView()
		vTable.coordinator = inContext.coordinator
		vTable.allowsMultipleSelection = true
		vTable.allowsColumnReordering = true
		vTable.allowsColumnResizing = true
		vTable.usesAlternatingRowBackgroundColors = true
		vTable.style = .fullWidth
		vTable.columnAutoresizingStyle = .noColumnAutoresizing
		vTable.intercellSpacing = NSSize(width: 6, height: 2)

		for (vId, vTitle, vWidth, vMin) in [
			(Self.kNameColumn, "Name", 320.0, 160.0),
			(Self.kPathColumn, "Path", 380.0, 120.0),
			(Self.kSizeColumn, "Size", 90.0, 60.0),
			(Self.kCreatedColumn, "Created", 140.0, 90.0),
			(Self.kModifiedColumn, "Modified", 140.0, 90.0)
		] {
			let vColumn = NSTableColumn(identifier: vId)
			vColumn.title = vTitle
			vColumn.width = vWidth
			vColumn.minWidth = vMin
			vColumn.sortDescriptorPrototype = NSSortDescriptor(key: vId.rawValue, ascending: true)
			vTable.addTableColumn(vColumn)
		}
		// remembers column order, widths and hidden columns across launches
		vTable.autosaveName = "Allofit.ResultsTable"
		vTable.autosaveTableColumns = true

		vTable.dataSource = inContext.coordinator
		vTable.delegate = inContext.coordinator
		vTable.target = inContext.coordinator
		vTable.doubleAction = #selector(Coordinator.doubleClicked(_:))
		// dragging out of the app copies the files (like Finder)
		vTable.setDraggingSourceOperationMask(.copy, forLocal: false)

		let vMenu = NSMenu()
		vMenu.delegate = inContext.coordinator
		vTable.menu = vMenu
		inContext.coordinator.installHeaderMenu(on: vTable)

		let vScroll = NSScrollView()
		vScroll.documentView = vTable
		vScroll.hasVerticalScroller = true
		vScroll.hasHorizontalScroller = true
		vScroll.autohidesScrollers = true
		vScroll.borderType = .noBorder
		inContext.coordinator.table = vTable
		inContext.coordinator.apply(inParent: self, inForce: true)
		return vScroll
	}

	// pushes new results / sort / selection into the table
	func updateNSView(_ inView: NSScrollView, context inContext: Context) {
		inContext.coordinator.apply(inParent: self, inForce: false)
	}

	// ===========================
	// MARK: Sort mapping
	// ===========================

	// sort mode for a column key + direction
	static func descriptor(forKey inKey: String, ascending inAscending: Bool) -> FileSortDescriptor {
		switch inKey {
			case kPathColumn.rawValue: return inAscending ? .pathAscending : .pathDescending
			case kSizeColumn.rawValue: return inAscending ? .sizeAscending : .sizeDescending
			case kCreatedColumn.rawValue: return inAscending ? .createdAscending : .createdDescending
			case kModifiedColumn.rawValue: return inAscending ? .modifiedAscending : .modifiedDescending
			default: return inAscending ? .nameAscending : .nameDescending
		}
	}

	// column key + direction for a sort mode
	static func sortDescriptor(for inSort: FileSortDescriptor) -> NSSortDescriptor {
		switch inSort {
			case .nameAscending: return NSSortDescriptor(key: kNameColumn.rawValue, ascending: true)
			case .nameDescending: return NSSortDescriptor(key: kNameColumn.rawValue, ascending: false)
			case .pathAscending: return NSSortDescriptor(key: kPathColumn.rawValue, ascending: true)
			case .pathDescending: return NSSortDescriptor(key: kPathColumn.rawValue, ascending: false)
			case .sizeAscending: return NSSortDescriptor(key: kSizeColumn.rawValue, ascending: true)
			case .sizeDescending: return NSSortDescriptor(key: kSizeColumn.rawValue, ascending: false)
			case .createdAscending: return NSSortDescriptor(key: kCreatedColumn.rawValue, ascending: true)
			case .createdDescending: return NSSortDescriptor(key: kCreatedColumn.rawValue, ascending: false)
			case .modifiedAscending: return NSSortDescriptor(key: kModifiedColumn.rawValue, ascending: true)
			case .modifiedDescending: return NSSortDescriptor(key: kModifiedColumn.rawValue, ascending: false)
		}
	}

	// ===========================
	// MARK: Coordinator
	// ===========================

	// Coordinator feeds the table from the current records and turns table
	// events (selection, sort clicks, menus, drags) into SwiftUI updates.
	@MainActor
	final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

		// latest SwiftUI description of the table
		var parent: ResultsTable
		// the table, set once created
		weak var table: NSTableView?
		// rows currently shown
		private var records = ResultList()
		// version of `records`, to skip redundant reloads
		private var shownVersion = -1
		// highlight settings the visible rows were drawn with
		private var shownHighlights = SearchEngine.Highlights()
		private var shownHighlightEnabled = true
		// sort the header currently shows
		private var shownSort: FileSortDescriptor?
		// true while the coordinator itself changes selection / sort, so the
		// resulting delegate callbacks aren't echoed back to SwiftUI
		private var isApplying = false

		// binds to the initial SwiftUI description
		init(_ inParent: ResultsTable) {
			parent = inParent
		}

		// syncs the table with a (possibly) new SwiftUI description
		func apply(inParent: ResultsTable, inForce: Bool) {
			parent = inParent
			guard let vTable = table else { return }
			isApplying = true
			defer { isApplying = false }

			if shownSort != inParent.sort {
				shownSort = inParent.sort
				vTable.sortDescriptors = [ResultsTable.sortDescriptor(for: inParent.sort)]
			}
			let vHighlightsChanged = shownHighlights != inParent.highlights
				|| shownHighlightEnabled != inParent.highlightEnabled
			if inForce || shownVersion != inParent.version || vHighlightsChanged {
				shownVersion = inParent.version
				shownHighlights = inParent.highlights
				shownHighlightEnabled = inParent.highlightEnabled
				records = inParent.records
				vTable.reloadData()
				restoreSelection(inTable: vTable)
			} else if selectedIds(inTable: vTable) != inParent.selection {
				restoreSelection(inTable: vTable)
			}
		}

		// selects the rows whose ids are in the SwiftUI selection
		private func restoreSelection(inTable: NSTableView) {
			let vWanted = parent.selection
			var vRows = IndexSet()
			if !vWanted.isEmpty {
				for (vRow, vRecord) in records.enumerated() where vWanted.contains(vRecord.id) {
					vRows.insert(vRow)
					if vRows.count == vWanted.count { break }
				}
			}
			inTable.selectRowIndexes(vRows, byExtendingSelection: false)
		}

		// ids of the rows selected in the table
		private func selectedIds(inTable: NSTableView) -> Set<FileRecord.ID> {
			var vIds = Set<FileRecord.ID>()
			for vRow in inTable.selectedRowIndexes where vRow < records.count {
				vIds.insert(records[vRow].id)
			}
			return vIds
		}

		// selection as ids, for the actions
		var currentSelection: Set<FileRecord.ID> {
			guard let vTable = table else { return [] }
			return selectedIds(inTable: vTable)
		}

		// runs an action on the current selection
		func perform(_ inAction: ResultAction) {
			let vIds = currentSelection
			guard !vIds.isEmpty else { return }
			parent.perform(inAction, vIds)
		}

		// ===========================
		// MARK: Data source
		// ===========================

		// number of results
		func numberOfRows(in inTableView: NSTableView) -> Int {
			return records.count
		}

		// drag: each row writes its file URL, exactly like a Finder drag
		func tableView(_ inTableView: NSTableView, pasteboardWriterForRow inRow: Int) -> NSPasteboardWriting? {
			guard inRow < records.count else { return nil }
			return URL(fileURLWithPath: records[inRow].fullPath) as NSURL
		}

		// header click: switch the sort (written back after the callback)
		func tableView(_ inTableView: NSTableView, sortDescriptorsDidChange inOld: [NSSortDescriptor]) {
			guard !isApplying, let vFirst = inTableView.sortDescriptors.first, let vKey = vFirst.key else { return }
			let vSort = ResultsTable.descriptor(forKey: vKey, ascending: vFirst.ascending)
			shownSort = vSort
			// deferred so SwiftUI isn't updated from inside a table callback
			DispatchQueue.main.async { [weak self] in
				self?.parent.sort = vSort
			}
		}

		// ===========================
		// MARK: Delegate
		// ===========================

		// cell view for one row / column, reused from the table's pool
		func tableView(_ inTableView: NSTableView, viewFor inColumn: NSTableColumn?, row inRow: Int) -> NSView? {
			guard let vColumn = inColumn, inRow < records.count else { return nil }
			let vRecord = records[inRow]
			let vCell = (inTableView.makeView(withIdentifier: vColumn.identifier, owner: nil) as? ResultCellView)
				?? ResultCellView(inIdentifier: vColumn.identifier, inWithIcon: vColumn.identifier == ResultsTable.kNameColumn)
			let vTerms = parent.highlightEnabled ? parent.highlights : SearchEngine.Highlights()
			switch vColumn.identifier {
				case ResultsTable.kNameColumn:
					vCell.imageView?.image = IconCache.icon(forName: vRecord.name, isDirectory: vRecord.isDirectory)
					vCell.show(inText: vRecord.name, inTerms: vTerms.name, inSecondary: false, inMiddleTruncation: false)
				case ResultsTable.kPathColumn:
					vCell.show(inText: vRecord.parentPath, inTerms: vTerms.path, inSecondary: true, inMiddleTruncation: true)
				case ResultsTable.kSizeColumn:
					vCell.show(inText: vRecord.isDirectory ? "-" : Formatters.size(bytes: vRecord.size), inTerms: [], inSecondary: true, inMiddleTruncation: false)
				case ResultsTable.kCreatedColumn:
					vCell.show(inText: Formatters.date(vRecord.dateCreated), inTerms: [], inSecondary: true, inMiddleTruncation: false)
				default:
					vCell.show(inText: Formatters.date(vRecord.dateModified), inTerms: [], inSecondary: true, inMiddleTruncation: false)
			}
			return vCell
		}

		// selection changed in the table: publish the ids
		func tableViewSelectionDidChange(_ inNotification: Notification) {
			guard !isApplying, let vTable = table else { return }
			let vIds = selectedIds(inTable: vTable)
			DispatchQueue.main.async { [weak self] in
				guard let vSelf = self, vSelf.parent.selection != vIds else { return }
				vSelf.parent.selection = vIds
			}
		}

		// double-click on a row
		@objc func doubleClicked(_ inSender: Any?) {
			guard let vTable = table, vTable.clickedRow >= 0 else { return }
			perform(.primary)
		}

		// ===========================
		// MARK: Menus
		// ===========================

		// right-click menu, rebuilt for the clicked row: like Finder, a click
		// outside the selection selects that row first
		func menuNeedsUpdate(_ inMenu: NSMenu) {
			inMenu.removeAllItems()
			guard let vTable = table else { return }
			let vClicked = vTable.clickedRow
			if vClicked >= 0, !vTable.selectedRowIndexes.contains(vClicked) {
				vTable.selectRowIndexes(IndexSet(integer: vClicked), byExtendingSelection: false)
			}
			let vIds = currentSelection
			guard !vIds.isEmpty else { return }
			let vSelected = records.filter { vIds.contains($0.id) }

			inMenu.addItem(ClosureMenuItem("Open") { [weak self] in self?.perform(.open) })
			if let vFirst = vSelected.first {
				inMenu.addItem(openWithItem(for: vFirst))
			}
			inMenu.addItem(ClosureMenuItem("Reveal in Finder") { [weak self] in self?.perform(.reveal) })
			inMenu.addItem(ClosureMenuItem("Quick Look") { [weak self] in self?.perform(.quickLook) })
			inMenu.addItem(.separator())
			inMenu.addItem(ClosureMenuItem("Copy") { [weak self] in self?.perform(.copyFiles) })
			inMenu.addItem(ClosureMenuItem("Copy Name") { [weak self] in self?.perform(.copyNames) })
			inMenu.addItem(ClosureMenuItem("Copy Path") { [weak self] in self?.perform(.copyPaths) })
			if vIds.count == 1, let vOnly = vSelected.first, parent.needsAuthorization(vOnly) {
				inMenu.addItem(.separator())
				inMenu.addItem(ClosureMenuItem("Authorize Access…") { [weak self] in self?.perform(.authorize) })
			}
			inMenu.addItem(.separator())
			inMenu.addItem(ClosureMenuItem("Move to Trash") { [weak self] in self?.perform(.trash) })
		}

		// "Open With" submenu: default app first, then the other candidates
		private func openWithItem(for inRecord: FileRecord) -> NSMenuItem {
			let vItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
			let vSub = NSMenu()
			let vUrl = URL(fileURLWithPath: inRecord.fullPath)
			let vDefault = NSWorkspace.shared.urlForApplication(toOpen: vUrl)
			let vApps = [vDefault].compactMap { $0 }
				+ NSWorkspace.shared.urlsForApplications(toOpen: vUrl).filter { $0 != vDefault }
			for vApp in vApps {
				let vTitle = FileManager.default.displayName(atPath: vApp.path) + (vApp == vDefault ? " (default)" : "")
				let vAppItem = ClosureMenuItem(vTitle) { [weak self] in self?.perform(.openWith(vApp)) }
				let vIcon = NSWorkspace.shared.icon(forFile: vApp.path)
				vIcon.size = NSSize(width: 16, height: 16)
				vAppItem.image = vIcon
				vSub.addItem(vAppItem)
			}
			vItem.submenu = vSub
			vItem.isEnabled = !vApps.isEmpty
			return vItem
		}

		// header right-click menu to show / hide columns (Name stays)
		func installHeaderMenu(on inTable: NSTableView) {
			let vMenu = NSMenu()
			for vColumn in inTable.tableColumns where vColumn.identifier != ResultsTable.kNameColumn {
				let vItem = ClosureMenuItem(vColumn.title) { [weak vColumn] in
					vColumn?.isHidden.toggle()
				}
				vItem.representedObject = vColumn
				vMenu.addItem(vItem)
			}
			vMenu.delegate = HeaderMenuStates.shared
			inTable.headerView?.menu = vMenu
		}
	}
}

// ResultsNSTableView adds Finder-style keyboard shortcuts and Edit > Copy to
// the results table.
final class ResultsNSTableView: NSTableView {

	// owner that performs the actions
	weak var coordinator: ResultsTable.Coordinator?

	// Space / Return / ⌘Return / ⌘Y / ⌥⌘C / ⌘⌫; everything else (arrows,
	// type-select, ⌘A) goes to NSTableView
	override func keyDown(with inEvent: NSEvent) {
		let vMods = inEvent.modifierFlags.intersection([.command, .option, .shift, .control])
		let vChars = inEvent.charactersIgnoringModifiers?.lowercased() ?? ""
		let vAction: ResultAction?
		switch (Int(inEvent.keyCode), vMods) {
			case (49, []): vAction = .quickLook                  // Space
			case (36, []), (76, []): vAction = .primary          // Return / Enter
			case (36, [.command]), (76, [.command]): vAction = .reveal
			case (51, [.command]): vAction = .trash              // ⌘⌫
			default:
				if vChars == "y" && vMods == [.command] {
					vAction = .quickLook
				} else if vChars == "c" && vMods == [.command, .option] {
					vAction = .copyPaths
				} else {
					vAction = nil
				}
		}
		guard let vRun = vAction, selectedRow >= 0 else {
			super.keyDown(with: inEvent)
			return
		}
		coordinator?.perform(vRun)
	}

	// Edit > Copy (⌘C) copies the files themselves, like Finder
	@objc func copy(_ inSender: Any?) {
		coordinator?.perform(.copyFiles)
	}

	// enables Edit > Copy only with a selection
	override func validateUserInterfaceItem(_ inItem: NSValidatedUserInterfaceItem) -> Bool {
		if inItem.action == #selector(copy(_:)) {
			return selectedRow >= 0
		}
		return super.validateUserInterfaceItem(inItem)
	}
}

// ResultCellView is one cell: optional icon + a label. Highlights are drawn
// in bold; the colors follow the row's selection state so bold text stays
// readable on the blue selection.
final class ResultCellView: NSTableCellView {

	// text, highlight terms and style of the current content
	private var text = ""
	private var terms: [String] = []
	private var isSecondary = false

	// builds the cell's subviews
	init(inIdentifier: NSUserInterfaceItemIdentifier, inWithIcon: Bool) {
		super.init(frame: .zero)
		identifier = inIdentifier
		let vLabel = NSTextField(labelWithString: "")
		vLabel.translatesAutoresizingMaskIntoConstraints = false
		vLabel.lineBreakMode = .byTruncatingTail
		vLabel.cell?.usesSingleLineMode = true
		// hovering a cut-off name / path shows the full text right away,
		// drawn over the cell (Finder's expansion tooltip), instead of a
		// help tag that waits for the tooltip delay
		vLabel.allowsExpansionToolTips = true
		addSubview(vLabel)
		textField = vLabel
		if inWithIcon {
			let vImage = NSImageView()
			vImage.translatesAutoresizingMaskIntoConstraints = false
			vImage.imageScaling = .scaleProportionallyDown
			addSubview(vImage)
			imageView = vImage
			NSLayoutConstraint.activate([
				vImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
				vImage.centerYAnchor.constraint(equalTo: centerYAnchor),
				vImage.widthAnchor.constraint(equalToConstant: 16),
				vImage.heightAnchor.constraint(equalToConstant: 16),
				vLabel.leadingAnchor.constraint(equalTo: vImage.trailingAnchor, constant: 6)
			])
		} else {
			vLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
		}
		NSLayoutConstraint.activate([
			vLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
			vLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}

	// not used: cells are created in code
	required init?(coder inCoder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	// sets the content and redraws it
	func show(inText: String, inTerms: [String], inSecondary: Bool, inMiddleTruncation: Bool) {
		text = inText
		terms = inTerms
		isSecondary = inSecondary
		textField?.lineBreakMode = inMiddleTruncation ? .byTruncatingMiddle : .byTruncatingTail
		render()
	}

	// selection highlight changed: recolor
	override var backgroundStyle: NSView.BackgroundStyle {
		didSet { render() }
	}

	// draws the label, bold where the terms match
	private func render() {
		guard let vLabel = textField else { return }
		let vEmphasized = backgroundStyle == .emphasized
		let vColor: NSColor = vEmphasized
			? .alternateSelectedControlTextColor
			: (isSecondary ? .secondaryLabelColor : .labelColor)
		let vFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		if terms.isEmpty {
			vLabel.font = isSecondary ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : vFont
			vLabel.textColor = vColor
			vLabel.stringValue = text
			return
		}
		let vString = NSMutableAttributedString(string: text, attributes: [.font: vFont, .foregroundColor: vColor])
		let vBold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
		let vNs = text as NSString
		for vTerm in terms {
			var vSearch = NSRange(location: 0, length: vNs.length)
			while vSearch.length > 0 {
				let vFound = vNs.range(of: vTerm, options: [.caseInsensitive, .diacriticInsensitive], range: vSearch)
				if vFound.location == NSNotFound || vFound.length == 0 { break }
				vString.addAttribute(.font, value: vBold, range: vFound)
				let vNext = vFound.location + vFound.length
				vSearch = NSRange(location: vNext, length: vNs.length - vNext)
			}
		}
		vLabel.attributedStringValue = vString
	}
}

// ClosureMenuItem is an NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {

	// what the item does
	private let handler: () -> Void

	// creates an item titled inTitle running inHandler
	init(_ inTitle: String, _ inHandler: @escaping () -> Void) {
		handler = inHandler
		super.init(title: inTitle, action: #selector(run(_:)), keyEquivalent: "")
		target = self
	}

	// not used: items are created in code
	required init(coder inCoder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	// menu callback
	@objc private func run(_ inSender: Any?) {
		handler()
	}
}

// HeaderMenuStates ticks the visible columns each time the header menu opens.
final class HeaderMenuStates: NSObject, NSMenuDelegate {

	// shared delegate for every results table's header menu
	static let shared = HeaderMenuStates()

	// marks shown columns with a checkmark
	func menuNeedsUpdate(_ inMenu: NSMenu) {
		for vItem in inMenu.items {
			if let vColumn = vItem.representedObject as? NSTableColumn {
				vItem.state = vColumn.isHidden ? .off : .on
			}
		}
	}
}
