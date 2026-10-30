/// Which parts of an answer are words and which are the work it did on the way. Drawing needs the
/// grouping and the test wants it without a screen, so it lives here, in the package both can see.
public enum TranscriptBlocking {
    public enum Block: Equatable {
        case text(String)
        case work([Part])
    }

    /// The parts in order, with reasoning and calls between two pieces of text gathered into one block.
    public static func blocks(of parts: [Part]) -> [Block] {
        var blocks: [Block] = []
        var work: [Part] = []
        for part in parts {
            switch part {
            case .text(let text):
                if !work.isEmpty {
                    blocks.append(.work(work))
                    work = []
                }
                blocks.append(.text(text))
            case .reasoning, .tool:
                work.append(part)
            }
        }
        if !work.isEmpty { blocks.append(.work(work)) }
        return blocks
    }
}
