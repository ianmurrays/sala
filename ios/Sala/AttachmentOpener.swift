import SwiftUI
import QuickLook

/// Downloads an attachment and hands it to QuickLook. Shared by Today and the message thread.
@MainActor @Observable
final class AttachmentOpener {
    /// The attachment being downloaded; one at a time.
    var downloading: String?
    var previewURL: URL?

    func open(_ attachment: Attachment, store: Store, onError: @escaping @MainActor (String) -> Void) {
        guard downloading == nil, let id = attachment.id else { return }
        downloading = id
        Task {
            defer { downloading = nil }
            do {
                previewURL = try await store.client.download(attachment)
            } catch {
                if let msg = store.handle(error) { onError("Couldn't open \(attachment.name). \(msg)") }
            }
        }
    }
}

extension View {
    func quickLookPreview(_ opener: AttachmentOpener) -> some View {
        @Bindable var opener = opener
        return quickLookPreview($opener.previewURL)
    }
}
