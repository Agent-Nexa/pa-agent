//
//  ShareViewController.swift
//  NexaShareExtension
//
//  Receives text, URLs or images shared from any app (WhatsApp, iMessage,
//  Telegram, Safari…) and writes a SharedItem to the App Group so the
//  main Nexa app can process it.
//

import UIKit
import Social
import UniformTypeIdentifiers
import MobileCoreServices
import UserNotifications

// Local copy of SharedItem — keep field names identical to EmailModels.swift
// so JSON round-trips correctly between the extension and the main app.
struct SharedItem: Codable {
    var id: String
    var content: String
    var contentType: String         // "text" | "image" | "url"
    var imageData: Data?
    var sourceBundleID: String
    var sourceAppName: String
    var userNote: String
    var timestamp: Date
    var processed: Bool
}

// MARK: - Source-app metadata helpers

private struct SourceAppInfo {
    let displayName: String
    let sfSymbol: String
    let tintColor: UIColor
}

private func sourceInfo(for bundleID: String) -> SourceAppInfo {
    let lower = bundleID.lowercased()
    if lower.contains("whatsapp") {
        return SourceAppInfo(displayName: "WhatsApp",  sfSymbol: "message.fill",         tintColor: UIColor(red: 0.07, green: 0.70, blue: 0.26, alpha: 1))
    }
    if lower.contains("apple.mobilesms") || lower.contains("messages") {
        return SourceAppInfo(displayName: "Messages",  sfSymbol: "message.fill",         tintColor: .systemBlue)
    }
    if lower.contains("telegram") {
        return SourceAppInfo(displayName: "Telegram",  sfSymbol: "paperplane.fill",      tintColor: UIColor(red: 0.16, green: 0.56, blue: 0.84, alpha: 1))
    }
    if lower.contains("instagram") {
        return SourceAppInfo(displayName: "Instagram", sfSymbol: "camera.fill",          tintColor: UIColor(red: 0.83, green: 0.21, blue: 0.51, alpha: 1))
    }
    if lower.contains("twitter") || lower.contains("x-corp") {
        return SourceAppInfo(displayName: "X / Twitter", sfSymbol: "text.bubble.fill",  tintColor: .label)
    }
    if lower.contains("apple.mobilesafari") || lower.contains("safari") {
        return SourceAppInfo(displayName: "Safari",    sfSymbol: "safari.fill",          tintColor: .systemBlue)
    }
    if lower.contains("linkedin") {
        return SourceAppInfo(displayName: "LinkedIn",  sfSymbol: "briefcase.fill",       tintColor: UIColor(red: 0.01, green: 0.46, blue: 0.71, alpha: 1))
    }
    return SourceAppInfo(displayName: "Shared",   sfSymbol: "square.and.arrow.up",  tintColor: .systemGray)
}

/// Detect source app from attachment UTIs and suggested names — works when bundle ID is unavailable.
private func sourceInfoFromUTIs(_ providers: [NSItemProvider]) -> SourceAppInfo? {
    let allUTIs    = providers.flatMap { $0.registeredTypeIdentifiers }
    let joinedUTIs = allUTIs.joined(separator: " ").lowercased()

    // suggestedName often contains the app name, e.g. "WhatsApp Image 2026-04-07"
    let names = providers.compactMap { $0.suggestedName?.lowercased() }.joined(separator: " ")

    let combined = joinedUTIs + " " + names

    if combined.contains("whatsapp") || combined.contains("net.whatsapp") {
        return SourceAppInfo(displayName: "WhatsApp",  sfSymbol: "message.fill",    tintColor: UIColor(red: 0.07, green: 0.70, blue: 0.26, alpha: 1))
    }
    if combined.contains("com.apple.uikit.image") {
        return SourceAppInfo(displayName: "Messages",  sfSymbol: "message.fill",    tintColor: .systemBlue)
    }
    if combined.contains("telegram") {
        return SourceAppInfo(displayName: "Telegram",  sfSymbol: "paperplane.fill", tintColor: UIColor(red: 0.16, green: 0.56, blue: 0.84, alpha: 1))
    }
    if combined.contains("instagram") {
        return SourceAppInfo(displayName: "Instagram", sfSymbol: "camera.fill",     tintColor: UIColor(red: 0.83, green: 0.21, blue: 0.51, alpha: 1))
    }
    return nil
}

// MARK: - ShareViewController

class ShareViewController: UIViewController {

    private let appGroupID = "group.z.Nexa"
    private let maxItems   = 50

    private var itemsFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("pendingSharedItems.json")
    }

    // ── Source metadata ────────────────────────────────────────────────
    private var hostBundleID: String   = ""
    private var sourceAppInfo: SourceAppInfo = sourceInfo(for: "")

    // ── Extracted content ──────────────────────────────────────────────
    private var extractedTexts:     [String] = []  // text + URL strings
    private var extractedImages:    [UIImage] = []  // all images
    private var extractedImageData: Data?           // first image, compressed

    // ── UI ─────────────────────────────────────────────────────────────
    private let containerView      = UIView()
    private let handleBar          = UIView()
    private let nexaIconView       = UIImageView()
    private let titleLabel         = UILabel()
    private let sourceLabel        = UILabel()   // hidden when source is unknown
    private let previewBox         = UIView()
    private let previewLabel       = UILabel()
    private let previewImageView   = UIImageView()
    private let spinnerView        = UIActivityIndicatorView(style: .medium)
    private let noteField          = UITextField()
    private let sendButton         = UIButton(type: .system)
    private let cancelButton       = UIButton(type: .system)

    // ── Lifecycle ──────────────────────────────────────────────────────

    override func viewDidLoad() {
        super.viewDidLoad()
        // Try UTI-based source detection before drawing UI
        let allProviders = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        if let detected = sourceInfoFromUTIs(allProviders) {
            sourceAppInfo = detected
            hostBundleID  = detected.displayName
        }
        setupUI()
        extractContent()
    }

    // ── Content extraction ─────────────────────────────────────────────

    private func extractContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            spinnerView.stopAnimating()
            return
        }

        let group = DispatchGroup()

        for item in items {
            // Capture iMessage's inline caption (attributedContentText)
            if let caption = item.attributedContentText?.string,
               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extractedTexts.append(caption)
            }

            for provider in item.attachments ?? [] {
                let typeIDs = provider.registeredTypeIdentifiers

                // ── Images ──────────────────────────────────────────────
                // loadObject(ofClass: UIImage.self) is the modern API — it handles
                // HEIC, JPEG, PNG, GIF, security-scoped file URLs (iMessage, WhatsApp,
                // Files app), and private UTIs like com.whatsapp.image automatically.
                let imageUTIs: [String] = [
                    "public.heic",
                    UTType.jpeg.identifier,
                    UTType.png.identifier,
                    UTType.gif.identifier,
                    "public.webp",
                    UTType.image.identifier,
                    "com.apple.uikit.image",
                    "com.whatsapp.image",
                    "net.whatsapp.WhatsApp.image",
                ]
                if imageUTIs.contains(where: { typeIDs.contains($0) || provider.hasItemConformingToTypeIdentifier($0) }) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                        DispatchQueue.main.async {
                            defer { group.leave() }
                            guard let self, let img = object as? UIImage else { return }
                            self.extractedImages.append(img)
                            if self.extractedImageData == nil {
                                self.extractedImageData = self.compressedJPEG(img, maxBytes: 1_000_000)
                            }
                        }
                    }
                    continue
                }

                // ── URLs (Safari, link previews from iMessage / WhatsApp) ──
                if typeIDs.contains(UTType.url.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                        DispatchQueue.main.async {
                            defer { group.leave() }
                            guard let url = object as? URL else { return }
                            let scheme = url.scheme?.lowercased() ?? ""
                            if scheme == "http" || scheme == "https" {
                                self?.extractedTexts.append(url.absoluteString)
                            }
                        }
                    }
                    continue
                }

                // ── Plain text (iMessage body, WhatsApp, Telegram…) ──────
                let textUTIs: [String] = [
                    UTType.utf8PlainText.identifier,   // public.utf8-plain-text  (iMessage)
                    UTType.plainText.identifier,        // public.plain-text
                    UTType.text.identifier,             // public.text (parent)
                ]
                if let textUTI = textUTIs.first(where: {
                    typeIDs.contains($0) || provider.hasItemConformingToTypeIdentifier($0)
                }) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: textUTI, options: nil) { [weak self] rawData, _ in
                        DispatchQueue.main.async {
                            defer { group.leave() }
                            guard let self else { return }
                            var resolved: String?
                            if let s = rawData as? String { resolved = s }
                            else if let url = rawData as? URL, let s = try? String(contentsOf: url, encoding: .utf8) { resolved = s }
                            else if let d = rawData as? Data, let s = String(data: d, encoding: .utf8) { resolved = s }
                            if let resolved, !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.extractedTexts.append(resolved)
                            }
                        }
                    }
                    continue
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.didFinishExtraction()
        }
    }

    // Compress JPEG, stepping down quality until the result fits within maxBytes
    private func compressedJPEG(_ image: UIImage, maxBytes: Int) -> Data? {
        var quality: CGFloat = 0.8
        while quality > 0.1 {
            if let data = image.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            quality -= 0.15
        }
        return image.jpegData(compressionQuality: 0.1)
    }

    private func didFinishExtraction() {
        spinnerView.stopAnimating()
        // Deduplicate: iMessage sometimes provides the URL both as a caption and as public.url
        let combined = extractedTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { acc, s in if !acc.contains(s) { acc.append(s) } }
            .joined(separator: "\n\n")

        let hasImage = !extractedImages.isEmpty
        let hasText  = !combined.isEmpty

        if hasImage {
            previewImageView.image = extractedImages.first
            previewImageView.isHidden = false
            if extractedImages.count > 1 {
                previewLabel.text = "\(extractedImages.count) images selected"
                previewLabel.isHidden = false
            } else if hasText {
                previewLabel.text = combined.count > 300 ? String(combined.prefix(300)) + "…" : combined
                previewLabel.isHidden = false
            }
            previewBox.isHidden = false
        } else if hasText {
            previewLabel.text = combined.count > 500 ? String(combined.prefix(500)) + "…" : combined
            previewLabel.isHidden = false
            previewBox.isHidden = false
        } else {
            previewLabel.text = "Nothing found to share."
            previewLabel.isHidden = false
            previewBox.isHidden = false
            sendButton.isEnabled = false
            sendButton.alpha = 0.4
        }
    }

    // ── Actions ────────────────────────────────────────────────────────

    @objc private func didTapSend() {
        let note    = noteField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = extractedTexts.joined(separator: "\n\n")
        let type: String
        if extractedImageData != nil && content.isEmpty {
            type = "image"
        } else if content.hasPrefix("http://") || content.hasPrefix("https://") {
            type = "url"
        } else {
            type = "text"
        }

        let item = SharedItem(
            id:             UUID().uuidString,
            content:        content,
            contentType:    type,
            imageData:      extractedImageData,
            sourceBundleID: hostBundleID,
            sourceAppName:  sourceAppInfo.displayName,
            userNote:       note,
            timestamp:      Date(),
            processed:      false
        )
        writeToAppGroup(item)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @objc private func didTapCancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "NexaShareExtension", code: 0))
    }

    // ── App Group persistence ──────────────────────────────────────────

    private func writeToAppGroup(_ item: SharedItem) {
        guard let url = itemsFileURL else { return }
        // Read existing items directly from the shared file — no in-process cache.
        var items: [SharedItem] = []
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = existing
        }
        items.append(item)
        if items.count > maxItems { items = Array(items.suffix(maxItems)) }
        // .atomic write guarantees the reader never sees a half-written file.
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
        // Signal the main app via Darwin notification center.
        // This wakes the foreground app immediately without relying on scenePhase.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("group.z.Nexa.sharedItemAdded" as CFString),
            nil, nil, true
        )
        // Schedule a local notification so the user is informed when the main app
        // is in the background or hasn't been opened yet.
        scheduleLocalNotification(for: item)
    }

    private func scheduleLocalNotification(for item: SharedItem) {
        let content = UNMutableNotificationContent()
        content.title = "Nexa received new content"
        let knownSource = !item.sourceAppName.isEmpty && item.sourceAppName != "Shared"
        switch item.contentType {
        case "image":
            content.body = knownSource ? "Image from \(item.sourceAppName) — tap to open" : "New image — tap to open"
        case "url":
            let host = URL(string: item.content)?.host ?? item.content
            content.body = knownSource ? "Link from \(item.sourceAppName): \(host)" : "New link: \(host)"
        default:
            let preview = item.content.prefix(80)
            content.body = knownSource ? "From \(item.sourceAppName): \(preview)" : String(preview)
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request  = UNNotificationRequest(
            identifier: "nexa_shared_\(item.id)",
            content:    content,
            trigger:    trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // ── UI Setup ───────────────────────────────────────────────────────

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        // Dismiss tap on the dimmed backdrop
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapCancel))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // ── Container sheet ─────────────────────────────────────────────
        containerView.backgroundColor = UIColor.systemBackground
        containerView.layer.cornerRadius = 24
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.clipsToBounds = true
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        // Intercept touches on the container so they don't bubble to the dimmed backdrop
        let containerTap = UITapGestureRecognizer(target: nil, action: nil)
        containerView.addGestureRecognizer(containerTap)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // ── Handle bar ──────────────────────────────────────────────────
        handleBar.backgroundColor = UIColor.systemGray4
        handleBar.layer.cornerRadius = 3
        handleBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(handleBar)

        // ── Header row: Nexa icon + title ───────────────────────────────
        let nexaCfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        nexaIconView.image = UIImage(systemName: "brain.head.profile", withConfiguration: nexaCfg)
        nexaIconView.tintColor = .systemPurple
        nexaIconView.contentMode = .scaleAspectFit
        nexaIconView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(nexaIconView)

        titleLabel.text = "Send to Nexa"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // Only show source label when we actually know the source
        let knownSource = !hostBundleID.isEmpty && sourceAppInfo.displayName != "Shared"
        sourceLabel.text = "From \(sourceAppInfo.displayName)"
        sourceLabel.font = UIFont.systemFont(ofSize: 13)
        sourceLabel.textColor = .secondaryLabel
        sourceLabel.isHidden = !knownSource
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(sourceLabel)

        // ── Spinner (shown while extracting) ───────────────────────────
        spinnerView.startAnimating()
        spinnerView.hidesWhenStopped = true
        spinnerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(spinnerView)

        // ── Preview box ─────────────────────────────────────────────────
        previewBox.backgroundColor = UIColor.secondarySystemBackground
        previewBox.layer.cornerRadius = 12
        previewBox.clipsToBounds = true
        previewBox.isHidden = true
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(previewBox)

        previewLabel.numberOfLines = 6
        previewLabel.font = UIFont.systemFont(ofSize: 14)
        previewLabel.textColor = .secondaryLabel
        previewLabel.isHidden = true
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewLabel)

        previewImageView.contentMode = .scaleAspectFill
        previewImageView.clipsToBounds = true
        previewImageView.isHidden = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewImageView)

        // ── Note field ──────────────────────────────────────────────────
        noteField.placeholder = "Add a note for Nexa (optional)…"
        noteField.font = UIFont.systemFont(ofSize: 15)
        noteField.borderStyle = .roundedRect
        noteField.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(noteField)

        // ── Send button ─────────────────────────────────────────────────
        sendButton.setTitle("Send to Nexa", for: .normal)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        sendButton.backgroundColor = .systemPurple
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 14
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(sendButton)

        // ── Cancel button ───────────────────────────────────────────────
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.secondaryLabel, for: .normal)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(cancelButton)

        // ── Constraints ─────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            // Handle bar
            handleBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            handleBar.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            handleBar.widthAnchor.constraint(equalToConstant: 40),
            handleBar.heightAnchor.constraint(equalToConstant: 5),

            // Nexa icon
            nexaIconView.topAnchor.constraint(equalTo: handleBar.bottomAnchor, constant: 18),
            nexaIconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            nexaIconView.widthAnchor.constraint(equalToConstant: 28),
            nexaIconView.heightAnchor.constraint(equalToConstant: 28),

            // Title
            titleLabel.centerYAnchor.constraint(equalTo: nexaIconView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: nexaIconView.trailingAnchor, constant: 12),

            // Source label (zero height when hidden keeps layout clean)
            sourceLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            sourceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            // Spinner
            spinnerView.topAnchor.constraint(equalTo: nexaIconView.bottomAnchor, constant: 20),
            spinnerView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            // Preview box
            previewBox.topAnchor.constraint(equalTo: nexaIconView.bottomAnchor, constant: 16),
            previewBox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            previewBox.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            // Image inside preview box (shown above text when both present)
            previewImageView.topAnchor.constraint(equalTo: previewBox.topAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            previewImageView.heightAnchor.constraint(equalToConstant: 130),

            // Text label inside preview box
            previewLabel.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 8),
            previewLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -12),
            previewLabel.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -10),

            // Note field
            noteField.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 14),
            noteField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            noteField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            noteField.heightAnchor.constraint(equalToConstant: 44),

            // Send button
            sendButton.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 16),
            sendButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            sendButton.heightAnchor.constraint(equalToConstant: 50),

            // Cancel button
            cancelButton.topAnchor.constraint(equalTo: sendButton.bottomAnchor, constant: 8),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
    }
}
