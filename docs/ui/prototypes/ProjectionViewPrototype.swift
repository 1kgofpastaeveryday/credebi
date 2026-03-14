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
      .navigationTitle("見通し")
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
          Text(isWarning ? "要注意：残高が0円を下回る可能性" : "いまは安全")
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(isWarning ? .red : .teal)

          if let risk = firstRiskPoint {
            Text("想定危険日: \(risk.date, formatter: Formatters.shortDate)")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.secondary)
          } else {
            Text("予測期間内で0円割れはありません。")
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
            Label("危険日へ移動", systemImage: "exclamationmark.triangle")
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
        Text("資金推移")
          .font(.title3.weight(.bold))

        Text("グラフをタップすると、その日の内訳を表示します。")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)

        Chart {
          RuleMark(y: .value("0円", 0))
            .foregroundStyle(.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

          ForEach(points) { point in
            LineMark(
              x: .value("日付", point.date),
              y: .value("残高", point.endBalance)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(lineColor(for: point))
            .lineStyle(StrokeStyle(lineWidth: 3))
          }

          ForEach(points) { point in
            PointMark(
              x: .value("日付", point.date),
              y: .value("残高", point.endBalance)
            )
            .symbolSize(point.id == selectedPoint.id ? 100 : 52)
            .foregroundStyle(point.belowZero ? .red : .blue)
          }

          if let risk = firstRiskPoint {
            PointMark(
              x: .value("危険日", risk.date),
              y: .value("危険時残高", risk.endBalance)
            )
            .symbol(.diamond)
            .symbolSize(120)
            .foregroundStyle(.red)
            .annotation(position: .top, alignment: .leading) {
              Text("危険日")
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
          Label("トレンド: \(trendWord)", systemImage: "waveform.path.ecg")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1), in: Capsule())

          Label("0円ライン表示中", systemImage: "minus")
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
        Text("\(selectedPoint.date, formatter: Formatters.shortDate) • \(selectedPoint.belowZero ? "注意" : "安全")")
          .font(.headline.weight(.bold))
          .foregroundStyle(selectedPoint.belowZero ? .red : .primary)

        HStack(spacing: 10) {
          metricButton(
            title: "収入",
            value: money(sum(of: selectedPoint.incomeItems)),
            tint: .green,
            active: mode == .income
          ) {
            mode = .income
          }

          metricButton(
            title: "支出",
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
          Text(mode == .income ? "収入の内訳" : "支出の内訳")
            .font(.headline.weight(.bold))
          Spacer()
          Text(selectedPoint.date, formatter: Formatters.shortDate)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }

        let items = mode == .income ? selectedPoint.incomeItems : selectedPoint.spendItems
        if items.isEmpty {
          Text("この日の\(mode.label)項目はありません。")
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
    guard let first = points.first?.endBalance, let last = points.last?.endBalance else { return "横ばい" }
    let threshold = abs(first) / 20
    if last > first + threshold { return "上昇" }
    if last < first - threshold { return "下降" }
    return "横ばい"
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

  var label: String {
    switch self {
    case .income: return "収入"
    case .spend: return "支出"
    }
  }
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
    point("2026-03-20", 38500, false, income: [item("inc-1", "アルバイト代", 4200, "カフェ勤務")], spend: [item("sp-1", "夕食", 1700, "駅前ラーメン")]),
    point("2026-03-21", 36000, false, spend: [item("sp-2", "食料品", 2200, "スーパー"), item("sp-3", "電車", 600, "ICカードチャージ")]),
    point("2026-03-22", 32500, false, spend: [item("sp-4", "映画チケット", 1800, "週末レジャー")]),
    point("2026-03-23", 28000, false, income: [item("inc-2", "不用品販売", 3000, "フリマアプリ")], spend: [item("sp-5", "昼食", 900, "学食")]),
    point("2026-03-24", 10200, false, spend: [item("sp-6", "SMBCカード引落", 17800, "自動引き落とし")]),
    point("2026-03-25", 210200, false, income: [item("inc-3", "給与", 200000, "本業収入")]),
    point("2026-03-26", 5600, false, spend: [item("sp-7", "家賃", 65000, "固定費"), item("sp-8", "携帯代", 4800, "モバイルプラン"), item("sp-9", "光熱費", 2600, "電気代")]),
    point("2026-03-27", -7200, true, spend: [item("sp-10", "ライフカード引落", 12800, "自動引き落とし"), item("sp-11", "Netflix料金", 1490, "サブスク")]),
    point("2026-03-28", -4200, true, income: [item("inc-4", "立替返金", 3000, "友人から送金")]),
    point("2026-03-29", -11500, true, spend: [item("sp-12", "食費+交通費", 7300, "日常支出")]),
    point("2026-03-30", 15000, false, income: [item("inc-5", "単発バイト", 26500, "イベント補助")]),
    point("2026-03-31", 22000, false, income: [item("inc-6", "返金", 9000, "注文キャンセル")], spend: [item("sp-13", "コーヒー", 600, "カフェ")])
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
    formatter.locale = Locale(identifier: "ja_JP")
    return formatter
  }()

  static let yen: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "JPY"
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.maximumFractionDigits = 0
    return formatter
  }()
}

#Preview {
  ProjectionViewPrototype()
}
