# Deep Dive 04: サブスクリプション自動検知

## 1. 概要

メールからサブスクリプション (定額課金) を自動検知し、
固定費として管理する。ユーザーの手入力を極力なくす。

## 2. 検知の3段階

```
┌──────────────────────────────────────────────────┐
│ Stage 1: メールキーワード検知 (即時)               │
│                                                    │
│ メール本文/件名に以下を含む:                        │
│   - 「月額」「年額」「自動更新」「定期購入」         │
│   - 「サブスクリプション」「subscription」           │
│   - 「更新のお知らせ」「自動引き落とし」             │
│   - 「次回請求日」「契約更新」                       │
│                                                    │
│ → 即座にサブスク候補としてフラグ                     │
└──────────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────┐
│ Stage 2: パターン検知 (蓄積後)                     │
│                                                    │
│ 過去の取引から定期パターンを検出:                    │
│   - 同一merchant + 同一金額 が 2回以上              │
│   - 間隔が 25-35日 (月次) or 355-375日 (年次)      │
│   - 同一カードからの引き落とし                      │
│                                                    │
│ → 2回目の検知時にサブスク候補として提案               │
└──────────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────┐
│ Stage 3: 既知サービスDB照合                        │
│                                                    │
│ よくあるサブスクのマスターデータ:                    │
│   Netflix, Spotify, Apple Music, YouTube Premium,  │
│   Amazon Prime, Disney+, iCloud+, Adobe CC,        │
│   Microsoft 365, ChatGPT Plus, etc.                │
│                                                    │
│ merchant_name と照合し、サービス名・カテゴリを特定   │
└──────────────────────────────────────────────────┘
```

## 3. 既知サブスクリプション マスターデータ

```typescript
// data/known-subscriptions.ts

interface KnownSubscription {
  patterns: string[]       // merchant_name のマッチパターン
  name: string             // 表示名
  icon: string             // SF Symbol or URL
  typical_amounts: number[] // よくある金額 (円)
  billing_cycle: 'monthly' | 'yearly'
  category: string         // デフォルトカテゴリ
}

const KNOWN_SUBSCRIPTIONS: KnownSubscription[] = [
  // 動画配信
  {
    patterns: ['NETFLIX', 'netflix.com'],
    name: 'Netflix',
    icon: 'play.tv',
    typical_amounts: [890, 1490, 1980],
    billing_cycle: 'monthly',
    category: '娯楽',  // XDOC-R3-005: synced with DESIGN.md seed ('娯楽' not 'エンタメ')
  },
  {
    patterns: ['SPOTIFY', 'spotify.com'],
    name: 'Spotify',
    icon: 'music.note',
    typical_amounts: [980, 480, 1580],
    billing_cycle: 'monthly',
    category: '娯楽',  // XDOC-R3-005: synced with DESIGN.md seed ('娯楽' not 'エンタメ')
  },
  {
    patterns: ['AMAZON PRIME', 'AMZN PRIME', 'amazon.co.jp.*prime'],
    name: 'Amazon Prime',
    icon: 'shippingbox',
    typical_amounts: [600, 5900],
    billing_cycle: 'monthly', // or yearly
    category: 'サブスク',
  },
  {
    patterns: ['APPLE.COM/BILL', 'APPLE COM BILL'],
    name: 'Apple (iCloud+ / Music / One)',
    icon: 'apple.logo',
    typical_amounts: [130, 400, 1200, 1600, 2100],
    billing_cycle: 'monthly',
    category: 'サブスク',
  },
  {
    patterns: ['YOUTUBE PREMIUM', 'GOOGLE\\*YouTubePremium'],
    name: 'YouTube Premium',
    icon: 'play.rectangle',
    typical_amounts: [1280, 2280],
    billing_cycle: 'monthly',
    category: '娯楽',  // XDOC-R3-005: synced with DESIGN.md seed ('娯楽' not 'エンタメ')
  },
  {
    patterns: ['CHATGPT', 'OPENAI'],
    name: 'ChatGPT Plus',
    icon: 'bubble.left.and.bubble.right',
    typical_amounts: [3000],
    billing_cycle: 'monthly',
    category: 'その他',  // XDOC-R3-005: no 'ツール' in DESIGN.md seed. Closest = 'その他'
  },
  {
    patterns: ['ADOBE', 'CREATIVE CLOUD'],
    name: 'Adobe Creative Cloud',
    icon: 'paintbrush',
    typical_amounts: [2728, 6480],
    billing_cycle: 'monthly',
    category: 'その他',  // XDOC-R3-005: no 'ツール' in DESIGN.md seed. Closest = 'その他'
  },
  {
    patterns: ['MICROSOFT\\*', 'MSFT\\*'],
    name: 'Microsoft 365',
    icon: 'doc.richtext',
    typical_amounts: [1490, 12984],
    billing_cycle: 'monthly',
    category: 'その他',  // XDOC-R3-005: no 'ツール' in DESIGN.md seed. Closest = 'その他'
  },
  {
    patterns: ['DISNEY PLUS', 'DISNEYPLUS'],
    name: 'Disney+',
    icon: 'play.tv',
    typical_amounts: [990, 1320],
    billing_cycle: 'monthly',
    category: '娯楽',  // XDOC-R3-005: synced with DESIGN.md seed ('娯楽' not 'エンタメ')
  },
  // ... 追加可能 (ユーザーが使い始めたら拡張)
]
```

## 3b. 自動検知サブスクの信頼方針 (DT-158)

```text
方針: 自動検知 = デフォルト信頼。即 projection に含める。

理由:
- UXの要は「ユーザーの手間を減らす」こと
- 検知されたサブスクは is_active = true で即座に固定費 projection に反映
- 誤検知 = 支出を多めに見積もる = 安全側の誤り (fail-safe)
- 検知漏れ = 本物のサブスクが予測から抜ける = 静かに穴が空く (Design Principle #1 違反)

ユーザー通知フロー:
1. 検知時: Push「Netflixのサブスク ¥1,490/月 を検知しました」
   → [OK] / [違います]
2. 放置 = OK とみなす (projection にそのまま残る)
3. [違います] → is_active = false
   → 同パターンの再検知を metadata.dismissed_pattern = true で抑制

誤検知の修正:
- サブスク一覧画面で [解除] / [金額変更] / [周期変更] が可能
- 誤検知を消しても、元の取引データには影響しない (サブスクと取引は独立)

新カラム不要: 既存の is_active + Push通知で成立。
```

## 4. パターン検知アルゴリズム

```typescript
// Edge Function: detect-subscription (transaction INSERT trigger)
//
// UX-R4-004: Bootstrap import suppression
// - source='bootstrap_import' → skip individual detection.
//   Bootstrap runs batch detection AFTER correlation/dedup completes.
// - is_primary=false → skip (already correlated as duplicate notification)

async function detectSubscriptionPattern(
  userId: string,
  newTransaction: Transaction
): Promise<void> {
  if (newTransaction.amount >= 0) return // 収入は無視
  if (newTransaction.source === 'bootstrap_import') return  // UX-R4-004: batch later
  if (newTransaction.is_primary === false) return  // correlated duplicate → skip

  const amount = Math.abs(newTransaction.amount)
  const merchant = newTransaction.merchant_name

  if (!merchant) return

  // Step 1: 既知サブスクDBと照合
  const knownMatch = matchKnownSubscription(merchant, amount)
  if (knownMatch) {
    await createOrUpdateSubscription(userId, {
      name: knownMatch.name,
      amount,
      billing_cycle: knownMatch.billing_cycle,
      account_id: newTransaction.account_id,
      detected_from: 'known_db',
    })
    return
  }

  // Step 2: 過去の取引からパターン検知
  const similarTransactions = await supabase
    .from('transactions')
    .select('*')
    .eq('user_id', userId)
    .eq('merchant_name', merchant)
    .gte('amount', -(amount * 1.05))  // ±5%の幅で検索
    .lte('amount', -(amount * 0.95))
    .order('transacted_at', { ascending: false })
    .limit(6)

  const transactions = similarTransactions.data ?? []

  if (transactions.length < 2) return // 2回未満はパターン不成立

  // 間隔を計算
  const intervals = calculateIntervals(transactions)
  const avgInterval = mean(intervals)

  // 月次判定 (25-35日間隔)
  if (avgInterval >= 25 && avgInterval <= 35) {
    const subscription = await createOrUpdateSubscription(userId, {
      name: merchant,
      amount,
      billing_cycle: 'monthly',
      account_id: newTransaction.account_id,
      detected_from: 'pattern',
    })
    // DT-110: サブスクと分割払いはユーザーに確認して判別する。
    // 自動判別のヒューリスティックは誤検知が多すぎるため、確認UIを出す。
    // subscription は subscription_type = 'recurring' (仮) で作成済み。
    // ユーザーの回答に応じて subscription_type を更新する。
    await sendPush(userId, {
      title: '定期的な支払いを検知',
      body: `${merchant} (¥${amount.toLocaleString()}/月) はどの種類ですか？`,
      // iOS側で3択ボタン表示:
      //   [サブスク] → subscription_type = 'recurring', そのまま
      //   [分割払い] → subscription_type = 'installment', 残り回数入力画面へ
      //   [無視]     → is_active = false
      deepLink: `credebi://subscriptions/${subscription.id}/classify`,
      actions: [
        { id: 'recurring', title: 'サブスク' },
        { id: 'installment', title: '分割払い' },
        { id: 'dismiss', title: '無視' },
      ],
    })
  }

  // 年次判定 (355-375日間隔)
  if (avgInterval >= 355 && avgInterval <= 375) {
    await createOrUpdateSubscription(userId, {
      name: merchant,
      amount,
      billing_cycle: 'yearly',
      account_id: newTransaction.account_id,
      detected_from: 'pattern',
    })
  }
}

// DT-121: createOrUpdateSubscription must match by (user_id, merchant_name),
// NOT by (user_id, merchant_name, amount).
// If the same merchant exists with a different amount, UPDATE the amount
// instead of creating a phantom duplicate (e.g., price increase from ¥980 → ¥1,280).
// On amount change: set previous_amount in metadata, send push notification
// "Netflix の月額が ¥980 → ¥1,280 に変更されました"
async function createOrUpdateSubscription(
  userId: string,
  data: {
    name: string, amount: number, billing_cycle: string,
    account_id: string, detected_from: string,
    parsed_email_id?: string  // SEC-R4-004: source traceability
  }
): Promise<Subscription> {
  const existing = await supabase
    .from('subscriptions')
    .select('*')
    .eq('user_id', userId)
    .eq('name', data.name)        // merchant name match
    .eq('is_active', true)
    .maybeSingle()

  if (existing.data) {
    // Update existing (price change, cycle change, etc.)
    if (existing.data.amount !== data.amount) {
      await sendPush(userId, {
        title: 'サブスク金額変更',
        body: `${data.name} の月額が ¥${existing.data.amount.toLocaleString()} → ¥${data.amount.toLocaleString()} に変更されました`,
      })
    }
    const { data: updated } = await supabase
      .from('subscriptions')
      .update({
        amount: data.amount,
        detected_from: data.detected_from,
        last_detected_email_id: data.parsed_email_id ?? null,  // SEC-R4-004
        metadata: { ...existing.data.metadata, previous_amount: existing.data.amount },
        updated_at: new Date().toISOString(),
      })
      .eq('id', existing.data.id)
      .select()
      .single()
    return updated
  }

  // Create new
  // XDOC-R4-013: Compute next_billing_at so the subscription is usable for projection.
  // Without this, next_billing_at is NULL → fixed cost filter can't de-duplicate
  // against card charges, risking double-counting.
  const nextBilling = computeNextBilling(data.billing_cycle)

  const { data: created } = await supabase
    .from('subscriptions')
    .insert({
      user_id: userId, ...data,
      next_billing_at: nextBilling,
      last_detected_email_id: data.parsed_email_id ?? null,  // SEC-R4-004
    })
    .select()
    .single()
  return created
}

// XDOC-R4-013: Compute the next billing date from the current date and billing cycle.
function computeNextBilling(billingCycle: string): string {
  const now = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Tokyo' }))
  const next = new Date(now)
  if (billingCycle === 'yearly') {
    next.setFullYear(next.getFullYear() + 1)
  } else {
    // monthly (default)
    next.setMonth(next.getMonth() + 1)
  }
  return next.toISOString().slice(0, 10)  // DATE format
}

function calculateIntervals(transactions: Transaction[]): number[] {
  const sorted = transactions
    .sort((a, b) => new Date(b.transacted_at).getTime() - new Date(a.transacted_at).getTime())

  const intervals: number[] = []
  for (let i = 0; i < sorted.length - 1; i++) {
    const diff = new Date(sorted[i].transacted_at).getTime()
      - new Date(sorted[i + 1].transacted_at).getTime()
    intervals.push(diff / (1000 * 60 * 60 * 24)) // 日数
  }
  return intervals
}
```

## 5. サブスク管理機能

```
サブスク一覧画面:

┌─────────────────────────────────────────┐
│ 月額固定費: ¥8,940                       │
│                                         │
│ ┌───────────────────────────────────┐   │
│ │ 🎬 Netflix          ¥1,490/月    │   │
│ │    次回: 3月15日 | 三井住友NL      │   │
│ └───────────────────────────────────┘   │
│ ┌───────────────────────────────────┐   │
│ │ 🎵 Spotify          ¥980/月      │   │
│ │    次回: 3月3日 | 三井住友NL       │   │
│ └───────────────────────────────────┘   │
│ ┌───────────────────────────────────┐   │
│ │ ☁️ iCloud+           ¥400/月     │   │
│ │    次回: 3月8日 | ライフカード     │   │
│ └───────────────────────────────────┘   │
│ ┌───────────────────────────────────┐   │
│ │ 🤖 ChatGPT Plus     ¥3,000/月    │   │
│ │    次回: 3月20日 | セゾンAMEX     │   │
│ └───────────────────────────────────┘   │
│ ...                                     │
│                                         │
│ [+ 手動で追加]                           │
└─────────────────────────────────────────┘
```

## 5b. Bootstrap 後の一括サブスク検知 (UX-R4-004)

```typescript
// Called once after bootstrap import completes (02-gmail-integration.md §2b step 9)
// 1. Correlation/dedup has already run on all imported transactions
// 2. This function scans is_primary=true transactions for subscription patterns
// 3. Results are sent as a SINGLE summary push, not individual notifications

async function detectSubscriptionsAfterBootstrap(userId: string): Promise<void> {
  // Get all bootstrap transactions (is_primary=true only — duplicates already excluded)
  const { data: transactions } = await supabase
    .from('transactions')
    .select('*')
    .eq('user_id', userId)
    .eq('source', 'bootstrap_import')
    .eq('is_primary', true)
    .lt('amount', 0)
    .order('transacted_at', { ascending: true })

  if (!transactions?.length) return

  // Group by merchant and run pattern detection
  const byMerchant = groupBy(transactions, t => t.merchant_name)
  const detected: string[] = []

  for (const [merchant, txs] of Object.entries(byMerchant)) {
    if (!merchant) continue

    // Known DB match
    const amount = Math.abs(txs[0].amount)
    const knownMatch = matchKnownSubscription(merchant, amount)
    if (knownMatch) {
      await createOrUpdateSubscription(userId, {
        name: knownMatch.name, amount, billing_cycle: knownMatch.billing_cycle,
        account_id: txs[0].account_id, detected_from: 'known_db',
      })
      detected.push(knownMatch.name)
      continue
    }

    // Pattern match (need 2+ transactions)
    if (txs.length < 2) continue
    const intervals = calculateIntervals(txs)
    const avgInterval = mean(intervals)
    if (avgInterval >= 25 && avgInterval <= 35) {
      await createOrUpdateSubscription(userId, {
        name: merchant, amount, billing_cycle: 'monthly',
        account_id: txs[0].account_id, detected_from: 'pattern',
      })
      detected.push(merchant)
    }
  }

  // Single summary push instead of N individual notifications
  if (detected.length > 0) {
    await sendPush(userId, {
      title: 'サブスクを検知しました',
      body: `${detected.slice(0, 3).join('、')}${detected.length > 3 ? ` 他${detected.length - 3}件` : ''}`,
      deepLink: 'credebi://subscriptions',
    })
  }
}
```

## 6. サブスク解約検知

```
以下の条件でサブスクが解約された可能性を検知:

前提: subscription_type = 'recurring' のみ対象。
       subscription_type = 'installment' は §6b で別処理。

1. next_billing_at を7日過ぎても新しい取引がない
2. 同一サービスから「解約」「キャンセル」メールを受信

検知時:
  → Push通知「Netflix の課金が確認されません。解約しましたか？」
  → ユーザーが確認 → is_active = false
```

### 6b. 分割払い終了処理 (DT-110)

```
subscription_type = 'installment' の場合:

1. next_billing_at > expected_end_at → 自動で is_active = false
   (Push通知なし — 予定通りの終了なので確認不要)

2. 毎月の課金検知時に remaining_count を -1 (デクリメント)
   remaining_count = 0 → is_active = false

3. 予測エンジンへの影響:
   - 'recurring' は horizon 全期間に繰り返し
   - 'installment' は remaining_count 回分のみ timeline に配置
   例: remaining_count=3, amount=¥10,000 → 3ヶ月分のみ固定費に含める
```
