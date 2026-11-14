import AVFoundation
import SwiftUI

/// The two voice settings, as controls shared by the last onboarding screen and Memories > Settings.

/// Slower to faster. Letting go of the slider plays a sample at the new speed.
struct SpeedControl: View {
    @ObservedObject var settings: VoiceSettings

    var body: some View {
        Slider(value: $settings.rate, in: VoiceSettings.rateRange) {
            Text("Speaking speed")
        } minimumValueLabel: {
            Image(systemName: "tortoise.fill").accessibilityHidden(true)
        } maximumValueLabel: {
            Image(systemName: "hare.fill").accessibilityHidden(true)
        } onEditingChanged: { editing in
            if !editing { settings.sample() }
        }
        .accessibilityValue(spokenValue)
    }

    /// The slider's position in words; a percentage of an arbitrary range would mean nothing.
    private var spokenValue: String {
        let range = VoiceSettings.rateRange
        let position = (settings.rate - range.lowerBound) / (range.upperBound - range.lowerBound)
        switch position {
        case ..<0.2: return "Slowest"
        case ..<0.45: return "Slow"
        case ..<0.7: return "Medium"
        case ..<0.9: return "Fast"
        default: return "Fastest"
        }
    }
}

/// One row per voice offered; choosing one plays a sample in it.
struct VoiceChoices: View {
    @ObservedObject var settings: VoiceSettings

    var body: some View {
        ForEach(settings.choices, id: \.identifier) { voice in
            let selected = voice.identifier == settings.voiceID
            Button {
                settings.voiceID = voice.identifier
                settings.sample()
            } label: {
                HStack(spacing: 12) {
                    Text(VoiceSettings.displayName(voice))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Shown instead of a sample while VoiceOver is doing the talking.
struct VoiceOverNote: View {
    var body: some View {
        if UIAccessibility.isVoiceOverRunning {
            Text("While VoiceOver is on, replies use VoiceOver's own voice and speed.")
        }
    }
}

/// Memories > Settings: the same two settings as the last onboarding screen.
struct VoiceSettingsPage: View {
    @ObservedObject var settings: VoiceSettings

    var body: some View {
        Form {
            Section("Speaking speed") {
                SpeedControl(settings: settings)
            }
            Section {
                VoiceChoices(settings: settings)
            } header: {
                Text("Voice")
            } footer: {
                VoiceOverNote()
            }
        }
        .navigationTitle("Settings")
        .onDisappear { settings.stopSample() }
    }
}
