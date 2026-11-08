import SwiftUI

/// Rueda de color (lift/gamma/gain) con brillo.
struct ColorWheelControl: View {
    let title: String
    let subtitle: String
    @Binding var value: WheelValue

    // Sentido horario en pantalla desde la derecha = sentido antihorario matemático invertido.
    private static let hues: [Color] = [.red, Color(red: 1, green: 0, blue: 1), .blue, .cyan, .green, .yellow, .red]

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.callout.bold())
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let r = d / 2
                ZStack {
                    Circle().fill(AngularGradient(colors: Self.hues, center: .center))
                    Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5, opacity: 0)],
                                                 center: .center, startRadius: 0, endRadius: r))
                    Circle().stroke(Color.black.opacity(0.4), lineWidth: 1)
                    Path { p in
                        p.move(to: CGPoint(x: r, y: r - 4)); p.addLine(to: CGPoint(x: r, y: r + 4))
                        p.move(to: CGPoint(x: r - 4, y: r)); p.addLine(to: CGPoint(x: r + 4, y: r))
                    }.stroke(Color.black.opacity(0.5), lineWidth: 1)
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .position(x: r + value.x * r, y: r - value.y * r)
                }
                .frame(width: d, height: d)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    var x = (g.location.x - r) / r, y = -(g.location.y - r) / r
                    let len = (x * x + y * y).squareRoot()
                    if len > 1 { x /= len; y /= len }
                    // Zona muerta pequeña en el centro.
                    if len < 0.04 { x = 0; y = 0 }
                    value.x = Double(x); value.y = Double(y)
                })
                .onTapGesture(count: 2) { value.x = 0; value.y = 0 }
            }
            .aspectRatio(1, contentMode: .fit)
            Slider(value: $value.luma, in: -1...1).controlSize(.mini)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .onTapGesture(count: 2) { value = WheelValue() }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Editor de curva (dominio 0…1 = negro…blanco de referencia).
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    let color: Color
    @State private var dragIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
                Path { p in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        p.move(to: CGPoint(x: f * size.width, y: 0)); p.addLine(to: CGPoint(x: f * size.width, y: size.height))
                        p.move(to: CGPoint(x: 0, y: f * size.height)); p.addLine(to: CGPoint(x: size.width, y: f * size.height))
                    }
                }.stroke(Color.white.opacity(0.12), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0))
                }.stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { p in
                    let spline = MonotoneSpline(points)
                    let steps = 120
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        let y = spline.eval(x)
                        let pt = CGPoint(x: x * size.width, y: (1 - min(1.05, max(-0.05, y))) * size.height)
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }.stroke(color, lineWidth: 2)
                ForEach(points.indices, id: \.self) { i in
                    Circle().fill(dragIndex == i ? color : Color.black)
                        .overlay(Circle().stroke(color, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .position(x: points[i].x * size.width, y: (1 - points[i].y) * size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in drag(g, size: size) }
                .onEnded { _ in dragIndex = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { e in removePoint(near: e.location, size: size) })
        }
    }

    private func nearest(_ loc: CGPoint, size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in points.enumerated() {
            let d = hypot(CGFloat(p.x) * size.width - loc.x, CGFloat(1 - p.y) * size.height - loc.y)
            if d < 12, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func drag(_ g: DragGesture.Value, size: CGSize) {
        let x = min(1, max(0, g.location.x / size.width))
        let y = min(1, max(0, 1 - g.location.y / size.height))
        if dragIndex == nil {
            if let i = nearest(g.startLocation, size: size) {
                dragIndex = i
            } else {
                let sx = min(1, max(0, g.startLocation.x / size.width))
                let sy = min(1, max(0, 1 - g.startLocation.y / size.height))
                points.append(CurvePoint(x: sx, y: sy))
                points.sort { $0.x < $1.x }
                dragIndex = points.firstIndex { $0.x == sx && $0.y == sy }
            }
        }
        guard let i = dragIndex, points.indices.contains(i) else { return }
        // Cada punto queda entre sus vecinos; los extremos solo se mueven en vertical.
        let isEnd = i == 0 || i == points.count - 1
        var nx = x
        if isEnd { nx = points[i].x } else {
            nx = min(points[i + 1].x - 0.01, max(points[i - 1].x + 0.01, x))
        }
        points[i] = CurvePoint(x: nx, y: y)
    }

    private func removePoint(near loc: CGPoint, size: CGSize) {
        guard let i = nearest(loc, size: size), i != 0, i != points.count - 1 else { return }
        points.remove(at: i)
    }
}
