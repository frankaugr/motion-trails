import SwiftUI

/// Upgrade screen (spec §8, §13). Leads with the trail motif (the effect itself, animated),
/// lists what premium unlocks, and shows the price on the CTA. Purchase is still the stubbed
/// entitlement flip behind `MonetizationStore`.
struct PaywallView: View {
    @Environment(MonetizationStore.self) private var monetization
    @Environment(\.dismiss) private var dismiss

    private struct Benefit: Identifiable {
        var id: String { title }
        let icon: String
        let title: String
        let detail: String
    }

    private var benefits: [Benefit] {
        [
            .init(icon: "photo.on.rectangle.angled", title: "Import from library",
                  detail: "Turn any existing clip into trails — free tier records in-app."),
            .init(icon: "drop.fill", title: "No watermark",
                  detail: "Clean exports, ready to share."),
            .init(icon: "timer", title: "Record up to \(Int(monetization.premiumRecordingLimit)) seconds",
                  detail: "Free tier is capped at \(Int(monetization.freeRecordingLimit))s."),
            .init(icon: "4k.tv", title: "4K export",
                  detail: "Highest quality on supported devices."),
            .init(icon: "slider.horizontal.below.square.filled.and.square", title: "Fade & blend modes",
                  detail: "Creative trail styling."),
            .init(icon: "scribble.variable", title: "Ignore-region masks",
                  detail: "Exclude waving trees, water, shadows."),
            .init(icon: "paintpalette.fill", title: "Color trail styles",
                  detail: "Stylized, colorful trails.")
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        TrailMotif()
                            .frame(height: 120)
                            .padding(.horizontal, 16)
                        Text("Motion Trails Premium")
                            .font(.title2.bold())
                        Text("Longer recordings, watermark-free 4K exports, and the full creative toolkit.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 0) {
                        ForEach(benefits) { benefit in
                            HStack(spacing: 14) {
                                Image(systemName: benefit.icon)
                                    .font(.title3)
                                    .frame(width: 32)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(benefit.title).font(.subheadline.weight(.medium))
                                    Text(benefit.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            if benefit.id != benefits.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
                    .padding(.horizontal, 16)

                    if monetization.isPremium {
                        Label("Premium unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.headline)
                    } else {
                        VStack(spacing: 10) {
                            Button {
                                Theme.Haptics.success()
                                monetization.purchasePremium()
                                dismiss()
                            } label: {
                                Text("Unlock Premium · \(monetization.displayPrice)")
                            }
                            .buttonStyle(PrimaryButtonStyle())

                            Text("One-time purchase")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Restore Purchases") { monetization.restore() }
                                .font(.footnote)
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.canvas.ignoresSafeArea())
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
