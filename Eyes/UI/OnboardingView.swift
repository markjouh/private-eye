import SwiftUI

enum Brand {
    /// The yellow of the app icon (and of the armband its three dots come from).
    static let yellow = Color(red: 1, green: 214 / 255, blue: 0)
}

/// The app icon, drawn: three black dots on yellow, laid out like the phone's three cameras. The dots
/// keep their proportions to the shorter side, so the same view is the icon and the full-screen splash.
struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Brand.yellow))
            // Offsets from the centre and the radius, on the icon's 1024-point grid (tools/make_icon.py).
            let unit = min(size.width, size.height) / 1024
            let radius = 150 * unit
            for (dx, dy) in [(-160.0, -182.0), (-160.0, 182.0), (160.0, 0.0)] {
                let centre = CGPoint(x: size.width / 2 + dx * unit, y: size.height / 2 + dy * unit)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .color(.black))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The introduction shown at every launch: the logo, four short notes, and the voice settings.
///
/// The logo zooms in until its yellow fills the screen, then zooms out to an icon at the top, where
/// it stays while the two pages pass under it. With Reduce Motion on, nothing moves: the icon and
/// the pages fade in.
struct OnboardingView: View {
    @ObservedObject var settings: VoiceSettings
    /// Called by the last page's button.
    var onFinish: () -> Void

    private enum Step {
        case launch, logo, notes, voice
    }
    @State private var step = Step.launch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let iconSide: CGFloat = 88
    /// From the top of the safe area to the top of the icon.
    private let iconTop: CGFloat = 28

    var body: some View {
        // The outer reader is for the safe area's top edge, which the inner one, drawn across the
        // whole screen, no longer knows.
        GeometryReader { safe in
            ZStack {
                Color.black.ignoresSafeArea()
                page
                GeometryReader { screen in logo(in: screen, safeTop: safe.safeAreaInsets.top) }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .tint(Brand.yellow)
        .task { await playOpening() }
        .onChange(of: step) {
            // A new page: VoiceOver should start again from its title.
            AccessibilityNotification.ScreenChanged().post()
        }
    }

    private func playOpening() async {
        guard step == .launch else { return }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.4)) { step = .notes }
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.spring(duration: 0.5, bounce: 0.1)) { step = .logo }
        try? await Task.sleep(for: .milliseconds(1050))
        withAnimation(.spring(duration: 0.6, bounce: 0.12)) { step = .notes }
    }

    private func logo(in screen: GeometryProxy, safeTop: CGFloat) -> some View {
        let filling = step == .logo
        let waiting = step == .launch
        let size = filling ? screen.size : CGSize(width: iconSide, height: iconSide)
        let resting = CGPoint(x: screen.size.width / 2, y: safeTop + iconTop + iconSide / 2)
        let middle = CGPoint(x: screen.size.width / 2, y: screen.size.height / 2)
        return LogoMark()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: filling ? 0 : iconSide * 0.225, style: .continuous))
            .scaleEffect(waiting && !reduceMotion ? 0.4 : 1)
            .opacity(waiting ? 0 : 1)
            .position(filling || (waiting && !reduceMotion) ? middle : resting)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .launch, .logo:
            Color.clear
        case .notes:
            OnboardingPage(title: "Before you start", button: "Next", topInset: iconTop + iconSide) {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.05)) { step = .voice }
            } content: {
                VStack(alignment: .leading, spacing: 22) {
                    note("exclamationmark.triangle.fill", "It can be wrong. Stay aware of your surroundings.")
                    note("pawprint.fill", "Not a replacement for a cane, guide dog or sighted help.")
                    note("car.fill", "Never rely on it to cross a street.")
                    note("lock.fill", "Everything stays on this phone.")
                }
            }
            .transition(.asymmetric(
                // Arrives as the logo settles, leaves to the left when the next page comes in.
                insertion: (reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .offset(y: 18)))
                    .animation(.easeOut(duration: 0.35).delay(reduceMotion ? 0 : 0.3)),
                removal: reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity)))
        case .voice:
            OnboardingPage(title: "Voice", button: "Start", topInset: iconTop + iconSide) {
                settings.stopSample()
                onFinish()
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    heading("Speaking speed")
                    SpeedControl(settings: settings)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    heading("Voice").padding(.top, 12)
                    VStack(spacing: 0) {
                        VoiceChoices(settings: settings)
                            .font(.title3.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VoiceOverNote()
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Brand.yellow)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(text)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white.opacity(0.75))
            .accessibilityAddTraits(.isHeader)
    }
}

/// One onboarding page: a title under the logo, its content, and one button at the bottom.
private struct OnboardingPage<Content: View>: View {
    let title: String
    let button: String
    /// Room left at the top for the logo, which is drawn over the page.
    let topInset: CGFloat
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { area in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    // The content sits a third of the way down the room it has, and scrolls when
                    // large text needs more than that.
                    Spacer(minLength: 0)
                    content
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, topInset + 24)
                .padding(.bottom, 16)
                .frame(minHeight: area.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: action) {
                Text(button)
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(OnboardingButtonStyle())
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.black)
        }
    }
}

/// Black on the brand yellow: about 15:1.
private struct OnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(Brand.yellow.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
