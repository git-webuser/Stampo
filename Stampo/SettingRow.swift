import SwiftUI

/// Reusable settings row: SF Symbol icon + title + optional description + trailing control.
///
/// Inspired by Snapzy (BSD 3-Clause), adapted for Stampo.
struct SettingRow<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var description: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

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
