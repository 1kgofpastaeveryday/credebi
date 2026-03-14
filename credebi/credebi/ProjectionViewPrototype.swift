import SwiftUI
import Charts

struct ProjectionViewPrototype: View {
  @State private var points: [ProjectionPoint] = SampleProjection.points
  @State private var selectedPointID: ProjectionPoint.ID?
  @State private var mode: BreakdownMode = .spend

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 14) {
          statusCard
          chartCard
          selectionCard
          detailsCard
        }
        .padding(16)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Projection")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear {
        if selectedPointID == nil {
          selectedPointID = firstRiskPoint?.id ?? points.first?.id
        }
      }
    }
  }

  private var statusCard: some View {
    SurfaceCard {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 6) {
          Text(isWarning ? "WARNING: MAY HIT ZERO" : "SAFE FOR NOW")
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(isWarning ? .red : .teal)

          if let risk = firstRiskPoint {
            Text("Likely turning point: \(risk.date, formatter: Formatters.shortDate)")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.secondary)
          } else {
            Text("No zero-cross in forecast range.")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }

        Spacer(minLength: 0)

        if let risk = firstRiskPoint {
          Button {
            selectedPointID = risk.id
            mode = .spend
          } label: {
            Label("Jump to risk", systemImage: "exclamationmark.triangle")
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
          .controlSize(.regular)
        }
      }
    }
  }

  private var chartCard: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Resource Trend")
          .font(.title3.weight(.bold))

        Text("Tap anywhere on the chart to inspect that day.")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)

        Chart {
          RuleMark(y: .value("Zero", 0))
            .foregroundStyle(.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

          ForEach(points) { point in
            LineMark(
              x: .value("Date", point.date),
              y: .value("Balance", point.endBalance)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(lineColor(for: point))
            .lineStyle(StrokeStyle(lineWidth: 3))
          }

          ForEach(points) { point in
            PointMark(
              x: .value("Date", point.date),
              y: .value("Balance", point.endBalance)
            )
            .symbolSize(point.id == selectedPoint.id ? 100 : 52)
            .foregroundStyle(point.belowZero ? .red : .blue)
          }

          if let risk = firstRiskPoint {
            PointMark(
              x: .value("Risk Date", risk.date),
              y: .value("Risk Balance", risk.endBalance)
            )
            .symbol(.diamond)
            .symbolSize(120)
            .foregroundStyle(.red)
            .annotation(position: .top, alignment: .leading) {
              Text("Risk")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.red.opacity(0.12), in: Capsule())
                .foregroundStyle(.red)
            }
          }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine().foregroundStyle(.clear)
            AxisTick()
            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
          }
        }
        .frame(height: 240)
        .chartOverlay { proxy in
          GeometryReader { geometry in
            Rectangle()
              .fill(.clear)
              .contentShape(Rectangle())
              .gesture(
                DragGesture(minimumDistance: 0)
                  .onEnded { value in
                    let plotOrigin = geometry[proxy.plotAreaFrame].origin
                    let xPosition = value.location.x - plotOrigin.x
                    guard xPosition >= 0, xPosition <= proxy.plotAreaSize.width else { return }
                    guard let date = proxy.value(atX: xPosition, as: Date.self) else { return }
                    if let nearest = nearestPoint(to: date) {
                      selectedPointID = nearest.id
                    }
                  }
              )
          }
        }

        HStack(spacing: 8) {
          Label("Trend: \(trendWord)", systemImage: "waveform.path.ecg")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1), in: Capsule())

          Label("Zero line shown", systemImage: "minus")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.14), in: Capsule())
        }
      }
    }
  }

  private var selectionCard: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("\(selectedPoint.date, formatter: Formatters.shortDate) • \(selectedPoint.belowZero ? "NOT SAFE" : "SAFE")")
          .font(.headline.weight(.bold))
          .foregroundStyle(selectedPoint.belowZero ? .red : .primary)

        HStack(spacing: 10) {
          metricButton(
            title: "Earned",
            value: money(sum(of: selectedPoint.incomeItems)),
            tint: .green,
            active: mode == .income
          ) {
            mode = .income
          }

          metricButton(
            title: "Spent",
            value: money(sum(of: selectedPoint.spendItems)),
            tint: .red,
            active: mode == .spend
          ) {
            mode = .spend
          }
        }
      }
    }
  }

  private var detailsCard: some View {
    SurfaceCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(mode == .income ? "Earned details" : "Spent details")
            .font(.headline.weight(.bold))
          Spacer()
          Text(selectedPoint.date, formatter: Formatters.shortDate)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }

        let items = mode == .income ? selectedPoint.incomeItems : selectedPoint.spendItems
        if items.isEmpty {
          Text("No \(mode.rawValue) items for this day.")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
        } else {
          ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(item.label)
                  .font(.subheadline.weight(.semibold))
                Spacer()
                Text((mode == .income ? "+" : "-") + money(item.amount))
                  .font(.subheadline.weight(.bold))
                  .foregroundStyle(mode == .income ? .green : .red)
              }
              if let note = item.note {
                Text(note)
                  .font(.caption.weight(.medium))
                  .foregroundStyle(.secondary)
              }
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
        }
      }
    }
  }

  private func metricButton(title: String, value: String, tint: Color, active: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.title3.weight(.bold))
          .foregroundStyle(tint)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(active ? tint.opacity(0.14) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(active ? tint.opacity(0.45) : Color(uiColor: .separator), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title) \(value)")
  }

  private var selectedPoint: ProjectionPoint {
    if let selectedPointID, let point = points.first(where: { $0.id == selectedPointID }) {
      return point
    }
    return points.first ?? ProjectionPoint.empty
  }

  private var firstRiskPoint: ProjectionPoint? {
    points.first(where: { $0.belowZero })
  }

  private var isWarning: Bool {
    firstRiskPoint != nil
  }

  private var trendWord: String {
    guard let first = points.first?.endBalance, let last = points.last?.endBalance else { return "FLAT" }
    let threshold = abs(first) / 20
    if last > first + threshold { return "UP" }
    if last < first - threshold { return "DOWN" }
    return "FLAT"
  }

  private func lineColor(for point: ProjectionPoint) -> Color {
    guard let firstRiskPoint else { return .blue }
    return point.date >= firstRiskPoint.date ? .red : .blue
  }

  private func nearestPoint(to date: Date) -> ProjectionPoint? {
    points.min { lhs, rhs in
      abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
    }
  }

  private func sum(of items: [CashflowItem]) -> Int {
    items.reduce(0) { $0 + $1.amount }
  }

  private func money(_ amount: Int) -> String {
    Formatters.yen.string(from: NSNumber(value: amount)) ?? "¥0"
  }
}

private struct SurfaceCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(14)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color(uiColor: .separator), lineWidth: 0.8)
      }
  }
}

private enum BreakdownMode: String {
  case spend
  case income
}

private struct CashflowItem: Identifiable {
  let id: String
  let label: String
  let amount: Int
  let note: String?
}

private struct ProjectionPoint: Identifiable {
  let id = UUID()
  let date: Date
  let endBalance: Int
  let belowZero: Bool
  let incomeItems: [CashflowItem]
  let spendItems: [CashflowItem]

  static let empty = ProjectionPoint(
    date: Date(),
    endBalance: 0,
    belowZero: false,
    incomeItems: [],
    spendItems: []
  )
}

private enum SampleProjection {
  static let points: [ProjectionPoint] = [
    point("2026-03-20", 38500, false, income: [item("inc-1", "Part-time shift pay", 4200, "Cafe shift")], spend: [item("sp-1", "Dinner", 1700, "Ramen near station")]),
    point("2026-03-21", 36000, false, spend: [item("sp-2", "Groceries", 2200, "Supermarket"), item("sp-3", "Train", 600, "IC card top-up")]),
    point("2026-03-22", 32500, false, spend: [item("sp-4", "Movie ticket", 1800, "Weekend")]),
    point("2026-03-23", 28000, false, income: [item("inc-2", "Used item sale", 3000, "Marketplace app")], spend: [item("sp-5", "Lunch", 900, "Campus cafeteria")]),
    point("2026-03-24", 10200, false, spend: [item("sp-6", "SMBC card payment", 17800, "Auto debit")]),
    point("2026-03-25", 210200, false, income: [item("inc-3", "Monthly salary", 200000, "Main income")]),
    point("2026-03-26", 5600, false, spend: [item("sp-7", "Rent", 65000, "Monthly fixed cost"), item("sp-8", "Phone bill", 4800, "Mobile plan"), item("sp-9", "Utilities", 2600, "Electricity")]),
    point("2026-03-27", -7200, true, spend: [item("sp-10", "Life card payment", 12800, "Auto debit"), item("sp-11", "Netflix fee", 1490, "Subscription")]),
    point("2026-03-28", -4200, true, income: [item("inc-4", "Friend repayment", 3000, "Transfer")]),
    point("2026-03-29", -11500, true, spend: [item("sp-12", "Food + transport", 7300, "Daily use")]),
    point("2026-03-30", 15000, false, income: [item("inc-5", "Temporary gig", 26500, "Event support")]),
    point("2026-03-31", 22000, false, income: [item("inc-6", "Refund", 9000, "Order cancellation")], spend: [item("sp-13", "Coffee", 600, "Cafe")])
  ]

  private static func point(
    _ isoDate: String,
    _ endBalance: Int,
    _ belowZero: Bool,
    income: [CashflowItem] = [],
    spend: [CashflowItem] = []
  ) -> ProjectionPoint {
    ProjectionPoint(
      date: Formatters.isoDate.date(from: isoDate) ?? Date(),
      endBalance: endBalance,
      belowZero: belowZero,
      incomeItems: income,
      spendItems: spend
    )
  }

  private static func item(_ id: String, _ label: String, _ amount: Int, _ note: String?) -> CashflowItem {
    CashflowItem(id: id, label: label, amount: amount, note: note)
  }
}

private enum Formatters {
  static let isoDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return formatter
  }()

  static let shortDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "M/d"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  static let yen: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "JPY"
    formatter.maximumFractionDigits = 0
    return formatter
  }()
}

#Preview {
  ProjectionViewPrototype()
}
