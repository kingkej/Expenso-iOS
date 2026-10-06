import SwiftUI
import Testing
import UIKit
@testable import Expenso

@Suite("Decorative reflection motion — mocked sensor")
@MainActor
struct GlassReflectionMotionTests {
    @Test func visibleClientsShareSensorAndLateSamplesAreIgnored() async throws {
        let sensor = MockReflectionMotionSource()
        let motion = GlassReflectionMotion(source: sensor)
        let first = UUID(), second = UUID()
        motion.setActive(true, client: first)
        motion.setActive(true, client: second)
        #expect(sensor.starts == 1)
        let receive = try #require(sensor.receive)
        await receive(1, 1)
        #expect(motion.x > 0 && motion.y > 0)
        motion.setActive(false, client: first)
        #expect(sensor.stops == 0)
        motion.setActive(false, client: second)
        #expect(sensor.stops == 1)
        #expect(motion.x == 0 && motion.y == 0)
        await receive(1, 1)
        #expect(motion.x == 0 && motion.y == 0)
        motion.setActive(true, client: first)
        await receive(-1, -1) // Callback from the previous session.
        #expect(motion.x == 0 && motion.y == 0)
        motion.setActive(false, client: first)
    }

    @Test func extremeAndInvalidSensorSamplesAreSafe() async throws {
        let sensor = MockReflectionMotionSource()
        let motion = GlassReflectionMotion(source: sensor)
        motion.setActive(true, client: UUID())
        let receive = try #require(sensor.receive)
        for _ in 0..<100 { await receive(100, -100) }
        #expect(motion.x >= 0 && motion.x <= 0.18)
        #expect(motion.y <= 0 && motion.y >= -0.14)
        await receive(.nan, 0)
        #expect(sensor.stops == 1)
        #expect(motion.x == 0 && motion.y == 0)
    }

    @Test func unavailableSensorKeepsStaticHighlight() {
        let sensor = MockReflectionMotionSource()
        sensor.isAvailable = false
        let motion = GlassReflectionMotion(source: sensor)
        motion.setActive(true, client: UUID())
        #expect(sensor.starts == 0)
        #expect(motion.x == 0 && motion.y == 0)
    }
}

@MainActor
private final class MockReflectionMotionSource: ReflectionMotionSource {
    var isAvailable = true
    var starts = 0
    var stops = 0
    var receive: (@Sendable (Double?, Double?) async -> Void)?
    func start(_ receive: @escaping @Sendable (Double?, Double?) async -> Void) {
        starts += 1
        self.receive = receive
    }
    func stop() { stops += 1 }
}

/// Intentional integration: real SwiftUI layout and production summary-card rendering.
@Suite("Summary cards — hosted layout integration")
@MainActor
struct SummaryCardLayoutTests {
    @Test("Unequal totals retain equal nonoverlapping cards", arguments: [
        (DynamicTypeSize.large, LayoutDirection.leftToRight),
        (.accessibility3, .leftToRight),
        (.large, .rightToLeft),
        (.accessibility3, .rightToLeft)
    ])
    func equalCards(_ textSize: DynamicTypeSize, _ direction: LayoutDirection) async throws {
        let capture = SummaryFrameCapture()
        let root = SummaryLayoutFixture(capture: capture)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.layoutDirection, direction)
            .frame(width: 361)
        let host = UIHostingController(rootView: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let testWindow = UIWindow(windowScene: scene)
        testWindow.frame = CGRect(x: 0, y: 0, width: 361, height: 1_200)
        testWindow.rootViewController = host
        defer {
            testWindow.isHidden = true
            testWindow.rootViewController = nil
        }
        // A visible, non-key window lets SwiftUI deliver layout preferences without
        // replacing or modifying the verification app's existing windows.
        try await capture.waitForFrames {
            testWindow.isHidden = false
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        let income = try #require(capture.frames["income"])
        let expense = try #require(capture.frames["expense"])
        #expect(income.width > 0 && income.height > 0)
        #expect(expense.width > 0 && expense.height > 0)
        #expect(abs(income.width - expense.width) < 0.5)
        #expect(abs(income.height - expense.height) < 0.5)
        #expect(!income.intersects(expense))
        #expect(income.minX >= -0.5 && expense.minX >= -0.5)
        #expect(income.maxX <= 361.5 && expense.maxX <= 361.5)
        if textSize.isAccessibilitySize {
            #expect(expense.minY - income.maxY >= 7.5)
        } else if direction == .rightToLeft {
            #expect(income.minX - expense.maxX >= 7.5)
        } else {
            #expect(expense.minX - income.maxX >= 7.5)
        }
    }
}

@MainActor
private final class SummaryFrameCapture {
    private(set) var frames: [String: CGRect] = [:]
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: DispatchWorkItem?

    func update(_ frames: [String: CGRect]) {
        self.frames = frames
        guard let income = frames["income"], let expense = frames["expense"],
              income.width > 0, income.height > 0, expense.width > 0, expense.height > 0 else { return }
        finish(.success(()))
    }

    func waitForFrames(activate: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(SummaryLayoutError.preferencesNotDelivered))
            }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            activate()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}

private enum SummaryLayoutError: Error {
    case preferencesNotDelivered
}

private struct SummaryFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private struct SummaryLayoutFixture: View {
    let capture: SummaryFrameCapture

    var body: some View {
        VStack(spacing: 0) {
            ExpenseSummaryPair {
                Button {} label: {
                    ExpenseSummaryCard(isIncome: true, amount: 0, currency: "RUB", compactAmounts: false)
                        .background { measurement("income") }
                }
                .buttonStyle(.plain)
                Button {} label: {
                    ExpenseSummaryCard(isIncome: false, amount: Decimal(string: "107745.90")!, currency: "RUB", compactAmounts: false)
                        .background { measurement("expense") }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .coordinateSpace(name: "summary-fixture")
        .onPreferenceChange(SummaryFramesKey.self) { capture.update($0) }
    }

    private func measurement(_ id: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SummaryFramesKey.self,
                value: [id: geometry.frame(in: .named("summary-fixture"))])
        }
    }
}
