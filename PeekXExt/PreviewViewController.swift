// PeekX - Folder Preview Extension for macOS
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa
import Quartz
import UniformTypeIdentifiers
import QuickLook
import ImageIO
import WebKit
import QuartzCore  // For CATransaction
import QuickLookThumbnailing

// MARK: - Debug Logger
final class DebugLogger {
    static let shared = DebugLogger()
    
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.peekx.logger", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let maxSize: UInt64 = 256 * 1024 // 256 KB
    
    private init() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        fileURL = temp.appendingPathComponent("PeekXExt.log")
    }
    
    func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        queue.async {
            if let data = entry.data(using: .utf8) {
                self.append(data)
            }
            NSLog(message)
        }
    }
    
    func locationDescription() -> String { fileURL.path }
    
    private func append(_ data: Data) {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                try data.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
            pruneIfNeeded()
        } catch {
            NSLog("PeekX logger error: \(error.localizedDescription)")
        }
    }
    
    private func pruneIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size > maxSize
        else { return }
        
        if let data = try? Data(contentsOf: fileURL) {
            let trimmed = data.suffix(Int(maxSize / 2))
            try? trimmed.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Custom Outline View

/// Protocol for handling keyboard events in the outline view
protocol FinderOutlineViewKeyboardDelegate: AnyObject {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool
}

protocol FinderCollectionViewKeyboardDelegate: AnyObject {
    func collectionView(_ collectionView: FinderCollectionView, handle event: NSEvent) -> Bool
}

/// Custom outline view that intercepts keyboard events for QuickLook-specific shortcuts
final class FinderOutlineView: NSOutlineView {
    weak var keyboardDelegate: FinderOutlineViewKeyboardDelegate?
    
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    
    override func keyDown(with event: NSEvent) {
        if keyboardDelegate?.outlineView(self, handle: event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class FinderCollectionView: NSCollectionView {
    weak var keyboardDelegate: FinderCollectionViewKeyboardDelegate?

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyboardDelegate?.collectionView(self, handle: event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if keyboardDelegate?.collectionView(self, handle: event) == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class FinderGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FinderGridItem")

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        image.imageAlignment = .alignCenter

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor

        root.addSubview(image)
        root.addSubview(label)

        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            image.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            image.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            image.heightAnchor.constraint(equalToConstant: 72),

            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -6)
        ])

        self.view = root
        self.imageView = image
        self.textField = label
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        }
    }
}

// MARK: - File Item Model

/// Represents a file or folder in the preview hierarchy
final class FileItem: NSObject, QLPreviewItem {
    let url: URL
    let name: String
    let isFolder: Bool
    let size: Int64
    let modificationDate: Date
    let contentType: UTType?
    weak var parent: FileItem?
    var icon: NSImage?
    var children: [FileItem]?
    var childrenLoaded = false
    
    // Cached formatted strings to avoid repeated formatting
    private var _formattedSize: String?
    private var _formattedDate: String?
    private var _kindDescription: String?
    private var _previewInfo: String?
    private let fileExtension: String
    
    // Cached type checks for fast preview decisions
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "icns"]
    private static let textExtensions: Set<String> = ["md", "markdown", "txt", "rtf", "json", "yaml", "yml", "xml", "log", "csv", "tsv", "swift", "sh"]
    
    lazy var isImage: Bool = (contentType?.conforms(to: .image) ?? false) || Self.imageExtensions.contains(fileExtension)
    lazy var isText: Bool = (contentType?.conforms(to: .text) ?? false) || Self.textExtensions.contains(fileExtension)
    lazy var isMedia: Bool = contentType?.conforms(to: .audiovisualContent) ?? false
    lazy var isPDF: Bool = contentType?.conforms(to: .pdf) ?? false || fileExtension == "pdf"
    
    init(url: URL, resourceValues: URLResourceValues, parent: FileItem? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.fileExtension = url.pathExtension.lowercased()
        self.isFolder = resourceValues.isDirectory ?? false
        self.size = Int64(resourceValues.fileSize ?? 0)
        self.modificationDate = resourceValues.contentModificationDate ?? Date()
        self.contentType = resourceValues.contentType
        self.parent = parent
        super.init()
    }
    
    var kindDescription: String {
        if let cached = _kindDescription {
            return cached
        }
        let desc = isFolder ? "Folder" : (contentType?.localizedDescription ?? "File")
        _kindDescription = desc
        return desc
    }
    
    // Lazy formatted size - computed once and cached
    func formattedSize(using formatter: ByteCountFormatter) -> String {
        if let cached = _formattedSize {
            return cached
        }
        let formatted = isFolder ? "—" : formatter.string(fromByteCount: size)
        _formattedSize = formatted
        return formatted
    }
    
    // Lazy formatted date - computed once and cached
    func formattedDate(using formatter: DateFormatter) -> String {
        if let cached = _formattedDate {
            return cached
        }
        let formatted = formatter.string(from: modificationDate)
        _formattedDate = formatted
        return formatted
    }
    
    // Pre-build complete preview info string
    func previewInfo(sizeFormatter: ByteCountFormatter, dateFormatter: DateFormatter) -> String {
        if let cached = _previewInfo {
            return cached
        }
        var segments: [String] = []
        if !isFolder {
            segments.append(formattedSize(using: sizeFormatter))
        }
        segments.append(kindDescription)
        segments.append(formattedDate(using: dateFormatter))
        let info = segments.joined(separator: " · ")
        _previewInfo = info
        return info
    }
    
    func setChildren(_ children: [FileItem]) {
        self.children = children
        self.childrenLoaded = true
        for child in children {
            child.parent = self
        }
    }
    
    func resetChildren() {
        children = nil
        childrenLoaded = false
    }
    
    var previewItemURL: URL? { url }
    var previewItemTitle: String { name }
}

// MARK: - Preview View Controller

/// Main view controller for the QuickLook folder preview extension
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    
    // MARK: - Filter Types
    
    private enum FilterType: Int {
        case all, folders, images, documents, media
        
        func matches(_ item: FileItem) -> Bool {
            switch self {
            case .all:
                return true
            case .folders:
                return item.isFolder
            case .images:
                return item.isImage
            case .documents:
                if item.isFolder { return false }
                // Document = not image and not media
                return !item.isImage && !item.isMedia
            case .media:
                return item.isMedia
            }
        }
    }

    private enum ViewMode: Int {
        case list = 0
        case grid = 1
        case fullList = 2
    }
    
    // MARK: - UI Components
    
    private var mainStack: NSStackView!
    private var scrollView: NSScrollView!
    private var gridScrollView: NSScrollView!
    private var collectionView: FinderCollectionView!
    private var splitView: NSSplitView!
    private var outlineView: FinderOutlineView!
    private var headerView: NSView!
    private var iconImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var controlsStack: NSStackView!
    private var filterControl: NSSegmentedControl!
    private var sortKeyControl: NSSegmentedControl!
    private var sortOrderControl: NSSegmentedControl!
    private var viewModeControl: NSSegmentedControl!
    private var previewPane: NSView!
    private var pathBarView: NSView!
    private var pathControl: NSPathControl!
    private var previewImageView: NSImageView!
    private var webView: WKWebView!
    private var singleFileWebView: WKWebView!  // Separate WebView for single file mode
    private var previewSpinner: NSProgressIndicator!
    private var previewTitleLabel: NSTextField!
    private var previewInfoLabel: NSTextField!
    private var previewMessageLabel: NSTextField!
    private var previewPaneMinWidthConstraint: NSLayoutConstraint?
    private var outlinePaneMinWidthConstraint: NSLayoutConstraint?
    
    // MARK: - Performance Caches
    
    private let iconCache = NSCache<NSString, NSImage>()
    private let iconLoadQueue = DispatchQueue(label: "com.peekx.iconloader", qos: .userInitiated, attributes: .concurrent)
    private let thumbnailCache = NSCache<NSString, NSImage>()
    
    // MARK: - Data State
    
    private var rootItems: [FileItem] = []
    private var filterType: FilterType = .all
    private var currentSortDescriptor: NSSortDescriptor? = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    private var visibleRootItems: [FileItem] = []
    private var previewedItem: FileItem?
    private var previewImageLoadTask: DispatchWorkItem?
    private var previewFallbackTask: DispatchWorkItem?
    private var previewRootURL: URL?
    private var activeArchiveExtractionURL: URL?
    private var didSetInitialSplitPosition = false
    private var singleFileMode = false
    private var previewUpdateWorkItem: DispatchWorkItem?
    private var currentViewMode: ViewMode = .list
    private var gridContextItem: FileItem?
    private var isApplyingSplitRatio = false
    
    private let prefs = UserDefaults.standard
    private let defaultSplitRatio: CGFloat = 0.4
    
    private enum PreferenceKeys {
        static let previewWidth = "peekx.previewWidth"
        static let previewHeight = "peekx.previewHeight"
        static let splitRatio = "peekx.splitRatio"
        static let viewMode = "peekx.viewMode"
    }

    deinit {
        cleanupActiveArchiveExtraction()
    }
    
    // MARK: - Formatters
    
    private lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    
    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
    
    // MARK: - View Lifecycle
    
    override func loadView() {
        let preferredSize = loadPreferredPreviewSize()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: preferredSize.width, height: preferredSize.height))
        container.translatesAutoresizingMaskIntoConstraints = false
        preferredContentSize = preferredSize
        
        // Main Vertical Stack
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.distribution = .fill
        self.mainStack = stack
        
        headerView = createHeaderView()
        controlsStack = createControlsStack()
        pathBarView = createPathBar()
        
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        
        outlineView = FinderOutlineView()
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.focusRingType = .none
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .default
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = true
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.keyboardDelegate = self
        outlineView.menu = contextMenu
        outlineView.menu?.delegate = self
        
        scrollView.documentView = outlineView

        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 12
        layout.itemSize = NSSize(width: 110, height: 112)

        collectionView = FinderCollectionView()
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.collectionViewLayout = layout
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.keyboardDelegate = self
        collectionView.isSelectable = true
        collectionView.register(FinderGridItem.self, forItemWithIdentifier: FinderGridItem.identifier)
        collectionView.backgroundColors = [.clear]
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleGridDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        gridScrollView = NSScrollView()
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false
        gridScrollView.hasVerticalScroller = true
        gridScrollView.autohidesScrollers = true
        gridScrollView.borderType = .noBorder
        gridScrollView.documentView = collectionView
        gridScrollView.isHidden = true
        
        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter
        splitView.delegate = self
        splitView.addArrangedSubview(scrollView)
        previewPane = createPreviewPane()
        splitView.addArrangedSubview(previewPane)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        outlinePaneMinWidthConstraint = splitView.arrangedSubviews[0].widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        previewPaneMinWidthConstraint = splitView.arrangedSubviews[1].widthAnchor.constraint(greaterThanOrEqualToConstant: 340)
        outlinePaneMinWidthConstraint?.isActive = true
        previewPaneMinWidthConstraint?.isActive = true
        splitView.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        splitView.arrangedSubviews[0].setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        splitView.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        splitView.arrangedSubviews[1].setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        mainStack.addArrangedSubview(headerView)
        mainStack.addArrangedSubview(controlsStack)
        mainStack.addArrangedSubview(splitView)
        mainStack.addArrangedSubview(gridScrollView)
        mainStack.addArrangedSubview(pathBarView)

        container.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            
            headerView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            controlsStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            splitView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            gridScrollView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            pathBarView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            pathBarView.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        // Content priorities to ensure SplitView fills space
        headerView.setContentHuggingPriority(.required, for: .vertical)
        controlsStack.setContentHuggingPriority(.required, for: .vertical)
        pathBarView.setContentHuggingPriority(.required, for: .vertical)
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        gridScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        
        // Create standalone WebView for single-file mode
        let singleFileConfig = WKWebViewConfiguration()
        singleFileWebView = WKWebView(frame: .zero, configuration: singleFileConfig)
        singleFileWebView.translatesAutoresizingMaskIntoConstraints = false
        singleFileWebView.isHidden = true
        singleFileWebView.setValue(false, forKey: "drawsBackground")
        container.addSubview(singleFileWebView)
        
        NSLayoutConstraint.activate([
            singleFileWebView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 16),
            singleFileWebView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            singleFileWebView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            singleFileWebView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        
        createColumns()
        updatePreview(for: nil)
        let storedMode = prefs.integer(forKey: PreferenceKeys.viewMode)
        // Preserve previous values and add full-list mode.
        switch storedMode {
        case 1:
            currentViewMode = .grid
        case 2:
            currentViewMode = .fullList
        default:
            currentViewMode = .list
        }
        viewModeControl.selectedSegment = currentViewMode.rawValue
        updatePathBar()
        self.view = container
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        focusPrimaryBrowser()
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        savePreferredPreviewSizeIfNeeded()
        if !didSetInitialSplitPosition {
            didSetInitialSplitPosition = true
            setDefaultSplitPosition()
            applyViewMode(currentViewMode)
        }
    }
    
    // MARK: - UI Builders
    private func createHeaderView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        iconImageView = NSImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown
        
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = NSFont.systemFont(ofSize: 13)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(iconImageView)
        view.addSubview(titleLabel)
        view.addSubview(infoLabel)
        
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            iconImageView.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
            iconImageView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 48),
            iconImageView.heightAnchor.constraint(equalToConstant: 48),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            
            infoLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            infoLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            infoLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        
        return view
    }
    
    private func createControlsStack() -> NSStackView {
        filterControl = NSSegmentedControl(labels: ["All", "Folders", "Images", "Docs", "Media"], trackingMode: .selectOne, target: self, action: #selector(filterChanged(_:)))
        filterControl.selectedSegment = FilterType.all.rawValue
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        sortKeyControl = NSSegmentedControl(labels: ["Name", "Date", "Size", "Kind"], trackingMode: .selectOne, target: self, action: #selector(sortKeyChanged(_:)))
        sortKeyControl.selectedSegment = 0
        sortKeyControl.translatesAutoresizingMaskIntoConstraints = false

        sortOrderControl = NSSegmentedControl(labels: ["Asc", "Desc"], trackingMode: .selectOne, target: self, action: #selector(sortOrderChanged(_:)))
        sortOrderControl.selectedSegment = 0
        sortOrderControl.translatesAutoresizingMaskIntoConstraints = false

        viewModeControl = NSSegmentedControl(labels: ["List", "Grid", "Full List"], trackingMode: .selectOne, target: self, action: #selector(viewModeChanged(_:)))
        viewModeControl.selectedSegment = ViewMode.list.rawValue
        viewModeControl.translatesAutoresizingMaskIntoConstraints = false
        
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [filterControl, sortKeyControl, sortOrderControl, spacer, viewModeControl])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        
        // Ensure the stack itself doesn't force a specific width if not needed, 
        // but we can center the filter control inside it.
        
        let filterWidth = filterControl.widthAnchor.constraint(equalToConstant: 300)
        let sortKeyWidth = sortKeyControl.widthAnchor.constraint(equalToConstant: 240)
        let sortOrderWidth = sortOrderControl.widthAnchor.constraint(equalToConstant: 110)
        let viewModeWidth = viewModeControl.widthAnchor.constraint(equalToConstant: 210)

        for constraint in [filterWidth, sortKeyWidth, sortOrderWidth, viewModeWidth] {
            constraint.priority = .defaultHigh
            constraint.isActive = true
        }
        
        return stack
    }
    
    private func setDefaultSplitPosition() {
        let persistedRatio = CGFloat(prefs.double(forKey: PreferenceKeys.splitRatio))
        let ratio = max(0.2, min(0.8, persistedRatio > 0 ? persistedRatio : defaultSplitRatio))
        applySplitRatio(ratio)
    }

    private func applySplitRatio(_ ratio: CGFloat) {
        guard splitView.subviews.count >= 2 else { return }
        let clampedRatio = max(0.2, min(0.8, ratio))
        view.layoutSubtreeIfNeeded()

        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }

        let minLeft: CGFloat = 280
        let minRight: CGFloat = currentViewMode == .fullList ? 0 : 340
        let maxLeft = max(minLeft, totalWidth - minRight)
        let desiredLeft = min(max(totalWidth * clampedRatio, minLeft), maxLeft)
        isApplyingSplitRatio = true
        splitView.setPosition(desiredLeft, ofDividerAt: 0)
        splitView.adjustSubviews()
        isApplyingSplitRatio = false
    }

    private func applyViewMode(_ mode: ViewMode) {
        let previousMode = currentViewMode
        currentViewMode = mode
        prefs.set(mode.rawValue, forKey: PreferenceKeys.viewMode)

        guard !singleFileMode else { return }

        switch mode {
        case .list:
            splitView.isHidden = false
            gridScrollView.isHidden = true
            previewPane.isHidden = false
            previewPaneMinWidthConstraint?.isActive = true
            // Keep user-resized split position while staying in list mode.
            // Only restore persisted/default split when returning from another mode.
            if previousMode != .list {
                setDefaultSplitPosition()
            }
        case .grid:
            splitView.isHidden = true
            gridScrollView.isHidden = false
            collectionView.reloadData()
        case .fullList:
            splitView.isHidden = false
            gridScrollView.isHidden = true
            previewPane.isHidden = true
            previewPaneMinWidthConstraint?.isActive = false
            view.layoutSubtreeIfNeeded()
            let totalWidth = splitView.bounds.width
            if totalWidth > 0 {
                splitView.setPosition(totalWidth - 1, ofDividerAt: 0)
            }
        }
        updatePathBar()
        focusPrimaryBrowser()
    }

    private func focusPrimaryBrowser() {
        let responder: NSResponder = currentViewMode == .grid ? collectionView : outlineView
        (responder as? NSView)?.window?.makeFirstResponder(responder)
    }
    
    private func createColumns() {
        outlineView.tableColumns.forEach { outlineView.removeTableColumn($0) }
        
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 250
        nameColumn.width = 380
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn
        
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Date Modified"
        dateColumn.minWidth = 160
        dateColumn.width = 200
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        outlineView.addTableColumn(dateColumn)
        
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 80
        sizeColumn.width = 120
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        outlineView.addTableColumn(sizeColumn)
        
        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.minWidth = 140
        kindColumn.width = 180
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)
        outlineView.addTableColumn(kindColumn)
    }
    
    private func createPreviewPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        
        let imageContainer = NSView()
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.wantsLayer = true
        imageContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageContainer.layer?.cornerRadius = 8
        imageContainer.layer?.masksToBounds = true
        
        previewImageView = NSImageView()
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter
        
        let webConfig = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        webView.setValue(false, forKey: "drawsBackground")
        
        previewSpinner = NSProgressIndicator()
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewSpinner.style = .spinning
        previewSpinner.controlSize = .large
        previewSpinner.isDisplayedWhenStopped = false
        
        imageContainer.addSubview(previewImageView)
        imageContainer.addSubview(webView)
        imageContainer.addSubview(previewSpinner)
        
        NSLayoutConstraint.activate([
            previewImageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            
            webView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            
            previewSpinner.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
            
            imageContainer.heightAnchor.constraint(equalToConstant: 340)
        ])
        
        previewTitleLabel = NSTextField(labelWithString: "No Selection")
        previewTitleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        previewTitleLabel.lineBreakMode = .byTruncatingTail
        
        previewInfoLabel = NSTextField(labelWithString: "Select a file to preview.")
        previewInfoLabel.font = NSFont.systemFont(ofSize: 12)
        previewInfoLabel.textColor = .secondaryLabelColor
        previewInfoLabel.lineBreakMode = .byWordWrapping
        
        previewMessageLabel = NSTextField(labelWithString: "")
        previewMessageLabel.font = NSFont.systemFont(ofSize: 12)
        previewMessageLabel.textColor = .tertiaryLabelColor
        previewMessageLabel.lineBreakMode = .byWordWrapping
        previewMessageLabel.isHidden = true
        
        stack.addArrangedSubview(imageContainer)
        stack.addArrangedSubview(previewTitleLabel)
        stack.addArrangedSubview(previewInfoLabel)
        stack.addArrangedSubview(previewMessageLabel)
        stack.setCustomSpacing(4, after: previewTitleLabel)
        
        NSLayoutConstraint.activate([
            imageContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewTitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewInfoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewMessageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor)
        ])
        
        return pane
    }
    
    private func createPathBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.material = .underPageBackground
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 6
        bar.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        
        pathControl = NSPathControl()
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.focusRingType = .none
        pathControl.font = NSFont.systemFont(ofSize: 12)
        pathControl.isEnabled = true
        pathControl.isEditable = false
        bar.addSubview(pathControl)
        
        NSLayoutConstraint.activate([
            pathControl.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            pathControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            pathControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        
        return bar
    }
    
    private func loadPreferredPreviewSize() -> CGSize {
        let width = prefs.double(forKey: PreferenceKeys.previewWidth)
        let height = prefs.double(forKey: PreferenceKeys.previewHeight)
        let defaultSize = PreviewConstants.defaultPreviewSize
        guard width >= 640, height >= 420 else {
            return defaultSize
        }
        return CGSize(width: width, height: height)
    }
    
    private func savePreferredPreviewSizeIfNeeded() {
        guard view.bounds.width >= 640, view.bounds.height >= 420 else { return }
        prefs.set(view.bounds.width, forKey: PreferenceKeys.previewWidth)
        prefs.set(view.bounds.height, forKey: PreferenceKeys.previewHeight)
        preferredContentSize = view.bounds.size
    }
    
    
    // MARK: - Preview Loading
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        cleanupActiveArchiveExtraction()

        var hasCompleted = false
        let completeOnce: (Error?) -> Void = { error in
            guard !hasCompleted else { return }
            hasCompleted = true
            DispatchQueue.main.async {
                handler(error)
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Check if directory
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == false {
                    if self.isArchiveURL(url) {
                        DispatchQueue.main.async {
                            self.applySingleFileLayout(false)
                            self.filterType = .all
                            self.filterControl.selectedSegment = FilterType.all.rawValue
                            self.previewRootURL = url
                            self.rootItems = []
                            self.rebuildVisibleRootItems()
                            self.outlineView.reloadData()
                            self.collectionView.reloadData()
                            let icon = NSWorkspace.shared.icon(forFile: url.path)
                            icon.size = NSSize(width: 48, height: 48)
                            self.iconImageView.image = icon
                            self.titleLabel.stringValue = url.lastPathComponent
                            self.infoLabel.stringValue = "Loading archive contents…"
                            self.updatePreview(for: nil)
                        }
                        completeOnce(nil)
                        self.loadArchivePreview(from: url)
                        return
                    }

                    DebugLogger.shared.log("Detected single file preview: \(url.lastPathComponent)")
                    
                    DispatchQueue.main.async {
                        // SINGLE FILE MODE
                        self.applySingleFileLayout(true)
                        
                        // Load markdown content asynchronously
                        DispatchQueue.global(qos: .userInitiated).async {
                            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? "Could not read file."
                            // Escape the content for safe embedding in JS
                            let escapedContent = content
                                .replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "`", with: "\\`")
                                .replacingOccurrences(of: "$", with: "\\$")
                            
                            let html = """
                            <!DOCTYPE html>
                            <html>
                            <head>
                                <meta charset="utf-8">
                                <meta name="viewport" content="width=device-width, initial-scale=1">
                                <script src="https://cdn.jsdelivr.net/npm/marked@11.1.1/marked.min.js"></script>
                                <style>
                                    :root { color-scheme: light dark; }
                                    body {
                                        margin: 0;
                                        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                                        font-size: 15px;
                                        line-height: 1.6;
                                        color: #1d1d1f;
                                        background: #ffffff;
                                    }
                                    .md-layout {
                                        max-width: 1200px;
                                        margin: 0 auto;
                                        padding: 20px 24px 40px 24px;
                                        display: grid;
                                        grid-template-columns: minmax(0, 1fr) 230px;
                                        gap: 24px;
                                        align-items: start;
                                    }
                                    .md-content { min-width: 0; }
                                    .md-toc {
                                        position: sticky;
                                        top: 16px;
                                        border: 1px solid rgba(142,142,147,0.25);
                                        border-radius: 10px;
                                        padding: 10px 12px;
                                        background: rgba(142,142,147,0.08);
                                        max-height: calc(100vh - 40px);
                                        overflow: auto;
                                    }
                                    .md-toc h4 {
                                        margin: 0 0 8px 0;
                                        font-size: 12px;
                                        text-transform: uppercase;
                                        letter-spacing: 0.04em;
                                        color: #6a6a6a;
                                    }
                                    .md-toc ul { list-style: none; padding: 0; margin: 0; }
                                    .md-toc li { margin: 4px 0; }
                                    .md-toc li.level-2 { padding-left: 10px; }
                                    .md-toc li.level-3 { padding-left: 20px; }
                                    .md-toc a { text-decoration: none; color: inherit; font-size: 13px; }
                                    .md-toc a:hover { text-decoration: underline; }
                                    @media (prefers-color-scheme: dark) {
                                        body { color: #e5e5e5; background: #1e1e1e; }
                                        a { color: #58a6ff; }
                                        code { background: rgba(110,118,129,0.2); color: #e5e5e5; }
                                        pre { background: rgba(110,118,129,0.15); border-color: rgba(110,118,129,0.3); }
                                        h1, h2 { border-bottom-color: rgba(110,118,129,0.3); }
                                        th { background: rgba(110,118,129,0.15); }
                                        td, th { border-color: rgba(110,118,129,0.3); }
                                        blockquote { border-left-color: rgba(110,118,129,0.4); color: #a0a0a0; }
                                        .md-toc {
                                            border-color: rgba(110,118,129,0.35);
                                            background: rgba(110,118,129,0.16);
                                        }
                                        .md-toc h4 { color: rgba(235,235,245,0.6); }
                                    }
                                    h1, h2, h3, h4, h5, h6 { margin-top: 24px; margin-bottom: 16px; font-weight: 600; line-height: 1.25; }
                                    h1 { font-size: 2em; border-bottom: 1px solid #e1e4e8; padding-bottom: 8px; }
                                    h2 { font-size: 1.5em; border-bottom: 1px solid #e1e4e8; padding-bottom: 6px; }
                                    h3 { font-size: 1.25em; }
                                    p { margin: 0 0 16px 0; }
                                    a { color: #0969da; text-decoration: none; }
                                    a:hover { text-decoration: underline; }
                                    code {
                                        font-family: "SF Mono", Monaco, Menlo, Consolas, monospace;
                                        font-size: 13px;
                                        background: rgba(175,184,193,0.2);
                                        padding: 2px 6px;
                                        border-radius: 4px;
                                    }
                                    pre {
                                        background: #f6f8fa;
                                        padding: 16px;
                                        border-radius: 8px;
                                        overflow-x: auto;
                                        border: 1px solid #e1e4e8;
                                        margin: 16px 0;
                                    }
                                    pre * { background: transparent !important; }
                                    pre code { background: none; padding: 0; }
                                    pre code, pre code * { color: inherit !important; }
                                    ul, ol { margin: 0 0 16px 0; padding-left: 32px; }
                                    li { margin: 4px 0; }
                                    blockquote {
                                        margin: 0 0 16px 0;
                                        padding: 0 16px;
                                        border-left: 4px solid #d0d7de;
                                        color: #57606a;
                                    }
                                    table { border-collapse: collapse; width: 100%; margin: 16px 0; }
                                    th, td { border: 1px solid #d0d7de; padding: 8px 12px; text-align: left; }
                                    th { background: #f6f8fa; font-weight: 600; }
                                    img { max-width: 100%; height: auto; border-radius: 8px; margin: 16px 0; }
                                    @media (max-width: 900px) {
                                        .md-layout { grid-template-columns: minmax(0, 1fr); padding: 20px 14px 24px 14px; }
                                        .md-toc { position: static; max-height: none; }
                                    }
                                </style>
                            </head>
                            <body>
                                <div class="md-layout">
                                    <div id="content" class="md-content"></div>
                                    <nav id="toc" class="md-toc">
                                        <h4>Contents</h4>
                                        <ul id="toc-list"></ul>
                                    </nav>
                                </div>
                                <script>
                                    const markdown = `\(escapedContent)`;
                                    const content = document.getElementById('content');
                                    const toc = document.getElementById('toc');
                                    const tocList = document.getElementById('toc-list');
                                    content.innerHTML = marked.parse(markdown);
                                    
                                    const normalizeCodeBlocks = () => {
                                        content.querySelectorAll('pre, pre *').forEach((el) => {
                                            if (el.style) {
                                                el.style.background = 'transparent';
                                                el.style.backgroundColor = 'transparent';
                                            }
                                        });
                                        content.querySelectorAll('pre').forEach((pre) => {
                                            pre.style.background = 'rgba(110,118,129,0.18)';
                                            pre.style.backgroundColor = 'rgba(110,118,129,0.18)';
                                        });
                                    };
                                    normalizeCodeBlocks();
                                    
                                    const headings = [...content.querySelectorAll('h1, h2, h3')];
                                    const usedIds = {};
                                    const slugify = (value) => {
                                        const base = (value || 'section').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'section';
                                        const count = (usedIds[base] || 0) + 1;
                                        usedIds[base] = count;
                                        return count === 1 ? base : `${base}-${count}`;
                                    };
                                    
                                    if (!headings.length) {
                                        toc.style.display = 'none';
                                    } else {
                                        headings.forEach((heading) => {
                                            heading.id = slugify(heading.textContent);
                                            const item = document.createElement('li');
                                            item.className = `level-${heading.tagName.slice(1)}`;
                                            const link = document.createElement('a');
                                            link.href = `#${heading.id}`;
                                            link.textContent = heading.textContent || heading.id;
                                            item.appendChild(link);
                                            tocList.appendChild(item);
                                        });
                                    }
                                </script>
                            </body>
                            </html>
                            """
                            
                            DispatchQueue.main.async {
                                self.singleFileWebView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
                                DebugLogger.shared.log("Markdown rendered for \(url.lastPathComponent)")
                            }
                        }
                        
                        completeOnce(nil)
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.applySingleFileLayout(false)
                    self.previewRootURL = url
                    self.gridContextItem = nil
                    self.rootItems = []
                    self.rebuildVisibleRootItems()
                    self.outlineView.reloadData()
                    self.collectionView.reloadData()
                    self.previewTitleLabel.stringValue = "Loading…"
                    self.previewInfoLabel.stringValue = "Gathering folder contents"
                    self.previewMessageLabel.stringValue = ""
                    self.previewMessageLabel.isHidden = true
                    self.infoLabel.stringValue = "Loading…"
                }
                completeOnce(nil)

                let start = CFAbsoluteTimeGetCurrent()
                let contents: [URL] = self.withSecurityScopedAccess(url) {
                    (try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )) ?? []
                }
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DebugLogger.shared.log("Enumerated \(contents.count) entries for \(url.lastPathComponent) in \(String(format: "%.1f", elapsed)) ms")
                
                let sortedContents = self.sortURLs(contents)
                var rootItems: [FileItem] = []
                var immediateTotalSize: Int64 = 0
                var immediateFolderCount = 0
                var immediateFileCount = 0
                
                for entry in sortedContents.prefix(500) {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                    let item = FileItem(url: entry, resourceValues: values)
                    rootItems.append(item)
                    if item.isFolder {
                        immediateFolderCount += 1
                    } else {
                        immediateFileCount += 1
                        immediateTotalSize += item.size
                    }
                }
                self.sortFileItems(&rootItems)
                
                let infoText = "\(self.byteFormatter.string(fromByteCount: immediateTotalSize)) · \(immediateFolderCount) folders, \(immediateFileCount) files"
                
                DispatchQueue.main.async {
                    self.applySingleFileLayout(false)
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 48, height: 48)
                    DebugLogger.shared.log("Applying preview data for \(url.lastPathComponent). Diagnostics log: \(DebugLogger.shared.locationDescription())")
                    self.gridContextItem = nil
                    self.rootItems = rootItems
                    self.previewRootURL = url
                    self.rebuildVisibleRootItems()
                    self.iconImageView.image = icon
                    self.titleLabel.stringValue = url.lastPathComponent
                    self.infoLabel.stringValue = infoText
                    self.outlineView.reloadData()
                    self.collectionView.reloadData()
                    self.syncPreviewWithSelection()
                }
                
                DispatchQueue.global(qos: .utility).async {
                    let recursive = self.recursiveStats(for: url, maxEntries: 50_000, timeBudget: 2.0)
                    let recursiveInfoText = "\(self.byteFormatter.string(fromByteCount: recursive.totalSize)) · \(recursive.folderCount) folders, \(recursive.fileCount) files"
                    DispatchQueue.main.async {
                        guard self.previewRootURL == url else { return }
                        self.infoLabel.stringValue = recursiveInfoText
                    }
                }
            } catch {
                DebugLogger.shared.log("Failed to build preview for \(url.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.applySingleFileLayout(false)
                    self.titleLabel.stringValue = url.lastPathComponent
                    self.infoLabel.stringValue = "Could not load preview."
                    self.gridContextItem = nil
                    self.rootItems = []
                    self.rebuildVisibleRootItems()
                    self.outlineView.reloadData()
                    self.collectionView.reloadData()
                    self.updatePreview(for: nil)
                }
                completeOnce(error)
            }
        }
    }
    
    // MARK: - Actions
    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        guard let type = FilterType(rawValue: sender.selectedSegment) else { return }
        
        // Early return if filter hasn't changed - avoid unnecessary work
        guard type != filterType else { return }
        
        DebugLogger.shared.log("Filter switched to \(type)")
        filterType = type
        rebuildVisibleRootItems()
        
        // Use targeted reload instead of full reloadData() - significantly faster
        // This reloads only the root level items rather than the entire table structure
        outlineView.reloadItem(nil, reloadChildren: true)
        collectionView.reloadData()
        
        syncPreviewWithSelection()
        focusPrimaryBrowser()
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        guard let mode = ViewMode(rawValue: sender.selectedSegment) else { return }
        applyViewMode(mode)
    }

    @objc private func sortKeyChanged(_ sender: NSSegmentedControl) {
        guard let key = sortKey(for: sender.selectedSegment) else { return }
        setSortDescriptor(key: key, ascending: sortOrderControl.selectedSegment == 0)
        focusPrimaryBrowser()
    }

    @objc private func sortOrderChanged(_ sender: NSSegmentedControl) {
        let key = currentSortDescriptor?.key ?? "name"
        setSortDescriptor(key: key, ascending: sender.selectedSegment == 0)
        focusPrimaryBrowser()
    }

    private func sortKey(for segment: Int) -> String? {
        switch segment {
        case 0: return "name"
        case 1: return "date"
        case 2: return "size"
        case 3: return "kind"
        default: return nil
        }
    }

    private func segment(forSortKey key: String?) -> Int {
        switch key ?? "name" {
        case "date": return 1
        case "size": return 2
        case "kind": return 3
        default: return 0
        }
    }

    private func setSortDescriptor(key: String, ascending: Bool) {
        let descriptor: NSSortDescriptor
        if key == "name" {
            descriptor = NSSortDescriptor(key: key, ascending: ascending, selector: #selector(NSString.localizedStandardCompare(_:)))
        } else {
            descriptor = NSSortDescriptor(key: key, ascending: ascending)
        }
        currentSortDescriptor = descriptor
        sortKeyControl.selectedSegment = segment(forSortKey: key)
        sortOrderControl.selectedSegment = ascending ? 0 : 1
        outlineView.sortDescriptors = [descriptor]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.sortFileItems(&self.rootItems)
            self.resortDescendants(from: self.rootItems)
            DispatchQueue.main.async {
                self.rebuildVisibleRootItems()
                self.outlineView.reloadItem(nil, reloadChildren: true)
                self.collectionView.reloadData()
                self.syncPreviewWithSelection()
            }
        }
    }

    @objc private func handleGridDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        let items = currentGridItems
        guard indexPath.item < items.count else { return }
        let item = items[indexPath.item]
        guard item.isFolder else { return }
        enterGridFolder(item)
    }
    
    // MARK: - Helpers
    private func sortURLs(_ urls: [URL]) -> [URL] {
        let sorted = urls.sorted { lhs, rhs in
            let lhsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rhsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if lhsDir != rhsDir {
                return lhsDir
            }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
        if let descriptor = currentSortDescriptor {
            return sorted.sorted { lhs, rhs in
                compareURLs(lhs, rhs, with: descriptor)
            }
        }
        return sorted
    }
    
    private func sortFileItems(_ items: inout [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        items.sort(by: comparator)
    }
    
    private func makeItemComparator() -> (FileItem, FileItem) -> Bool {
        if let descriptor = currentSortDescriptor {
            return { lhs, rhs in
                self.compareFileItems(lhs, rhs, with: descriptor)
            }
        }
        return { lhs, rhs in
            self.defaultItemComparator(lhs, rhs)
        }
    }
    
    private func compareFileItems(_ lhs: FileItem, _ rhs: FileItem, with descriptor: NSSortDescriptor) -> Bool {
        let ascending = descriptor.ascending
        switch descriptor.key ?? "name" {
        case "date":
            if lhs.modificationDate == rhs.modificationDate {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.modificationDate < rhs.modificationDate : lhs.modificationDate > rhs.modificationDate
        case "size":
            if lhs.size == rhs.size {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
        case "kind":
            if lhs.kindDescription == rhs.kindDescription {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.kindDescription < rhs.kindDescription : lhs.kindDescription > rhs.kindDescription
        case "name":
            fallthrough
        default:
            if lhs.name == rhs.name {
                return defaultItemComparator(lhs, rhs)
            }
            if ascending {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            } else {
                return rhs.name.localizedStandardCompare(lhs.name) == .orderedAscending
            }
        }
    }
    
    private func defaultItemComparator(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) != .orderedDescending
    }
    
    private func resortDescendants(from items: [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        resortDescendants(items, comparator: comparator)
    }
    
    private func resortDescendants(_ items: [FileItem], comparator: @escaping (FileItem, FileItem) -> Bool) {
        for item in items {
            if var children = item.children {
                children.sort(by: comparator)
                item.children = children
                resortDescendants(children, comparator: comparator)
            }
        }
    }
    
    private func compareURLs(_ lhs: URL, _ rhs: URL, with descriptor: NSSortDescriptor) -> Bool {
        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending
        switch key {
        case "name":
            return ascending ?
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending :
                rhs.lastPathComponent.localizedStandardCompare(lhs.lastPathComponent) == .orderedAscending
        case "date":
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
        case "size":
            let lhsSize = Int64((try? lhs.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let rhsSize = Int64((try? rhs.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return ascending ? lhsSize < rhsSize : lhsSize > rhsSize
        case "kind":
            let lhsType = (try? lhs.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.localizedDescription ?? ""
            let rhsType = (try? rhs.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.localizedDescription ?? ""
            return ascending ? lhsType < rhsType : lhsType > rhsType
        default:
            return true
        }
    }
    
    private func rebuildVisibleRootItems() {
        if filterType == .all {
            visibleRootItems = rootItems
            return
        }
        visibleRootItems = filterItems(rootItems)
    }
    
    private func children(of item: FileItem?) -> [FileItem] {
        if let item {
            guard let children = item.children else { return [] }
            return filterItems(children)
        }
        return visibleRootItems
    }

    private var currentGridItems: [FileItem] {
        if let context = gridContextItem {
            return children(of: context)
        }
        return visibleRootItems
    }
    
    private func filterItems(_ items: [FileItem]) -> [FileItem] {
        items.filter { item in
            filterType.matches(item)
        }
    }

    private func enterGridFolder(_ folder: FileItem) {
        loadChildren(for: folder) { [weak self] in
            guard let self else { return }
            self.gridContextItem = folder
            self.collectionView.reloadData()
            self.collectionView.deselectAll(nil)
            self.previewedItem = nil
            self.updatePathBar()
        }
    }

    private func exitGridFolder() {
        guard let current = gridContextItem else { return }
        gridContextItem = current.parent
        collectionView.reloadData()
        collectionView.deselectAll(nil)
        previewedItem = nil
        updatePathBar()
    }
    
    private func updatePathBar() {
        guard !singleFileMode else {
            pathBarView.isHidden = true
            return
        }
        let selected = selectedItems.last?.url
        let target: URL?
        if let selected {
            target = selected
        } else if currentViewMode == .grid, let context = gridContextItem?.url {
            target = context
        } else {
            target = previewRootURL
        }
        pathControl.url = target
        pathBarView.isHidden = (target == nil)
    }
    
    private func syncPreviewWithSelection() {
        if currentViewMode == .grid {
            previewedItem = selectedItems.last
            updatePathBar()
            return
        }

        // Cancel any pending preview update
        previewUpdateWorkItem?.cancel()
        
        // Minimal debounce (10ms) - just enough to prevent rapid-fire updates
        // but imperceptible to users for single clicks
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.updatePreview(for: self.selectedItems.last)
        }
        previewUpdateWorkItem = workItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: workItem)
    }
    
    private func updatePreview(for item: FileItem?) {
        previewImageLoadTask?.cancel()
        previewImageLoadTask = nil
        previewFallbackTask?.cancel()
        previewFallbackTask = nil
        previewSpinner.stopAnimation(nil)
        
        // Batch all view updates in a single transaction for better performance
        CATransaction.begin()
        
        previewImageView.image = nil
        previewedItem = item
        
        guard let item else {
            previewTitleLabel.stringValue = "No Selection"
            previewInfoLabel.stringValue = "Select a file or folder to preview."
            previewMessageLabel.stringValue = ""
            previewMessageLabel.isHidden = true
            CATransaction.commit()
            updatePathBar()
            return
        }
        
        // Use pre-built cached info string - zero string operations on UI thread
        previewTitleLabel.stringValue = item.name
        previewInfoLabel.stringValue = item.previewInfo(sizeFormatter: byteFormatter, dateFormatter: dateFormatter)
        previewMessageLabel.isHidden = true
        
        CATransaction.commit()
        updatePathBar()
        
        // Use cached type checks instead of repeated UTType conformance checks
        webView.isHidden = true
        previewImageView.isHidden = true
        
        if item.isImage {
            previewImageView.isHidden = false
            loadPreviewImage(for: item)
        } else if item.isText {
            webView.isHidden = false
            previewMessageLabel.isHidden = true
            loadMarkdownPreview(for: item)
        } else if item.isFolder {
            previewImageView.isHidden = false
            loadLargeIcon(for: item) { [weak self] icon in
                guard let self, self.previewedItem === item else { return }
                self.previewImageView.image = icon
            }
            previewMessageLabel.stringValue = "Select a file to preview."
            previewMessageLabel.isHidden = false
        } else {
            previewImageView.isHidden = false
            previewMessageLabel.isHidden = true
            loadDocumentThumbnail(for: item)
        }
    }

    private func applySingleFileLayout(_ enabled: Bool) {
        singleFileMode = enabled
        mainStack.isHidden = enabled
        singleFileWebView.isHidden = !enabled
        pathBarView.isHidden = enabled
        if !enabled {
            applyViewMode(currentViewMode)
        }
    }
    
    private func loadMarkdownPreview(for item: FileItem) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = self.withSecurityScopedAccess(item.url) {
                (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            }
            let htmlBody = self.makeHTML(fromMarkdown: text)
            let template = self.makeMarkdownTemplate(htmlBody: htmlBody)
            DispatchQueue.main.async {
                guard self.previewedItem === item else { return }
                self.webView.loadHTMLString(template, baseURL: item.url.deletingLastPathComponent())
            }
        }
    }
    
    private func loadDocumentThumbnail(for item: FileItem) {
        loadLargeIcon(for: item) { [weak self] icon in
            guard let self, self.previewedItem === item, self.previewImageView.image == nil else { return }
            self.previewImageView.image = icon
        }
        
        previewSpinner.startAnimation(nil)
        
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.previewedItem === item else { return }
            self.previewSpinner.stopAnimation(nil)
            self.previewMessageLabel.stringValue = "Preview unavailable for this file."
            self.previewMessageLabel.isHidden = false
        }
        previewFallbackTask = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: fallback)
        
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 920, height: 680),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )
        let hasAccess = item.url.startAccessingSecurityScopedResource()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            DispatchQueue.main.async {
                if hasAccess { item.url.stopAccessingSecurityScopedResource() }
                guard let self, self.previewedItem === item else { return }
                self.previewFallbackTask?.cancel()
                self.previewFallbackTask = nil
                self.previewSpinner.stopAnimation(nil)
                if let cgImage = thumbnail?.cgImage {
                    self.previewImageView.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.previewMessageLabel.isHidden = true
                } else {
                    self.previewMessageLabel.stringValue = "Preview unavailable for this file."
                    self.previewMessageLabel.isHidden = false
                    self.loadLargeIcon(for: item) { [weak self] icon in
                        guard let self, self.previewedItem === item else { return }
                        self.previewImageView.image = icon
                    }
                }
            }
        }
    }
    
    private func makeHTML(fromMarkdown markdown: String) -> String {
        if markdown.isEmpty {
            return "<p>No content.</p>"
        }
        if #available(macOS 12.0, *) {
            if let attributed = try? AttributedString(markdown: markdown) {
                let nsAttr = NSAttributedString(attributed)
                if let data = try? nsAttr.data(
                    from: NSRange(location: 0, length: nsAttr.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
                ), let rawHTML = String(data: data, encoding: .utf8) {
                    return extractBody(from: rawHTML)
                }
            }
        }
        let escaped = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre>\(escaped)</pre>"
    }
    
    private func makeMarkdownTemplate(htmlBody: String) -> String {
        let result = addAnchorsAndBuildTOC(from: htmlBody)
        let tocSection = result.tocHTML.isEmpty ? "" : """
        <nav class="md-toc">
            <h4>Contents</h4>
            <ul>\(result.tocHTML)</ul>
        </nav>
        """
        
        return """
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            :root { color-scheme: light dark; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                margin: 0;
                line-height: 1.5;
                background: transparent;
                color: #1f1f1f;
            }
            .md-layout {
                display: grid;
                grid-template-columns: minmax(0, 1fr) 220px;
                gap: 20px;
                align-items: start;
                padding: 18px 20px 20px 20px;
            }
            .md-content { min-width: 0; }
            .md-toc {
                position: sticky;
                top: 14px;
                border: 1px solid rgba(142,142,147,0.25);
                border-radius: 10px;
                padding: 10px 12px;
                background: rgba(142,142,147,0.08);
                max-height: calc(100vh - 30px);
                overflow: auto;
            }
            .md-toc h4 {
                margin: 0 0 8px 0;
                font-size: 12px;
                text-transform: uppercase;
                letter-spacing: 0.04em;
                color: #6a6a6a;
            }
            .md-toc ul { list-style: none; padding: 0; margin: 0; }
            .md-toc li { margin: 4px 0; }
            .md-toc li.level-2 { padding-left: 10px; }
            .md-toc li.level-3 { padding-left: 20px; }
            .md-toc a { text-decoration: none; color: inherit; font-size: 13px; }
            .md-toc a:hover { text-decoration: underline; }
            @media (prefers-color-scheme: dark) {
                body { color: #e5e5e5; }
                pre {
                    background-color: rgba(110,118,129,0.18);
                    border: 1px solid rgba(110,118,129,0.35);
                }
                code {
                    background-color: rgba(110,118,129,0.22);
                    color: #f2f4f7;
                }
                th, td { border-color: rgba(110,118,129,0.35); }
                th { background-color: rgba(110,118,129,0.15); }
                blockquote {
                    border-left-color: rgba(110,118,129,0.45);
                    color: rgba(235,235,245,0.65);
                }
                .md-toc {
                    border-color: rgba(110,118,129,0.35);
                    background: rgba(110,118,129,0.16);
                }
                .md-toc h4 { color: rgba(235,235,245,0.6); }
            }
            h1, h2, h3, h4, h5, h6 { font-weight: 600; }
            pre, code {
                font-family: Menlo, SFMono-Regular, Consolas, monospace;
            }
            pre {
                background-color: rgba(142,142,147,0.08);
                border: 1px solid rgba(142,142,147,0.22);
                padding: 12px 16px;
                border-radius: 8px;
                    overflow-x: auto;
            }
            pre * { background: transparent !important; }
            code {
                background-color: rgba(142,142,147,0.2);
                border-radius: 4px;
                padding: 1px 4px;
            }
            pre code {
                background: transparent !important;
                padding: 0 !important;
                color: inherit !important;
            }
            pre code, pre code * { color: inherit !important; }
            table {
                border-collapse: collapse;
                width: 100%;
                margin: 16px 0;
            }
            th, td {
                border: 1px solid rgba(142,142,147,0.3);
                padding: 6px 8px;
                text-align: left;
            }
            blockquote {
                border-left: 3px solid rgba(142,142,147,0.4);
                margin: 0;
                padding-left: 12px;
                color: rgba(60,60,67,0.7);
            }
            @media (max-width: 920px) {
                .md-layout { grid-template-columns: minmax(0, 1fr); padding: 16px 12px 16px 12px; }
                .md-toc { position: static; max-height: none; }
            }
        </style>
        </head>
        <body>
        <div class="md-layout">
            <article class="md-content">\(result.bodyWithAnchors)</article>
            \(tocSection)
        </div>
        <script>
            document.querySelectorAll('pre, pre *').forEach((el) => {
                if (el.style) {
                    el.style.background = 'transparent';
                    el.style.backgroundColor = 'transparent';
                }
            });
            document.querySelectorAll('pre').forEach((pre) => {
                pre.style.background = 'rgba(110,118,129,0.18)';
                pre.style.backgroundColor = 'rgba(110,118,129,0.18)';
            });
        </script>
        </body>
        </html>
        """
    }
    
    private func addAnchorsAndBuildTOC(from html: String) -> (bodyWithAnchors: String, tocHTML: String) {
        guard let regex = try? NSRegularExpression(pattern: "<h([1-6])([^>]*)>(.*?)</h\\1>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return (html, "")
        }
        
        let fullRange = NSRange(location: 0, length: html.utf16.count)
        let matches = regex.matches(in: html, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return (html, "")
        }
        
        let mutableBody = NSMutableString(string: html)
        var tocItems: [String] = []
        var usedIDs: [String: Int] = [:]
        
        for match in matches.reversed() {
            guard
                let levelRange = Range(match.range(at: 1), in: html),
                let attrsRange = Range(match.range(at: 2), in: html),
                let contentRange = Range(match.range(at: 3), in: html)
            else { continue }
            
            let level = Int(html[levelRange]) ?? 1
            let attributes = String(html[attrsRange])
            let content = String(html[contentRange])
            let text = stripHTML(content).trimmingCharacters(in: .whitespacesAndNewlines)
            let baseID = slugifyHeadingID(text)
            let usage = (usedIDs[baseID] ?? 0) + 1
            usedIDs[baseID] = usage
            let finalID = usage == 1 ? baseID : "\(baseID)-\(usage)"
            let heading = "<h\(level)\(attributes) id=\"\(finalID)\">\(content)</h\(level)>"
            
            mutableBody.replaceCharacters(in: match.range(at: 0), with: heading)
            
            if level <= 3 && !text.isEmpty {
                tocItems.append("<li class=\"level-\(level)\"><a href=\"#\(finalID)\">\(escapeHTML(text))</a></li>")
            }
        }
        
        return (mutableBody as String, tocItems.reversed().joined())
    }
    
    private func stripHTML(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
            return value
        }
        let range = NSRange(location: 0, length: value.utf16.count)
        let noTags = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: "")
        return noTags.replacingOccurrences(of: "&nbsp;", with: " ")
    }
    
    private func slugifyHeadingID(_ text: String) -> String {
        let lowered = text.lowercased()
        let pieces = lowered.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar)
            }
            return "-"
        }
        let joined = pieces.joined()
        let collapsed = joined.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "section" : trimmed
    }
    
    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    
    private func extractBody(from html: String) -> String {
        guard let bodyStartRange = html.range(of: "<body", options: .caseInsensitive),
              let closingBracket = html[bodyStartRange.lowerBound...].firstIndex(of: ">"),
              let bodyEndRange = html.range(of: "</body>", options: .caseInsensitive) else {
            return html
        }
        let start = html.index(after: closingBracket)
        return String(html[start..<bodyEndRange.lowerBound])
    }
    
    private func loadPreviewImage(for item: FileItem) {
        previewSpinner.startAnimation(nil)
        let start = CFAbsoluteTimeGetCurrent()
        
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.previewedItem === item else { return }
            self.previewSpinner.stopAnimation(nil)
            self.previewMessageLabel.stringValue = "Preview unavailable for this file."
            self.previewMessageLabel.isHidden = false
            self.loadLargeIcon(for: item) { [weak self] icon in
                guard let self, self.previewedItem === item else { return }
                self.previewImageView.image = icon
            }
        }
        previewFallbackTask = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: fallback)
        
        let fileURL = item.url as NSURL
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let hasAccess = item.url.startAccessingSecurityScopedResource()
            let source = CGImageSourceCreateWithURL(fileURL, nil)
            let cgImage = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            if hasAccess { item.url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard self.previewedItem === item else { return }
                self.previewFallbackTask?.cancel()
                self.previewFallbackTask = nil
                self.previewSpinner.stopAnimation(nil)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DebugLogger.shared.log("Preview image load for \(item.name) finished in \(String(format: "%.1f", elapsed)) ms")
                if let cgImage {
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.previewImageView.image = image
                    self.previewMessageLabel.isHidden = true
                } else {
                    self.previewMessageLabel.stringValue = "Preview unavailable for this file."
                    self.previewMessageLabel.isHidden = false
                    self.loadLargeIcon(for: item) { [weak self] icon in
                        guard let self, self.previewedItem === item else { return }
                        self.previewImageView.image = icon
                    }
                }
                self.previewImageLoadTask = nil
            }
        }
        previewImageLoadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }
    
    private var selectedItems: [FileItem] {
        if currentViewMode == .grid {
            return collectionView.selectionIndexPaths
                .sorted { $0.item < $1.item }
                .compactMap { indexPath in
                    let items = currentGridItems
                    guard indexPath.item < items.count else { return nil }
                    return items[indexPath.item]
                }
        }
        return outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }
    }
    
    private func actionURLs() -> [URL] {
        let selection = selectedItems.map { $0.url }
        if !selection.isEmpty { return selection }
        if let previewedItem {
            return [previewedItem.url]
        }
        return []
    }
    
    @objc private func copyPathAction() {
        let urls = actionURLs().map { $0.path }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSString])
    }
    
    private func showQuickLook() {
        guard QLPreviewPanel.shared()?.isVisible == false else {
            QLPreviewPanel.shared()?.reloadData()
            return
        }
        guard let panel = QLPreviewPanel.shared(), !selectedItems.isEmpty else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(self)
    }
    
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu(title: "Actions")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPathAction), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Expand All", action: #selector(expandAllAction), keyEquivalent: "")
        menu.addItem(withTitle: "Collapse All", action: #selector(collapseAllAction), keyEquivalent: "")
        return menu
    }()
    
    @objc private func expandAllAction() {
        outlineView.expandItem(nil, expandChildren: true)
    }
    
    @objc private func collapseAllAction() {
        outlineView.collapseItem(nil, collapseChildren: true)
    }
    
    private func recursiveStats(for rootURL: URL, maxEntries: Int = 50_000, timeBudget: TimeInterval = 2.0) -> (totalSize: Int64, folderCount: Int, fileCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0, 0)
        }
        
        var totalSize: Int64 = 0
        var folderCount = 0
        var fileCount = 0
        var visited = 0
        let deadline = Date().addingTimeInterval(max(0.2, timeBudget))
        
        for case let entryURL as URL in enumerator {
            visited += 1
            if visited > maxEntries || Date() >= deadline {
                break
            }
            guard let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]) else { continue }
            if values.isDirectory == true {
                folderCount += 1
                continue
            }
            if values.isRegularFile == true {
                fileCount += 1
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        
        return (totalSize, folderCount, fileCount)
    }
    
    
    private func loadChildren(for item: FileItem, completion: @escaping () -> Void) {
        if item.childrenLoaded {
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let start = CFAbsoluteTimeGetCurrent()
                let contents: [URL] = self.withSecurityScopedAccess(item.url) {
                    (try? FileManager.default.contentsOfDirectory(
                        at: item.url,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )) ?? []
                }
                let sorted = self.sortURLs(contents)
                var children: [FileItem] = []
                for entry in sorted.prefix(500) {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                    children.append(FileItem(url: entry, resourceValues: values, parent: item))
                }
                self.sortFileItems(&children)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DispatchQueue.main.async {
                    DebugLogger.shared.log("Loaded \(children.count) children for \(item.name) in \(String(format: "%.1f", elapsed)) ms")
                    item.setChildren(children)
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    DebugLogger.shared.log("Failed to load children for \(item.name): \(error.localizedDescription)")
                    item.setChildren([])
                    completion()
                }
            }
        }
    }
    
    private func loadIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        // First check if item already has icon cached
        if let icon = item.icon {
            completion(icon)
            return
        }
        
        let path = item.url.path
        let cacheKey = path as NSString
        
        // Check NSCache
        if let cached = iconCache.object(forKey: cacheKey) {
            item.icon = cached
            completion(cached)
            return
        }
        
        // Load icon on background thread to avoid blocking UI
        iconLoadQueue.async { [weak self] in
            guard let self = self else { return }
            
            // NSWorkspace.shared.icon is thread-safe and can be called from background
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            
            // Cache the icon
            self.iconCache.setObject(icon, forKey: cacheKey)
            item.icon = icon
            
            // Update UI on main thread
            DispatchQueue.main.async {
                completion(icon)
            }
        }
    }
    
    private func loadLargeIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        let path = item.url.path
        let cacheKey = "\(path)-large" as NSString
        
        // Check cache for large icon
        if let cached = iconCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }
        
        // Load large icon on background thread
        iconLoadQueue.async { [weak self] in
            guard let self = self else { return }
            
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 256, height: 256)
            
            // Cache the large icon
            self.iconCache.setObject(icon, forKey: cacheKey)
            
            // Update UI on main thread
            DispatchQueue.main.async {
                completion(icon)
            }
        }
    }

    private func loadGridThumbnail(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        let key = "grid-\(item.url.path)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            completion(cached)
            return
        }

        if item.isFolder {
            loadLargeIcon(for: item) { [weak self] icon in
                self?.thumbnailCache.setObject(icon, forKey: key)
                completion(icon)
            }
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 180, height: 180),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )
        let hasAccess = item.url.startAccessingSecurityScopedResource()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            DispatchQueue.main.async {
                if hasAccess { item.url.stopAccessingSecurityScopedResource() }
                if let cgImage = thumbnail?.cgImage {
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self?.thumbnailCache.setObject(image, forKey: key)
                    completion(image)
                } else {
                    self?.loadLargeIcon(for: item) { [weak self] icon in
                        self?.thumbnailCache.setObject(icon, forKey: key)
                        completion(icon)
                    }
                }
            }
        }
    }

    private func isArchiveURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "tgz", "gz", "bz2", "xz", "tbz2", "txz"]
        return archiveExtensions.contains(ext)
    }

    private func loadArchivePreview(from archiveURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let extractionURL = self.makeArchiveExtractionURL(for: archiveURL)
            do {
                let archiveSize = self.archiveByteSize(for: archiveURL)
                try FileManager.default.createDirectory(at: extractionURL, withIntermediateDirectories: true)
                let extractionResult: Result<Void, Error> = self.withSecurityScopedAccess(archiveURL) {
                    do {
                        try self.extractArchive(archiveURL, to: extractionURL)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                switch extractionResult {
                case .success:
                    break
                case .failure(let error):
                    throw error
                }
                self.activeArchiveExtractionURL = extractionURL

                let contents = try FileManager.default.contentsOfDirectory(
                    at: extractionURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                let sorted = self.sortURLs(contents)
                var rootItems: [FileItem] = []
                var totalSize: Int64 = 0
                var folderCount = 0
                var fileCount = 0

                for entry in sorted.prefix(500) {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                    let item = FileItem(url: entry, resourceValues: values)
                    if item.isFolder {
                        let children = self.makeDirectoryItems(at: item.url, parent: item, limit: 500)
                        item.setChildren(children)
                    }
                    rootItems.append(item)
                    if item.isFolder {
                        folderCount += 1
                    } else {
                        fileCount += 1
                        totalSize += item.size
                    }
                }
                self.sortFileItems(&rootItems)
                let displaySize = archiveSize > 0 ? archiveSize : totalSize
                let infoText = "\(self.byteFormatter.string(fromByteCount: displaySize)) · \(folderCount) folders, \(fileCount) files (archive)"

                DispatchQueue.main.async {
                    guard self.previewRootURL == archiveURL else { return }
                    self.gridContextItem = nil
                    self.rootItems = rootItems
                    self.rebuildVisibleRootItems()
                    self.infoLabel.stringValue = infoText
                    self.outlineView.reloadData()
                    self.collectionView.reloadData()
                    self.syncPreviewWithSelection()
                }

                DispatchQueue.global(qos: .utility).async {
                    let recursive = self.recursiveStats(for: extractionURL, maxEntries: 50_000, timeBudget: 2.0)
                    let recursiveDisplaySize = archiveSize > 0 ? archiveSize : recursive.totalSize
                    let recursiveInfoText = "\(self.byteFormatter.string(fromByteCount: recursiveDisplaySize)) · \(recursive.folderCount) folders, \(recursive.fileCount) files (archive)"
                    DispatchQueue.main.async {
                        guard self.previewRootURL == archiveURL else { return }
                        self.infoLabel.stringValue = recursiveInfoText
                    }
                }
            } catch {
                DebugLogger.shared.log("Archive preview failed for \(archiveURL.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.previewRootURL == archiveURL else { return }
                    self.gridContextItem = nil
                    self.rootItems = []
                    self.rebuildVisibleRootItems()
                    self.outlineView.reloadData()
                    self.collectionView.reloadData()
                    self.infoLabel.stringValue = "Could not open archive."
                    self.previewMessageLabel.stringValue = "Archive preview unavailable for this file."
                    self.previewMessageLabel.isHidden = false
                    self.updatePreview(for: nil)
                }
            }
        }
    }

    private func archiveByteSize(for archiveURL: URL) -> Int64 {
        let value: Int64 = withSecurityScopedAccess(archiveURL) {
            let rv = try? archiveURL.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv?.fileSize ?? 0)
        }
        return max(0, value)
    }

    private func makeArchiveExtractionURL(for archiveURL: URL) -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let container = temp.appendingPathComponent("PeekXArchivePreview", isDirectory: true)
        let name = archiveURL.deletingPathExtension().lastPathComponent
        let unique = UUID().uuidString
        return container.appendingPathComponent("\(name)-\(unique)", isDirectory: true)
    }

    private func makeDirectoryItems(at url: URL, parent: FileItem?, limit: Int) -> [FileItem] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var items: [FileItem] = []
        for entry in sortURLs(contents).prefix(limit) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
            guard let values else { continue }
            items.append(FileItem(url: entry, resourceValues: values, parent: parent))
        }
        sortFileItems(&items)
        return items
    }

    private func extractArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let ext = archiveURL.pathExtension.lowercased()
        if ext == "zip" {
            try materializeZipIndex(from: archiveURL, to: destinationURL)
            return
        }

        throw PreviewError.accessDenied
    }

    private func cleanupActiveArchiveExtraction() {
        guard let url = activeArchiveExtractionURL else { return }
        try? FileManager.default.removeItem(at: url)
        activeArchiveExtractionURL = nil
    }

    private func materializeZipIndex(from archiveURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        guard let entries = parseZipEntries(from: data), !entries.isEmpty else {
            throw PreviewError.accessDenied
        }

        // Materialize a safe virtual tree (dirs + empty files) for archive browsing.
        let manager = FileManager.default
        var createdDirectories = Set<String>()
        let limit = 10_000
        var processed = 0

        for rawPath in entries {
            if processed >= limit { break }
            guard let safePath = sanitizedArchiveRelativePath(rawPath) else { continue }
            let destination = destinationURL.appendingPathComponent(safePath)

            if rawPath.hasSuffix("/") {
                if createdDirectories.insert(safePath).inserted {
                    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                }
            } else {
                let parent = destination.deletingLastPathComponent()
                try manager.createDirectory(at: parent, withIntermediateDirectories: true)
                _ = manager.createFile(atPath: destination.path, contents: nil)
            }
            processed += 1
        }
    }

    private func parseZipEntries(from data: Data) -> [String]? {
        let eocdSignature: UInt32 = 0x06054b50
        let cdfhSignature: UInt32 = 0x02014b50
        let minEOCDSize = 22
        guard data.count >= minEOCDSize else { return nil }

        let maxComment = 65_535
        let searchStart = max(0, data.count - (minEOCDSize + maxComment))
        var eocdOffset: Int?
        if data.count >= 4 {
            for i in stride(from: data.count - 4, through: searchStart, by: -1) {
                guard let sig = readUInt32LE(data, at: i) else { continue }
                if sig == eocdSignature {
                    eocdOffset = i
                    break
                }
            }
        }
        guard let eocd = eocdOffset else { return nil }

        guard
            let totalEntries = readUInt16LE(data, at: eocd + 10),
            let centralDirSize = readUInt32LE(data, at: eocd + 12),
            let centralDirOffset = readUInt32LE(data, at: eocd + 16)
        else {
            return nil
        }

        var cursor = Int(centralDirOffset)
        let end = min(data.count, Int(centralDirOffset) + Int(centralDirSize))
        var names: [String] = []
        names.reserveCapacity(Int(totalEntries))

        while cursor + 46 <= end {
            guard let sig = readUInt32LE(data, at: cursor), sig == cdfhSignature else { break }
            guard
                let fileNameLength = readUInt16LE(data, at: cursor + 28),
                let extraLength = readUInt16LE(data, at: cursor + 30),
                let commentLength = readUInt16LE(data, at: cursor + 32)
            else {
                break
            }

            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(fileNameLength)
            guard nameEnd <= data.count else { break }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            if !name.isEmpty {
                names.append(name)
            }

            let step = 46 + Int(fileNameLength) + Int(extraLength) + Int(commentLength)
            if step <= 0 { break }
            cursor += step
        }

        return names
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { raw -> UInt16 in
            let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt16(p[0]) | (UInt16(p[1]) << 8)
        }
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { raw -> UInt32 in
            let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(p[0]) | (UInt32(p[1]) << 8) | (UInt32(p[2]) << 16) | (UInt32(p[3]) << 24)
        }
    }

    private func sanitizedArchiveRelativePath(_ rawPath: String) -> String? {
        var path = rawPath.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        let pieces = path.split(separator: "/").map(String.init)
        if pieces.isEmpty { return nil }
        if pieces.first == "__MACOSX" { return nil }
        let safePieces = pieces.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        if safePieces.isEmpty { return nil }
        if safePieces.last == ".DS_Store" { return nil }
        if safePieces.last?.hasPrefix("._") == true { return nil }
        return safePieces.joined(separator: "/")
    }
    
    private func withSecurityScopedAccess<T>(_ url: URL, block: () -> T) -> T {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return block()
    }
}

// MARK: - NSOutlineViewDataSource
extension PreviewViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return children(of: item as? FileItem).count
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return children(of: item as? FileItem)[index]
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isFolder
    }
}

// MARK: - NSOutlineViewDelegate
extension PreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem,
              let identifier = tableColumn?.identifier else { return nil }
        let reuseIdentifier = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
        let cellView: NSTableCellView
        
        if let existing = outlineView.makeView(withIdentifier: reuseIdentifier, owner: self) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = reuseIdentifier
            let stackView = NSStackView()
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
            stackView.spacing = 6
            cellView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                stackView.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
                stackView.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 2),
                stackView.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -2)
            ])
            if identifier.rawValue == "name" {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16)
                ])
                stackView.addArrangedSubview(imageView)
                cellView.imageView = imageView
            }
            let alignment: NSTextAlignment = identifier.rawValue == "size" ? .right : .left
            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = false
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.textColor = .labelColor
            textField.lineBreakMode = .byTruncatingTail
            textField.alignment = alignment
            textField.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(textField)
            cellView.textField = textField
        }
        
        switch identifier.rawValue {
        case "name":
            cellView.textField?.stringValue = fileItem.name
            loadIcon(for: fileItem) { icon in
                cellView.imageView?.image = icon
            }
        case "date":
            // Use cached formatted date to avoid repeated formatting
            cellView.textField?.stringValue = fileItem.formattedDate(using: dateFormatter)
        case "size":
            // Use cached formatted size to avoid repeated formatting
            cellView.textField?.stringValue = fileItem.formattedSize(using: byteFormatter)
        case "kind":
            cellView.textField?.stringValue = fileItem.kindDescription
        default:
            cellView.textField?.stringValue = ""
        }
        return cellView
    }
    
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        currentSortDescriptor = outlineView.sortDescriptors.first
        sortKeyControl.selectedSegment = segment(forSortKey: currentSortDescriptor?.key)
        sortOrderControl.selectedSegment = (currentSortDescriptor?.ascending ?? true) ? 0 : 1
        
        // Move sorting to background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.sortFileItems(&self.rootItems)
            self.resortDescendants(from: self.rootItems)
            
            DispatchQueue.main.async {
                self.rebuildVisibleRootItems()
                // Use targeted reload instead of full reloadData()
                self.outlineView.reloadItem(nil, reloadChildren: true)
                self.collectionView.reloadData()
            }
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        loadChildren(for: fileItem) {
            outlineView.reloadItem(fileItem, reloadChildren: true)
        }
        return true
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSOutlineView === outlineView else { return }
        // Removed logging here to reduce overhead on every selection change
        syncPreviewWithSelection()
    }
}

extension PreviewViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        currentGridItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let itemView = collectionView.makeItem(withIdentifier: FinderGridItem.identifier, for: indexPath)
        guard
            let gridItem = itemView as? FinderGridItem,
            indexPath.item < currentGridItems.count
        else {
            return itemView
        }

        let model = currentGridItems[indexPath.item]
        gridItem.textField?.stringValue = model.name
        gridItem.representedObject = model.url.path
        gridItem.imageView?.image = NSWorkspace.shared.icon(forFile: model.url.path)

        loadGridThumbnail(for: model) { [weak gridItem] image in
            guard let gridItem else { return }
            guard (gridItem.representedObject as? String) == model.url.path else { return }
            gridItem.imageView?.image = image
        }
        return gridItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncPreviewWithSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncPreviewWithSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDoubleClickItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item else { return }
        let items = currentGridItems
        guard index < items.count else { return }
        let item = items[index]
        guard item.isFolder else { return }
        enterGridFolder(item)
    }
}

// MARK: - Keyboard & Menu Handling
extension PreviewViewController {
}

extension PreviewViewController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let location = outlineView.convert(outlineView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let row = outlineView.row(at: location)
        if row >= 0 && !outlineView.isRowSelected(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let hasSelection = !selectedItems.isEmpty
        for item in menu.items where item.action == #selector(copyPathAction) {
            item.isEnabled = hasSelection
        }
    }
}

extension PreviewViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let minLeft: CGFloat = 280
        let minRight: CGFloat = currentViewMode == .fullList ? 0 : 340
        let maxLeft = max(minLeft, splitView.bounds.width - minRight)
        return min(max(proposedPosition, minLeft), maxLeft)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard currentViewMode == .list else { return }
        guard !isApplyingSplitRatio else { return }
        guard splitView.bounds.width > 0, splitView.subviews.count >= 2 else { return }
        let leftWidth = splitView.subviews[0].frame.width
        let ratio = max(0.2, min(0.8, leftWidth / splitView.bounds.width))
        prefs.set(ratio, forKey: PreferenceKeys.splitRatio)
    }
}

// MARK: - Quick Look Panel
extension PreviewViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedItems[index]
    }
}

// MARK: - Outline Keyboard Delegate
extension PreviewViewController: FinderOutlineViewKeyboardDelegate {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool {
        let commandPressed = event.modifierFlags.contains(.command)
        switch (event.keyCode, commandPressed) {
        case (49, false): // Space
            // Space shortcut intentionally disabled.
            return true
        case (_, true) where event.charactersIgnoringModifiers == "c":
            copyPathAction()
            return true
        default:
            return false
        }
    }
}

extension PreviewViewController: FinderCollectionViewKeyboardDelegate {
    func collectionView(_ collectionView: FinderCollectionView, handle event: NSEvent) -> Bool {
        let commandPressed = event.modifierFlags.contains(.command)
        switch (event.keyCode, commandPressed) {
        case (49, false): // Space
            // Space shortcut intentionally disabled.
            return true
        case (36, false), (76, false): // Return / Enter
            guard let item = selectedItems.last, item.isFolder else { return false }
            enterGridFolder(item)
            return true
        case (51, false), (117, false): // Delete / Forward Delete
            exitGridFolder()
            return true
        case (_, true) where event.charactersIgnoringModifiers == "c":
            copyPathAction()
            return true
        default:
            return false
        }
    }
}
