import SwiftUI

/// Shared custom editing surface. Sections retain identity and semantics, while
/// spacing, card shape and row alignment are owned by Expenso rather than Form.
struct ExpenseForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.header.isEmpty {
                            ForEach(section.header) { header in
                                header.font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                        if !section.content.isEmpty {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(section.content) { row in
                                    row.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .expenseSummarySurface(cornerRadius: 24, reflectsMotion: false)
                        }
                        if !section.footer.isEmpty {
                            ForEach(section.footer) { footer in
                                footer.font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.always, axes: .vertical)
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { keyboardEndEditing() }
        }
        .buttonStyle(ExpenseFormButtonStyle())
        .labeledContentStyle(ExpenseLabeledContentStyle())
        .disclosureGroupStyle(ExpenseDisclosureGroupStyle())
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct ExpenseDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: 16) { configuration.content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ExpenseFormButtonStyle: ButtonStyle {
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .foregroundStyle(isEnabled ? (configuration.role == .destructive ? Color.red : accentColor) : Color.secondary)
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct ExpenseValueRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        ExpenseAlignedRow {
            Text(title).foregroundStyle(.primary)
        } value: { value }
        .frame(minHeight: 44)
    }
}

private struct ExpenseAlignedRow<Label: View, Value: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var value: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                label.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                value.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                value.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ExpenseLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ExpenseAlignedRow {
            configuration.label.foregroundStyle(.primary)
        } value: { configuration.content.foregroundStyle(.secondary) }
        .frame(minHeight: 44)
    }
}

struct ExpenseMenuRow<Options: View>: View {
    let title: String
    let value: String
    var symbol: String? = nil
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            options
        } label: {
            ExpenseValueRow(title: title) {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                    Text(value)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct ExpenseField<Input: View>: View {
    let title: String
    @ViewBuilder var input: Input

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            input.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

extension EnvironmentValues {
    @Entry var motionReflectionsAllowed = true
}

/// Explicit row contrast survives the sheet's transition from floating to expanded.
/// Content uses frosted material, not the interactive glass reserved for controls.
private struct ExpenseFormRowSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            Rectangle().fill(Color(uiColor: contrast == .increased ? .systemGray5 : .systemGray6))
        } else {
            Rectangle()
                .fill(.regularMaterial)
                .overlay { Color(uiColor: .systemGray6).opacity(0.65) }
        }
    }
}

/// Equal-width, equal-height summary cards, stacked at accessibility text sizes.
struct ExpenseSummaryPair<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: Content

    var body: some View {
        EqualSummaryLayout(stacked: dynamicTypeSize.isAccessibilitySize) { content }
    }
}

private struct EqualSummaryLayout: Layout {
    let stacked: Bool
    private let spacing: CGFloat = 8

    private func cellSize(proposal: ProposedViewSize, subviews: Subviews) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let idealWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let availableWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = availableWidth.map { stacked ? $0 : max(0, ($0 - spacing * (count - 1)) / count) } ?? idealWidth
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cell = cellSize(proposal: proposal, subviews: subviews)
        let count = CGFloat(subviews.count)
        return CGSize(width: stacked ? cell.width : cell.width * count + spacing * (count - 1),
                      height: stacked ? cell.height * count + spacing * (count - 1) : cell.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cellSize(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            // SwiftUI mirrors custom-layout placement for right-to-left environments.
            subview.place(at: CGPoint(x: bounds.minX + (stacked ? 0 : CGFloat(index) * (cell.width + spacing)),
                                     y: bounds.minY + (stacked ? CGFloat(index) * (cell.height + spacing) : 0)),
                          anchor: .topLeading, proposal: ProposedViewSize(cell))
        }
    }
}

/// Content uses a quiet frosted material; Liquid Glass remains on navigation and controls.
private struct ExpenseSummarySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    let cornerRadius: CGFloat
    let reflectsMotion: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                } else {
                    shape.fill(.regularMaterial)
                        .overlay {
                            shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                }
            }
            .overlay {
                shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.3 : 0.08), lineWidth: 1 / displayScale)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay {
                if !reduceTransparency && contrast != .increased {
                    ExpenseReflectiveRim(cornerRadius: cornerRadius, reflectsMotion: reflectsMotion)
                }
            }
    }
}

private struct ExpenseReflectiveRim: View {
    @Environment(\.motionReflectionsAllowed) private var screenAllowsMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @AppStorage(GlassAppearanceSettings.motionKey) private var motionEnabled = false
    @State private var motion = GlassReflectionMotion.shared
    @State private var client = UUID()
    @State private var isVisible = false
    let cornerRadius: CGFloat
    let reflectsMotion: Bool

    private var active: Bool { isVisible && screenAllowsMotion && reflectsMotion && motionEnabled && !reduceMotion && scenePhase == .active }

    var body: some View {
        let x = active ? motion.x : 0
        let y = active ? motion.y : 0
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.32 : 0.7),
                                                  .white.opacity(0.04), .primary.opacity(0.06),
                                                  .white.opacity(0.18)],
                                         startPoint: UnitPoint(x: 0.15 + x, y: y),
                                         endPoint: UnitPoint(x: 0.85 - x, y: 1 - y)),
                          lineWidth: 1 / displayScale)
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { isVisible = true }
            .onChange(of: active, initial: true) { _, value in motion.setActive(value, client: client) }
            .onDisappear { isVisible = false; motion.setActive(false, client: client) }
    }
}

/// Vega's public-API treatment: material fades into content instead of ending at a bar edge.
private struct ExpenseProgressiveBlur: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let edge: VerticalEdge

    private var start: UnitPoint { edge == .top ? .top : .bottom }
    private var end: UnitPoint { edge == .top ? .bottom : .top }

    var body: some View {
        ZStack {
            Group {
                if reduceTransparency {
                    Color(uiColor: .systemBackground)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .mask(LinearGradient(colors: [.black, .black.opacity(0.9), .black.opacity(0.4), .clear],
                                 startPoint: start, endPoint: end))

            LinearGradient(colors: [Color(uiColor: .systemBackground).opacity(0.58),
                                    Color(uiColor: .systemBackground).opacity(0.32),
                                    Color(uiColor: .systemBackground).opacity(0.10), .clear],
                           startPoint: start, endPoint: end)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ExpenseScreenChrome: ViewModifier {
    let bottom: Bool

    func body(content: Content) -> some View {
        // Like Vega's native edge-bar path, let the navigation container own its
        // material and scroll fade. A screen-wide safe-area overlay can mistake
        // a keyboard or nested presentation for part of the header.
        edgeEffects(content)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.automatic, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()
            .scrollBounceBehavior(.always, axes: .vertical)
    }

    @ViewBuilder private func edgeEffects(_ content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: bottom ? .vertical : .top)
        } else {
            content
        }
    }
}

enum ExpenseSheetProfile: Equatable {
    case floating, editor
}

private struct ExpenseSheetStyle: ViewModifier {
    let profile: ExpenseSheetProfile
    @State private var selectedDetent: PresentationDetent

    init(profile: ExpenseSheetProfile) {
        self.profile = profile
        _selectedDetent = State(initialValue: profile == .editor ? .large : .fraction(0.8))
    }

    func body(content: Content) -> some View {
        content
            .presentationDetents(profile == .editor ? [.large] : [.fraction(0.8), .large], selection: $selectedDetent)
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
            .scrollContentBackground(.hidden)
    }
}

extension View {
    /// Apply to each Form Section, keeping native grouped corners and separators.
    func expenseFormSectionSurface() -> some View {
        listRowBackground(ExpenseFormRowSurface())
    }

    func expenseSummarySurface(cornerRadius: CGFloat = 24, reflectsMotion: Bool = true) -> some View {
        modifier(ExpenseSummarySurface(cornerRadius: cornerRadius, reflectsMotion: reflectsMotion))
    }

    /// Use once on a screen's content inside its NavigationStack.
    func expenseScreenChrome(bottom: Bool = true) -> some View {
        modifier(ExpenseScreenChrome(bottom: bottom))
    }

    /// Modern scroll edges already supply progressive blur. An additional masked
    /// material can create a second boundary at the sheet's bottom safe area.
    @ViewBuilder
    func expenseBottomBarBackground() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            background {
                ExpenseProgressiveBlur(edge: .bottom)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Reserve the action's actual height so the final form row stays reachable.
    /// Native soft edges supply blur on modern systems; older systems use the
    /// masked material fallback. Keyboard avoidance stays owned by the container.
    @ViewBuilder
    func expenseBottomBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        if #available(iOS 26, *) {
            safeAreaInset(edge: .bottom, spacing: 0) {
                content().expenseBottomBarBackground()
            }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                content().expenseBottomBarBackground()
            }
        }
    }

    func expenseSheetStyle(_ profile: ExpenseSheetProfile = .floating) -> some View {
        modifier(ExpenseSheetStyle(profile: profile))
    }
}
