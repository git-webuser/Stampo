/// Stepping through a fixed list of cases, forwards or backwards.
///
/// One implementation because ⇥ now steps through four of them — the colour
/// format in the picker and in the archive, the language in the translator and
/// on the scan overlay — and four hand-written `(index + 1) % count` lines is
/// four chances to write the backwards case wrong.
///
/// The user's languages are deliberately not here: they are a list the user
/// edits, not a set of cases, and `TranslationLanguages.language(after:in:)`
/// takes the array it walks.
nonisolated func nextCase<T>(after value: T, backwards: Bool = false) -> T
where T: CaseIterable & Equatable, T.AllCases == [T] {
    let all = T.allCases
    guard let index = all.firstIndex(of: value), all.count > 1 else { return value }
    // Backwards is a forward step of count-1, which wraps on the same
    // expression instead of needing a negative index guarded separately.
    let step = backwards ? all.count - 1 : 1
    return all[(index + step) % all.count]
}
