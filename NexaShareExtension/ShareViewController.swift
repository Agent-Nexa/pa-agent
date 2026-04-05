//
//  ShareViewController.swift
//  NexaShareExtension
//
//  Receives text or images shared from any app (WhatsApp, Messages, Safari…)
//  and writes a SharedItem to the App Group so the main Nexa app can process it.
//

import UIKit
import Social
import UniformTypeIdentifiers
import MobileCoreServices

// Local copy of SharedItem for use inside the extension (main app has its own in EmailModels.swift).
// Keep field names identical so JSON round-trips correctly.
struct SharedItem: Codable {
    var id: String
    var content: String
    var contentType: String
    var imageData: Data?
    var sourceBundleID: String
    var sourceAppName: String
    var userNote: String
    var timestamp: Date
    var processed: Bool
}

class ShareViewController: UIViewController {

    private let suiteName = "group.z.Nexa"
    private let udKey     = "pendingSharedItems"
    private let maxItems  = 50

    // ── UI ─────────────────────────────────────────────────────────────
    private let containerView    = UIView()
    private let handleBar        = UIView()
    private let iconView         = UIImageView()
    private let titleLabel       = UILabel()
    private let previewLabel     = UILabel()
    private let previewImageView = UIImageView()
    private let noteField        = UITextField()
    private let sendButton       = UIButton(type: .system)
    private let cancelButton     = UIButton(type: .system)

    private var extractedText: String = ""
    private var extractedImageData: Data?

    // ── Lifecycle ──────────────────────────────────────────────────────

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        extractContent()
    }

    // ── Content extraction ─────────────────────────────────────────────

    private func extractContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }

        for item in items {
            for provider in item.attachments ?? [] {
                // Plain text
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, _ in
                        DispatchQueue.main.async {
                            if let text = data as? String { self?.didExtractText(text) }
                            else if let url = data as? URL, let text = try? String(contentsOf: url) { self?.didExtractText(text) }
                        }
                    }
                    return
                }
                // URL (share from Safari etc.)
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
                        DispatchQueue.main.async {
                            if let url = data as? URL { self?.didExtractText(url.absoluteString) }
                        }
                    }
                    return
                }
                // Image
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, _ in
                        DispatchQueue.main.async {
                            if let image = data as? UIImage {
                                self?.didExtractImage(image)
                            } else if let url = data as? URL, let img = UIImage(contentsOfFile: url.path) {
                                self?.didExtractImage(img)
                            }
                        }
                    }
                    return
                }
            }
        }
    }

    private func didExtractText(_ text: String) {
        extractedText = text
        previewLabel.text = text.count > 300 ? String(text.prefix(300)) + "…" : text
        previewLabel.isHidden = false
        previewImageView.isHidden = true
    }

    private func didExtractImage(_ image: UIImage) {
        extractedImageData = image.jpegData(compressionQuality: 0.6)
        previewImageView.image = image
        previewImageView.isHidden = false
        previewLabel.text = "Image"
        previewLabel.isHidden = false
    }

    // ── Actions ────────────────────────────────────────────────────────

    @objc private func didTapSend() {
        let note = noteField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceBundleID = Bundle.main.object(forInfoDictionaryKey: "NSExtensionHostBundleIdentifier") as? String ?? ""
        let item = SharedItem(
            id:            UUID().uuidString,
            content:       extractedText,
            contentType:   extractedImageData != nil ? "image" : (extractedText.hasPrefix("http") ? "url" : "text"),
            imageData:     extractedImageData,
            sourceBundleID: sourceBundleID,
            sourceAppName: "",
            userNote:      note,
            timestamp:     Date(),
            processed:     false
        )
        writeToAppGroup(item)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    @objc private func didTapCancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "NexaShareExtension", code: 0))
    }

    // ── App Group persistence ──────────────────────────────────────────

    private func writeToAppGroup(_ item: SharedItem) {
        guard let ud = UserDefaults(suiteName: suiteName) else { return }
        var items: [SharedItem]
        if let data = ud.data(forKey: udKey), let existing = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = existing
        } else {
            items = []
        }
        items.append(item)
        // Cap at maxItems
        if items.count > maxItems { items = Array(items.suffix(maxItems)) }
        if let data = try? JSONEncoder().encode(items) {
            ud.set(data, forKey: udKey)
        }
    }

    // ── UI Setup ───────────────────────────────────────────────────────

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        // Container
        containerView.backgroundColor = UIColor.systemBackground
        containerView.layer.cornerRadius = 20
        containerView.clipsToBounds = true
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Handle bar
        handleBar.backgroundColor = UIColor.systemGray4
        handleBar.layer.cornerRadius = 3
        handleBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(handleBar)

        // Icon
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        iconView.image = UIImage(systemName: "brain.head.profile", withConfiguration: config)
        iconView.tintColor = .systemPurple
        iconView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(iconView)

        // Title
        titleLabel.text = "Send to Nexa"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // Preview label
        previewLabel.numberOfLines = 5
        previewLabel.font = UIFont.systemFont(ofSize: 14)
        previewLabel.textColor = .secondaryLabel
        previewLabel.backgroundColor = UIColor.secondarySystemBackground
        previewLabel.layer.cornerRadius = 10
        previewLabel.clipsToBounds = true
        previewLabel.isHidden = true
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(previewLabel)

        // Preview image
        previewImageView.contentMode = .scaleAspectFit
        previewImageView.layer.cornerRadius = 10
        previewImageView.clipsToBounds = true
        previewImageView.isHidden = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(previewImageView)

        // Note field
        noteField.placeholder = "Add a note for Nexa (optional)…"
        noteField.font = UIFont.systemFont(ofSize: 15)
        noteField.borderStyle = .roundedRect
        noteField.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(noteField)

        // Send button
        sendButton.setTitle("Send to Nexa", for: .normal)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        sendButton.backgroundColor = .systemPurple
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 14
        sendButton.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(sendButton)

        // Cancel button
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.secondaryLabel, for: .normal)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            handleBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            handleBar.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            handleBar.widthAnchor.constraint(equalToConstant: 40),
            handleBar.heightAnchor.constraint(equalToConstant: 6),

            iconView.topAnchor.constraint(equalTo: handleBar.bottomAnchor, constant: 16),
            iconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),

            previewLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            previewLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            previewLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            previewImageView.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 8),
            previewImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            previewImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            previewImageView.heightAnchor.constraint(equalToConstant: 120),

            noteField.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 12),
            noteField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            noteField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            noteField.heightAnchor.constraint(equalToConstant: 44),

            sendButton.topAnchor.constraint(equalTo: noteField.bottomAnchor, constant: 16),
            sendButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            sendButton.heightAnchor.constraint(equalToConstant: 50),

            cancelButton.topAnchor.constraint(equalTo: sendButton.bottomAnchor, constant: 8),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }
}
