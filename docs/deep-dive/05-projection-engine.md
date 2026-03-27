# Deep Dive 05: 引き落とし予測エンジン

## 1. 概要

「来月の引き落とし日に口座残高は足りるか？」をリアルタイムに予測。
クレジットカードの "見えない負債" を可視化し、デビットカード的な体験を実現する。

## 2. 予測モデル

### 2a. Truth Strength Precedence (データ信頼性の階層)

```text
予測は「銀行残高が引き落とし日に足りるか」を答える。
すべてのキャッシュフロー情報は、以下の信頼性順で優先される:

Layer 1 — Observed (最強)
  ├── bank_balance          手動入力 / OCRスクショ / API (truth anchor)
  ├── transactions          メールパース / 明細取得による実績取引
  └── issuer_statement      カード会社からの請求確定額 (billing notification)

Layer 2 — Committed (実績から推定される未来キャッシュイベント)
  └── committed_card_charge 締め日を過ぎた期間の transaction 集計
                            → 引き落とし日に銀行口座から出る確定額
                            ※ issuer_statement があればそちらが優先

Layer 3 — Forecast (仮定・予測)
  ├── projected_income      給料見込み (freee/Playwright/手動)
  ├── fixed_costs           サブスク・固定費 (将来期間のみ)
  ├── accumulating_charge   今期オープン中のカード利用 (まだ増える可能性あり)
  └── estimated_variable    過去3ヶ月平均の変動費

合成ルール (Composition Rule):
  Layer 3 の forecast は、同じキャッシュフローが Layer 1/2 で
  すでにカバーされている場合は timeline に含めない。

  具体例:
  - Netflix ¥1,490 が transactions に記録済み (Layer 1)
    → fixed_costs の Netflix は今期分を timeline から除外
  - 給料 ¥150,000 が balance_observed_at 以降に入金済み (Layer 1)
    → projected_income のその月分を除外
  - 三井住友カード ¥45,000 の issuer_statement あり (Layer 1)
    → committed_card_charge の transaction 集計値は表示用 breakdown に格下げ
```

### 2b. 予測式

```
予測残高 = 銀行残高 (Layer 1: truth anchor)
         + 未来の見込み収入 (Layer 3: balance_observed_at 以降のみ)
         - committed card charges (Layer 2: 引き落とし日が未来)
         - 未来の fixed_costs (Layer 3: 取引記録がまだない期間のみ)
         - accumulating card charges (Layer 3: 今期オープン分)
         - 見込み変動費 (Layer 3: 過去3ヶ月平均)
```

```text
可視化対象期間:
- 履歴: 過去30日 (実績, Layer 1 のみ)
- 予測: 今日から60日先 (Layer 2 + Layer 3)
- 粒度: 日次バー (1日1本)

UIでの信頼度表示:
- Layer 1/2 由来のバー: 実線 (高信頼)
- Layer 3 由来のバー: 点線 or 半透明 (予測)
```

## 3. 各カードの締め日・引き落とし日

```typescript
// 初期設定 (ユーザーのカード)
const CARD_SCHEDULES = {
  // 三井住友カード (NL / Olive 共通)
  smbc: {
    closing_day: 15,     // 毎月15日締め
    billing_day: 10,     // 翌月10日引き落とし
    // → 前月16日〜当月15日の利用分が翌月10日に引き落とし
  },
  // ライフカード
  lifecard: {
    closing_day: 5,      // デフォルト値。請求案内メール抽出 or ユーザー確認で補正
    billing_day: 27,     // デフォルト値。ユーザー設定を優先
  },
  // セゾンカード
  saison: {
    closing_day: 10,     // 毎月10日締め
    billing_day: 4,      // 翌月4日引き落とし
  },
  // JALカード (三井住友発行の場合)
  jal_smbc: {
    closing_day: 15,     // 毎月15日締め
    billing_day: 10,     // 翌月10日引き落とし
  },
}
```

```text
初期セットアップ方針:
- credit_card の closing_day / billing_day は自動取得を優先
- 優先順位: 請求案内メール抽出 > 発行会社デフォルト > 手入力
- 請求案内メールから抽出できた場合は UI確認なしで即反映
- 自動取得できない場合のみ手入力を促す
- 未設定のカードは予測計算から一時的に除外し、設定完了後に再計算
```

## 4. 予測計算ロジック

```typescript
// DT-159: Account-Scoped Cashflow Model
// Projection engine computes per-account timelines; aggregate view is derived.
// Truth: per-account solvency. Presentation: unified portfolio view.

interface Projection {
  // Aggregate (UX default view)
  aggregate_balance: number        // 全口座合計残高
  aggregate_timeline: TimelineEvent[]  // 全口座合算のイベント列
  aggregate_balance_bars: BalanceBar[] // 全口座合算の日次バー

  // Per-account (展開ビュー / 判定の実体)
  account_projections: AccountProjection[]

  // Derived from per-account analysis
  charge_coverages: CardChargeCoverage[] // 引き落とし時点の資金充足判定
  danger_zones: DangerZone[]     // 口座単位の残高マイナス区間

  // DT-107 + DT-109 + Design Principle #2: Freshness & status
  status: 'SETUP_REQUIRED' | 'SAFE' | 'WARNING' | 'CRITICAL'
  data_as_of: string             // ISO timestamp: 最も古い upstream source の更新時刻
  is_stale: boolean              // いずれかの source が stale なら true
  stale_sources: string[]        // e.g. ['bank_balance:楽天銀行', 'income_account_unknown']
}

// Per-account projection (the real truth unit)
interface AccountProjection {
  account_id: string
  account_name: string
  current_balance: number
  timeline: TimelineEvent[]
  balance_bars: BalanceBar[]
  danger_zones: DangerZone[]
  is_safe: boolean               // この口座単体で0割れなし
}

// Status semantics:
//   SETUP_REQUIRED — balance未入力 / card schedule未設定 / settlement_account未設定
//   SAFE           — 全口座で0割れなし
//   WARNING        — いずれかの口座で0割れだが、全口座合計では足りる (口座間移動で解決可能)
//   CRITICAL       — 全口座合計でも0割れ (資金移動では解決不可)

// DT-107 + DT-159: Bank balance is the projection's truth anchor (per-account).
// Staleness sources (each independently contributes to is_stale):
//   'bank_balance:{name}'        — per-account: balance_observed_at > 30d
//   'email_connection'           — last_synced_at > 48h
//   'income_connection'          — data_as_of on projected_incomes > 7d
//   'income_account_unknown'     — projected_income with bank_account_id = NULL
//   'settlement_account_missing:{card}' — credit card with settlement_account_id = NULL
//   'card_schedule_missing:{card}'      — credit card with closing_day/billing_day = NULL
//
// status = 'SETUP_REQUIRED' when ANY of:
//   - No bank account has balance_updated_at set (balance never entered)
//   - email_connections required AND not bootstrapped (has credit cards but no email)
//   - Any credit card has closing_day/billing_day = NULL (card schedule missing)
//   - Any credit card has settlement_account_id = NULL (settlement account missing)
//
// Phase 1 (MVP): Manual balance input + payday Push nudge
// Phase 2: Moneytree LINK API for auto balance refresh
// Phase 3: 電子決済等代行業登録 → direct bank API

interface TimelineEvent {
  id: string
  date: string              // ISO date
  type: 'income' | 'card_charge' | 'fixed_cost' | 'variable_cost'
  account_id?: string       // card_charge: the credit card id
  bank_account_id: string   // DT-159: which bank account is affected
                            //   income → projected_incomes.bank_account_id
                            //   card_charge → card.settlement_account_id
                            //   fixed_cost (direct debit) → subscription.account_id (if bank)
                            //   fixed_cost (card-paid) → card.settlement_account_id
                            //   variable_cost → spending share で按分した bank account
  description: string
  amount: number            // 正:入金, 負:出金
  running_balance: number   // per-account running balance at this point
}

interface DangerZone {
  date: string
  shortfall: number         // 不足額
  cause: string             // どの引き落としが原因か
  suggestion: string        // 対処法の提案
}

interface BalanceBar {
  date: string
  phase: 'actual' | 'forecast'
  start_balance: number
  end_balance: number
  inflow: number
  outflow: number
  below_zero: boolean
  trigger_event_ids: string[]  // 0円割れを発生させたイベント
}

interface CardChargeCoverage {
  card_id: string
  card_name: string
  billing_date: string
  charge_amount: number        // PROJ-R4-005: always positive absolute value (e.g. 50000, not -50000)
  balance_before: number       // bank balance just before this charge settles
  balance_after: number        // bank balance just after (negative = shortfall)
  shortfall: number         // max(0, -balance_after)
  is_funded: boolean
  utilization: number | null  // XDOC-R4-001: % of credit limit used (null if limit unknown)
}

// API contract source of truth:
// docs/contracts/projection-response.schema.json
// First-screen UI should consume status: 'SETUP_REQUIRED' | 'SAFE' | 'WARNING' | 'CRITICAL'
// SETUP_REQUIRED: suppress graph, show setup wizard
// SAFE:           green indicator
// WARNING:        yellow — per-account deficit, aggregate solvent (move funds between accounts)
// CRITICAL:       red — aggregate deficit, no fix without external funds

async function calculateProjection(userId: string): Promise<Projection> {
  const now = new Date()
  const jstNow = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Tokyo' }))
  const todayStr = jstNow.toISOString().slice(0, 10)

  // ── 1. Fetch all accounts ──
  const bankAccounts = await supabase
    .from('financial_accounts')
    .select('*')
    .eq('user_id', userId)
    .eq('type', 'bank')

  const cardAccounts = await supabase
    .from('financial_accounts')
    .select('*')
    .eq('user_id', userId)
    .eq('type', 'credit_card')

  // ── 2. Card charges (unchanged logic, but now carries settlement routing) ──
  const cardCharges: CardCharge[] = []
  for (const card of cardAccounts.data ?? []) {
    const charges = await calculateCardCharges(userId, card)
    cardCharges.push(...charges)
  }

  // ── 3. Income — per-account exclusion (DT-159 + DT-157) ──
  //
  // 2-layer rule:
  //   Layer A (deterministic): observed on a LATER JST date → exclude
  //   Layer B (heuristic):     observed on the SAME JST date → reconcile by amount
  //   Fallback:                can't determine → keep income (conservative)
  //
  // Layer B rationale: balance_observed_at shares the same date as payday.
  // We can't know deposit time, but the observed balance VALUE itself is evidence.
  // If (observed_balance - income_amount) ≈ expected pre-income balance, income likely landed.
  //
  // Threshold for Layer B is DYNAMIC, not a fixed %:
  //   tolerance = sum of absolute transaction amounts for this account in the last 48h
  //   (captures recent spending/other deposits that explain drift from previous balance)
  //   minimum tolerance = ¥1,000 (floor for accounts with no recent activity)
  //
  // Layer B is a confidence signal, not a proof. When it's ambiguous, we keep income.
  // This avoids false exclusions (income disappearing = 偽WARNING = worse than double-count).

  const allIncome = await getProjectedIncome(userId)
  const bankAccountMap = new Map(bankAccounts.data?.map(a => [a.id, a]) ?? [])

  const income = allIncome.filter(inc => {
    if (inc.date < todayStr) return false  // past → advance job will move forward

    if (!inc.bank_account_id) return true  // unknown destination → keep (conservative)

    const targetAccount = bankAccountMap.get(inc.bank_account_id)
    if (!targetAccount) return true

    const observedAt = targetAccount.balance_observed_at ?? targetAccount.balance_updated_at
    if (!observedAt) return true  // never observed → keep

    const observedDate = new Date(observedAt).toLocaleDateString('en-CA', { timeZone: 'Asia/Tokyo' })

    // Layer A: Balance observed on a LATER date → income definitely baked in
    if (observedDate > inc.date) return false

    // Layer B: Same day → reconcile by amount
    if (observedDate === inc.date) {
      const prevBalance = targetAccount.previous_balance
      if (prevBalance == null) return true  // no previous observation → can't reconcile → keep

      // UX-R4-001 + XDOC-R4-007: Guard against stale previous_balance.
      // If previous observation is too old, tolerance can't explain the drift → skip Layer B.
      const prevObservedAt = targetAccount.previous_balance_observed_at
      if (prevObservedAt) {
        const prevAge = jstNow.getTime() - new Date(prevObservedAt).getTime()
        if (prevAge > 7 * 24 * 3600_000) return true  // >7 days old → can't reconcile → keep
      }

      // Dynamic tolerance: recent transaction activity explains balance drift
      // beyond the income amount (other spending, deposits, transfers between observations)
      const recentTxVolume = targetAccount._recent_tx_volume  // precomputed: see below
      const tolerance = Math.max(1_000, recentTxVolume)  // floor ¥1,000

      // If removing income from current balance lands near previous balance (± tolerance),
      // the income is likely already in the observed balance
      const balanceWithoutIncome = targetAccount.current_balance - inc.amount
      const drift = Math.abs(balanceWithoutIncome - prevBalance)
      if (drift <= tolerance) return false  // reconciliation: income likely received → exclude

      // Drift too large → can't confidently say income is baked in → keep
      return true
    }

    // Balance observed BEFORE income date → income not yet in balance
    return true
  })

  // _recent_tx_volume: precomputed per bank account before income filtering.
  // = SUM(ABS(amount)) of transactions hitting this bank account in the last 48h.
  // This captures ATM withdrawals, card refunds, transfers, other small deposits, etc.
  // that would make (current_balance - income) differ from previous_balance even
  // if income DID land.
  //
  // Precompute (runs once, before the filter loop above):
  // for (const bank of bankAccounts.data ?? []) {
  //   const { data: recentTx } = await supabase.from('transactions')
  //     .select('amount')
  //     .eq('account_id', bank.id)
  //     .gte('transacted_at', new Date(Date.now() - 48 * 3600_000).toISOString())
  //   bank._recent_tx_volume = recentTx?.reduce((s, t) => s + Math.abs(t.amount), 0) ?? 0
  // }

  // ── 4. Fixed costs — composition rule (unchanged but now routes to bank account) ──
  const allFixedCosts = await getFixedCosts(userId)
  const creditCardIds = new Set(cardAccounts.data?.map(c => c.id) ?? [])

  const fixedCosts = allFixedCosts.filter(fc => {
    if (!fc.account_id || !creditCardIds.has(fc.account_id)) return true
    // PROJ-R4-003: If next_billing_at is null (not yet computed), keep conservatively.
    // Without this guard, the matchingCharge comparison below uses null >= string = false,
    // making the fixed cost escape de-duplication entirely.
    if (!fc.next_billing_at) return true
    if (fc.next_billing_at <= todayStr) return false
    const matchingCharge = cardCharges.find(cc =>
      cc.card_id === fc.account_id
      && fc.next_billing_at >= cc.period_start?.slice(0, 10)
      && fc.next_billing_at <= cc.period_end?.slice(0, 10)
    )
    if (matchingCharge) return false
    return true
  })

  // ── 4b. Variable costs — monthly_summaries average + account routing ──
  // PROJ-R5-001: estimated_variable must be explicitly generated.
  // Source of truth = monthly_summaries.variable_costs + uncategorized.
  // We include uncategorized on purpose (Design Principle #3: conservative).
  const variableCosts = await estimateVariableCosts(
    userId,
    bankAccounts.data ?? [],
    cardAccounts.data ?? [],
  )

  // ── 5. Build per-account timelines (DT-159: the real truth unit) ──
  // Build a settlement routing map: card.id → bank account
  const cardSettlementMap = new Map<string, string>()  // card_id → bank_account_id
  for (const card of cardAccounts.data ?? []) {
    if (card.settlement_account_id) {
      cardSettlementMap.set(card.id, card.settlement_account_id)
    }
  }

  const accountProjections: AccountProjection[] = []

  for (const bank of bankAccounts.data ?? []) {
    // Income landing in THIS bank account (+ unknown-destination income is NOT included
    // per-account — it only appears in aggregate to avoid phantom per-account inflation)
    const accountIncome = income.filter(i => i.bank_account_id === bank.id)

    // Card charges settling FROM this bank account
    const accountCardCharges = cardCharges.filter(cc =>
      cardSettlementMap.get(cc.card_id) === bank.id
    )

    // Fixed costs hitting this bank account:
    //   - Direct debit (fc.account_id IS this bank) → appears here
    //   - Card-paid → already inside accountCardCharges (via settlement routing)
    const accountFixedCosts = fixedCosts.filter(fc => {
      if (!fc.account_id) return false  // unknown payment method → aggregate only
      if (fc.account_id === bank.id) return true  // direct debit from this bank
      // Card-paid fixed costs are handled via card charges, not here
      return false
    })
    const accountVariableCosts = variableCosts.filter(vc => vc.bank_account_id === bank.id)

    const timeline = buildTimeline(
      bank.current_balance ?? 0,
      accountIncome,
      accountCardCharges,
      accountFixedCosts,
      accountVariableCosts,
    )
    const balanceBars = buildBalanceBars(bank.current_balance ?? 0, timeline, now)
    const dangerZones = detectDangerZones(balanceBars)

    accountProjections.push({
      account_id: bank.id,
      account_name: bank.name,
      current_balance: bank.current_balance ?? 0,
      timeline,
      balance_bars: balanceBars,
      danger_zones: dangerZones,
      is_safe: dangerZones.length === 0,
    })
  }

  // ── 6. Aggregate view (UX default) ──
  // XDOC-R4-015: `income` already includes unknown-destination income (bank_account_id=null).
  // Per-account excludes them (line 361), but aggregate gets all via [...income] below.
  // No separate unknownIncome variable needed — it was dead code causing confusion.
  const unroutedCardCharges = cardCharges.filter(cc => !cardSettlementMap.has(cc.card_id))
  const unroutedFixedCosts = fixedCosts.filter(fc =>
    !fc.account_id || (!bankAccountMap.has(fc.account_id) && !creditCardIds.has(fc.account_id))
  )

  const aggregateBalance = accountProjections.reduce((sum, ap) => sum + ap.current_balance, 0)
  // DT-R4-001: Aggregate timeline must NOT double-count card-paid fixed costs.
  // Per-account logic already excludes card-paid fixed costs (they flow through cardCharges).
  // For aggregate, we must also exclude them here — they're already inside cardCharges.
  // Unrouted fixed costs are appended separately below, so they must NOT be included here.
  const directDebitFixedCosts = fixedCosts.filter(fc => {
    if (bankAccountMap.has(fc.account_id)) return true  // direct debit from bank
    // Card-paid fixed costs (fc.account_id is a credit card) → exclude (already in cardCharges)
    return false
  })

  const aggregateTimeline = buildTimeline(
    aggregateBalance,
    [...income],  // all income (account-scoped + unknown)
    [...cardCharges],  // all card charges (includes card-paid fixed costs via settlement)
    [...directDebitFixedCosts, ...unroutedFixedCosts],  // only direct-debit + unrouted
    [...variableCosts],  // monthly_summaries based estimate, already bank-routed when possible
  )
  const aggregateBalanceBars = buildBalanceBars(aggregateBalance, aggregateTimeline, now)
  const aggregateDangerZones = detectDangerZones(aggregateBalanceBars)

  // DT-R4-002: Charge coverage must use per-account (settlement bank) balance,
  // not aggregate. A card's "is_funded" depends on the specific bank it settles from.
  const chargeCoverages = evaluateChargeCoveragePerAccount(
    cardCharges, cardSettlementMap, accountProjections
  )

  // Combine danger zones from all accounts
  const allDangerZones = accountProjections.flatMap(ap => ap.danger_zones)

  // ── 7. Staleness computation ──
  const staleSources: string[] = []

  // Per-account bank balance staleness
  const anyBalanceUpdated = bankAccounts.data?.some(a => a.balance_updated_at)
  // UX-R4-003: Payday-relative staleness (DESIGN.md §残高取得戦略 cases 1-3)
  // If payday has passed since last balance observation, the balance is definitively stale
  // (income has landed, projection anchor is wrong). 30-day threshold is fallback only.
  const userIncomes = await supabase.from('projected_incomes')
    .select('day_of_month, bank_account_id').eq('user_id', userId).eq('is_active', true)

  if (!anyBalanceUpdated) {
    staleSources.push('bank_balance')
  } else {
    for (const acc of bankAccounts.data ?? []) {
      if (!acc.balance_updated_at) {
        staleSources.push(`bank_balance:${acc.name}`)
        continue
      }
      const observedAt = acc.balance_observed_at ?? acc.balance_updated_at
      const observedDate = new Date(observedAt)
      const age = jstNow.getTime() - observedDate.getTime()

      // Case 2: Payday-relative check — has a payday passed since last observation?
      const accountPaydays = (userIncomes.data ?? [])
        .filter(i => i.bank_account_id === acc.id && i.day_of_month)
        .map(i => i.day_of_month)
      let paydayStale = false
      for (const payday of accountPaydays) {
        // Find the most recent payday date
        const todayDay = jstNow.getDate()
        const thisMonth = new Date(jstNow)
        thisMonth.setDate(payday)
        const lastPayday = todayDay >= payday ? thisMonth : new Date(thisMonth.setMonth(thisMonth.getMonth() - 1))
        if (observedDate < lastPayday) {
          paydayStale = true
          break
        }
      }

      // Case 3: 30-day fallback (no payday configured)
      if (paydayStale || (accountPaydays.length === 0 && age > 30 * 24 * 3600_000)) {
        staleSources.push(`bank_balance:${acc.name}`)
      }
    }
  }

  // Email connection staleness
  const emailConns = await supabase.from('email_connections')
    .select('last_synced_at, bootstrap_completed_at').eq('user_id', userId).eq('is_active', true)
  const emailStale = emailConns.data?.some(c =>
    !c.last_synced_at || (jstNow.getTime() - new Date(c.last_synced_at).getTime()) > 48 * 3600_000
  )
  if (emailStale || !emailConns.data?.length) staleSources.push('email_connection')

  // DT-159: Missing settlement_account_id on any credit card
  const cardsWithMissingSettlement = cardAccounts.data?.filter(
    c => c.settlement_account_id == null
  ) ?? []
  for (const c of cardsWithMissingSettlement) {
    staleSources.push(`settlement_account_missing:${c.name}`)
  }

  // Missing card schedule
  const cardsWithMissingSchedule = cardAccounts.data?.filter(
    c => c.closing_day == null || c.billing_day == null
  ) ?? []
  for (const c of cardsWithMissingSchedule) {
    staleSources.push(`card_schedule_missing:${c.name}`)
  }

  // DT-159: Income with unknown bank_account_id
  const hasUnknownIncomeAccount = income.some(i => !i.bank_account_id)
  if (hasUnknownIncomeAccount) staleSources.push('income_account_unknown')

  // data_as_of: oldest upstream timestamp
  const timestamps = [
    ...(bankAccounts.data?.map(a => a.balance_observed_at ?? a.balance_updated_at).filter(Boolean) ?? []),
    ...(emailConns.data?.map(c => c.last_synced_at).filter(Boolean) ?? []),
  ].map(t => new Date(t).getTime())
  const dataAsOf = timestamps.length > 0
    ? new Date(Math.min(...timestamps)).toISOString()
    : new Date(0).toISOString()

  // ── 8. Status determination ──
  const bootstrapDone = emailConns.data?.some(c => c.bootstrap_completed_at != null) ?? false
  const hasAnyCreditCards = (cardAccounts.data?.length ?? 0) > 0
  const emailRequired = hasAnyCreditCards
  const hasUnscheduledCards = cardsWithMissingSchedule.length > 0
  const hasUnsettledCards = cardsWithMissingSettlement.length > 0

  // DT-177: settlement_account_id=NULL does NOT block projection.
  // Unsettled cards run in aggregate-only mode (per-account accuracy degraded, not broken).
  // Instead of SETUP_REQUIRED (which hides the graph entirely), we:
  //   1. Add to stale_sources (visible degradation indicator)
  //   2. Trigger a settlement confirmation prompt in the iOS app
  //   3. Prompt always shows ALL bank accounts + "銀行口座を追加" option
  //      (the card may settle from an unregistered bank account)
  // This avoids hard-blocking all existing users on migration day.
  const setupRequired = !anyBalanceUpdated
    || (emailRequired && !bootstrapDone)
    || hasUnscheduledCards
    // hasUnsettledCards removed — unsettled cards degrade to aggregate-only, not hard-block

  // DT-159: WARNING vs CRITICAL distinction
  const anyAccountDanger = accountProjections.some(ap => !ap.is_safe)
  const aggregateDanger = aggregateDangerZones.length > 0

  let status: Projection['status']
  if (setupRequired) {
    status = 'SETUP_REQUIRED'
  } else if (aggregateDanger) {
    status = 'CRITICAL'  // 全口座合計でも0割れ — 資金移動では解決不可
  } else if (anyAccountDanger) {
    status = 'WARNING'   // 口座単体で0割れだが合計は足りる — 口座間移動で解決可能
  } else {
    status = 'SAFE'
  }

  return {
    aggregate_balance: aggregateBalance,
    aggregate_timeline: aggregateTimeline,
    aggregate_balance_bars: aggregateBalanceBars,
    account_projections: accountProjections,
    charge_coverages: chargeCoverages,
    danger_zones: allDangerZones,
    status,
    data_as_of: dataAsOf,
    is_stale: staleSources.length > 0,
    stale_sources: staleSources,
  }
}
```

```typescript
interface EstimatedVariableCost {
  id: string
  date: string
  bank_account_id: string
  amount: number            // positive absolute amount
  source_months: string[]   // e.g. ['2026-01', '2026-02', '2026-03']
}

// PROJ-R5-001: variable costs are not guessed from thin air.
// We derive them from monthly_summaries so the engine has an explicit producer
// for "estimated_variable" in the main formula.
async function estimateVariableCosts(
  userId: string,
  bankAccounts: FinancialAccount[],
  cardAccounts: FinancialAccount[],
): Promise<EstimatedVariableCost[]> {
  const todayStr = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Tokyo' })
  const summaries = await supabase
    .from('monthly_summaries')
    .select('year_month, variable_costs, uncategorized')
    .eq('user_id', userId)
    .order('year_month', { ascending: false })
    .limit(3)

  const closedMonths = summaries.data ?? []
  if (closedMonths.length === 0 || bankAccounts.length === 0) return []

  const monthlyAverage = Math.ceil(
    closedMonths.reduce(
      (sum, m) => sum + (m.variable_costs ?? 0) + (m.uncategorized ?? 0),
      0,
    ) / closedMonths.length
  )
  if (monthlyAverage <= 0) return []

  // Route the estimate to bank accounts using the recent 90-day spending mix.
  // Bank/debit transactions stay on their bank account.
  // Card transactions are re-routed to the card's settlement bank.
  // If there is insufficient history, fall back to the primary bank account.
  const settlementMap = new Map(
    cardAccounts
      .filter(card => card.settlement_account_id)
      .map(card => [card.id, card.settlement_account_id!])
  )
  const routingWeights = await buildVariableCostRoutingWeights(userId, settlementMap)
  const fallbackBankId = bankAccounts[0].id

  const horizonDays = 60
  const days = Array.from({ length: horizonDays }, (_, i) => addDays(todayStr, i + 1))
  const perDayBase = Math.ceil(monthlyAverage / 30)

  return days.flatMap(date => {
    const weights = routingWeights.length > 0
      ? routingWeights
      : [{ bank_account_id: fallbackBankId, ratio: 1 }]

    return weights.map(weight => ({
      id: `estimated_variable:${weight.bank_account_id}:${date}`,
      date,
      bank_account_id: weight.bank_account_id,
      amount: Math.ceil(perDayBase * weight.ratio),
      source_months: closedMonths.map(m => m.year_month),
    }))
  })
}

// Helper contract:
// buildVariableCostRoutingWeights() groups the last 90 days of variable transactions by
// settlement bank and returns [{ bank_account_id, ratio }] where ratios sum to 1.
// "variable transactions" = expense transactions that are not income and not matched to
// subscriptions / fixed_cost_items. Unknown routing is excluded from per-account weights.

// buildTimeline() accepts estimated variable costs as a fifth input and converts them to
// negative TimelineEvent(type='variable_cost') rows on their target dates.
```

### カード引き落とし額の計算

```typescript
// DT-108: Returns up to 2 CardCharge records per card:
//   1. committed: Previous period's confirmed charge (billing date = next billing day)
//   2. accumulating: Current open period's running total (billing date = following month's billing day)
// Before the closing day: only "accumulating" exists (current period is still open).
// After the closing day: "committed" = closed period total, "accumulating" = new period's running total.
async function calculateCardCharges(
  userId: string,
  card: FinancialAccount
): Promise<CardCharge[]> {
  const now = new Date()
  if (!card.closing_day || !card.billing_day) {
    return []
  }
  const closingDay = card.closing_day
  const billingDay = card.billing_day
  const charges: CardCharge[] = []

  // --- Committed charge (前期確定分) ---
  // 締め日を過ぎていたら、前期の合計が次の引き落とし日に確定している
  const committedPeriodStart = getPreviousPeriodStart(now, closingDay)
  const committedPeriodEnd = getPreviousPeriodEnd(now, closingDay)
  const committedBillingDate = getNextBillingDate(now, closingDay, billingDay)

  // 引き落とし日がまだ来ていない場合のみ committed を出す
  if (committedBillingDate > now) {
    const committedTx = await supabase
      .from('transactions')
      .select('amount')
      .eq('user_id', userId)
      .eq('account_id', card.id)
      .lt('amount', 0)
      .gte('transacted_at', committedPeriodStart.toISOString())
      .lte('transacted_at', committedPeriodEnd.toISOString())

    const committedTotal = committedTx.data
      ?.reduce((sum, t) => sum + Math.abs(t.amount), 0) ?? 0

    if (committedTotal > 0) {
      charges.push({
        card_id: card.id,
        card_name: card.name,
        card_last4: card.last4,
        charge_amount: committedTotal,
        billing_date: committedBillingDate.toISOString(),
        period_start: committedPeriodStart.toISOString(),
        period_end: committedPeriodEnd.toISOString(),
        is_committed: true,  // 確定済み
        credit_limit: card.credit_limit,
        utilization: null,
      })
    }
  }

  // --- Accumulating charge (今期オープン分) ---
  const currentPeriodStart = getPeriodStart(now, closingDay)
  const currentPeriodEnd = getPeriodEnd(now, closingDay)
  const nextBillingDate = getFollowingBillingDate(now, closingDay, billingDay)

  const currentTx = await supabase
    .from('transactions')
    .select('amount')
    .eq('user_id', userId)
    .eq('account_id', card.id)
    .lt('amount', 0)
    .gte('transacted_at', currentPeriodStart.toISOString())
    // PROJ-R4-004: Use JST end-of-day, not UTC now.
    // Between 00:00-08:59 JST, UTC `now` is still "yesterday" — early-morning
    // transactions (convenience store, ATM) would be excluded, undercounting spending.
    .lte('transacted_at', new Date(jstNow.getTime()).toISOString())  // JST-aware upper bound

  const currentTotal = currentTx.data
    ?.reduce((sum, t) => sum + Math.abs(t.amount), 0) ?? 0

  if (currentTotal > 0) {
    charges.push({
      card_id: card.id,
      card_name: card.name,
      card_last4: card.last4,
      charge_amount: currentTotal,
      billing_date: nextBillingDate.toISOString(),
      period_start: currentPeriodStart.toISOString(),
      period_end: currentPeriodEnd.toISOString(),
      is_committed: false,  // まだオープン (金額は増える可能性あり)
      credit_limit: card.credit_limit,
      utilization: card.credit_limit
        ? (currentTotal / card.credit_limit) * 100
        : null,
    })
  }

  return charges
}
```

```text
未設定カードの扱い:
- サーバー側: 該当カードをスキップし、警告ログを記録
- クライアント側: 「このカードは締め日/引き落とし日の設定が必要です」を表示
- 設定完了後に即時再計算
```

### 引き落とし日ごとの資金充足判定 (カード別)

```typescript
const EVENT_PRIORITY: Record<TimelineEvent['type'], number> = {
  card_charge: 1,
  fixed_cost: 2,
  income: 3,
}

// DT-R4-002: Evaluate charge coverage using per-account (settlement bank) balance,
// not aggregate. Each card's "is_funded" depends on the specific bank it settles from.
function evaluateChargeCoveragePerAccount(
  cardCharges: CardCharge[],
  cardSettlementMap: Map<string, string>,
  accountProjections: AccountProjection[],
): CardChargeCoverage[] {
  const accountMap = new Map(accountProjections.map(ap => [ap.account_id, ap]))
  const coverages: CardChargeCoverage[] = []

  for (const charge of cardCharges) {
    const settlementBankId = cardSettlementMap.get(charge.card_id)
    const bankProjection = settlementBankId ? accountMap.get(settlementBankId) : null

    if (!bankProjection) {
      // Unrouted card — no settlement bank configured.
      // Conservative: assume NOT funded (Design Principle #3).
      coverages.push({
        card_id: charge.card_id,
        card_name: charge.card_name,
        billing_date: charge.billing_date,
        charge_amount: charge.amount,
        balance_before: 0,
        balance_after: -charge.amount,
        shortfall: charge.amount,
        is_funded: false,
      })
      continue
    }

    // Walk the bank's timeline to find the balance at charge.billing_date
    const timeline = [...bankProjection.timeline].sort((a, b) =>
      a.date === b.date
        ? EVENT_PRIORITY[a.type] - EVENT_PRIORITY[b.type]
        : a.date.localeCompare(b.date),
    )

    let running = bankProjection.current_balance
    let balanceAtBilling = running

    for (const event of timeline) {
      if (event.date > charge.billing_date) break
      running += event.amount
      if (event.date <= charge.billing_date) {
        balanceAtBilling = running
      }
    }

    const balanceAfter = balanceAtBilling  // charge is already in the timeline
    coverages.push({
      card_id: charge.card_id,
      card_name: charge.card_name,
      billing_date: charge.billing_date,
      charge_amount: charge.amount,
      balance_before: balanceAtBilling + charge.amount,  // before this charge hit
      balance_after: balanceAfter,
      shortfall: Math.max(0, -balanceAfter),
      is_funded: balanceAfter >= 0,
    })
  }

  return coverages
}
```

```text
UIの見せ方:
- 各カード行に「引き落とし時点の残高」を表示
- is_funded=true: 緑バッジ「資金OK」
- is_funded=false: 赤バッジ「不足 -¥xx,xxx」
- タップで「不足が発生した日の前後イベント」を展開
```

## 5. 見込み収入の管理

```typescript
// 見込み収入は以下のソースから:

// A. ユーザー手動設定 (初回セットアップ)
interface RecurringIncome {
  name: string         // '給料', 'アルバイト'
  amount: number
  day: number          // 毎月25日
  is_estimated: boolean // 概算フラグ
}

// B. メールからの検知 (給与明細メール等)
// → 「給与振込のお知らせ」メールをパース
// → 振込額を自動更新

// C. 過去の入金パターンから推定
// → 過去3ヶ月の入金を分析
// → 定期的な入金パターンを検出
```

```sql
-- 実装時は DESIGN.md の以下テーブルを利用:
-- projected_incomes: 見込み収入の定義
-- fixed_cost_items: サブスク以外の固定費 (家賃/通信費など, account_id で支払口座/カードを保持)
-- monthly_summaries: variable_costs + uncategorized から estimated_variable を算出
```

## 6. アラートロジック

```typescript
async function checkAndAlert(userId: string): Promise<void> {
  const projection = await calculateProjection(userId)

  for (const danger of projection.danger_zones) {
    const daysUntil = daysBetween(new Date(), new Date(danger.date))

    // UX-R4-005: Dedup projection alerts via system_alerts.
    // Without this, the same "残高不足" push fires every day for the duration
    // of the danger zone (e.g., 7 consecutive days). Users will disable notifications.
    const alertKey = `projection_deficit:${danger.date}`
    const { data: existingAlert } = await supabase
      .from('system_alerts')
      .select('id')
      .eq('user_id', userId)
      .eq('alert_type', alertKey)
      .is('resolved_at', null)
      .maybeSingle()

    if (existingAlert) continue  // already notified, not yet resolved

    if (daysUntil <= 7) {
      await sendPush(userId, {
        title: '⚠️ 残高不足の可能性',
        body: `${danger.date} の引き落とし時に ¥${Math.abs(danger.shortfall).toLocaleString()} 不足する可能性があります`,
        priority: 'high',
        deepLink: 'credebi://projection',
      })
      await supabase.from('system_alerts').insert({
        user_id: userId,
        alert_type: alertKey,
        message: `Deficit ¥${Math.abs(danger.shortfall)} on ${danger.date}`,
      })
    } else if (daysUntil <= 14) {
      await sendPush(userId, {
        title: '来月の引き落としについて',
        body: `${danger.cause} の引き落とし ¥${Math.abs(danger.shortfall).toLocaleString()} に備えて残高をご確認ください`,
        priority: 'normal',
        deepLink: 'credebi://projection',
      })
      await supabase.from('system_alerts').insert({
        user_id: userId,
        alert_type: alertKey,
        message: `Upcoming charge ${danger.cause} ¥${Math.abs(danger.shortfall)} on ${danger.date}`,
      })
    }
  }

  // Auto-resolve alerts for danger zones that no longer exist
  // (e.g., user deposited money, deficit resolved)
  const { data: activeAlerts } = await supabase
    .from('system_alerts')
    .select('id, alert_type')
    .eq('user_id', userId)
    .like('alert_type', 'projection_deficit:%')
    .is('resolved_at', null)

  for (const alert of activeAlerts ?? []) {
    const alertDate = alert.alert_type.replace('projection_deficit:', '')
    const stillDanger = projection.danger_zones.some(d => d.date === alertDate)
    if (!stillDanger) {
      await supabase.from('system_alerts')
        .update({ resolved_at: new Date().toISOString() })
        .eq('id', alert.id)
    }
  }

  // DT-160: Push notification policy — user-configurable level
  //
  // users.notification_level controls what gets delivered:
  //   'least':  CRITICAL + broken_connection only
  //   'less':   WARNING+ and subscription detection (cap 2/day)
  //   'medium': + balance reminder, card utilization (cap 3/day) [default]
  //   'full':   all notifications, no daily cap
  //
  // Common rules (all levels):
  //   - Quiet hours: iOS側制御 (Focus/おやすみモード)。サーバーキュー不要。
  //     CRITICAL/broken_connection は APNs interruption-level='time-sensitive' で貫通 (critical は Apple entitlement必要)。
  //   - Bypass (no cap, no quiet): CRITICAL within 7 days, broken_connection
  //   - Bootstrap/setup notifications: exempt from daily cap
  //
  // Design Principle #3: false alarms are tolerable, missed alerts are not.
  // So bypass rules lean toward "always deliver" for urgent financial warnings.

  // ショッピング枠の利用率アラート (XDOC-R4-001: fixed field name)
  for (const charge of projection.charge_coverages) {
    if (charge.utilization != null && charge.utilization >= 80) {
      await sendPush(userId, {
        title: 'カード利用枠の注意',
        body: `${charge.card_name} の利用率が ${Math.round(charge.utilization)}% です`,
        priority: 'normal',
      })
    }
  }
}
```

## 7. ダッシュボード表示モデル

```
┌─────────────────────────────────────────────────────────┐
│                資金推移 (シンプル表示)                    │
│                                                          │
│  SAFE FOR NOW / WARNING: MAY HIT ZERO                    │
│                                                          │
│      ●───●───●───●───●────●────●────●                    │
│                         \                    \            │
│                          \                    ●──●──●     │
│  0ライン ─────────────────────────────────────────         │
│  3/27 付近で 0円割れの可能性                              │
└─────────────────────────────────────────────────────────┘
```

```text
MVPグラフ仕様 (Gen-Z向け簡易):
- X軸: 日付 (過去30日〜未来60日)
- Y軸: 数値ラベル非表示 (認知負荷を下げる)
- 線グラフ1本のみ
- 表示ステータスは四値 (DT-159):
  - SETUP_REQUIRED (銀行残高未入力 or bootstrap未完了 or カード引き落とし口座未設定)
  - SAFE (全口座で0を下回らない)
  - WARNING 🟡 (いずれかの口座で0割れだが全口座合計なら足りる — 口座間移動で解決可能)
  - CRITICAL 🔴 (全口座合計でも0割れ — 資金移動では解決不可)
- SETUP_REQUIRED 時はグラフ非表示、代わりにセットアップウィザードへ誘導
  「予測を開始するために、銀行口座の残高を入力してください」
- DT-109: データ不足で SAFE を出すのは Design Principle #1 違反
- WARNING時: 不足口座名 + 「三井住友に ¥X,XXX 移動すれば解決できます」表示
- CRITICAL時: 0割れの最初の日を強調表示 + 不足額
```

```text
詳細表示方針:
- 初期画面では「金額の羅列」は出さない
- 点タップ時に「その日 SAFE/NOT SAFE」と Earned/Spent 合計を表示
- Earned/Spent の数値をタップすると内訳を展開 (例: Netflix fee, Lunch)
- カード別不足額などの深い分析は二次画面に分離

DT-159: Account-scoped UX (デフォルト=まとめ、展開=口座別):

デフォルト表示 (まとめビュー = aggregate):
┌─────────────────────────────────────────┐
│  SAFE  /  WARNING 🟡  /  CRITICAL 🔴   │
│  ●───●───●───●───●────●────●            │  ← 全口座合計
│  合計残高: ¥234,000                      │
└─────────────────────────────────────────┘

WARNING時 or タップで展開 (per-account):
┌─────────────────────────────────────────┐
│  三井住友 (普通)     ¥180,000  🟢 SAFE  │
│  ●───●───●───●──●                       │
│                                          │
│  楽天銀行           ¥54,000   🟡 不足   │
│  ●───●───●──╳──●   ← 3/27に不足         │
│  三井住友NLの引き落とし ¥62,000           │
│  → ¥8,000 不足                           │
│                                          │
│  💡 三井住友から楽天に ¥8,000 移動で解決  │
└─────────────────────────────────────────┘
```

```text
UI仕様・プロトタイプ:
- UI spec: docs/ui/projection-view-spec.md
- SwiftUI prototype (iOS primary): docs/ui/prototypes/ProjectionViewPrototype.swift
- Web prototype (reference): docs/ui/prototypes/projection-view-prototype.html
- Visual tone: Apple HIG aligned, low-cognitive layout
```

## 8. 更新トリガー

```
予測は以下のタイミングで再計算:

1. 取引追加/更新時 (リアルタイム)
   → transaction INSERT/UPDATE → update-projection Edge Function

2. 日次バッチ (pg_cron)
   → 全ユーザーの予測を更新
   → アラート判定を実行

3. 銀行残高更新時
   → financial_accounts.current_balance UPDATE
   → 予測再計算

4. サブスク変更時
   → subscriptions INSERT/UPDATE/DELETE
   → 固定費再計算

5. スケジュール変更時
   → financial_accounts.closing_day / billing_day UPDATE
   → 引き落とし日を再配置してバー再計算
```

## 9. Realtime表示 (Supabase Realtime)

```typescript
// iOS側: Supabase Realtimeで予測の変更をリアルタイム受信

// monthly_summaries テーブルの変更をサブスクライブ
let subscription = supabase
  .channel('projection-updates')
  .on(
    'postgres_changes',
    {
      event: 'UPDATE',
      schema: 'public',
      table: 'monthly_summaries',
      filter: `user_id=eq.${userId}`
    },
    (payload) => {
      // ダッシュボードをリアルタイム更新
      updateDashboard(payload.new)
    }
  )
  .subscribe()
```

## 10. 自由残額 (Spendable Balance) — 残額フォーカス

### 10a. 設計思想

~~「今日あといくら使える？」~~ → PROJ-R4-006: daily budget (日割り計算) は削除。
大学生の支出パターンは日によって大きく変動するため、均等割りの日次予算は非現実的。

代わりに「自由残額」を**ダッシュボードのヒーロー数値**として常時表示する。
これは予測エンジンの既存出力からの派生メトリクスであり、新しい計算は行わない。

```
自由残額 = 給料日前日の予測残高 (pre_payday_balance)

つまり:
  現在の銀行残高 (Layer 1: truth anchor)
  + 給料日までの見込み収入 (Layer 3)
  - 給料日までの確定引き落とし (Layer 2: committed charges)
  - 給料日までの固定費 (Layer 3: subscriptions, fixed costs)
  - 見込み変動費 (Layer 3: 過去3ヶ月平均)
  = 給料日時点で手元に残る見込み額
```

**日割りにしない理由は変わらない。** 「1日¥2,000まで」は非現実的だが、
「給料日まで¥38,200の余裕がある」は行動可能な事実。

**Design Principle #3 との関係:**
- 見込み変動費は過去3ヶ月平均を使う（楽観しない）
- accumulating_charge はオープン期間の現時点累計をそのまま含める（安全側）
- 自由残額が負値になりうる — その場合は WARNING/CRITICAL に直結

### 10b. ProjectionSummary

```typescript
interface ProjectionSummary {
  // 自由残額 (ヒーロー数値): 給料日前日の予測残高
  // 給料日未設定の場合は min_projected_balance にフォールバック
  spendable_balance: number

  // 補助メトリクス
  min_projected_balance: number     // 期間中の最低残高
  min_projected_date: string        // その最低残高になる日付
  next_payday: string | null        // 次の給料日 (projected_incomes から)
  pre_payday_balance: number | null // 給料日前日の予測残高 (null = 給料日未設定)

  // staleness (Design Principle #2)
  data_as_of: string                // 最新の upstream data timestamp
  is_stale: boolean
  stale_sources: string[]
}

function computeProjectionSummary(projection: Projection): ProjectionSummary {
  const minBar = projection.aggregate_balance_bars.reduce(
    (min, bar) => bar.balance < min.balance ? bar : min,
    projection.aggregate_balance_bars[0]
  )

  // Next payday from projected_incomes (is_estimated=false, amount >= 30_000)
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Tokyo' })
  const nextPayday = projection.aggregate_timeline.find(
    e => e.type === 'income' && e.date > today && e.amount >= 30_000
  )

  // Pre-payday balance: balance bar for the day before payday
  let prePaydayBalance: number | null = null
  if (nextPayday) {
    const dayBefore = addDays(nextPayday.date, -1)
    const bar = projection.aggregate_balance_bars.find(b => b.date === dayBefore)
    prePaydayBalance = bar?.balance ?? minBar.balance
  }

  // Spendable balance: pre-payday if available, otherwise min projected
  // Using min as fallback is conservative (Design Principle #3)
  const spendableBalance = prePaydayBalance ?? minBar.balance

  return {
    spendable_balance: spendableBalance,
    min_projected_balance: minBar.balance,
    min_projected_date: minBar.date,
    next_payday: nextPayday?.date ?? null,
    pre_payday_balance: prePaydayBalance,
    data_as_of: projection.data_as_of,
    is_stale: projection.is_stale,
    stale_sources: projection.stale_sources,
  }
}
```

### 10c. ダッシュボード ヒーローカード

```
ダッシュボード上部に常時表示。アプリを開いたら最初に目に入る数字。

■ 通常状態 (SAFE):
┌─────────────────────────────────────────┐
│  あと自由に使える                          │
│  ¥38,200                    ← ヒーロー数値 │
│                                           │
│  次の給料日  3/25 (火)                      │
│  最低残高    ¥12,400 (3/15 引き落とし後)      │
│  ───────────────────────                  │
│  SAFE  口座残高は足りる見込みです              │
└─────────────────────────────────────────┘

■ WARNING状態:
┌─────────────────────────────────────────┐
│  あと自由に使える                          │
│  ¥2,100                     ← 黄色       │
│                                           │
│  次の給料日  3/25 (火)                      │
│  最低残高    ¥-3,200 (3/15 引き落とし後)     │
│  ───────────────────────                  │
│  ⚠ WARNING  3/15の引き落としで不足の可能性    │
└─────────────────────────────────────────┘

■ CRITICAL状態:
┌─────────────────────────────────────────┐
│  あと自由に使える                          │
│  ¥-8,400                    ← 赤         │
│                                           │
│  次の給料日  3/25 (火)                      │
│  最低残高    ¥-8,400 (3/10 引き落とし後)     │
│  ───────────────────────                  │
│  🔴 CRITICAL  残高不足が見込まれます         │
│  入金が必要です                             │
└─────────────────────────────────────────┘

■ 給料日未設定:
┌─────────────────────────────────────────┐
│  最低予測残高                               │
│  ¥12,400                    ← ヒーロー数値 │
│  (3/15 引き落とし後)                        │
│  ───────────────────────                  │
│  給料日を設定するとより正確な予測ができます      │
└─────────────────────────────────────────┘

■ データ古い (is_stale = true):
┌─────────────────────────────────────────┐
│  あと自由に使える                          │
│  ¥38,200                    ← オレンジ帯  │
│                                           │
│  ⚠ データが古い可能性があります               │
│    銀行残高: 3日前に更新                     │
│  ───────────────────────                  │
│  残高を更新してください                      │
└─────────────────────────────────────────┘
```

### 10d. 設計判断

- **「使っていい額」ではなく「自由に使える余裕」。** 日割り予算のように消費を誘導しない。
  「¥38,200余裕がある」は事実の提示。「¥5,000使っていい」は行動の指示。Credebiは前者。
- **ヒーロー数値は1つだけ。** 情報過多を避ける。詳細はタップで展開。
- **色セマンティクスは SAFE/WARNING/CRITICAL に直結。** 数値の大小ではなく、
  min_projected_balance が負になるかどうかで判定（既存ロジック）。
- **広告禁止ゾーン。** このカード周辺には広告を配置しない（既存ルール維持）。

## 11. 銀行残高更新チャネル

### 11a. 手動入力 (Phase 1 MVP)

```text
設定 > 口座 > [口座名] > 残高を更新
→ テンキー入力画面
→ balance_source = 'manual'
→ balance_observed_at = balance_updated_at = now()
```

### 11b. スクリーンショットOCR (Phase 1)

```typescript
// UX-R4-002: EXIF DateTimeOriginal has NO timezone — it's local time from the camera.
// Japanese phones produce JST timestamps. Treating them as UTC shifts observedAt by +9h,
// which can push the observation into the wrong JST date (breaking Layer A/B decisions).
function parseExifDate(exifDateStr: string): Date {
  // EXIF format: "2026:03:15 14:30:00"
  // Parse as JST (UTC+9) since this is a Japanese-market app with Japanese bank screenshots
  const [datePart, timePart] = exifDateStr.split(' ')
  const isoString = `${datePart.replace(/:/g, '-')}T${timePart}+09:00`
  return new Date(isoString)
}

function isReasonableTimestamp(exifDateStr: string): boolean {
  try {
    const d = parseExifDate(exifDateStr)
    const now = new Date()
    const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 3600_000)
    return d >= sevenDaysAgo && d <= now
  } catch {
    return false
  }
}

// Edge Function: update-balance-ocr
// Input: multipart/form-data { account_id: UUID, image: File }
// Output: { balance: number, observed_at: string, source_detail: object }

async function handleBalanceOCR(req: Request): Promise<Response> {
  const formData = await req.formData()
  const accountId = formData.get('account_id') as string
  const image = formData.get('image') as File

  // SEC-R3-002: Verify the account belongs to the authenticated user BEFORE
  // sending anything to the LLM. Prevents: (1) IDOR — updating someone else's
  // balance, (2) wasting LLM cost on unauthorized requests.
  const { data: account } = await supabase
    .from('financial_accounts')
    .select('id, type')
    .eq('id', accountId)
    .eq('user_id', userId)
    .single()
  if (!account) {
    return errorResponse('NOT_FOUND', 'Account not found or not owned by user')
  }
  if (account.type !== 'bank') {
    return errorResponse('VALIDATION_ERROR', 'OCR balance update is only for bank accounts')
  }

  // 1. EXIF metadata extraction for timestamp
  const exifData = await extractExif(image)
  let observedAt: Date

  if (exifData?.DateTimeOriginal && isReasonableTimestamp(exifData.DateTimeOriginal)) {
    // EXIF timestamp exists and is within last 7 days → trust it
    observedAt = parseExifDate(exifData.DateTimeOriginal)
  } else {
    // No EXIF, or EXIF stripped (screenshots via LINE/AirDrop, edited images, etc.)
    // → use upload time as fallback
    observedAt = new Date()
  }

  // 2. OCR via Gemini Vision (cheapest multimodal model)
  const ocrResult = await callGeminiVision(image, {
    prompt: `Extract the bank account balance from this screenshot.
Return JSON: { "balance": <number in yen, integer>, "bank_name": "<detected bank name>" }
If no balance is visible, return { "balance": null, "error": "no_balance_found" }`,
  })

  if (ocrResult.balance === null) {
    return errorResponse('OCR_FAILED', 'Could not detect balance in screenshot')
  }

  // SEC-R3-002: Validate LLM output before trusting it.
  // LLM prompt injection could return malicious values.
  if (typeof ocrResult.balance !== 'number' || !Number.isFinite(ocrResult.balance)) {
    return errorResponse('OCR_FAILED', 'OCR returned invalid balance value')
  }
  if (ocrResult.balance < 0 || ocrResult.balance > 100_000_000) {
    // Bank balance sanity check: negative balances aren't typical for savings/checking,
    // and >¥100M is unreasonable for a college student.
    return errorResponse('OCR_FAILED', 'OCR balance out of reasonable range')
  }

  // 3. Update financial_accounts via SP (atomically shifts previous_balance)
  // XDOC-R4-011: MUST use update_bank_balance SP, never raw .update(),
  // to ensure previous_balance is populated for Layer B reconciliation.
  await supabase.rpc('update_bank_balance', {
    p_account_id: accountId,
    p_user_id: userId,
    p_new_balance: ocrResult.balance,
    p_observed_at: observedAt.toISOString(),
    p_source: 'ocr_screenshot',
  })

  // 4. Recalculate projection with fresh balance
  // OPS-R4-005: Fire-and-forget — balance is already committed.
  // Awaiting would block the user response on projection computation.
  supabase.functions.invoke('update-projection', {
    body: { user_id: userId },
  }).catch(err => console.error('update-projection failed after OCR:', err))

  return jsonResponse({
    balance: ocrResult.balance,
    observed_at: observedAt.toISOString(),
    source_detail: {
      exif_used: !!exifData?.DateTimeOriginal,
      bank_name_detected: ocrResult.bank_name,
    },
  })
}

// EXIF timestamp sanity check:
// - Must be within last 7 days (older screenshots are suspect)
// - Must not be in the future
// - Timezone: EXIF dates are typically local time (JST for Japanese phones)
function isReasonableTimestamp(exifDate: Date): boolean {
  const now = new Date()
  const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 3600_000)
  return exifDate >= sevenDaysAgo && exifDate <= now
}
```

```text
iOS UI フロー:
1. 設定 > 口座 > [口座名] > 残高を更新
2. [手動入力] or [スクリーンショットで更新]
3. スクショ選択 → OCR処理中スピナー
4. 結果表示: 「残高: ¥1,234,567 (住信SBIネット銀行)」
5. [この金額で更新] or [金額を修正] → テンキー画面
6. 確定 → projection 再計算

observed_at の表示:
- EXIF取得時: 「3月14日 15:32 のスクリーンショット」
- EXIF なし時: 「たった今」

注意: balance_observed_at は income double-count 防止ルール (UX-008) で使用。
balance_updated_at ではなく balance_observed_at で「いつ時点の残高か」を判定する。
```

### 11c. API連携 (Phase 2+)

```text
Phase 2: Moneytree LINK API
Phase 3: 電子決済等代行業登録 → 直接銀行API
→ balance_source = 'api'
→ balance_observed_at = API response timestamp
```

## 12. API契約とUI仕様の固定ファイル

```text
1) API response contract (JSON Schema):
   docs/contracts/projection-response.schema.json

2) ProjectionView UI spec:
   docs/ui/projection-view-spec.md

3) ProjectionView interactive prototype:
   docs/ui/prototypes/projection-view-prototype.html
```
