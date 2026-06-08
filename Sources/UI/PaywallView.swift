import SwiftUI

/// Upgrade screen (spec §8, §13). Lists what premium unlocks now and what's coming, and
/// flips the (stubbed) entitlement on "Upgrade".
struct PaywallView: View {
    @Environment(MonetizationStore.self) private var monetization
    @Environment(\.dismiss) private var dismiss

    private struct Benefit: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let available: Bool
    }

    private var benefits: [Benefit] {
        [
            .init(icon: "drop.fill", title: "No watermark", detail: "Clean exports, ready to share.", available: true),
            .init(icon: "timer", title: "Record up to 60 seconds", detail: "Free tier is capped at \(Int(monetization.freeRecordingLimit))s.", available: true),
            .init(icon: "4k.tv", title: "4K export", detail: "Highest quality on supported devices.", available: true),
            .init(icon: "slider.horizontal.below.square.filled.and.square", title: "Fade & blend modes", detail: "Creative trail styling.", available: true),
            .init(icon: "scribble.variable", title: "Ignore-region masks", detail: "Exclude waving trees, water, shadows.", available: true),
            .init(icon: "paintpalette.fill", title: "Color trail styles", detail: "Stylized, colorful trails.", available: true)
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.yellow)
                        Text("Motion Trails Premium")
                            .font(.title2.bold())
                        Text("Unlock longer recordings, watermark-free exports, and creative controls.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 12)

                    VStack(spacing: 14) {
                        ForEach(benefits) { benefit in
                            HStack(spacing: 14) {
                                Image(systemName: benefit.icon)
                                    .font(.title3)
                                    .frame(width: 32)
                                    .foregroundStyle(benefit.available ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(benefit.title).font(.headline)
                                        if !benefit.available {
                                            Text("Soon")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(.secondary.opacity(0.2), in: Capsule())
                                        }
                                    }
                                    Text(benefit.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal)

                    if monetization.isPremium {
                        Label("Premium unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                    } else {
                        Button {
                            monetization.purchasePremium()
                            dismiss()
                        } label: {
                            Text("Upgrade")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)

                        Button("Restore Purchases") { monetization.restore() }
                            .font(.footnote)
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }
}
