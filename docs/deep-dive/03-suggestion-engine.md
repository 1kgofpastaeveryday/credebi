# Deep Dive 03: サジェストエンジン

## 1. 目的

カード利用を検知した瞬間に「何の決済か」をサジェストし、
ユーザーがワンタップで分類を完了できるようにする。

```
目標: サジェストの1番目が正解である確率 > 70%
      上位3つに正解が含まれる確率 > 90%
```

## 2. シグナルの種類と重み

```
┌─────────────────────────────────────────────────┐
│              Suggestion Engine                    │
│                                                   │
│  Input Signals:                                   │
│                                                   │
│  [Weight: 0.40] 📍 GPS (現在地)                   │
│    - 決済時刻の位置情報                             │
│    - 近隣の店舗検索                                │
│                                                   │
│  [Weight: 0.30] 📊 履歴 (同一カード・同額の過去取引) │
│    - 同じ金額パターン                              │
│    - 同じ曜日・時間帯                              │
│                                                   │
│  [Weight: 0.15] 🕐 時間帯                         │
│    - 朝 (6-10): コンビニ、カフェ                    │
│    - 昼 (11-14): ランチ、飲食                      │
│    - 夜 (17-22): 夕食、居酒屋                      │
│    - 深夜 (22-6): コンビニ、オンライン              │
│                                                   │
│  [Weight: 0.10] 💴 金額レンジ                      │
│    - ~500円: コンビニ、カフェ                       │
│    - 500-2000円: ランチ、日用品                     │
│    - 2000-5000円: ディナー、衣類                    │
│    - 5000円~: 大型買い物、サブスク年額              │
│                                                   │
│  [Weight: 0.05] 📧 メール本文のヒント              │
│    - 店舗名が含まれている場合 → 直接利用            │
│                                                   │
│  Output:                                          │
│    Suggestion[] (スコア順、上位5件)                 │
└─────────────────────────────────────────────────┘
```

## 3. サジェストのデータ構造

```typescript
interface Suggestion {
  merchant_name: string    // "セブン-イレブン 新宿西口店"
  category_id: string      // UUID
  category_name: string    // "食費"
  category_icon: string    // SF Symbol: "fork.knife"
  score: number            // 0.0 - 1.0 (総合スコア)
  source: SuggestionSource // どのシグナルが主要因か
  metadata: {
    distance_m?: number    // GPS: 店舗までの距離
    past_count?: number    // 履歴: 過去の同パターン回数
  }
}

type SuggestionSource = 'gps' | 'history' | 'time' | 'amount' | 'email_hint'
```

## 4. 各シグナルの実装

### 4a. GPS シグナル

```text
DT-113: GPS タイミングの制約と対策

GPSは「通知タップ時」にiOS側で取得する。取引時刻とは乖離がある
(カード通知 → メール到着 → webhook → Push通知 → タップ = 数分〜数時間のラグ)。

これは構造的制約: Edge Function側にユーザーの位置情報はない。
iOS Push通知タップ時が唯一のGPS取得タイミング。

対策:
1. GPS signal の weight を下げる (max 0.3 → 他の signal がない場合のみ 0.5)
2. location_age = now() - transacted_at を計算し、30分以上は GPS weight を 0 に
3. 代わりに history signal (過去に同じ金額×時間帯で使った店) を優先
4. email_hint (メール本文の店舗名) があれば GPS より確実 → weight 上位
```

```typescript
// iOS側: CoreLocation で取得した位置情報をリクエストに含める

interface LocationContext {
  lat: number
  lng: number
  accuracy: number  // meters
  timestamp: string
}

// サーバー側: 逆ジオコーディング + 周辺店舗検索
async function getGPSSuggestions(
  location: LocationContext,
  amount: number
): Promise<Suggestion[]> {
  // Option A: Apple Maps のPOI検索 (iOS側で実行)
  // Option B: Google Places API (サーバー側)
  // Option C: Supabase に蓄積した過去の位置×店舗データ

  // まずは過去の位置データから検索 (コスト$0)
  const nearbyPastTransactions = await supabase
    .from('transactions')
    .select('merchant_name, category_id, location_lat, location_lng')
    .eq('user_id', userId)
    .eq('status', 'confirmed')
    .not('location_lat', 'is', null)
    // PostGIS的な距離計算 (簡易版: 緯度経度の差)
    .filter('location_lat', 'gte', location.lat - 0.005)  // ~500m
    .filter('location_lat', 'lte', location.lat + 0.005)
    .filter('location_lng', 'gte', location.lng - 0.005)
    .filter('location_lng', 'lte', location.lng + 0.005)
    .order('transacted_at', { ascending: false })
    .limit(20)

  // 距離でソートし、近い順にサジェスト
  return rankByDistance(nearbyPastTransactions.data, location)
}
```

**GPS取得のタイミング**:
```
カード利用メール検知
    │
    ▼
Push通知送信と同時に、iOS側でバックグラウンド位置取得
    │
    ▼
ユーザーが通知をタップした時点で位置情報をリクエストに含める
    │
    ▼
QuickCategorizeView がサジェスト表示
```

iOS 26+ では Background Location Access の許可が必要。
ただし「利用時のみ」でも、通知タップ後のフォアグラウンド復帰時に取得可能。

### 4b. 履歴シグナル

```typescript
async function getHistorySuggestions(
  userId: string,
  amount: number,
  cardLast4: string | null
): Promise<Suggestion[]> {
  // 同じカード × 同じ金額帯 (±10%) の過去取引を検索
  // transactions.amount は「支出=負値」なので検索レンジも負値で作る
  const expenseMin = -Math.ceil(amount * 1.1)   // 例: 1000円 -> -1100
  const expenseMax = -Math.floor(amount * 0.9)  // 例: 1000円 -> -900

  const pastTransactions = await supabase
    .from('transactions')
    .select('merchant_name, category_id, amount, transacted_at')
    .eq('user_id', userId)
    .eq('status', 'confirmed')
    .lt('amount', 0)
    .gte('amount', expenseMin)
    .lte('amount', expenseMax)
    .order('transacted_at', { ascending: false })
    .limit(50)

  // 出現頻度でランキング
  const merchantCounts = countBy(pastTransactions.data, 'merchant_name')

  return Object.entries(merchantCounts)
    .sort(([, a], [, b]) => b - a)
    .map(([merchant, count]) => ({
      merchant_name: merchant,
      score: Math.min(count / 10, 1.0),  // 10回以上で最高スコア
      source: 'history',
      metadata: { past_count: count }
    }))
}
```

### 4c. 時間帯シグナル

```typescript
// DT-055/DT-103: DESIGN.md seed の16カテゴリ名のみ使用
// マッピング: ランチ/ディナー→食費, 居酒屋/飲み会→食費, ショッピング→日用品,
//   エンタメ→娯楽, オンライン→その他, タクシー→交通費, ファストフード→食費,
//   ドラッグストア→日用品, 自販機→コンビニ, 大型買い物→その他, 家電→その他,
//   旅行→娯楽, 家具→その他, 書籍→教育, 衣類→衣服
const TIME_PROFILES: Record<string, { categories: string[], weight: number }[]> = {
  // 朝 (6:00-10:00)
  morning: [
    { categories: ['コンビニ', 'カフェ'], weight: 0.6 },
    { categories: ['交通費'], weight: 0.3 },
    { categories: ['食費'], weight: 0.1 },
  ],
  // 昼 (11:00-14:00)
  lunch: [
    { categories: ['食費'], weight: 0.7 },
    { categories: ['カフェ'], weight: 0.2 },
    { categories: ['日用品'], weight: 0.1 },
  ],
  // 午後 (14:00-17:00)
  afternoon: [
    { categories: ['カフェ'], weight: 0.3 },
    { categories: ['日用品'], weight: 0.3 },
    { categories: ['衣服'], weight: 0.2 },
    { categories: ['食費'], weight: 0.2 },
  ],
  // 夜 (17:00-22:00)
  evening: [
    { categories: ['食費'], weight: 0.5 },
    { categories: ['娯楽'], weight: 0.3 },
    { categories: ['日用品'], weight: 0.1 },
    { categories: ['美容'], weight: 0.1 },
  ],
  // 深夜 (22:00-6:00)
  night: [
    { categories: ['コンビニ'], weight: 0.4 },
    { categories: ['その他'], weight: 0.3 },
    { categories: ['交通費'], weight: 0.2 },
    { categories: ['食費'], weight: 0.1 },
  ],
}

function getTimePeriod(hour: number): string {
  if (hour >= 6 && hour < 10) return 'morning'
  if (hour >= 10 && hour < 14) return 'lunch'
  if (hour >= 14 && hour < 17) return 'afternoon'
  if (hour >= 17 && hour < 22) return 'evening'
  return 'night'
}
```

### 4d. 金額レンジシグナル

```typescript
// DT-129: Half-open intervals [min, max) to avoid boundary overlap
const AMOUNT_PROFILES = [
  { range: [1, 300],          categories: ['コンビニ'], weight: 0.8 },
  { range: [300, 800],        categories: ['コンビニ', 'カフェ', '食費'], weight: 0.7 },
  { range: [800, 1500],       categories: ['食費', 'カフェ'], weight: 0.6 },
  { range: [1500, 3000],      categories: ['食費', '日用品'], weight: 0.5 },
  { range: [3000, 5000],      categories: ['食費', '衣服', '教育'], weight: 0.4 },
  { range: [5000, 10000],     categories: ['食費', '日用品'], weight: 0.3 },
  { range: [10000, 50000],    categories: ['その他', '娯楽'], weight: 0.2 },
  { range: [50000, Infinity], categories: ['娯楽', 'その他'], weight: 0.1 },
]
```

## 5. スコア統合

```typescript
async function generateSuggestions(
  userId: string,
  parseResult: ParseResult,
  location: LocationContext | null
): Promise<Suggestion[]> {
  const amount = Math.abs(parseResult.amount)
  const hour = new Date(parseResult.transacted_at).getHours()

  // 各シグナルからサジェスト候補を取得 (並列実行)
  const [gps, history, timeBased, amountBased] = await Promise.all([
    location ? getGPSSuggestions(location, amount) : [],
    getHistorySuggestions(userId, amount, parseResult.card_last4),
    getTimeSuggestions(hour),
    getAmountSuggestions(amount),
  ])

  // メール本文に店舗名があればボーナス
  const emailHint = parseResult.merchant
    ? [{ merchant_name: parseResult.merchant, score: 1.0, source: 'email_hint' as const }]
    : []

  // 重み付きスコア統合
  const WEIGHTS = {
    email_hint: 0.50,  // メールに店舗名があれば最優先
    gps: 0.40,
    history: 0.30,
    time: 0.15,
    amount: 0.10,
  }

  // 全候補をマージ
  const allSuggestions = [
    ...emailHint.map(s => ({ ...s, weightedScore: s.score * WEIGHTS.email_hint })),
    ...gps.map(s => ({ ...s, weightedScore: s.score * WEIGHTS.gps })),
    ...history.map(s => ({ ...s, weightedScore: s.score * WEIGHTS.history })),
    ...timeBased.map(s => ({ ...s, weightedScore: s.score * WEIGHTS.time })),
    ...amountBased.map(s => ({ ...s, weightedScore: s.score * WEIGHTS.amount })),
  ]

  // 同じ merchant_name / category のスコアを合算
  const merged = mergeSuggestions(allSuggestions)

  // スコア降順で上位5件
  return merged
    .sort((a, b) => b.weightedScore - a.weightedScore)
    .slice(0, 5)
}
```

## 6. 学習メカニズム (ユーザーのフィードバックループ)

```
ユーザーがサジェストを選択 or 手入力するたびに:

1. 選択されたサジェストの source を記録
2. 各シグナルの的中率を個人ごとに追跡

user_suggestion_stats:
  user_id       UUID
  signal_type   TEXT  -- 'gps', 'history', 'time', 'amount'
  hit_count     INT   -- 的中回数
  miss_count    INT   -- 不的中回数
  accuracy      REAL  -- hit / (hit + miss)
  updated_at    TIMESTAMPTZ

→ 個人ごとにWEIGHTSを動的調整:
  - GPS的中率が高いユーザー → GPS weight を増加
  - 履歴的中率が高いユーザー → history weight を増加
  - 初期状態はデフォルトWEIGHTS
```

## 7. パーソナライゼーション (Phase 5+)

```
段階的に賢くなる:

Level 0 (初回利用):
  → 時間帯 + 金額のみ (GPS許可前 / 履歴なし)
  → サジェスト精度: ~30%

Level 1 (1週間後):
  → 履歴が蓄積開始
  → メール本文の店舗名で補完
  → サジェスト精度: ~50%

Level 2 (1ヶ月後):
  → GPS + 履歴 + 時間帯 + 金額が全て機能
  → 個人の行動パターンが形成
  → サジェスト精度: ~70%

Level 3 (3ヶ月後):
  → 重み自動調整済み
  → 曜日 × 時間帯 × 場所の3次元パターン
  → サジェスト精度: ~85%
```

## 8. iOS側の実装概要

```swift
// SuggestionEngine.swift

class SuggestionEngine {
    private let locationService: LocationService
    private let supabase: SupabaseClient

    func getSuggestions(
        for transaction: PendingTransaction
    ) async throws -> [Suggestion] {
        // 現在地を取得 (タイムアウト3秒)
        let location = try? await locationService
            .getCurrentLocation(timeout: 3.0)

        // Edge Function にリクエスト
        let response = try await supabase.functions.invoke(
            "get-suggestions",
            options: .init(body: SuggestionRequest(
                transaction_id: transaction.id,
                amount: transaction.amount,
                card_last4: transaction.cardLast4,
                transacted_at: transaction.transactedAt,
                lat: location?.coordinate.latitude,
                lng: location?.coordinate.longitude
            ))
        )

        return try response.decode(as: [Suggestion].self)
    }
}
```

## 9. QuickCategorizeView (SwiftUI)

```swift
struct QuickCategorizeView: View {
    let transaction: PendingTransaction
    @State private var suggestions: [Suggestion] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 20) {
            // 取引情報カード
            TransactionCard(transaction: transaction)

            if isLoading {
                ProgressView()
            } else {
                // サジェスト一覧
                LazyVGrid(columns: [.init(), .init()], spacing: 12) {
                    ForEach(suggestions) { suggestion in
                        SuggestionButton(suggestion: suggestion) {
                            confirmTransaction(with: suggestion)
                        }
                    }

                    // 手入力ボタン
                    ManualInputButton {
                        showManualInput = true
                    }

                    // スキップボタン
                    SkipButton {
                        skipTransaction()
                    }
                }
            }
        }
        .task { await loadSuggestions() }
    }
}
```
