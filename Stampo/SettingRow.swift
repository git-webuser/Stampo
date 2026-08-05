import SwiftUI

/// Reusable settings row: SF Symbol icon + title + optional description + trailing control.
///
/// The row draws the title, so the trailing control is built with `""` and no
/// visible label of its own — but the label is what VoiceOver reads, and an
/// empty one leaves it announcing "switch, off" with nothing to attach that
/// to. Give the control the same title the row shows and hide it with
/// `.labelsHidden()`: hidden from the eye, still there for the ear.
///
/// Inspired by Snapzy (BSD 3-Clause), adapted for Stampo.
struct SettingRow<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var description: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            // Decorative: every icon here restates the title next to it, and
            // VoiceOver reading "folder" before "Save to" is noise, not
            // information.
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            content()
        }
        .padding(.vertical, 4)
    }
}
