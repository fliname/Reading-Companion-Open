import SwiftUI

/// Keeps the reader and sidebar hosts in fixed slots when sidebar content changes.
struct ReaderColumns<Left: View, Reader: View, Right: View>: View {
    var leftVisible: Bool
    var rightVisible: Bool
    var locked: Bool
    @ViewBuilder var left: () -> Left
    @ViewBuilder var reader: () -> Reader
    @ViewBuilder var right: () -> Right
    @State private var leftWidth: CGFloat = 330
    @State private var rightWidth: CGFloat = 430
    @State private var lockedWidth: CGFloat?
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = lockedWidth ?? geometry.size.width
            let available = max(0, width - 440 - (leftVisible ? 5 : 0) - (rightVisible ? 5 : 0))
            let requested = (leftVisible ? leftWidth : 0) + (rightVisible ? rightWidth : 0)
            let ratio = requested > 0 ? min(1, available / requested) : 1
            let leftSize = leftVisible ? leftWidth * ratio : 0
            let rightSize = rightVisible ? rightWidth * ratio : 0
            HStack(spacing: 0) {
                if leftVisible {
                    left().frame(width: leftSize).clipped()
                    divider(isLeft: true, size: leftSize, otherSize: rightSize, width: width)
                }
                reader()
                    .frame(width: max(0, width - leftSize - rightSize - (leftVisible ? 5 : 0) - (rightVisible ? 5 : 0)))
                    .clipped()
                if rightVisible {
                    divider(isLeft: false, size: rightSize, otherSize: leftSize, width: width)
                    right().frame(width: rightSize).clipped()
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            .onChange(of: locked) { _, value in
                lockedWidth = value ? geometry.size.width : nil
            }
            .onAppear { if locked { lockedWidth = geometry.size.width } }
        }
        .clipped()
    }

    private func divider(isLeft: Bool, size: CGFloat, otherSize: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.4))
            .frame(width: 5)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !locked else { return }
                if dragStart == nil { dragStart = size }
                let proposed = (dragStart ?? size) + value.translation.width * (isLeft ? 1 : -1)
                let limit = max(180, width - otherSize - 450)
                if isLeft { leftWidth = min(max(proposed, 180), limit) }
                else { rightWidth = min(max(proposed, 260), limit) }
            }.onEnded { _ in dragStart = nil })
            .help(locked ? "页面与左右栏宽度已锁定" : "拖动调整栏宽")
    }
}
