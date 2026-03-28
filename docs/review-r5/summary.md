# Round 5 Adversarial Design Review — Summary

Source: Claude Opus 5-agent parallel review (2026-03-28). Codex cross-validation attempted but output capture failed.

## Verified (code/migration gap confirmed)

### P0

- `SEC-R5-001`: `users.tier` の初期値が `Owner(3)` になっている。場所: `supabase/migrations/20260317000002_tables.sql`. 推奨: `実装前修正`
- `SEC-R5-002`: `users` の RLS が `FOR ALL USING (id = auth.uid())` で、自己 `tier` 更新を止められない。場所: `supabase/migrations/20260317000005_rls.sql`. 推奨: `実装前修正`
- `SEC-R5-003`: `transactions.account_id` / `subscriptions.account_id` に所有権検証 trigger がなく、他人の口座参照を防げない。場所: `supabase/migrations/20260317000002_tables.sql`, `supabase/migrations/20260317000003_functions_triggers.sql`. 推奨: `実装前修正`
- `PROJ-R5-003`: `fixed_cost_items` に `account_id` がなく、口座別ルーティング前提を満たせない。場所: `supabase/migrations/20260317000002_tables.sql`, `docs/deep-dive/05-projection-engine.md`. 推奨: `実装前修正`

### P1

- `SEC-R5-009`: `claimMessageId()` が想定外 DB エラー時に `"new"` を返し fail-open する。場所: `supabase/functions/handle-email-webhook/index.ts`. 推奨: `実装中修正`
- `SEC-R5-016`: `email_connections.email_address` が平文カラムで保存される。場所: `supabase/migrations/20260317000002_tables.sql`. 推奨: `実装中修正`
- `UX-R5-008`: DMS の stale 条件が `last_synced_at IS NULL` 接続を拾えず、bootstrap 停止系が漏れる。場所: `supabase/migrations/20260317000007_cron_jobs.sql`. 推奨: `実装中修正`
- `UX-R5-015`: `fixed_cost_items.next_billing_at` を進める cron が存在しない。場所: `supabase/migrations/20260317000007_cron_jobs.sql`. 推奨: `実装中修正`
- `XDOC-R5-007`: `_shared/api.ts` の `ErrorCode` 列挙に `FORBIDDEN` / `CONFLICT` / `NOT_FOUND` がない。場所: `supabase/functions/_shared/api.ts`. 推奨: `実装中修正`
- `XDOC-R5-015`: cron が呼ぶ `update-projection` / `nudge-balance-update` の実体が repo 上に存在しない。場所: `supabase/migrations/20260317000007_cron_jobs.sql`, `supabase/functions/`. 推奨: `実装中修正`
- `OPS-R5-004`: `claimMessageId()` の reclaim `update()` が `count` 判定前提なのに `count: 'exact'` を指定していない。場所: `supabase/functions/handle-email-webhook/index.ts`. 推奨: `実装中修正`

### P2

- 該当なし

## Likely (doc/code drift)

### P0

- `PROJ-R5-001`: projection 式にある `estimated_variable` が仕様本文では重要なのに、設計コード断片へ接続されていない。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装前修正`
- `XDOC-R5-002`: `projection-response.schema.json` の `summary.safety_status` 2値 lower-case と、projection engine の `status` 4値 upper-case が不整合。場所: `docs/contracts/projection-response.schema.json`, `docs/deep-dive/05-projection-engine.md`, `docs/deep-dive/07-public-api.md`. 推奨: `実装前修正`
- `XDOC-R5-003`: schema に `account_projections` / `aggregate_*` / `danger_zones` / `status` など主要 field がない。場所: `docs/contracts/projection-response.schema.json`, `docs/deep-dive/05-projection-engine.md`, `docs/deep-dive/07-public-api.md`. 推奨: `実装前修正`
- `OPS-R5-002`: Dead Man's Switch 自体の最終成功を別経路で監視する設計が見当たらない。場所: `supabase/migrations/20260317000007_cron_jobs.sql`, `DESIGN.md`. 推奨: `実装前修正`
- `OPS-R5-003`: cron 呼び出しが `net.http_post()` の fire-and-forget 前提で、成功 marker / heartbeat 設計が見当たらない。場所: `supabase/migrations/20260317000007_cron_jobs.sql`, `DESIGN.md`. 推奨: `実装前修正`

### P1

- `PROJ-R5-002`: `todayStr` の JST 変換が `toISOString()` 往復依存で脆い。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `PROJ-R5-004`: 未設定カード 1 枚で projection 全体を `SETUP_REQUIRED` に倒す設計が強すぎる。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `PROJ-R5-005`: `computeProjectionSummary()` が `minBar.balance` を参照しており、`BalanceBar` 定義と一致しない。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `PROJ-R5-006`: `amount >= 30000` 閾値が低所得ユーザーの payday 検知を落とす。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `PROJ-R5-007`: `computeNextBilling()` の基準時刻が transaction date ではなく検知時刻に寄りやすい。場所: `docs/deep-dive/04-subscription-detection.md`, `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `PROJ-R5-008`: カード締め期間境界が UTC midnight 想定で、JST 規約と衝突している。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `PROJ-R5-009`: projection status の schema/engine 不整合が別 ID でも再発している。場所: `docs/contracts/projection-response.schema.json`, `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `PROJ-R5-011`: `fixed_cost_items` の aggregate 二重計上論点が projection 側仕様にも残っている。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `UX-R5-002`: bootstrap サブスク金額推定が最古トランザクション額固定になっている。場所: `docs/deep-dive/04-subscription-detection.md`. 推奨: `実装中修正`
- `UX-R5-003`: 未設定カードの利用額が projection から丸ごと脱落する degraded 仕様になっている。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `UX-R5-004`: UI spec 側に `data_as_of` / `is_stale` / `stale_sources` の反映が薄い。場所: `docs/ui/projection-view-spec.md`, `docs/ui/prototypes/ProjectionViewPrototype.swift`, `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`
- `UX-R5-007`: Pub/Sub fallback polling は deep-dive にあるが cron SQL に反映されていない。場所: `docs/deep-dive/02-gmail-integration.md`, `supabase/migrations/20260317000007_cron_jobs.sql`. 推奨: `実装中修正`
- `XDOC-R5-008`: `ProactiveInboxProactiveInboxCrawlRequest` 型名の重複が docs / shared types / 実装で揃っていない。場所: `docs/deep-dive/02-gmail-integration.md`, `supabase/functions/proactive-inbox-crawl/index.ts`. 推奨: `実装中修正`
- `XDOC-R5-016`: `computeNextBilling()` の UTC `.toISOString()` 依存が JST 規約とずれている。場所: `docs/deep-dive/04-subscription-detection.md`, `docs/deep-dive/05-projection-engine.md`. 推奨: `実装中修正`

### P2

- `UX-R5-011`: projection の confidence / uncertainty 表示がまだ弱い。場所: `docs/ui/prototypes/ProjectionViewPrototype.swift`, `docs/deep-dive/05-projection-engine.md`. 推奨: `監視・確認`
- `UX-R5-012`: カード未設定時の guided recovery UX を強化する余地がある。場所: `docs/ui/prototypes/ProjectionViewPrototype.swift`. 推奨: `監視・確認`
- `UX-R5-014`: 通知 explainability の表現ルールが未整理。場所: `docs/deep-dive/05-projection-engine.md`, `DESIGN.md`. 推奨: `監視・確認`
- `PROJ-R5-012`: projection の感度分析 / what-if は将来設計に残る。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `監視・確認`
- `PROJ-R5-013`: variable cost 学習方式の高度化余地がある。場所: `docs/deep-dive/05-projection-engine.md`. 推奨: `監視・確認`
- `PROJ-R5-014`: サブスク金額変動の自動追跡高度化が未整理。場所: `docs/deep-dive/04-subscription-detection.md`. 推奨: `監視・確認`
- `OPS-R5-013`: schema / docs / shared types の drift 自動検知は未整備。場所: `docs/contracts/projection-response.schema.json`, `supabase/functions/_shared/api.ts`. 推奨: `監視・確認`
- `OPS-R5-016`: cron / Edge Function inventory の単一正典化が未完了。場所: `DESIGN.md`, `supabase/migrations/20260317000007_cron_jobs.sql`. 推奨: `監視・確認`

## Needs Confirmation

### P0

- 該当なし

### P1

- `SEC-R5-004`: `subscriptions.account_id` 側の IDOR 経路を API / Edge Function 経由で再確認する必要がある。場所: `supabase/migrations/20260317000002_tables.sql`, 関連API実装全般. 推奨: `実装中修正`
- `SEC-R5-005`: Pub/Sub OIDC JWT の `iat` / `nbf` 検証要件が実運用で十分か手動確認が必要。場所: `supabase/functions/handle-email-webhook/index.ts`, `docs/deep-dive/02-gmail-integration.md`. 推奨: `実装中修正`
- `SEC-R5-006`: JWT `email` claim と Pub/Sub service account の一致確認が必要。場所: `supabase/functions/handle-email-webhook/index.ts`, `docs/deep-dive/02-gmail-integration.md`. 推奨: `実装中修正`
- `SEC-R5-007`: `service_role_key` の pg_cron SQL / pg_net ログ露出は Supabase 側ログ面も含め手動確認が必要。場所: `supabase/migrations/20260317000007_cron_jobs.sql`. 推奨: `実装中修正`
- `SEC-R5-014`: LLM 出力受理経路が `JSON.parse` のみか、他箇所も含めて横断確認が必要。場所: `docs/deep-dive/01-email-parser.md`, `docs/deep-dive/05-projection-engine.md`, 関連 Edge Functions. 推奨: `実装中修正`
- `OPS-R5-008`: webhook handler と `renew-gmail-watch` の token refresh race は実装順序と Vault 更新戦略の実測確認が必要。場所: `docs/deep-dive/02-gmail-integration.md`, `supabase/functions/renew-gmail-watch/index.ts`. 推奨: `実装中修正`

### P2

- `SEC-R5-008`: JWT / webhook replay hardening の費用対効果は追加検証が必要。場所: `docs/deep-dive/02-gmail-integration.md`. 推奨: `監視・確認`
- `SEC-R5-010`: webhook / cron 系シークレットのローテーション監査強化は運用条件を確認して決めるべき。場所: `DESIGN.md`. 推奨: `監視・確認`
- `SEC-R5-012`: 長期セキュリティ監査ログ粒度は保持コストと併せて要確認。場所: `DESIGN.md`. 推奨: `監視・確認`
- `SEC-R5-015`: `email_address` 非保持運用の可否は実 UX / サポート要件確認が必要。場所: `DESIGN.md`. 推奨: `監視・確認`
- `OPS-R5-005`: DMS 外部監視の依存先・冗長化・コスト確認が必要。場所: `DESIGN.md`. 推奨: `監視・確認`
- `OPS-R5-006`: cron heartbeat 保存先 / retention は運用負荷を見て確認が必要。場所: `DESIGN.md`. 推奨: `監視・確認`
- `OPS-R5-012`: token refresh race の実測監視追加はメトリクス設計の確認が必要。場所: `docs/deep-dive/02-gmail-integration.md`. 推奨: `監視・確認`
