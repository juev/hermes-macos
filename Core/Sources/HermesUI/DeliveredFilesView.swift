import AppKit
import HermesCore
import SwiftUI

/// The files the agent delivered, under its answer: a picture shows itself, anything else a card
/// with its name and its kind, and every one of them opens on a click.
public struct DeliveredFilesView: View {
    public let paths: [String]
    public let load: (@Sendable (String) async throws -> Data)?
    public let open: (@Sendable (String) -> Void)?

    public init(
        paths: [String],
        load: (@Sendable (String) async throws -> Data)? = nil,
        open: (@Sendable (String) -> Void)? = nil
    ) {
        self.paths = paths
        self.load = load
        self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paths, id: \.self) { path in
                DeliveredFileCard(path: path, load: load, open: open)
            }
        }
    }
}

struct DeliveredFileCard: View {
    let path: String
    let load: (@Sendable (String) async throws -> Data)?
    let open: (@Sendable (String) -> Void)?

    @State private var image: NSImage?
    @State private var failed = false

    private var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private var fileExtension: String {
        name.split(separator: ".").last.map { $0.lowercased() } ?? ""
    }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(fileExtension)
    }

    var body: some View {
        Button {
            open?(path)
        } label: {
            HStack(spacing: 10) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 104, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: isImage ? "photo" : glyph)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.Palette.reasoningRule.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Theme.Fonts.sessionTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(failed ? "Could not be read" : (fileExtension.isEmpty ? "File" : fileExtension.uppercased()))
                        .font(Theme.Fonts.sessionMeta)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Theme.Palette.toolBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .task(id: path) {
            guard isImage, let load else { return }
            do {
                let data = try await load(path)
                guard let picture = NSImage(data: data) else {
                    failed = true
                    return
                }
                image = picture
            } catch {
                failed = true
            }
        }
    }

    private var glyph: String {
        switch fileExtension {
        case "md", "txt", "log": "doc.text"
        case "json", "yaml", "yml", "toml": "curlybraces"
        case "pdf": "doc.richtext"
        case "zip", "tar", "gz": "archivebox"
        case "sh", "py", "kt", "swift", "js", "ts": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}
