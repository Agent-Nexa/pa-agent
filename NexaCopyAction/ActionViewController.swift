//
//  ActionViewController.swift
//  NexaCopyAction
//
//  Shows in the Actions row (bottom strip) of the iOS share sheet.
//  Tapping "Send to Nexa" writes the shared content to the App Group
//  so the main Nexa app can inject it into chat on next foreground.
//

import UIKit
import UniformTypeIdentifiers
import MobileCoreServices
import UserNotifications

// ── SharedItem — must match EmailModels.swift field-for-field ─────────────────
private struct SharedItem: Codable {
    var id:            String
    var content:       String
    var contentType:   String   // "text" | "image" | "url"
    var imageData:     Data?
    var sourceBundleID: String
    var sourceAppName: String
    var userNote:      String
    var timestamp:     Date
    var processed:     Bool
}

// MARK: - ActionViewController

class ActionViewController: UIViewController {

    private let appGroupID = "group.z.Nexa"
    private let maxItems   = 50

    private var itemsFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("pendingSharedItems.json")
    }

    // ── Extracted content ──────────────────────────────────────────────
    private var extractedText: String = ""
    private var extractedImageData: Data?

    // ── UI ─────────────────────────────────────────────────────────────
    private let containerView  = UIView()
    private let handleBar      = UIView()
    private let iconView       = UIImageView()
    private let titleLabel     = UILabel()
    private let previewLabel   = UILabel()
    private let previewImageView = UIImageView()
    private let spinnerView    = UIActivityIndicatorView(style: .medium)
    private let sendButton     = UIButton(type: .system)
    private let cancelButton   = UIButton(type: .system)

    // ── Lifecycle ──────────────────────────────────────────────────────

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        extractContent()
    }

    // ── Content extraction ─────────────────────────────────────────────

    private func extractContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            spinnerView.stopAnimating()
            sendButton.isEnabled = true
            sendButton.alpha = 1
            return
        }

        let group = DispatchGroup()

        for item in items {
            if let caption = item.attributedContentText?.string,
               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extractedText = caption
            }

            for provider in item.attachments ?? [] {
                let typeIDs = provider.registeredTypeIdentifiers

                // Images
                let imageUTIs: [String] = [
                    "public.heic", UTType.jpeg.identifier, UTType.png.identifier,
                    UTType.gif.identifier, "public.webp", UTType.image.identifier,
                    "com.apple.uikit.image", "com.whatsapp.image", "net.whatsapp.WhatsApp.image",
                ]
                if imageUTIs.contains(where: { typeIDs.contains($0) || provider.hasItemConformingToTypeIdentifier($0) }) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                        DispatchQueue.main.async {
                            defer { group.leave() }
                            guard let self, let img = object as? UIImage else { return }
                            self.extractedImageData = self.compressedJPEG(img, maxBytes: 1_000_000)
                            self.previewImageView.image = img
                        }
                    }
                    continue
                }

                // URLs
                if typeIDs.contains(UTType.url.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                        DispatchQueue.main.async {
                            defer { group.leave() }
                            guard let url = object as? URL else { return }
                            let s = url.scheme?.lowercased() ?? ""
                            if s == "http" || s == "https" { self?.extractedText = url.absoluteString }
                        }
                    }
                    continue
                }

                // Text
                let textUTIs: [String] = [
                    UTType.utf8PlainText.identifier,
                    UTType.plainText.identifier,
                    UTType.text.identifier,
                ]
                if let textUTI = textUTIs.first(where: { typeIDs.contains($0) || provider.hasItemConformingToTypeIdentifier($0) }) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: textUTI, options: nil) { [weak self] raw, _ in
                        DispatchQueue.main.async {
                            defer { group.leave() }
                            var resolved: String?
                            if let s = raw as? String { resolved = s }
                            else if let u = raw as? URL, let s = try? String(contentsOf: u, encoding: .utf8) { resolved = s }
                            else if let d = raw as? Data, let s = String(data: d, encoding: .utf8) { resolved = s }
                            if let resolved, !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self?.extractedText = resolved
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

    private func didFinishExtraction() {
        spinnerView.stopAnimating()

        if let img = previewImageView.image {
            previewImageView.isHidden = false
            previewLabel.isHidden = true
            _ = img // already set
        } else if !extractedText.isEmpty {
            previewLabel.text = String(extractedText.prefix(200))
            previewLabel.isHidden = false
            previewImageView.isHidden = true
        } else {
            previewLabel.text = "Ready to send to Nexa"
            previewLabel.isHidden = false
            previewImageView.isHidden = true
        }

        sendButton.isEnabled = true
        sendButton.alpha = 1
    }

    // ── Send ───────────────────────────────────────────────────────────

    @objc private func didTapSend() {
        let content = extractedText
        let type: String
        if extractedImageData != nil && content.isEmpty {
            type = "image"
        } else if content.hasPrefix("http://") || content.hasPrefix("https://") {
            type = "url"
        } else {
            type = "text"
        }

        let item = SharedItem(
            id:            UUID().uuidString,
            content:       content,
            contentType:   type,
            imageData:     extractedImageData,
            sourceBundleID: "",
            sourceAppName: "",
            userNote:      "",
            timestamp:     Date(),
            processed:     false
        )

        guard let url = itemsFileURL else { return }
        // Read existing items directly from the shared file — no in-process cache.
        var items: [SharedItem] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = decoded
        }
        items.append(item)
        if items.count > maxItems { items = Array(items.suffix(maxItems)) }
        // .atomic write guarantees the reader never sees a half-written file.
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
        // Signal the main app via Darwin notification — works even when the
        // main app is already in the foreground (scenePhase won't re-fire).
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("group.z.Nexa.sharedItemAdded" as CFString),
            nil, nil, true
        )
        // Local notification so the user knows content arrived if the app is backgrounded.
        scheduleLocalNotification(for: item)

        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @objc private func didTapCancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "NexaCopyAction", code: 0))
    }

    // ── Local notification ─────────────────────────────────────────────

    private func scheduleLocalNotification(for item: SharedItem) {
        let content = UNMutableNotificationContent()
        content.title = "Nexa received new content"
        switch item.contentType {
        case "image":
            content.body = "New image — tap to open"
        case "url":
            let host = URL(string: item.content)?.host ?? item.content
            content.body = "New link: \(host)"
        default:
            content.body = String(item.content.prefix(80))
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

    // ── Helpers ────────────────────────────────────────────────────────

    private func compressedJPEG(_ image: UIImage, maxBytes: Int) -> Data? {
        var quality: CGFloat = 0.85
        while quality > 0.1 {
            if let data = image.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            quality -= 0.15
        }
        return image.jpegData(compressionQuality: 0.1)
    }

    // ── UI Setup ───────────────────────────────────────────────────────

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        let bgTap = UITapGestureRecognizer(target: self, action: #selector(didTapCancel))
        bgTap.cancelsTouchesInView = false
        view.addGestureRecognizer(bgTap)

        containerView.backgroundColor = .systemBackground
        containerView.layer.cornerRadius = 24
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.clipsToBounds = true
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)
        let sheetTap = UITapGestureRecognizer(target: nil, action: nil)
        containerView.addGestureRecognizer(sheetTap)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        handleBar.backgroundColor = .systemGray4
        handleBar.layer.cornerRadius = 3
        handleBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(handleBar)

        // ── Icon: purple circle with white sparkle symbol ─────────────
        let iconContainer = UIView()
        iconContainer.backgroundColor = .systemPurple
        iconContainer.layer.cornerRadius = 22
        iconContainer.clipsToBounds = true
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(iconContainer)

        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        iconView.image = UIImage(systemName: "sparkles", withConfiguration: cfg)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        titleLabel.text = "Send to Nexa"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: handleBar.bottomAnchor, constant: 18),
            iconContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            iconContainer.widthAnchor.constraint(equalToConstant: 44),
            iconContainer.heightAnchor.constraint(equalToConstant: 44),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
        ])

        spinnerView.startAnimating()
        spinnerView.hidesWhenStopped = true
        spinnerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(spinnerView)

        previewImageView.contentMode = .scaleAspectFill
        previewImageView.clipsToBounds = true
        previewImageView.layer.cornerRadius = 12
        previewImageView.isHidden = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(previewImageView)

        previewLabel.numberOfLines = 5
        previewLabel.font = .systemFont(ofSize: 14)
        previewLabel.textColor = .secondaryLabel
        previewLabel.isHidden = true
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(previewLabel)

        sendButton.setTitle("Send to Nexa", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        sendButton.backgroundColor = .systemPurple
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 14
        sendButton.isEnabled = false
        sendButton.alpha = 0.4
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(sendButton)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.secondaryLabel, for: .normal)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            handleBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            handleBar.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            handleBar.widthAnchor.constraint(equalToConstant: 40),
            handleBar.heightAnchor.constraint(equalToConstant: 5),

            spinnerView.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 20),
            spinnerView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            previewImageView.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 16),
            previewImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            previewImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            previewImageView.heightAnchor.constraint(equalToConstant: 140),

            previewLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 16),
            previewLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            previewLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            sendButton.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 16),
            sendButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            sendButton.heightAnchor.constraint(equalToConstant: 50),

            cancelButton.topAnchor.constraint(equalTo: sendButton.bottomAnchor, constant: 8),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
    }
}
