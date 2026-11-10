/// Snapshot text, pruned: what changed since the last one, or the lines matching a search. Either way each line
/// comes with the lines above it that place it in the tree, so the agent needs no full snapshot to act on it.
public enum Snapshot {
    private static func depth(_ line: Substring) -> Int { line.prefix { $0 == " " }.count / 2 }

    /// Indices of the lines that enclose a line at `depth` sitting just before `index`, outermost first.
    private static func ancestors(of depth: Int, before index: Int, in lines: [Substring]) -> [Int] {
        var found: [Int] = [], depth = depth, k = index - 1
        while k >= 0, depth > 0 {
            let d = Self.depth(lines[k])
            if d < depth {
                found.append(k)
                depth = d
            }
            k -= 1
        }
        return found.reversed()
    }

    /// `+ ` added and `- ` removed lines, with unchanged enclosing lines indented by two; nil when nothing changed.
    public static func diff(from old: String, to new: String) -> String? {
        let before = old.split(separator: "\n", omittingEmptySubsequences: false)
        let after = new.split(separator: "\n", omittingEmptySubsequences: false)
        let changes = after.difference(from: before)
        guard !changes.isEmpty else { return nil }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [String] = [], shown = Set<Int>()
        func context(_ depth: Int, _ index: Int) {
            for k in ancestors(of: depth, before: index, in: after) where !shown.contains(k) && !inserted.contains(k) {
                out.append("  " + after[k])
                shown.insert(k)
            }
        }
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                context(depth(before[i]), j)
                out.append("- " + before[i])
                i += 1
            } else if j < after.count, inserted.contains(j) {
                context(depth(after[j]), j)
                out.append("+ " + after[j])
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return out.joined(separator: "\n")
    }

    /// The lines containing `query` (any case) and the lines enclosing them, as a pruned tree; nil when none match.
    public static func find(_ query: String, in tree: String, max: Int) -> (tree: String, matches: Int)? {
        let lines = tree.split(separator: "\n", omittingEmptySubsequences: false)
        let matching = lines.indices.filter { lines[$0].range(of: query, options: .caseInsensitive) != nil }
        guard !matching.isEmpty else { return nil }
        var keep = Set<Int>()
        for index in matching.prefix(max) {
            keep.formUnion(ancestors(of: depth(lines[index]), before: index, in: lines))
            keep.insert(index)
        }
        var out = keep.sorted().map { String(lines[$0]) }
        if matching.count > max { out.append("- (\(matching.count - max) more; --max-results to see them)") }
        return (out.joined(separator: "\n"), matching.count)
    }
}
