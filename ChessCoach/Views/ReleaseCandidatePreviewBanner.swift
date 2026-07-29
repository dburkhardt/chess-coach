import SwiftUI

struct ReleaseCandidatePreviewBanner: View {
    let identity: ReleaseCandidateIdentity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("QA Candidate · Unapproved")
                .fontWeight(.semibold)
            Spacer(minLength: 12)
            Text("Build \(appBuild) · \(identity.commit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background(Color.orange.opacity(0.22))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Unapproved QA candidate, build \(appBuild), commit \(identity.commit)"
        )
        .accessibilityIdentifier("release-candidate-preview-banner")
    }

    private var appBuild: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
    }
}
