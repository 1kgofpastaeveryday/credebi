# Deep Dive 06: 収入予測エンジン (シフト → 給与見込み)

## 1. 概要

アルバイト/パートのシフト・勤怠データから次回給与の見込み額を算出し、
予測エンジン (`05-projection-engine`) の `projected_income` として投入する。

**現状の問題**: 予測モデルの `見込み収入` が手動入力 or メール検知 or パターン推定に
依存しており、シフト勤務者の収入はバイト月ごとに変動するため精度が低い。

**解決**: 勤怠プラットフォームから実データを取得し、
`(今月の累計勤務時間 + 残りシフトの予定時間) × 時給` で給与見込みを算出する。

## 2. データソース戦略

```
┌──────────────────────────────────────────────────────────┐
│                  Income Source Adapter                     │
│                                                           │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────────┐ │
│  │ freee HR    │  │ Playwright  │  │ Manual Input     │ │
│  │ (OAuth API) │  │ + LLM       │  │ (既存)           │ │
│  └──────┬──────┘  └──────┬──────┘  └────────┬─────────┘ │
│         │                │                   │            │
│         └────────────────┼───────────────────┘            │
│                          ▼                                │
│              shift_records テーブル                        │
│                          │                                │
│                          ▼                                │
│              給与見込み算出ロジック                          │
│                          │                                │
│                          ▼                                │
│              projected_incomes 更新                       │
│              (source = 'shift_calc')                      │
└──────────────────────────────────────────────────────────┘
```

### Adapter優先順位

| 優先度 | ソース | 精度 | コスト | 対象ユーザー |
|--------|--------|------|--------|-------------|
| 1 | freee HR API | 高 (実勤怠+基本給ルール) | $0 (API無料) | freee導入企業のバイト |
| 2 | Playwright + LLM | 中〜高 (画面スクレイプ) | ~$0.001/回 | ジョブカン, KING OF TIME, etc. |
| 3 | Manual + パターン推定 | 低〜中 | $0 | 全ユーザー (フォールバック) |

## 3. freee HR API 連携

### 3a. 認証フロー

```
iOS App → freee OAuth2 Authorization
    │
    ▼
freee login screen (WebView / ASWebAuthenticationSession)
    │
    ▼
Authorization Code → Credebi Edge Function
    │
    ▼
Edge Function → freee Token Exchange
    │  access_token + refresh_token
    ▼
Supabase Vault に暗号化保存
    │
    ▼
/users/me → company_id + employee_id 取得
    │
    ▼
income_connections レコード作成
```

```text
OAuth スコープ:
- hr:self_only (自分の勤怠・給与情報のみ)
- 管理者権限は不要。従業員本人のデータだけ取得する

freee OAuth アプリ登録:
- freee Developers Community でアプリ作成
- redirect_uri: credebi://oauth/freee/callback (iOS) + Edge Function用URL
- アプリ種別: "プライベートアプリ" でも可 (自分用なら)
```

### 3b. 使用エンドポイント

| エンドポイント | 用途 | 頻度 |
|--------------|------|------|
| `GET /users/me` | company_id, employee_id 取得 | 初回のみ |
| `GET /api/v1/employees/{id}/work_record_summaries/{year}/{month}` | 月次勤怠サマリー (累計勤務時間, 残業時間) | 日次 |
| `GET /api/v1/employees/{id}/work_records/{date}` | 日別勤怠 (シフト実績) | 日次 (当月分) |
| ~~`GET /api/v1/employees/{id}/basic_pay_rule`~~ | ~~基本給ルール (時給等)~~ | ~~初回 + 月次~~ |
| ~~`GET /api/v1/salaries/employee_payroll_statements/{id}`~~ | ~~給与明細 (確定後の実額)~~ | ~~給料日後~~ |

```text
⚠ 取り消し線のエンドポイントは self_only 権限ではアクセス不可 (2026-03-11 実機検証)
```

```text
basic_pay_rule の self_only 対応 (2026-03-11 実機検証済):
- 結果: self_only トークンではアクセス不可
  - レスポンス: {"message":"アクセスする権限がありません","code":"expired_access_token"}
  - 同一トークンで work_record_summaries は成功 → トークン失効ではなく権限不足と判断
  - ただし freee 側のエラーコードが不正確 (expired_access_token) なため、
    将来のスコープ変更で解放される可能性は排除しない
- 確定方針: ユーザーに時給を手入力してもらう
- 時給の自動取得は将来的に freee が self_only スコープを拡張した場合に再検討

employee_payroll_statements も同様に self_only ではアクセス不可:
- 給与確定値の自動突合は freee API 経由では実現不可
- 代替: 給与振込メールのパース (既存の email_detect フロー) でカバー
```

### 3c. 給与月パラメータの注意 (実機検証で判明)

```text
⚠ 重要: freee の work_record_summaries の {month} パラメータは「給与月」であり「勤怠月」ではない

実測結果:
  /2026/3 → {"year":2026,"month":2, "start_date":"2026-02-01", ...}  (2月の勤怠)
  /2026/2 → {"year":2026,"month":1, "start_date":"2026-01-01", ...}  (1月の勤怠)
  /2026/4 → {"year":2026,"month":3, "start_date":"2026-03-01", ...}  (3月の勤怠 = 今月)

つまり: 今月の勤怠を取るには {month} = 当月 + 1 を指定する
理由: 日本の給与体系では N月の勤怠 → N+1月の給与として扱うため
  (例: 3月勤怠 → 4月給与)

実装時の変換:
  attendanceMonth = 3 (欲しい勤怠月)
  apiMonth = attendanceMonth + 1  // = 4
  GET /work_record_summaries/2026/4

年跨ぎ (DT-038):
  12月勤怠 → apiMonth = 13 → year+1, month=1 に変換
  ⚠️ 変換なしで GET /work_record_summaries/2026/13 を送ると 404 → 収入¥0の致命バグ

  // DT-038: Canonical year-wrap conversion (must be used everywhere)
  function toFreeeApiParams(attendanceMonth: number, year: number) {
    const apiMonth = attendanceMonth + 1
    if (apiMonth > 12) {
      return { year: year + 1, month: apiMonth - 12 }
    }
    return { year, month: apiMonth }
  }
```

### 3d. 給与見込み算出ロジック

**E3検証結果 (2026-03-11)** により、以下が実データで確認済み:
- 勤務給 (勤怠時間 × 時給) の精度: gross誤差 ±0.01%
- 時給の期間管理が必須 (freee側も日次ベースで期間別レート適用)
- 交通費・控除は別レイヤーとして扱う

給与見込みは **3層構造** で算出する:

```
┌──────────────────────────────────────────┐
│ Layer 1: 勤務給 (高精度・検証済み)          │
│   日次レコード × 有効期間別時給              │
│   confidence: high                        │
├──────────────────────────────────────────┤
│ Layer 2: 手当 (中精度・条件依存)            │
│   交通費: 出勤日数 × 日額 (出社/リモート未区別)│
│   confidence: medium                      │
├──────────────────────────────────────────┤
│ Layer 3: 控除 (低精度・概算)               │
│   所得税, 雇用保険, 社保 (該当時)           │
│   confidence: low (DT-023 で精緻化)        │
└──────────────────────────────────────────┘
```

```typescript
// 時給期間履歴
interface HourlyRatePeriod {
  hourly_rate: number            // 時給 (円)
  overtime_multiplier: number    // 時間外割増率 (default 1.25)
  night_multiplier: number       // 深夜加算率 (default 0.25)
  holiday_multiplier: number     // 休日割増率 (default 1.35)
  effective_from: string         // 'YYYY-MM-DD'
  effective_to: string | null    // null = 現在有効
}

// DT-040: Result type for daily wage calculation (error accumulation, not throw)
type DailyWageResult = {
  wage: { base: number; overtime: number; night: number; holiday: number } | null
  error?: string  // e.g. "No rate period for 2026-03-15"
}

// 日次勤怠から日ごとの給与を算出
// DT-040: Returns result type instead of throwing on rate period gap.
// Missing rate periods are accumulated as errors in the caller, not fatal.
function calcDailyWage(
  record: DailyWorkRecord,
  ratePeriods: HourlyRatePeriod[]
): DailyWageResult {
  // 勤務日の有効レートを取得
  const rate = ratePeriods.find(r =>
    record.date >= r.effective_from &&
    (r.effective_to === null || record.date <= r.effective_to)
  )
  if (!rate) {
    return { wage: null, error: `No rate period for ${record.date}` }
  }

  const normalMins = record.total_work_mins - record.total_overtime_mins
  const base = Math.floor((normalMins / 60) * rate.hourly_rate)
  const overtime = Math.floor(
    (record.overtime_except_normal_mins / 60) * rate.hourly_rate * rate.overtime_multiplier
  )
  const night = Math.floor(
    (record.latenight_mins / 60) * rate.hourly_rate * rate.night_multiplier
  )
  const holiday = Math.floor(
    (record.holiday_work_mins / 60) * rate.hourly_rate * rate.holiday_multiplier
  )

  return { wage: { base, overtime, night, holiday } }
}

async function calculateShiftIncome(
  userId: string,
  yearMonth: string  // '2026-03'
): Promise<ProjectedIncome> {
  const conn = await getIncomeConnection(userId, 'freee')
  if (!conn) throw new Error('freee not connected')

  const ratePeriods = await getHourlyRatePeriods(conn.id)
  if (ratePeriods.length === 0) throw new Error('No rate periods configured')

  const [year, month] = yearMonth.split('-').map(Number)
  const today = new Date()

  // Layer 1: 勤務給 (日次レコードベース)
  const dailyRecords = await freeeApi.getDailyWorkRecords(
    conn.employee_id, conn.company_id, year, month
  )
  // clock_in_at が存在する日のみ = 実出勤日
  const workedRecords = dailyRecords.filter(r => r.clock_in_at !== null)

  // DT-040: Accumulate errors instead of aborting on first rate gap
  let wageTotal = 0
  const errors: string[] = []
  for (const record of workedRecords) {
    const result = calcDailyWage(record, ratePeriods)
    if (result.wage) {
      wageTotal += result.wage.base + result.wage.overtime
        + result.wage.night + result.wage.holiday
    } else {
      errors.push(result.error!)
    }
  }

  // Layer 2: 手当
  // 交通費は全出勤日 × 日額で概算 (出社/リモート区別はfreee APIから取得不可)
  const transportEstimate = workedRecords.length * (conn.transportation_per_day ?? 0)

  // 残りシフト推定 (月途中の場合)
  const remainingHours = estimateRemainingHours(workedRecords, today, year, month)
  const currentRate = ratePeriods.find(r =>
    r.effective_to === null || r.effective_to >= today.toISOString().slice(0, 10)
  )
  const remainingWage = Math.floor(
    remainingHours.regular * (currentRate?.hourly_rate ?? 0)
  )

  const grossPay = wageTotal + remainingWage + transportEstimate

  // Layer 3: 控除概算 (DT-023 で精緻化予定)
  const deductions = estimateDeductions(grossPay, conn)
  const netPay = grossPay - deductions

  return {
    user_id: userId,
    name: conn.employer_name ?? 'アルバイト給与',
    amount: netPay,
    gross_amount: grossPay,
    recurrence: 'monthly',
    day_of_month: conn.payday ?? 25,
    is_estimated: true,
    source: 'shift_calc',
    // DT-040: Confidence reduction when some days have no rate period
    confidence: (() => {
      const baseConfidence = calculateConfidence(workedRecords, remainingHours)
      const errorPenalty = errors.length > 0
        ? 0.5 * (1 - errors.length / workedRecords.length)
        : 1.0
      return baseConfidence * errorPenalty
    })(),
    breakdown: {
      wage_total: wageTotal,           // Layer 1 (検証済み高精度)
      remaining_wage: remainingWage,   // Layer 1 推定分
      transport_estimate: transportEstimate, // Layer 2 (条件依存)
      deductions,                      // Layer 3 (概算)
      gross_pay: grossPay,
      net_pay: netPay,
      worked_days: workedRecords.length,
      rate_periods_used: ratePeriods.length,
      // DT-040: Error accumulation for days with missing rate periods
      error_days: errors.length,
      skipped_dates: errors.map(e => e.match(/\d{4}-\d{2}-\d{2}/)?.[0]).filter(Boolean),
      // UI note: error_days > 0 の場合、「一部の勤務日の時給情報が見つかりません」を表示
    },
  }
}
```

#### freee API の実機検証で判明した注意点

```
1. normal_work_mins は所定労働時間 (全日480分 = 8h) であり、実勤務時間ではない
   → 実出勤の判定は clock_in_at の有無で行う
   → 非出勤日でも normal_work_mins = 480 が返る

2. company_id は全エンドポイントでクエリパラメータとして必須
   → /employees/me 系以外は省略すると 403

3. 給与明細の「時給単価」表示は代表値 (最新レート) だが、実計算は日次分割
   → 1月検証: 明細表記は ¥1,800 だが、1/1-19 は ¥1,600 で計算されていた

4. 交通費は出社タグ依存だが、freee日次レコードからタグ情報は取得不可
   → 全出勤日 × 日額で概算し、confidence を medium に設定
```

### 3d. 残りシフト時間の推定

```typescript
// DT-039/DT-111: Accept DailyWorkRecord[] instead of WorkRecordSummary.
// Aggregation is done internally so the caller doesn't need a separate summary type.
function estimateRemainingHours(
  records: DailyWorkRecord[],
  today: Date,
  year: number,
  month: number,
): { regular: number; overtime: number } {
  const daysInMonth = new Date(year, month, 0).getDate()
  const dayOfMonth = today.getDate()

  // Internal aggregation from daily records
  const workedDays = records.length
  const totalWorkHours = records.reduce(
    (sum, r) => sum + r.total_work_mins / 60, 0
  )
  const totalOvertimeHours = records.reduce(
    (sum, r) => sum + r.total_overtime_mins / 60, 0
  )

  if (workedDays === 0) {
    return { regular: 0, overtime: 0 }
  }

  // 平均日次勤務時間から残り日数分を推定
  const avgDailyHours = totalWorkHours / workedDays
  const avgDailyOvertime = totalOvertimeHours / workedDays

  // 残りの営業日数 (土日除外の簡易版。祝日は未考慮)
  const remainingWorkDays = countWorkDays(today, new Date(year, month, 0))

  // シフト勤務者は週の出勤日数にばらつきがあるため、
  // 直近の出勤頻度 (出勤日/経過日) で補正
  const attendanceRate = workedDays / dayOfMonth
  const estimatedRemainingDays = Math.round(
    (daysInMonth - dayOfMonth) * attendanceRate
  )

  return {
    regular: Math.round(estimatedRemainingDays * avgDailyHours * 10) / 10,
    overtime: Math.round(estimatedRemainingDays * avgDailyOvertime * 10) / 10,
  }
}
```

```text
精度の段階 (provenance label):

1. 勤務予定ベース見込み (confidence: 0.3-0.5)
   - 月初 (1-5日): 過去月の出勤パターンから推定
   - UIラベル: 「先月の勤務パターンから推定」
   - 根拠: 前月実績 × 当月カレンダー

2. 勤怠集計ベース見込み (confidence: 0.5-0.95)
   - 月中 (6-20日): 当月の実勤怠データ蓄積中 → confidence: 0.5-0.8
   - 月末 (21-末): ほぼ確定 → confidence: 0.8-0.95
   - UIラベル: 「今月の勤怠データから算出 (XX時間分確定)」
   - 根拠: freee work_record_summaries の累計 + 残日数推定

3. 給与確定 (confidence: 1.0)
   - 給与振込メール検知後: is_estimated: false
   - UIラベル: 「振込確認済み」
   - 根拠: 銀行振込通知メールのパース (email_detect フロー)
   - ※ freee payroll_statements は self_only で取得不可のため、
     メール検知 or ユーザー手動確認 で確定する

UI表示:
- 各段階でラベルを明示し、ユーザーが「どの程度信頼できる数字か」を常に判断できるようにする
- confidence < 0.5: グレー表示 + 「概算」バッジ
- confidence 0.5-0.8: 通常表示 + 「見込み」バッジ
- confidence > 0.8: 通常表示 + 「ほぼ確定」バッジ
- confidence = 1.0: 緑表示 + 「確定」バッジ
```

### 3e. 給与確定後の突合

```text
freee payroll_statements は self_only で取得不可のため、
給与確定は以下の代替手段で行う:

A. 給与振込メールの自動検知 (推奨)
   - 銀行からの振込通知メール or 給与明細通知メールをパース
   - 既存の email_detect フロー (01-email-parser) に乗せる
   - 振込額を確定値として projected_incomes を上書き

B. ユーザー手動確認
   - 給料日の翌日に Push通知: 「今月の給与は ¥XX,XXX の見込みでした。実際の振込額を確認しますか？」
   - ユーザーが実額を入力 → confidence: 1.0 に更新

C. 銀行口座残高の変動検知 (将来)
   - financial_accounts.current_balance の変動を監視
   - 給料日前後の入金を自動突合
```

```typescript
// 給与振込メール検知時 or ユーザー手動確認時に呼ばれる
async function reconcilePayroll(
  userId: string,
  yearMonth: string,
  confirmedNetPay: number,
  source: 'email_detect' | 'manual',
): Promise<void> {
  await supabase
    .from('projected_incomes')
    .update({
      amount: confirmedNetPay,
      is_estimated: false,
      source,
      confidence: 1.0,
      metadata: {
        reconciled_at: new Date().toISOString(),
      },
    })
    .eq('user_id', userId)
    .eq('source', 'shift_calc')
    .eq('target_month', yearMonth)

  // 予測再計算トリガー
  await triggerProjectionUpdate(userId)
}
```

## 4. Playwright + LLM 汎用アダプター

freee 以外の勤怠プラットフォーム向け。
ユーザーのブラウザセッションを Playwright で操作し、LLM で画面データを抽出する。

### 4a. 対応プラットフォーム (想定)

| プラットフォーム | シェア | 取得方法 |
|----------------|--------|---------|
| ジョブカン | 大 | Playwright (ログイン画面 → 勤怠一覧) |
| KING OF TIME | 大 | Playwright |
| マネーフォワード クラウド勤怠 | 中 | API (将来的に正式対応の可能性) |
| HRMOS | 中 | Playwright |
| シフトボード (リクルート) | バイト特化 | Playwright (シフト表画面) |
| LINEバイト シフト管理 | バイト特化 | Playwright |
| 紙/写真のシフト表 | - | カメラ → OCR + LLM |

### 4b. アーキテクチャ

```
iOS App
    │
    ├─ 初回: ユーザーがプラットフォームを選択
    │        → WebView でログイン (Playwright セッション確立)
    │        → Cookie/セッションを暗号化保存
    │
    └─ 定期: Edge Function (日次 pg_cron)
              │
              ▼
         Playwright (headless Chromium)
              │  Cookie復元 → ログイン維持
              │  勤怠ページにナビゲート
              │  ページ全体のスナップショット取得
              │
              ▼
         LLM (Gemini 2.5 Flash-Lite)
              │  プロンプト: "Extract shift/attendance data from this page"
              │  構造化出力: { worked_hours, shifts[], hourly_rate? }
              │
              ▼
         shift_records テーブルに保存
              │
              ▼
         給与見込み算出 (§3c と同じロジック)
```

### 4c. LLM抽出プロンプト

```typescript
const SHIFT_EXTRACTION_PROMPT = `
You are extracting shift/attendance data from a Japanese HR platform screenshot.

First, identify the page type. Then extract data if applicable.

Extract the following as JSON:
{
  "page_type": "attendance" | "login" | "captcha" | "error" | "unknown",
  // DT-118: If page_type is not "attendance", skip data extraction.
  // "login" = session expired, "captcha" = bot detection, "error" = server error.
  // Caller must treat non-"attendance" as a retriable failure, NOT as "0 shifts".
  "platform": "detected platform name",
  "year_month": "YYYY-MM",
  "records": [
    {
      "date": "YYYY-MM-DD",
      "clock_in": "HH:MM" | null,
      "clock_out": "HH:MM" | null,
      "break_minutes": number,
      "work_hours": number,
      "is_scheduled": boolean,  // true = future shift, false = worked
      "status": "worked" | "scheduled" | "absent" | "paid_leave"
    }
  ],
  "summary": {
    "total_work_hours": number | null,
    "total_overtime_hours": number | null,
    "total_work_days": number | null
  }
}

Rules:
- Japanese date formats: YYYY年MM月DD日, MM/DD, etc.
- Time formats: HH:MM, HH時MM分
- If hourly rate is visible on the page, include it as "hourly_rate"
- Distinguish between past (actual) and future (scheduled) shifts
- Return null for fields that cannot be determined
`
```

### 4d. セッション管理

```text
課題:
- Playwright セッションは長時間維持できない (Cookie失効, CAPTCHA, 2FA)
- ユーザーの資格情報を保存するのはセキュリティリスク

方針:
- Cookie/セッショントークンのみ Vault に保存 (パスワードは保存しない)
- セッション切れ検知 → Push通知でユーザーに再ログインを依頼
- 再ログインは iOS App 内 WebView で完結
- 頻度: 日次1回の取得で十分 (リアルタイム性は不要)

セッション有効期間の目安:
- ジョブカン: ~30日 (比較的長い)
- KING OF TIME: ~7日
- その他: プラットフォーム依存 → 初回取得時に学習
```

### 4d. Session Expiry Re-Authentication Flow

freee OAuth session が切れた場合の復帰フロー:

#### Push通知テンプレート
- title: "収入データの取得が停止しています"
- body: "{employer_name}への接続が切れました。タップして再ログイン"
- action: deep link → credebi://income_connections/{id}/reauth
- interruption-level: 'active' (通常通知、Focus時は配信待ち)

#### 再認証フロー
1. Push タップ → アプリ内 WebView で freee OAuth 再認可画面を表示
2. ユーザー認可 → 新 access_token + refresh_token 取得
3. 新 token → Vault 書き込み (compare-and-swap で race 防止)
4. session_status = 'active', session_expires_at = 新有効期限
5. 即座に sync-income-freee 実行 → confidence 復帰
6. UI: "接続が復旧しました" トースト表示

#### エスカレーション
- Push 1回目: session_status = 'expired' 検知時 (即時)
- Push 2回目: 24時間後にリマインダー
- Push 3回目: 72時間後に最終リマインダー
- 3回送信後も未復帰 → is_active = false, system_alert 作成
- projection: confidence を 0.3 に降格、stale_sources に追加

#### 通知制限
- notification_level = 'least' のユーザーには送信しない
- notification_level = 'less' 以上で配信

### 4e. Playwright 実行環境

```text
選択肢:
A) Supabase Edge Function + Browserless.io (推奨)
   - Edge Function から Browserless の Playwright API を呼ぶ
   - Chromium のホスティング不要
   - コスト: $0.01-0.05/セッション

B) 自前 Playwright サーバー (Fly.io / Railway)
   - Docker + Playwright
   - コスト: 月$5-10 (常時起動の場合)

C) ユーザーデバイス上で実行 (iOS WKWebView)
   - サーバーコスト $0
   - ただし iOS のバックグラウンド制約あり
   - MVP では非推奨

MVP推奨: A) Browserless.io
- 無料枠: 月1000セッション (1ユーザー日次取得なら余裕)
- Edge Function からの呼び出しが簡単
```

## 5. データモデル拡張

### 5a. 新規テーブル

```sql
-- ============================================================
-- 収入ソース連携 (freee, ジョブカン等)
-- ============================================================
CREATE TABLE income_connections (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID REFERENCES users(id) NOT NULL,
  provider          TEXT NOT NULL,        -- 'freee', 'jobcan', 'king_of_time', 'manual'
  -- freee 固有
  company_id        INT,                  -- freee company_id
  employee_id       INT,                  -- freee employee_id
  -- 共通
  employer_name     TEXT,                 -- 'ファミリーマート 新宿店'
  vault_secret_id   UUID,                 -- OAuth tokens or session cookies (Vault)
  -- ※ hourly_rate / overtime_multiplier は hourly_rate_periods テーブルで管理
  --    (正典: DESIGN.md の hourly_rate_periods テーブル)
  transportation_per_day INT DEFAULT 0,    -- 通勤手当 (日額, 出社日のみ支給)
  payday            INT DEFAULT 25,       -- 給料日
  pay_calc_method   TEXT DEFAULT 'hourly',-- 'hourly', 'monthly_fixed', 'daily'
  session_status    TEXT DEFAULT 'active',-- 'active', 'expired', 'error'
  session_expires_at TIMESTAMPTZ,
  last_synced_at    TIMESTAMPTZ,
  last_error        TEXT,
  is_active         BOOLEAN DEFAULT true,
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- シフト・勤怠レコード (全プラットフォーム共通)
-- ============================================================
CREATE TABLE shift_records (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID REFERENCES users(id) NOT NULL,
  connection_id     UUID REFERENCES income_connections(id) NOT NULL,
  date              DATE NOT NULL,
  clock_in          TIME,
  clock_out         TIME,
  break_minutes     INT DEFAULT 0,
  work_hours        REAL NOT NULL,        -- 実労働時間 (時間単位, 小数)
  overtime_hours    REAL DEFAULT 0,
  shift_type        TEXT NOT NULL,        -- 'actual', 'scheduled', 'absent', 'paid_leave'
  source            TEXT NOT NULL,        -- 'freee_api', 'playwright_scrape', 'manual'
  raw_data          JSONB DEFAULT '{}',   -- プラットフォーム固有の生データ
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, connection_id, date)
);

-- ============================================================
-- インデックス
-- ============================================================
CREATE INDEX idx_income_connections_user_active
  ON income_connections(user_id, is_active);
CREATE INDEX idx_shift_records_user_date
  ON shift_records(user_id, date DESC);
CREATE INDEX idx_shift_records_connection_month
  ON shift_records(connection_id, date);

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE income_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE shift_records ENABLE ROW LEVEL SECURITY;
```

### 5b. projected_incomes テーブル拡張

```sql
-- 既存テーブルにカラム追加
ALTER TABLE projected_incomes ADD COLUMN source TEXT DEFAULT 'manual';
  -- 'manual', 'email_detect', 'pattern_estimate', 'shift_calc', 'payroll_statement'
ALTER TABLE projected_incomes ADD COLUMN confidence REAL DEFAULT 0.5;
  -- 0.0-1.0 (shift_calc の場合は月内の経過日数で変動)
ALTER TABLE projected_incomes ADD COLUMN connection_id UUID REFERENCES income_connections(id);
ALTER TABLE projected_incomes ADD COLUMN target_month TEXT;
  -- '2026-03' (shift_calc は月ごとに別レコード)
ALTER TABLE projected_incomes ADD COLUMN gross_amount BIGINT;
ALTER TABLE projected_incomes ADD COLUMN breakdown JSONB DEFAULT '{}';
  -- { worked_hours, remaining_hours, overtime_hours, hourly_rate, deductions, ... }
ALTER TABLE projected_incomes ADD COLUMN metadata JSONB DEFAULT '{}';
```

## 6. Edge Functions

### 6a. sync-income-freee

```text
トリガー: pg_cron (日次) + income_connections INSERT/UPDATE
機能:
  1. freee API で当月の work_record_summaries を取得
  2. 日別 work_records で shift_records を更新
  3. 給与見込みを算出 → projected_incomes を更新
  4. 給料日翌日なら payroll_statements で確定値を取得 → 突合

DT-037: トークン失効時のエラーハンドリング:
  catch内で以下を実行:
  - income_connections.session_status = 'error'
  - income_connections.last_error = error.message
  - projected_incomes.confidence を 0.3 に降格 (staleデータで正常面させない)
  - 401/403エラー (token revoked) の場合:
    → income_connections.is_active = false
    → Push通知「freee連携が切れました。再設定してください」
  - その他エラー (500等):
    → リトライ対象 (次回pg_cronで再試行)
    → 3回連続失敗で system_alerts に記録
```

### 6b. sync-income-playwright

```text
トリガー: pg_cron (日次)
機能:
  1. income_connections (provider != 'freee') を取得
  2. Vault から session cookie 復元
  3. Browserless.io で対象プラットフォームにアクセス
  4. ページスナップショット → LLM で勤怠データ抽出
  5. shift_records 更新 → 給与見込み算出
  6. セッション切れ検知 → Push通知
```

### 6c. Edge Functions 一覧 (追加分)

| Function | トリガー | 機能 |
|----------|---------|------|
| `sync-income-freee` | pg_cron (日次) | freee API → shift_records → projected_incomes |
| `sync-income-playwright` | pg_cron (日次) | Playwright scrape → shift_records → projected_incomes |
| `oauth-freee-callback` | HTTP (OAuth redirect) | freee OAuth code → token exchange → Vault保存 |

## 7. 予測エンジンとの統合

### 既存の calculateProjection への変更

```typescript
// 05-projection-engine.md §4 の getProjectedIncome を拡張

async function getProjectedIncome(userId: string): Promise<IncomeItem[]> {
  const incomes = await supabase
    .from('projected_incomes')
    .select('*')
    .eq('user_id', userId)
    .eq('is_active', true)

  // shift_calc ソースの場合は confidence に基づいて金額に幅を持たせる
  return incomes.data?.map(inc => ({
    ...inc,
    // 予測モデルには confidence-weighted amount を渡す
    // confidence が低い場合は保守的に (安全側に振る)
    effective_amount: inc.source === 'shift_calc'
      ? Math.floor(inc.amount * Math.min(inc.confidence + 0.1, 1.0))
      : inc.amount,
  })) ?? []
}
```

```text
タイムラインイベントへの反映:
- shift_calc の収入は TimelineEvent.type = 'income' として既存フローに乗る
- description に内訳サマリーを含める
  例: "アルバイト給与 (見込み: 82h × ¥1,200)"
- confidence < 0.5 の場合は UI でグレー表示 + 「概算」ラベル
```

### 更新トリガー追加 (§8 への追記)

```text
6. シフトデータ更新時
   → shift_records INSERT/UPDATE → 給与見込み再算出
   → projected_incomes UPDATE → 予測再計算

7. 収入ソース変更時
   → income_connections INSERT/UPDATE/DELETE
   → 対応する projected_incomes を再算出
```

## 8. セキュリティ考慮

```text
freee OAuth トークン:
- access_token / refresh_token は Supabase Vault に暗号化保存
- email_connections と同じ vault_secret_id パターンを踏襲
- refresh_token の自動更新は sync-income-freee 内で実施

Playwright セッション:
- パスワードは一切保存しない (Cookie/セッショントークンのみ)
- Cookie は Vault に暗号化保存
- セッション有効期限を追跡し、切れたら速やかに削除
- LLM に送信するページデータからは個人情報をマスク
  (氏名、住所等は redactPII を適用)

RLS:
- income_connections, shift_records は user_id = auth.uid() で保護
- service_role 経由の Edge Function のみ他ユーザーデータにアクセス可能
```

## 9. Tier別対応

| 機能 | Free | Standard | Pro | Owner |
|------|------|----------|-----|-------|
| 手動収入入力 | ○ | ○ | ○ | ○ |
| freee HR 連携 | - | ○ | ○ | ○ |
| Playwright 汎用スクレイプ | - | - | ○ | ○ |
| 給与明細突合 (自動) | - | - | ○ | ○ |
| 複数バイト先対応 | - | 1件 | 3件 | 無制限 |

## 10. 開発フェーズ

```text
Phase 2.5 (Email Detection と並行):
- [ ] income_connections + shift_records テーブル作成
- [ ] projected_incomes カラム追加
- [ ] freee OAuth フロー実装
- [ ] sync-income-freee Edge Function
- [ ] basic_pay_rule の self_only 権限検証
- [ ] 給与見込み算出ロジック
- [ ] iOS: 収入ソース設定画面

Phase 4 (Projections と同時):
- [ ] Playwright + LLM アダプター基盤
- [ ] ジョブカン対応 (最初の Playwright ターゲット)
- [ ] 給与明細突合ロジック
- [ ] iOS: 収入内訳表示 (予測ビュー内)

Phase 5+:
- [ ] KING OF TIME, HRMOS 等の追加プラットフォーム
- [ ] カメラ OCR によるシフト表取り込み
- [ ] 複数バイト先の収入合算
```

## 11. 残設計タスク

| ID | Pri | 残タスク |
|---|---|---|
| DT-022 | P0 | freee basic_pay_rule の self_only 権限でのアクセス可否を実機検証 |
| DT-023 | P0 | 給与控除の概算ロジック確定 (源泉徴収率テーブル, 社保の閾値) |
| DT-024 | P1 | Playwright 実行環境の最終選定 (Browserless vs 自前 vs デバイス) |
| DT-025 | P1 | セッション切れ検知 → 再ログインフローの UX 設計 |
| DT-026 | P1 | confidence スコアの算出ルール詳細化 (月初/月中/月末の閾値) |
| DT-027 | P2 | カメラ OCR シフト表取り込みの精度検証 |
