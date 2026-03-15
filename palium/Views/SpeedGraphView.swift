import SwiftUI

struct SpeedGraphView: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxVal = samples.max() ?? 1
            let minVal: Double = 0
            let range = max(maxVal - minVal, 1)

            ZStack(alignment: .bottomLeading) {
                // Filled area
                Path { path in
                    let stepX = geo.size.width / CGFloat(max(samples.count - 1, 1))
                    path.move(to: CGPoint(x: 0, y: geo.size.height))

                    for (i, sample) in samples.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height * (1 - CGFloat((sample - minVal) / range))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }

                    path.addLine(to: CGPoint(x: CGFloat(samples.count - 1) * stepX, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Line on top
                Path { path in
                    let stepX = geo.size.width / CGFloat(max(samples.count - 1, 1))

                    for (i, sample) in samples.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height * (1 - CGFloat((sample - minVal) / range))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(.blue, lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.black.opacity(0.03))
        )
    }
}
