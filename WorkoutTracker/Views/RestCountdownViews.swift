//
//  RestCountdownViews.swift
//  WorkoutTracker
//
//  Shared rest-countdown visuals: a faint container with a solid olive (#6E7A3F)
//  fill revealed left→right over the remaining time. The reveal is a single
//  Core Animation, committed once from the timer's absolute `endDate`, so the
//  once-a-second title update never re-commits it (smooth, ~no CPU).
//
//  Used by:
//   • RestTimerBar        — the between-exercises rest, on the in-progress screen.
//
//  The scrolling barber-pole stripes are preserved (`RestFill.useStripes`) so they
//  can be swapped back in later.
//

import SwiftUI

/// Static diagonal (45°) stripe band geometry — drawn once for its frame and
/// scrolled with an animated `.offset`. Kept for the barber-pole fill option.
private struct DiagonalStripes: Shape {
    var stripeWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = rect.height
        let period = stripeWidth * 2
        var x = -h
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x + stripeWidth, y: 0))
            p.addLine(to: CGPoint(x: x + stripeWidth + h, y: h))
            p.addLine(to: CGPoint(x: x + h, y: h))
            p.closeSubpath()
            x += period
        }
        return p
    }
}

/// Sets `fill` to the current elapsed fraction, then (while running) animates it
/// to 1 over the whole remaining time in a single linear Core Animation. When
/// finished → full; when paused/stopped → frozen at the current fraction.
func startRestReveal(fill: Binding<CGFloat>, endDate: Date?, totalSeconds: Int,
                     isRunning: Bool, isFinished: Bool) {
    if isFinished { fill.wrappedValue = 1; return }
    guard let endDate, totalSeconds > 0 else { return }
    let remaining = max(0, endDate.timeIntervalSinceNow)
    fill.wrappedValue = CGFloat(min(max(1 - remaining / Double(totalSeconds), 0), 1))
    guard isRunning, remaining > 0 else { return }   // paused/stopped → frozen
    DispatchQueue.main.async {
        withAnimation(.linear(duration: remaining)) { fill.wrappedValue = 1 }
    }
}

/// Faint container + solid olive fill revealed left→right. ISOLATED — its inputs
/// don't change per second, so a parent's once-a-second title update never
/// rebuilds it and its reveal animation never restarts.
struct RestFill: View {
    let endDate: Date?
    let totalSeconds: Int
    let isRunning: Bool
    var isFinished: Bool = false

    /// `false` = solid olive fill. `true` = scrolling barber-pole stripes.
    private let useStripes = false
    private let stripeW: CGFloat = 14

    @State private var fill: CGFloat = 0
    @State private var scroll = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Theme.timerContainer
                revealedFill(geo: geo)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    .clipped()
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * fill) }
            }
            .onAppear { scroll = true; restart() }
            .onChange(of: endDate) { _, _ in restart() }
            .onChange(of: isRunning) { _, _ in restart() }
            .onChange(of: isFinished) { _, _ in restart() }
        }
    }

    private func restart() {
        startRestReveal(fill: $fill, endDate: endDate, totalSeconds: totalSeconds,
                        isRunning: isRunning, isFinished: isFinished)
    }

    @ViewBuilder
    private func revealedFill(geo: GeometryProxy) -> some View {
        if useStripes { barberStripes(geo: geo) } else { Theme.stripeA }   // solid olive #6E7A3F
    }

    /// Barber-pole stripes — pale base with scrolling olive bands. Kept available
    /// to swap back in via `useStripes`.
    private func barberStripes(geo: GeometryProxy) -> some View {
        let period = stripeW * 2
        return ZStack(alignment: .leading) {
            Theme.stripeB
            DiagonalStripes(stripeWidth: stripeW)
                .fill(Theme.stripeA)
                .frame(width: geo.size.width + period * 2, height: geo.size.height, alignment: .leading)
                .offset(x: scroll ? -period : 0)
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: scroll)
        }
    }
}

/// A leading rectangle that grows 0→full over the remaining time, in lock-step
/// with `RestFill`. Used to reveal white type wherever the fill has passed.
struct RevealMask: View {
    let endDate: Date?
    let totalSeconds: Int
    let isRunning: Bool
    var isFinished: Bool = false
    @State private var fill: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .frame(width: geo.size.width * fill, height: geo.size.height, alignment: .leading)
                .onAppear { restart() }
                .onChange(of: endDate) { _, _ in restart() }
                .onChange(of: isRunning) { _, _ in restart() }
                .onChange(of: isFinished) { _, _ in restart() }
        }
    }

    private func restart() {
        startRestReveal(fill: $fill, endDate: endDate, totalSeconds: totalSeconds,
                        isRunning: isRunning, isFinished: isFinished)
    }
}
