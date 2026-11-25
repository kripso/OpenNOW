#if os(iOS)
import SwiftUI

/// Draws the radial and touch menus a layout opens on a stick or trackpad, over the game. The
/// menus for the left side of the pad sit at the lower left of the screen and the right side's at
/// the lower right, so each is under the thumb that drives it.
struct SteamControllerMenuOverlay: View {
    let menus: [SteamInputEngine.Menu]
    /// The action set just switched to, shown for a moment at the top.
    var actionSet: String?

    var body: some View {
        ZStack(alignment: .top) {
            HStack(alignment: .bottom) {
                column(for: [.joystick, .leftTrackpad])
                Spacer(minLength: 0)
                column(for: [.rightJoystick, .rightTrackpad])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            if let actionSet {
                Text(actionSet)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(24)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: menus)
        .animation(.easeOut(duration: 0.2), value: actionSet)
    }

    private func column(for sources: [SteamInputConfig.Source]) -> some View {
        VStack(spacing: 12) {
            ForEach(menus.filter { sources.contains($0.source) }) { menu in
                VStack(spacing: 8) {
                    if !menu.title.isEmpty {
                        Text(menu.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if menu.radial { radial(menu) } else { grid(menu) }
                }
                .padding(12)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    private func label(_ menu: SteamInputEngine.Menu, _ index: Int) -> some View {
        let selected = menu.selected == index
        let text = menu.items[index].isEmpty ? "\(index + 1)" : menu.items[index]
        return Text(text)
            .font(.caption2.weight(selected ? .bold : .regular))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 6)
            .frame(width: 68, height: 34)
            .background(selected ? Color.white : Color.white.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Items around a circle, the first at the top and the rest clockwise, as the engine picks them.
    private func radial(_ menu: SteamInputEngine.Menu) -> some View {
        let radius: CGFloat = menu.items.count > 8 ? 112 : 88
        return ZStack {
            ForEach(menu.items.indices, id: \.self) { index in
                let angle = 2 * Double.pi * Double(index) / Double(max(menu.items.count, 1))
                label(menu, index)
                    .offset(x: radius * CGFloat(sin(angle)), y: -radius * CGFloat(cos(angle)))
            }
        }
        .frame(width: radius * 2 + 76, height: radius * 2 + 42)
    }

    /// Items in rows from the top left, matching where a thumb on the trackpad selects.
    private func grid(_ menu: SteamInputEngine.Menu) -> some View {
        let columns = SteamInputEngine.gridColumns(count: menu.items.count)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 6), count: columns), spacing: 6) {
            ForEach(menu.items.indices, id: \.self) { index in label(menu, index) }
        }
        .frame(width: CGFloat(columns) * 74)
    }
}
#endif
