# 残り設計タスク一覧 (2026-03-15 更新)

このドキュメントは、現時点で未完了の「設計系タスク」を集約したバックログ。
実装タスクではなく、仕様確定・運用方針・契約定義・安全性要件の確定を対象にする。

> **🏁 Round 1 + Round 2 + Round 3 + Round 4 全P0完了 (2026-03-15)**
> **Round 1**: 5観点マルチエージェントレビュー → DT-095~DT-129 (35件)。P0全7件即時修正済み。
> **Round 2**: 5観点再レビュー (Security/Projection/Cross-doc/UX/Ops) + Composition Layer 設計
> → DT-130~DT-146 (17件)。全17件修正済み。
> **Round 3**: 全体再レビュー → DT-147~DT-160 (14件)。全14件完了。
> → Account-Scoped Cashflow Model (DT-159), Design Principle #3 (安全側に倒す) を新規策定。
> **Round 4**: DT-159導入後の再レビュー → DT-161~DT-197 (37件)。P0全10件 + P1 14件修正済み。
> → IDOR trigger, aggregate dedup, Layer B SP, EXIF JST, watch_expiry, daily budget→予測残高,
>   API auth RLS統一, bootstrap 30日+batch検知, alert dedup, source traceability
> Total DTs: 197 (94 original + 35 R1 + 17 R2 + 14 R3 + 37 R4)。全P0完了。
> 残り未解決: P1 2件 (DT-184 last_used_at alerting, DT-192 N+1 loop) + P2 2件。
> ⚠️ 注: これは**設計クローズ** (spec/schema/scaffolding) であり、**runtime検証**はまだ。
> migration適用・実装・E2Eテストによる動作検証が次フェーズ。
>
> **横断的設計原則** (詳細は `CLAUDE.md`):
> 1. 「静かに穴が空く」設計は最大のNG
> 2. Stale Data Must Look Stale (`data_as_of` アーキテクチャ設計済み)
> 3. タイムゾーンは `Asia/Tokyo` を明示的に使用

## 1. 優先度定義

- `P0`: 実装開始前に確定必須
- `P1`: 実装と並行で確定可 (ただし早めに固定)
- `P2`: Phase 5+ または将来対応

## 2. 残タスク (全件)

| ID | Pri | 領域 | 残タスク | 完了条件 (DoD) | 参照 |
|---|---|---|---|---|---|
| DT-001 | ~~P0~~ ✅ | Gmail Webhook | ~~Pub/Sub OIDC検証仕様の固定~~ **設計+実装完了 (2026-03-11)**: iss/aud/exp/email_verified検証、JWKS署名検証、401応答仕様確定。**セキュリティ修正 (同日)**: PUBSUB_AUDIENCE未設定時fail-closed化、expクレーム必須化 | 完了 | `docs/deep-dive/02-gmail-integration.md:§9a-9d`, `supabase/functions/handle-email-webhook/index.ts` |
| DT-002 | ~~P0~~ ✅ | 冪等性 | ~~`message.messageId` の重複排除仕様~~ **設計+実装完了 (2026-03-11)**: DB保存 (processed_webhook_messages)、TTL 7日。**構造修正 (同日)**: 1フェーズ→2フェーズ冪等性に変更 (pending→done)。クラッシュ時のサイレントドロップを防止 | 完了 | `docs/deep-dive/02-gmail-integration.md:§9e`, `supabase/functions/handle-email-webhook/index.ts` |
| DT-003 | ~~P0~~ ✅ | Gmail履歴 | ~~`HISTORY_ID_EXPIRED` 時の復旧範囲最終仕様~~ **設計完了 (2026-03-11)**: Tier別件数 (100/300/500)、日数窓なし (件数で十分)、raw_hash重複排除、historyId上書きリセット、last_resync_at追記 | 完了 | `docs/deep-dive/02-gmail-integration.md:§3a Step5` |
| DT-004 | ~~P0~~ ✅ | メール抽出 | ~~ライフカード請求案内の抽出ルール安定化~~ **設計完了 (2026-03-11)**: 実メール2通 (利用通知+請求案内) から正規表現・送信元・エンコーディング仕様を確定。JIS X 0201半角カナ対応デコーダ設計済み。フィクスチャ定義追加 | 完了 | `docs/deep-dive/01-email-parser.md:§3c,§3c-2` |
| DT-005 | ~~P0~~ ✅ | スケジュール学習 | ~~`schedule_source/schedule_confidence` の更新ルール~~ **設計完了 (2026-03-11)**: 3段階優先度定義 (billing_email>issuer_default>manual)、upsertAccountSchedule()設計、issuerデフォルトテーブル、confidence詳細、オンボーディング連携フロー | 完了 | `DESIGN.md:financial_accounts`, `docs/deep-dive/05-projection-engine.md` |
| DT-006 | ~~P0~~ ✅ | 予測除外 | ~~未設定カードを予測から除外する際のUI/通知仕様~~ **設計完了 (2026-03-11)**: amberバナー仕様、Push通知 (1/7日/カード、3回上限)、`last_unlinked_notification_at` カラム、オンボーディング確認ステップ、再計算トリガー | 完了 | `DESIGN.md:financial_accounts`, `docs/deep-dive/05-projection-engine.md` |
| DT-007 | ~~P0~~ ✅ | Edge契約 | ~~3関数のI/O契約と実コード整合性レビュー~~ **完了 (2026-03-11)**: 型名整合 (RenewRequest→RenewGmailWatchRequest, CrawlRequest→ProactiveInboxCrawlRequest)、レスポンスフィールド差分 (skipped, target_month) 特定、auth記述追加。コード修正済み | 完了 | `supabase/functions/renew-gmail-watch/index.ts`, `supabase/functions/proactive-inbox-crawl/index.ts` |
| DT-008 | ~~P0~~ ✅ | エラー設計 | ~~共通エラーコードの運用規約~~ **設計完了 (2026-03-11)**: 7コードのretryableポリシー定義、Pub/Sub DLQ設計 (3層: Pub/Sub DLQ→system_alerts→parse_failures)、5つのアラート閾値、per-function error flow、`consecutive_failure_count`/`last_failure_at` カラム追加 | 完了 | `DESIGN.md:email_connections`, `supabase/functions/_shared/api.ts` |
| DT-009 | P1 | 能動クロール | `expected_email_rules` 初期マスタ内容の確定 | issuerごとの `subject_hint/sender_hint/day window` が投入可能なCSV/SQLで定義済み | `docs/deep-dive/02-gmail-integration.md:415`, `DESIGN.md:257` |
| DT-010 | P1 | 能動クロール | ジョブ状態遷移図の確定 (`pending/found/missed/crawled`) | 状態遷移条件と `attempt_count/next_run_at` 更新規則が図示済み | `docs/deep-dive/02-gmail-integration.md:433`, `DESIGN.md:275` |
| DT-011 | P1 | 能動クロール | コスト上限ガードの確定 | 日次上限、候補件数上限、LLM呼び出し上限がTier別に明文化 | `docs/deep-dive/02-gmail-integration.md:480` |
| DT-012 | P1 | 能動クロール | 失敗バックオフ仕様 | 指数バックオフ係数、最大遅延、`missed` 遷移条件が固定 | `docs/deep-dive/02-gmail-integration.md:488` |
| DT-013 | P1 | データ保持 | `expected_email_rules` のRLS方針最終化 | 管理者編集のみ/読み取り範囲の方針確定 (システムマスタ扱い) | `DESIGN.md:311` |
| DT-014 | P1 | セキュリティ | 能動クロール時マスキングの標準化 | `redactPII` の適用点、除外ルール、監査ログ方針が統一 | `docs/deep-dive/01-email-parser.md:645`, `docs/deep-dive/02-gmail-integration.md:524` |
| DT-015 | P1 | サジェスト | 個人化重み更新ロジックの具体化 | 学習更新頻度、減衰、cold start遷移が数式レベルで確定 | `docs/deep-dive/03-suggestion-engine.md:281` |
| DT-016 | P1 | 予測 | 予測算出の検証指標定義 | 予測誤差指標 (MAEなど)、検証期間、再学習方針が確定 | `docs/deep-dive/05-projection-engine.md:8` |
| DT-017 | P1 | サブスク | 誤検知抑制基準の確定 | 検知閾値、除外条件、ユーザー修正反映ループが定義済み | `docs/deep-dive/04-subscription-detection.md:140` |
| DT-018 | P1 | テスト設計 | 実メール匿名化フィクスチャの拡張計画 | 各カード×通知種別で必要ケースが一覧化済み | `docs/deep-dive/01-email-parser.md:1029` |
| DT-019 | P2 | セゾン対応 | セゾンの代替取得方針確定 | 案1/2/3の採否を決定し、Phase計画へ反映 | `docs/deep-dive/01-email-parser.md:968` |
| DT-020 | P2 | ETC | ETC連携の正規手段確定 | API/スクレイピング方式、法務/運用リスク整理が完了 | `DESIGN.md:546` |
| DT-021 | ~~P2~~ ✅ | 公開API | ~~外部API公開時の認可設計~~ **設計完了 (2026-03-11)**: `crd_live_` prefix APIキー + SHA-256ハッシュ、RLS付きクエリ (service_role非使用)、Tier別レート制限、MCP Server定義。`api_keys` テーブル追加 | 完了 | `docs/deep-dive/07-public-api.md`, `DESIGN.md:§6c` |
| DT-022 | ~~P0~~ ✅ | 収入予測 | ~~freee basic_pay_rule の self_only 権限アクセス可否を実機検証~~ **検証完了 (2026-03-11)**: self_only ではアクセス不可。時給は手入力で確定 | 完了 | `docs/deep-dive/06-income-projection.md:§3b` |
| DT-023 | P1 ⬇ | 収入予測 | 給与控除の概算ロジック確定 | 源泉徴収率テーブル、社保閾値 (月88,000円/年130万円) が定義済み。**E3検証で学生バイトの控除はほぼゼロと判明 (所得税¥700/月程度)。勤務給精度が十分高いため優先度をP1に下げ** | `docs/deep-dive/06-income-projection.md:§3c` |
| DT-024 | P1 | 収入予測 | Playwright実行環境の最終選定 | Browserless vs 自前 vs デバイスのコスト・制約比較が完了 | `docs/deep-dive/06-income-projection.md:§4e` |
| DT-025 | P1 | 収入予測 | セッション切れ検知→再ログインのUX設計 | Push通知文言、再ログインWebViewフロー、頻度上限が確定 | `docs/deep-dive/06-income-projection.md:§4d` |
| DT-026 | P1 | 収入予測 | confidence スコア算出ルールの詳細化 | 月初/月中/月末の閾値、予測エンジンへの反映ロジックが確定 | `docs/deep-dive/06-income-projection.md:§3d` |
| DT-027 | P2 | 収入予測 | カメラOCRシフト表取り込みの精度検証 | テスト画像セットでの認識率が確認済み | `docs/deep-dive/06-income-projection.md:§4a` |
| DT-028 | ~~P0~~ ✅ | 障害検知 | ~~壊れた接続の検知・ユーザー通知 (Dead Man's Switch)~~ **設計完了 (2026-03-11)**: `system_alerts` テーブル追加、`last_error` カラム追加、12時間ごとのpg_cronジョブで48h超のstale接続を検知→is_active=false→アラート作成。Token Lifecycle §3 にもフロー追記 | 完了 | `DESIGN.md`, `docs/deep-dive/02-gmail-integration.md:§5` |
| DT-029 | ~~P0~~ ✅ | データ整合 | ~~parsed_emails → transactions 部分書き込み防止~~ **設計+実装完了 (2026-03-11)**: `insert_parsed_email_with_transaction` ストアドプロシージャをDESIGN.mdに定義。webhook handler TODOを更新。SECURITY DEFINER で単一トランザクション保証 | 完了 | `DESIGN.md`, `supabase/functions/handle-email-webhook/index.ts` |
| DT-030 | P1 | 監査 | parse_failures テーブルの運用方針 | パーサー未対応/デコード失敗メールの記録。ユーザー通知要否、保持期間、ダッシュボード表示方針を確定 | `DESIGN.md:parse_failures` |
| DT-031 | P1 | パフォーマンス | renew-gmail-watch のバッチ並列化 | 1000+ユーザーで150秒タイムアウト回避。バッチ並列 (Promise.all) or シャード呼び出し設計 | `supabase/functions/renew-gmail-watch` |
| DT-032 | P1 | 最適化 | Gmail API クォータ最適化 | messages.get で format=metadata → From/Subject判定 → 必要時のみ本文取得。HISTORY_ID_EXPIRED時は `q="newer_than:7d (from:...)"` でフィルタ | `docs/deep-dive/02-gmail-integration.md:§3a` |
||||||| |
| | | **── 2周目レビュー発見 (2026-03-11) ──** | | | |
||||||| |
| DT-033 | ~~P0~~ ✅ | 横断設計 | ~~**データ鮮度 (data_as_of) アーキテクチャ**~~ **設計完了 (2026-03-11)**: DESIGN.mdにデータ鮮度アーキテクチャセクション追加。上流ソース別閾値定義、data_as_of算出ロジック、UI劣化表示仕様、DB反映箇所を明記。projection-response.schema.jsonに`data_as_of`, `is_stale`, `stale_sources` フィールド追加。`monthly_summaries`, `projected_incomes` 両テーブルに `data_as_of` カラム追加 | 完了 | `DESIGN.md`, `docs/contracts/projection-response.schema.json` |
| DT-034 | ~~P0~~ ✅ | 冪等性 | ~~**pending行の並行リトライ競合防止**~~ **設計+実装完了 (2026-03-11)**: `locked_until TIMESTAMPTZ` カラム追加。claimMessageIdで5分ロック、atomic UPDATE reclaim。スキーマ・コード両方に反映 | 完了 | `DESIGN.md`, `supabase/functions/handle-email-webhook/index.ts` |
| DT-035 | ~~P0~~ ✅ | 冪等性 | ~~**不正メッセージのリトライストーム防止**~~ **実装完了 (2026-03-11)**: base64デコード失敗時に `confirmMessageId()` で 'done' 化 + 400返却。Pub/Sub無限リトライを防止 | 完了 | `supabase/functions/handle-email-webhook/index.ts` |
| DT-036 | ~~P0~~ ✅ | 冪等性 | ~~**TTLクリーンアップジョブ定義 (processed_webhook_messages + pending_ec_correlations)**~~ **設計完了 (2026-03-11)**: pg_cronジョブ5本をDESIGN.mdに定義。webhook 7日TTL、EC突合 30日TTL、stale pending 24h監視、watch renewal、monthly summaries | 完了 | `DESIGN.md:pg_cronジョブ定義` |
| DT-037 | ~~P0~~ ✅ | 収入予測 | ~~**freeeトークン失効時の予測劣化処理**~~ **設計完了 (2026-03-11)**: sync-income-freee §6a にエラーハンドリング仕様追記。401/403でis_active=false+Push、confidence 0.3降格、3回連続失敗でsystem_alerts記録 | 完了 | `docs/deep-dive/06-income-projection.md:§6a` |
| DT-038 | ~~P0~~ ✅ | 収入予測 | ~~**12月年跨ぎ処理 (month=13→year+1,month=1)**~~ **設計修正完了 (2026-03-11)**: `toFreeeApiParams()` 変換関数を定義。apiMonth>12時にyear+1, month-12へ変換 | 完了 | `docs/deep-dive/06-income-projection.md:§3c` |
| DT-039 | P1 | 収入予測 | **estimateRemainingHours の引数型不整合修正** | 関数シグネチャは `WorkRecordSummary` だが呼び出し元は `DailyWorkRecord[]` を渡す。TypeScript型で検知可能だが設計docsの修正が必要 | `docs/deep-dive/06-income-projection.md:§3d` |
| DT-040 | P1 | 収入予測 | **時給期間ギャップ時のエラーハンドリング** | `calcDailyWage()` のthrowがバッチ内で握りつぶされると月給が途中で切断。エラー蓄積→projected_incomes.breakdownで可視化する設計 | `docs/deep-dive/06-income-projection.md:§3d` |
| DT-041 | ~~P0~~ ✅ | 支出予測 | ~~**月末ゼロ除算ガード**~~ **設計修正完了 (2026-03-11)**: `Math.max(1, daysBetween(...))` で最終日ガード。同時にDT-052 (JST) も適用 | 完了 | `docs/deep-dive/05-projection-engine.md:§10` |
| DT-042 | P1 | サブスク | **known_DB一致時のユーザー確認フロー** | 現設計はknown_DB一致で即サブスク登録 (Push通知なし)。誤検知→fixed_costs汚染を防ぐため、パターン検知と同様のconfirmフロー追加 | `docs/deep-dive/04-subscription-detection.md:§4` |
| DT-043 | P1 | サブスク | **支払い待ちの中間状態設計** | `next_billing_at` を過ぎて7日間は is_active=true のまま。`status='payment_pending'` 中間状態を追加し、予測エンジンで「未確認」として扱う | `docs/deep-dive/04-subscription-detection.md:§6` |
| DT-044 | P1 | pg_cron | **monthly_summaries ジョブ失敗検知** | pg_cron失敗時にサマリが古いまま残る。`last_successful_run_at` 列 or `job_runs` テーブルで監視。24h超未更新でアラート | `DESIGN.md:monthly_summaries` |
| DT-045 | ~~P0~~ ✅ | スキーマ | ~~**スキーマ不整合一括修正**~~ **完了 (2026-03-11)**: (a) `pending_ec_correlations` テーブル+RLS追加 ✅ (b) `last_resync_at` 追加済み ✅ (c) `parsed_type` カラム既存確認 ✅ (d) `transaction_line_items` RLSポリシー追加 ✅ (e) 3インデックス追加 ✅ | 完了 | `DESIGN.md` |
| DT-046 | P1 | セキュリティ | **内部関数authの専用シークレット化** | 現在service_role_key (DB全権限) を認証に使用。専用の低権限 `INTERNAL_SYNC_SECRET` に分離。漏洩時のblast radius低減 | `supabase/functions/renew-gmail-watch`, `supabase/functions/proactive-inbox-crawl` |
| DT-047 | P1 | プライバシー | **PII保持ポリシー・削除設計** | (a) `parsed_emails` のemail_subject/sender保持期間定義 (b) 全user_id FKに `ON DELETE CASCADE` (c) アカウント削除時の完全データ消去フロー (d) 個人情報保護法対応の保持期間ルール | `DESIGN.md`, 全テーブル |
| DT-048 | P1 | 堅牢化 | **update_history_id_monotonic のnon-numeric安全対策** | `last_history_id::bigint` castが非数値文字列で例外。`NULLIF + safe cast` or `TRY/CATCH` でハンドリング | `DESIGN.md` (stored procedure) |
||||||| |
| | | **── 3周目レビュー発見 (2026-03-11) ──** | | | |
||||||| |
| DT-049 | ~~P0~~ ✅ | オンボーディング | ~~**初回Gmail接続時のブートストラップinboxスキャン**~~ **設計完了 (2026-03-11)**: OAuthフロー Step 9 にbootstrap scan追加。Tier別スキャン日数、`bootstrap_completed_at` カラム、UIローディング表示を定義。スキーマにも反映済み | 完了 | `docs/deep-dive/02-gmail-integration.md:§2b`, `DESIGN.md:email_connections` |
| DT-051 | ~~P0~~ ✅ | 認証 | ~~**OAuthトークンリフレッシュ結果のDB永続化**~~ **設計完了 (2026-03-11)**: Token Lifecycle §2 にVault書き戻し必須を明記。`access_token_expires_at` カラム追加。Google refresh制限 (25回/6時間) への言及追加。スキーマ反映済み | 完了 | `docs/deep-dive/02-gmail-integration.md:§5`, `DESIGN.md:email_connections` |
| DT-052 | ~~P0~~ ✅ | 横断設計 | ~~**UTC→JST変換の統一 (日本限定アプリ)**~~ **設計+実装完了 (2026-03-11)**: DESIGN.mdにタイムゾーン規約セクション追加。CLAUDE.mdに規約追加。proactive-inbox-crawlのtargetMonth修正。projection-engineのcalculateDailyBudget修正 | 完了 | `DESIGN.md`, `CLAUDE.md`, `supabase/functions/proactive-inbox-crawl/index.ts`, `docs/deep-dive/05-projection-engine.md` |
| DT-053 | P1 | サブスク | **サブスク検知の加盟店名ファジーマッチ** | 現設計はknown_subscription_servicesとの完全一致。実際の加盟店名は `NETFLIX.COM` / `Netflix` / `ネットフリックス` 等バリエーションあり。NFKC正規化 + ローマ字/カタカナ変換 + 部分一致スコアリングが必要 | `docs/deep-dive/04-subscription-detection.md:§4` |
| DT-054 | P1 | リアルタイム | **Realtimeチャンネル名の衝突防止・クリーンアップ** | Supabase Realtimeのチャンネル名が固定文字列の場合、複数タブ・複数デバイスで衝突。`user_id:uuid` をチャンネル名に含め、アプリ非アクティブ時にunsubscribe | `docs/deep-dive/05-projection-engine.md` (リアルタイム更新セクション) |
||||||| |
| | | **── 3周目 サジェスト・カテゴリ深掘りレビュー (2026-03-11) ──** | | | |
||||||| |
| DT-055 | ~~P0~~ ✅ | サジェスト | ~~**コールドスタート時のUI出力未定義**~~ **設計完了 (2026-03-11)**: mergeSuggestions実装設計、getTimeSuggestions/getAmountSuggestions定義、merchant_name nullable化、cold start fallback (top5 system categories)、iOS SuggestionButton/banner仕様、TIME_PROFILES/AMOUNT_PROFILESをDT-059 seedカテゴリ名に整合 | 完了 | `docs/deep-dive/03-suggestion-engine.md` |
| DT-056 | ~~P0~~ ✅ | サジェスト | ~~**フィードバックループの設計欠落**~~ **設計完了 (2026-03-11)**: user_suggestion_stats正式化 (computed accuracy)、suggestion_feedback生イベントログ、update_suggestion_stat() SP、3アクション (accepted/skipped/manual_override) の記録パス、loadUserWeights()動的重み調整 (MIN_SAMPLES=10、accuracy→multiplier変換)、skipは統計未更新 (honest)。DESIGN.mdにテーブル+SP追加済み | 完了 | `DESIGN.md`, `docs/deep-dive/03-suggestion-engine.md` |
| DT-057 | ~~P0~~ ✅ | カテゴリ | ~~**未分類トランザクションの予測・サマリ扱い未定義**~~ **設計完了 (2026-03-11)**: monthly_summariesに`uncategorized`カラム追加。5つのルール定義: (1)total_expenseは常に含む (2)variable_costs=total-fixed-uncategorized (3)UIバッジ表示 (4)予測はvariableと同等扱い (5)20%超で警告 | 完了 | `DESIGN.md:monthly_summaries` |
| DT-058 | ~~P0~~ ✅ | カテゴリ | ~~**カスタムカテゴリ削除時のFK制約**~~ **修正完了 (2026-03-11)**: transactions, transaction_line_items, fixed_cost_items の全 `category_id` FK に `ON DELETE SET NULL` 追加 | 完了 | `DESIGN.md` |
| DT-059 | ~~P0~~ ✅ | カテゴリ | ~~**システムカテゴリのseedデータ不在**~~ **設計完了 (2026-03-11)**: 16件のシステムカテゴリ seed INSERT をDESIGN.mdに追加。`UNIQUE(user_id, name)` 制約追加 (DT-062も同時解決)。SF Symbol名・色・固定費フラグ・ソート順定義済み | 完了 | `DESIGN.md:categories` |
| DT-060 | P1 | サジェスト | **履歴スコアに時系列減衰なし** | `count / 10` の単純カウントで、6ヶ月前の旧住所近くの店が `score=1.0` で出続ける。`transacted_at` ベースの減衰関数が必要 | `docs/deep-dive/03-suggestion-engine.md:§3` |
| DT-061 | P1 | サジェスト | **amount=0/refund取引でサジェスト候補が空** | `Math.abs(0)` で金額レンジが `BETWEEN 0 AND 0` + `lt('amount', 0)` で矛盾。キャンセル取引にサジェストが必要かの設計判断も欠落 | `docs/deep-dive/03-suggestion-engine.md:§5` |
| DT-062 | ~~P1~~ ✅ | カテゴリ | ~~**システム/ユーザーカテゴリ同名共存**~~ **DT-059と同時解決 (2026-03-11)**: `UNIQUE(user_id, name)` 制約追加。システム (user_id=NULL) とユーザーカテゴリは名前空間が分離される。ユーザーは同名のカスタムカテゴリを作成できるが、自分のスコープ内ではUNIQUE | 完了 | `DESIGN.md:categories` |
| DT-063 | P1 | カテゴリ | **LLMカテゴリ文字列→UUID変換フォールバック未定義** | LLMが返す `suggested_category` 文字列がシステムカテゴリ名と完全一致しない場合 (表記揺れ) のハンドリング不在 | `docs/deep-dive/01-email-parser.md:§5` |
| DT-064 | P1 | カテゴリ | **バックグラウンド自動分類ジョブ未定義** | pending取引の「後日LLM自動分類」のpg_cronジョブが存在しない。トリガー条件・閾値・実行タイミング全て未定義 | `DESIGN.md:Edge Functions一覧` |
||||||| |
| | | **── 3周目 Gemini CLI レビュー (2026-03-11) ──** | | | |
||||||| |
| DT-065 | P1 | OAuth | **OAuth部分同意 (スコープ拒否) の検知** | Google同意画面で `gmail.readonly` のみ拒否可能。OAuth成功→watch()失敗のパス。`email_connections` 作成前にスコープ完全性チェック必要 | `docs/deep-dive/02-gmail-integration.md:§2b-2c` |
| DT-066 | P1 | 運用 | **メールアカウント接続数のTier別上限** | 5+アカウント接続時にrenew-gmail-watchバッチがGoogle APIレート制限 or タイムアウト。Tier別上限 (Free:1, Standard:2, Pro:5) を定義 | `DESIGN.md:email_connections`, `supabase/functions/renew-gmail-watch` |
| DT-067 | P1 | パーサー | **SMBCカード紐付け曖昧性 (last4なし)** | SMBC NLメールにカード下4桁なし。同一ユーザーが複数SMBCカード持ちの場合に取引の帰属先が不定 | `docs/deep-dive/01-email-parser.md:§3a` |
| DT-068 | P1 | パーサー | **外貨取引の金額パース** | `parseInt(amount.replace(/,/g, ''))` が小数点を無視。$10.50→10円として記録。海外利用・Apple Services等で発生 | `docs/deep-dive/01-email-parser.md:§3` |
| DT-069 | P1 | セキュリティ | **メール転送・偽装対策** | DKIM/SPF検証なし + 転送メール (Fwd:) のSubject/Body変更でパース失敗。意図的偽装で偽取引作成可能 | `docs/deep-dive/01-email-parser.md:§2` |
| DT-070 | P1 | UX | **通知の過多 (バッチ化・静音時間)** | 高頻度利用者 (コンビニ×3/日等) に即時Push通知→疲弊。通知バッチ化 or Quiet Hours設計なし | `DESIGN.md:Push通知` |
| DT-071 | P1 | 復帰 | **60日非アクティブ復帰時のデータ欠損** | resyncLimit (max 500件) が2ヶ月分のメールに不足する可能性。永続的な取引履歴の欠損→予測精度低下 | `DESIGN.md:非アクティブポリシー`, `docs/deep-dive/02-gmail-integration.md:§3a` |
| DT-072 | P2 | iOS | **オフラインキャッシュ (SwiftData)** | Supabase Realtime依存で、オフライン時に予測表示不可。60日分のprojectionをローカルキャッシュする設計なし | `docs/ui/prototypes/ProjectionViewPrototype.swift` |
||||||| |
| | | **── 局所レビュー: サブスク検知 + 予測/UI (2026-03-11) ──** | | | |
||||||| |
| DT-073 | ~~P1~~ ✅ | サブスク | ~~**subscriptions.account_id に ON DELETE SET NULL なし**~~ **修正完了 (2026-03-11)**: DT-058 と同パターン。financial_accounts 削除時にサブスクが孤立する問題を解消 | 完了 | `DESIGN.md:subscriptions` |
| DT-074 | ~~P1~~ ✅ | サブスク | ~~**subscriptions に category_id なし**~~ **修正完了 (2026-03-11)**: 予測エンジンでのカテゴリ別集計・UI表示にカテゴリ紐付けが必要。`ON DELETE SET NULL` 付きで追加 | 完了 | `DESIGN.md:subscriptions` |
| DT-075 | ~~P1~~ ✅ | サブスク | ~~**detected_from enum がスキーマとドキュメントで不整合**~~ **修正完了 (2026-03-11)**: スキーマ側を `'email_keyword', 'pattern', 'known_db', 'manual'` に修正。04-subscription-detection.md の使用値と一致 | 完了 | `DESIGN.md:subscriptions`, `docs/deep-dive/04-subscription-detection.md` |
| DT-076 | ~~P1~~ ✅ | サブスク | ~~**subscriptions に updated_at なし**~~ **修正完了 (2026-03-11)**: 金額変更・解約・再開等の変更追跡に必要。Dead Man's Switch のstale検知対象にもなる | 完了 | `DESIGN.md:subscriptions` |
| DT-077 | P1 | サブスク | **サブスク画面にデータ鮮度 (staleness) 表示なし** | Design Principle #2 違反。subscriptionsの `updated_at` と直近の取引日から staleness を算出し、UI上で「最終確認: X日前」を表示する設計が必要 | `docs/deep-dive/04-subscription-detection.md:§5` |
| DT-078 | P1 | サブスク | **解約時の監査ログ不在** | `is_active=false` への変更で旧情報が失われる。`cancelled_at TIMESTAMPTZ` カラム or 変更ログテーブルで解約履歴を保持する設計が必要 | `docs/deep-dive/04-subscription-detection.md:§6` |
| DT-079 | P1 | 予測契約 | **projection-response.schema.json の summary がオプショナル** | iOS UIは `summary.safety_status` を常時表示するが、スキーマ上は optional。required にするか、nil 時のフォールバック UI を定義する判断が必要 | `docs/contracts/projection-response.schema.json` |
| DT-080 | P1 | UI設計 | **UI仕様に is_stale / data_as_of / stale_sources の参照なし** | DT-033 で API 契約には追加済みだが、iOS UI仕様 (プロトタイプ) に degraded display のルールが未反映。Design Principle #2 違反 | `docs/ui/prototypes/ProjectionViewPrototype.swift` |
| DT-081 | P2 | 予測契約 | **daily_breakdown がオプショナル (UI前提と不一致の可能性)** | balance_bars 内の daily_breakdown は optional で正しいが (全日に必要ではない)、UIが nil ケースをハンドルしているか確認が必要 | `docs/contracts/projection-response.schema.json` |
||||||| |
| | | **── Gemini CLI 4th pass (2026-03-11) ──** | | | |
||||||| |
| DT-082 | P1 | パーサー | **MIME構造ハンドリング未定義** | multipart/alternative (text/plain無し)、multipart/mixed (添付)、S/MIME署名メール等の一般的なMIME構造への対応が未設計。DT-069はDKIM/偽装対策でありMIME構造解析は別問題 | `docs/deep-dive/01-email-parser.md` |
| DT-083 | P1 | パーサー | **card_last4 不一致時のフロー未定義** | parsed_card_last4 が financial_accounts のどのカードにもマッチしない場合の処理が未定義。account_id=NULL取引の扱い、ユーザーへのカード登録促進、予測への影響。DT-067はSMBC固有だがこれは汎用ケース | `docs/deep-dive/01-email-parser.md`, `DESIGN.md` |
| DT-084 | P1 | セキュリティ | **Supabase Vault アクセスAPI契約未定義** | vault_secret_id を参照する設計だが、Edge FunctionからのVault読み書き手段が未定義。SECURITY DEFINER SP経由のRPC呼び出しが必要。関数シグネチャ・権限・TTL・ローテーション方針が全て未指定 | `DESIGN.md`, `docs/deep-dive/02-gmail-integration.md:§5` |
| DT-085 | P1 | セキュリティ | **RLSバイパスの構造的リスク緩和策なし** | DT-046の専用シークレット化だけでは不十分。service_role使用時にuser_idフィルタ漏れ→テナント間データ漏洩の構造的リスク。SECURITY INVOKER SP必須化、データアクセス層のテナント分離パターン等の設計が必要 | `DESIGN.md`, `supabase/functions/` |
| DT-086 | P2 | 予測契約 | **trigger_event_ids/cause_event_id がマジック文字列** | `"ev_lifecard_20260327"` 形式の文字列をiOSがパースしてディープリンクに使用。フォーマット変更でクライアントがサイレントに壊れる。構造化オブジェクト or UUID+ルックアップAPIへの移行が望ましい | `docs/contracts/projection-response.schema.json` |
| DT-087 | ~~P1~~ ✅ | 公開API | ~~レート制限がインメモリで無効~~ **設計完了 (2026-03-11)**: DB側 `rate_limit_counters` テーブル + `increment_rate_limit` RPC に変更。Edge Functionはステートレスなのでインメモリは不可 | 完了 | `docs/deep-dive/07-public-api.md:§2f`, `DESIGN.md` |
| DT-088 | ~~P1~~ ✅ | 公開API | ~~POST冪等性なし~~ **設計完了 (2026-03-11)**: `Idempotency-Key` ヘッダー必須 + `api_idempotency_keys` テーブルで24h TTLキャッシュ | 完了 | `docs/deep-dive/07-public-api.md:§4a`, `DESIGN.md` |
| DT-089 | ~~P1~~ ✅ | 公開API | ~~取引リスト/サマリにdata_as_of欠落~~ **設計完了 (2026-03-11)**: 全GETレスポンスに `data_as_of` / `is_stale` を含む共通仕様。fail-closed (summaryなし=epoch=stale) | 完了 | `docs/deep-dive/07-public-api.md:§5a` |
| DT-090 | ~~P1~~ ✅ | 公開API | ~~スコープ未定義で全権限デフォルト~~ **設計完了 (2026-03-11)**: `read`/`write` 2スコープ。空配列禁止 (CHECK制約)。デフォルト `['read']` | 完了 | `docs/deep-dive/07-public-api.md:§2b`, `DESIGN.md` |
| DT-091 | ~~P1~~ ✅ | 公開API | ~~エラーコードが内部webhook用のまま~~ **設計完了 (2026-03-11)**: `PublicErrorCode` と `InternalErrorCode` を分離。NOT_FOUND, FORBIDDEN, CONFLICT, VALIDATION_ERROR 追加 | 完了 | `docs/deep-dive/07-public-api.md:§6` |
| DT-092 | ~~P1~~ ✅ | 公開API | ~~transactions テーブルに updated_at 欠落~~ **設計完了 (2026-03-11)**: `updated_at TIMESTAMPTZ DEFAULT now()` 追加。PATCH楽観的排他制御 (If-Match) の前提 | 完了 | `DESIGN.md`, `docs/deep-dive/07-public-api.md:§4b` |
| DT-093 | ~~P1~~ ✅ | 公開API | ~~projection-response.schema.json で summary が optional~~ **設計完了 (2026-03-11)**: `required` 配列に `summary` 追加 | 完了 | `docs/contracts/projection-response.schema.json` |
| DT-094 | P1 | 公開API | **auth bridge方式が未確定** | APIキー→user_id解決後のDBアクセス方法が2候補 (A: service_role+明示フィルタ, B: admin session発行) で未検証。Phase B (write API) 開始前に確定必須 | `docs/deep-dive/07-public-api.md:§3` |
| DT-095 | ~~P0~~ ✅ | DB/SP | ~~SP `insert_parsed_email_with_transaction` が `financial_account_id` 使用、テーブルは `account_id`~~ **設計修正 (2026-03-15)**: カラム名・パラメータ名を `account_id` に統一 | 完了 | `DESIGN.md` |
| DT-096 | ~~P0~~ ✅ | DB/SP | ~~SP デフォルト source `'email_auto'` が enum 外~~ **設計修正 (2026-03-15)**: `'email_detect'` に修正 | 完了 | `DESIGN.md` |
| DT-097 | ~~P0~~ ✅ | Gmail | ~~`isFinancialEmail` sender リストが parser registry と不一致~~ **設計修正 (2026-03-15)**: `01-email-parser.md` の `FINANCIAL_SENDERS` に同期。`smbc.co.jp`→削除、`qa.jcb.co.jp`/`starbucks.co.jp`/`amazon.co.jp` 追加 | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-098 | ~~P0~~ ✅ | Gmail | ~~webhook handler が `update_history_id_monotonic` をバイパス~~ **設計修正 (2026-03-15)**: bare `.update()` → `supabase.rpc('update_history_id_monotonic')` に変更 | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-099 | ~~P0~~ ✅ | OAuth | ~~`refreshTokenIfNeeded` が Vault に書き戻さない~~ **設計修正 (2026-03-15)**: `writeTokensToVault()` 呼び出し追加、`vaultSecretId` パラメータ追加 | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-100 | ~~P0~~ ✅ | DB | ~~`projected_incomes` FK が `income_connections` 定義前に参照~~ **設計修正 (2026-03-15)**: inline FK → ALTER TABLE ADD CONSTRAINT に変更 | 完了 | `DESIGN.md` |
| DT-101 | ~~P0~~ ✅ | Security | ~~全 SECURITY DEFINER 関数に `SET search_path` 未設定~~ **設計修正 (2026-03-15)**: 3関数全てに `SET search_path = public, pg_temp` + EXECUTE grant ポリシー追加 | 完了 | `DESIGN.md` |
| DT-102 | ~~P1~~ ✅ | 冪等性 | ~~`02-gmail-integration.md` inline DDL に `locked_until` 欠落~~ **設計修正 (2026-03-15)**: `locked_until TIMESTAMPTZ` 追加 + 正典参照コメント | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-103 | ~~P1~~ ✅ | LLM | ~~EC抽出プロンプトのカテゴリ名がseed dataと不一致 (5/8が未定義)~~ **設計修正 (2026-03-15)**: DESIGN.md seed の16カテゴリに整合 | 完了 | `docs/deep-dive/01-email-parser.md` |
| DT-104 | ~~P1~~ ✅ | 収入 | ~~`06-income-projection.md` DDL に孤立 `hourly_rate` カラム~~ **設計修正 (2026-03-15)**: 削除、`hourly_rate_periods` への参照コメントに置換 | 完了 | `docs/deep-dive/06-income-projection.md` |
| DT-105 | ~~P1~~ ✅ | DMS | ~~`detect-broken-connections` の UPDATE+INSERT が非アトミック + `message::jsonb` cast が TEXT カラムで失敗~~ **設計修正 (2026-03-15)**: CTE パターンに書き換え、dedup を user_id+alert_type JOIN に変更 | 完了 | `DESIGN.md` |
| DT-106 | ~~P1~~ ✅ | pg_cron | ~~`api_idempotency_keys` と `rate_limit_counters` の cleanup job 未定義~~ **設計修正 (2026-03-15)**: 2 cron entries 追加 (日次24h / 10分ごと) | 完了 | `DESIGN.md` |
| DT-107 | ~~P1~~ ✅ | 予測 | ~~銀行残高の更新メカニズムなし~~ **設計修正 (2026-03-15)**: Phase 1=手動入力+payday翌日Push nudge。`balance_updated_at` 追加、staleness判定 (payday cycle / 30d fallback)、`nudge-balance-update` pg_cron追加。Phase 2=Moneytree LINK API、Phase 3=電子決済等代行業 | 完了 | `DESIGN.md`, `docs/deep-dive/05-projection-engine.md` |
| DT-108 | ~~P1~~ ✅ | 予測 | ~~前期確定カード請求と今期オープン分の区別なし~~ **設計修正 (2026-03-15)**: `calculateCardCharges` を2レコード返却に再設計 (committed + accumulating)。`is_committed` フラグ追加 | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-109 | ~~P1~~ ✅ | UX | ~~「データ不足」状態がない~~ **設計修正 (2026-03-15)**: 三値ステータス (SETUP_REQUIRED / SAFE / WARNING) に変更。SETUP_REQUIRED時はグラフ非表示 | 完了 | `docs/deep-dive/05-projection-engine.md:§7` |
| DT-110 | ~~P1~~ ✅ | サブスク | ~~分割払いとサブスクが区別不能~~ **設計修正 (2026-03-15)**: ユーザー確認UI (3択Push: サブスク/分割払い/無視)。`subscription_type`, `expected_end_at`, `remaining_count` 追加。installment は自動終了 (解約確認Push不発火) | 完了 | `DESIGN.md`, `docs/deep-dive/04-subscription-detection.md` |
| DT-111 | P1 | 収入 | **`estimateRemainingHours` の引数型不一致 (DT-039 具体策)** | `WorkRecordSummary` 期待だが `DailyWorkRecord[]` を渡す→NaN伝播。呼び出し元で集約処理を追加 | `docs/deep-dive/06-income-projection.md:§3d` |
| DT-112 | ~~P1~~ ✅ | 予測 | ~~Daily budget が60日horizon残高で今月分を割る~~ **設計修正 (2026-03-15)**: budget window = today → min(next income, end of month)。window内の支出のみ差引 | 完了 | `docs/deep-dive/05-projection-engine.md:§10` |
| DT-113 | ~~P1~~ ✅ | サジェスト | ~~GPS信号が通知タップ時取得~~ **設計修正 (2026-03-15)**: GPS weight上限0.3、location_age>30分は無効、history/email_hint優先の方針記述 | 完了 | `docs/deep-dive/03-suggestion-engine.md:§4a` |
| DT-114 | ~~P1~~ ✅ | 収入 | ~~`next_occurs_at` 月次進行ロジックなし~~ **設計修正 (2026-03-15)**: `advance-projected-income-dates` pg_cron job 追加 (monthly/weekly) | 完了 | `DESIGN.md` |
| DT-115 | ~~P1~~ ✅ | Gmail | ~~`StarbucksParser` の type/source 不整合~~ **設計修正 (2026-03-15)**: `type: 'card_use'` → `'merchant_notification'` | 完了 | `docs/deep-dive/01-email-parser.md` |
| DT-116 | ~~P1~~ ✅ | Gmail | ~~`LifeCardBillingParser` closing_day source 誤り~~ **設計修正 (2026-03-15)**: `closing_day_source: 'issuer_default'` を分離追加 | 完了 | `docs/deep-dive/01-email-parser.md` |
| DT-117 | ~~P1~~ ✅ | スケール | ~~バッチ Edge Function の逐次全ユーザーループ問題~~ **設計修正 (2026-03-15)**: fan-out設計方針を DESIGN.md に追記。scheduler→per-user invocation パターン | 完了 | `DESIGN.md:§11` |
| DT-118 | ~~P1~~ ✅ | Playwright | ~~CAPTCHA/bot検知ページと「シフト0件」が区別不能~~ **設計修正 (2026-03-15)**: LLMレスポンスに `page_type` フィールド追加 | 完了 | `docs/deep-dive/06-income-projection.md:§4c` |
| DT-119 | ~~P1~~ ✅ | カテゴリ | ~~貯蓄振替・ATM出金・割り勘のカテゴリなし~~ **設計修正 (2026-03-15)**: `'貯蓄・投資'`, `'振込・送金'` をseedに追加 (計18カテゴリ)。通常の支出カテゴリとして扱う (is_transfer不要) | 完了 | `DESIGN.md` |
| DT-120 | ~~P1~~ ✅ | 予測 | ~~payday が祝日/土日の場合の前倒しロジックなし~~ **設計修正 (2026-03-15)**: `payday_adjustment` フィールド追加 (prev_business_day/next_business_day/exact) | 完了 | `DESIGN.md` |
| DT-121 | ~~P1~~ ✅ | サブスク | ~~価格改定で phantom 重複 subscription 作成~~ **設計修正 (2026-03-15)**: `createOrUpdateSubscription` を merchant name ベース lookup + 金額変更通知に再設計 | 完了 | `docs/deep-dive/04-subscription-detection.md` |
| DT-122 | ~~P1~~ ✅ | オンボーディング | ~~Bootstrap scan が前期取引を今期に取り込む~~ **設計修正 (2026-03-15)**: `source = 'bootstrap_import'` タグ + closing_day ベース period filter の方針追記 | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-123 | ~~P1~~ ✅ | Gmail | ~~historyId bypass 修正に伴う横断整合性~~ **検証完了 (2026-03-15)**: DT-097 (sender list) + DT-098 (RPC呼び出し) で整合済み | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-124 | ~~P1~~ ✅ | デプロイ | ~~pg_cron が DB parameter 要求 (未文書化)~~ **設計修正 (2026-03-15)**: デプロイ前提条件チェックリスト + 起動検証クエリ追加 | 完了 | `DESIGN.md:§11` |
| DT-130 | ~~P0~~ ✅ | 予測 | ~~`calculateCardCharges` caller が単数形のまま (CardCharge1件のみ)~~ **設計修正 (2026-03-15 R2)**: `calculateCardCharge` → `calculateCardCharges` (複数形)、戻り値を `push(...charges)` に変更 | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-131 | ~~P0~~ ✅ | Security | ~~Rate limit が fail-open (DB障害時に素通り)~~ **設計修正 (2026-03-15 R2)**: fail-closed に変更。DB障害時は retryable 500 を返す | 完了 | `docs/deep-dive/07-public-api.md:§2f` |
| DT-132 | ~~P0~~ ✅ | Security | ~~`increment_rate_limit` に SECURITY DEFINER 未設定~~ **設計修正 (2026-03-15 R2)**: `SECURITY DEFINER SET search_path = public, pg_temp` + EXECUTE grant 追加 | 完了 | `DESIGN.md`, `docs/deep-dive/07-public-api.md` |
| DT-133 | ~~P0~~ ✅ | Security | ~~`system_alerts` RLS無効 + Public API 公開~~ **設計修正 (2026-03-15 R2)**: RLS 有効化、`users_read_own_alerts` ポリシー追加 (user_id=auth.uid() OR NULL) | 完了 | `DESIGN.md` |
| DT-134 | ~~P0~~ ✅ | pg_cron | ~~`advance-projected-income-dates` 非冪等 + UTC使用~~ **設計修正 (2026-03-15 R2)**: CEIL式で未来日まで一気に進める冪等ロジックに変更、`(NOW() AT TIME ZONE 'Asia/Tokyo')::date` 使用 | 完了 | `DESIGN.md` |
| DT-135 | ~~P0~~ ✅ | pg_cron | ~~`subscriptions.next_billing_at` advancement job なし~~ **設計修正 (2026-03-15 R2)**: `advance-subscription-billing-dates` pg_cron 追加 (monthly/yearly + installment 自動終了) | 完了 | `DESIGN.md` |
| DT-136 | ~~P0~~ ✅ | Gmail | ~~watch renewal の `{project-id}` placeholder~~ **設計修正 (2026-03-15 R2)**: `Deno.env.get('GCP_PROJECT_ID')` に変更 | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-137 | ~~P0~~ ✅ | Gmail | ~~watch renewal failure が console.error のみ~~ **設計修正 (2026-03-15 R2)**: DT-008 パターン適用 (failure count → system_alert → deactivate + Push) | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-138 | ~~P0~~ ✅ | DMS | ~~`detect-broken-connections` dedup JOIN が user_id ベースで論理バグ~~ **設計修正 (2026-03-15 R2)**: `system_alerts.connection_id` 追加、connection_id ベース dedup に修正 | 完了 | `DESIGN.md` |
| DT-139 | ~~P0~~ ✅ | 予測 | ~~`calculateProjection` return に staleness fields 欠落~~ **設計修正 (2026-03-15 R2)**: `status`, `data_as_of`, `is_stale`, `stale_sources` の算出ロジック追加 | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-140 | ~~P0~~ ✅ | pg_cron | ~~`alert-stale-pending-messages` dedup なし → system_alerts flooding~~ **設計修正 (2026-03-15 R2)**: `NOT EXISTS` サブクエリで message_id ベース dedup 追加 | 完了 | `DESIGN.md` |
| DT-141 | ~~P0~~ ✅ | Gmail | ~~`refreshTokenIfNeeded` call site in `renewAllWatches` に `vaultSecretId` 引数漏れ~~ **設計修正 (2026-03-15 R2)**: 第2引数 `conn.vault_secret_id` 追加 | 完了 | `docs/deep-dive/02-gmail-integration.md` |
| DT-142 | ~~P0~~ ✅ | 予測 | ~~給料日に income double-count (UX-008)~~ **設計修正 (2026-03-15 R2)**: Option C (hybrid) — `next_occurs_at < today` を除外 + `balance_observed_at > income.date` も除外 | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-143 | ~~P1~~ ✅ | UX | ~~銀行残高更新がテンキー手入力のみ~~ **設計修正 (2026-03-15 R2)**: スクショOCR残高更新チャネル追加。EXIF日時判定、`balance_source`/`balance_observed_at` provenance tracking。Gemini Vision OCR | 完了 | `DESIGN.md`, `docs/deep-dive/05-projection-engine.md:§11b` |
| DT-144 | ~~P0~~ ✅ | 予測 | ~~サブスク/固定費が card_charges と二重計上 (F-006)~~ **設計修正 (2026-03-15 R2)**: Truth Strength Precedence (3層) 導入。Layer 1 (observed) > Layer 2 (committed) > Layer 3 (forecast)。クレカ払い固定費は同期間の card_charge と重複する場合 timeline から除外 | 完了 | `docs/deep-dive/05-projection-engine.md:§2a, §4` |
| DT-145 | ~~P0~~ ✅ | 予測 | ~~複数口座で1つだけstaleでも全体がcurrent表示 (UX-010)~~ **設計修正 (2026-03-15 R2)**: per-account staleness 判定。1口座でも stale なら `stale_sources` に `bank_balance:{name}` 追加。全体の `is_stale = true` | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-146 | ~~P0~~ ✅ | UX | ~~カードスケジュール未設定でSAFE表示 (UX-002)~~ **設計修正 (2026-03-15 R2)**: `closing_day`/`billing_day` 未設定のカードがある場合 `SETUP_REQUIRED` を強制。`stale_sources` に `card_schedule_missing:{name}` 追加 | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-125 | P2 | コスト | **LLMコスト見積がEC抽出・proactive crawlパスを未計上** | Tier 2 の blended cost 再計算 (現 $0.81 → 実態 $10-20) | `DESIGN.md` |
| DT-126 | P2 | Realtime | **Supabase Realtime 接続上限 (Free:200, Pro:500)** | polling fallback + Realtime を enhancement 扱いに | `docs/deep-dive/05-projection-engine.md` |
| DT-127 | P2 | スキーマ | **`projection-response.schema.json` で `stale_sources` が optional** | `required` に追加 (空配列で表現) | `docs/contracts/projection-response.schema.json` |
| DT-128 | ~~P2~~ ✅ | パフォーマンス | ~~GPS proximity query に spatial index なし~~ **設計修正 (2026-03-15)**: `idx_transactions_location` 追加 | 完了 | `DESIGN.md` |
| DT-129 | ~~P2~~ ✅ | サジェスト | ~~`AMOUNT_PROFILES` 境界値重複~~ **設計修正 (2026-03-15)**: 半開区間 + seed カテゴリ名に統一 (TIME_PROFILES含む) | 完了 | `docs/deep-dive/03-suggestion-engine.md` |
| | | | **--- Round 3 (全体再レビュー, 2026-03-15) ---** | | |
| DT-147 | ~~P0~~ ✅ | Ops | ~~CEIL式月末ドリフト (OPS-R3-001/PROJ-R3-001)~~ **設計修正 (2026-03-15 R3)**: `advance-projected-income-dates` と `advance-subscription-billing-dates` を `generate_series` カレンダー安全パターンに完全書き換え。weekly handler 追加 | 完了 | `DESIGN.md` |
| DT-148 | ~~P0~~ ✅ | Ops | ~~DMS が income_connections 未カバー~~ **設計修正 (2026-03-15 R3)**: `detect-broken-connections` CTE を email + income 両方に分離。`system_alerts.connection_id` → `email_connection_id` + `income_connection_id` に分割 | 完了 | `DESIGN.md` |
| DT-149 | ~~P0~~ ✅ | UX | ~~bootstrapDone が行存在のみチェック (UX-R3-004)~~ **設計修正 (2026-03-15 R3)**: `bootstrap_completed_at != null` でチェックするよう修正 | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-150 | ~~P0~~ ✅ | 予測 | ~~銀行のみユーザーに SETUP_REQUIRED (PROJ-R3-003)~~ **設計修正 (2026-03-15 R3)**: カード0枚なら email_connections 不要。`emailRequired = hasAnyCreditCards` | 完了 | `docs/deep-dive/05-projection-engine.md:§4` |
| DT-151 | ~~P0~~ ✅ | Security | ~~OCR: 所有権チェック前にLLM呼び出し + 出力未検証 (SEC-R3-002)~~ **設計修正 (2026-03-15 R3)**: LLM前に `account.user_id` 照合 + `type=bank` 検証。LLM出力に数値型・範囲チェック追加 | 完了 | `docs/deep-dive/05-projection-engine.md:§11b` |
| DT-152 | ~~P0~~ ✅ | Security | ~~api_idempotency_keys + rate_limit_counters RLS未有効 (SEC-R3-007/008)~~ **設計修正 (2026-03-15 R3)**: 両テーブルに `ENABLE ROW LEVEL SECURITY` 追加 (ポリシーなし = service_role のみ) | 完了 | `DESIGN.md` |
| DT-153 | ~~P0~~ ✅ | Security | ~~system_alerts RLS に `user_id IS NULL` (SEC-R3-003)~~ **設計修正 (2026-03-15 R3)**: `OR user_id IS NULL` 削除。system-wide alerts は service_role (ops) のみ | 完了 | `DESIGN.md` |
| DT-154 | ~~P0~~ ✅ | Security | ~~isFinancialEmail subdomain spoofing (SEC-R3-005)~~ **設計修正 (2026-03-15 R3)**: `String.includes()` → ドメイン抽出 + exact suffix match | 完了 | `docs/deep-dive/02-gmail-integration.md:§3b` |
| DT-155 | ~~P0~~ ✅ | XDOC | ~~4件のドキュメント間ドリフト (XDOC-R3-001/005/007/008)~~ **設計修正 (2026-03-15 R3)**: increment_rate_limit §11 SECURITY DEFINER追加、KNOWN_SUBSCRIPTIONS カテゴリ名修正 (エンタメ→娯楽、ツール→その他)、renew-gmail-watch alert に email_connection_id、data_as_of に balance_observed_at | 完了 | 07-public-api.md, 04-subscription-detection.md, 02-gmail-integration.md, 05-projection-engine.md |
| DT-156 | ~~P0~~ ✅ | 予測 | ~~calculateDailyBudget が timeline[0].running_balance を使用 (PROJ-R3-007)~~ **設計修正 (2026-03-15 R3)**: `projection.bank_balance` (truth anchor) に修正 | 完了 | `docs/deep-dive/05-projection-engine.md:§10` |
| DT-157 | ~~P1~~ ✅ | UX | ~~同日入金の income 除外粒度 (UX-R3-001)~~ **設計修正 (2026-03-15 R3)**: 2層ルール。Layer A (deterministic): 翌日以降に観測 → 除外。Layer B (heuristic): 同日観測 → 残高値から入金推定 (動的tolerance = 直近48h取引額合計, floor ¥1,000)。判定不能 → income残す (conservative)。`previous_balance` / `previous_balance_observed_at` をスキーマ追加 | 完了 | `DESIGN.md`, `docs/deep-dive/05-projection-engine.md:§4` |
| DT-158 | ~~P1~~ ✅ | UX | ~~未分類サブスク状態 (UX-R3-003)~~ **設計決定 (2026-03-15 R3)**: 自動検知サブスク = デフォルト信頼。即 projection に含める (is_active=true)。Push通知で「検知しました」→ 放置=OK、[違います]→is_active=false。新カラム不要。誤検知=支出多め=安全側の誤り (fail-safe)。検知漏れの方が Design Principle #1 違反 | 完了 | `docs/deep-dive/04-subscription-detection.md` |
| DT-159 | ~~P1~~ ✅ | 予測 | ~~複数口座の income 除外が口座単位でない (PROJ-R3-002)~~ **設計修正 (2026-03-15 R3)**: Account-Scoped Cashflow Model 導入。`projected_incomes.bank_account_id` + `financial_accounts.settlement_account_id` 追加。per-account timeline 計算 → aggregate は派生。WARNING (口座単体0割れ、移動で解決可) / CRITICAL (合計0割れ) の4段階status | 完了 | `DESIGN.md`, `docs/deep-dive/05-projection-engine.md:§4` |
| DT-160 | ~~P1~~ ✅ | UX | ~~Push通知の日次キャップ (UX-R3-006)~~ **設計決定 (2026-03-15 R3)**: ユーザー設定可能 4段階 (least/less/medium/full)。medium=デフォルト(3件/日)。quiet hours 23:00-07:00 JST。CRITICAL+broken_connectionは全レベルbypass。`users.notification_level` 追加 | 完了 | `DESIGN.md`, `docs/deep-dive/05-projection-engine.md:§6` |

## 3. 直近で着手すべき順序 (推奨)

### Tier A: 構造的欠陥 — 実装前に確定必須
~~1-10: 全完了 (2026-03-11)~~ ✅

### Tier A2: サジェスト・カテゴリの構造的欠陥 — ✅ 全完了
~~1-5: 全完了 (DT-055, DT-056, DT-057, DT-058, DT-059)~~ ✅

### Tier B: 既存P0 — ✅ 全完了
~~6. DT-005〜DT-008~~ ✅ (スケジュール・予測除外・Edge契約・エラー設計)

### Tier C: 品質・運用 (P1)
7. `DT-039`〜`DT-040` 収入予測の型/ギャップ処理
8. `DT-042`〜`DT-043` サブスク確認フロー・中間状態
9. `DT-044` pg_cronジョブ監視
10. `DT-046` 内部auth専用シークレット化
11. `DT-047` PII保持ポリシー
12. `DT-048` historyId safe cast
13. `DT-053` サブスク加盟店名ファジーマッチ
14. `DT-054` Realtimeチャンネル衝突防止
15. `DT-060`〜`DT-064` サジェスト・カテゴリ品質 (減衰、amount=0、同名、LLM変換、自動分類ジョブ)
16. `DT-065`〜`DT-071` OAuth/運用/パーサー/セキュリティ/UX/復帰
17. `DT-077`〜`DT-078` サブスク鮮度表示・解約監査
18. `DT-079`〜`DT-080` 予測API/UI鮮度表示整合
19. `DT-082`〜`DT-083` パーサー MIME構造・card_last4不一致
20. `DT-084`〜`DT-085` Vault API契約・RLSバイパス構造リスク
21. `DT-009`〜`DT-014` 能動クロール
22. `DT-030`〜`DT-032` 監査・パフォーマンス・クォータ

### Tier D: 精度改善・将来対応
23. `DT-015`〜`DT-018` 精度改善・検証設計
24. `DT-023`〜`DT-026` 収入予測の詳細化
25. `DT-019`〜`DT-021`, `DT-027` Phase 5+ 計画に編入
26. `DT-072` オフラインキャッシュ (SwiftData)
27. `DT-081`, `DT-086` 契約オプショナリティ・マジック文字列

## 4. 既知の実装雛形との対応

- `supabase/functions/handle-email-webhook/index.ts`
- `supabase/functions/renew-gmail-watch/index.ts`
- `supabase/functions/proactive-inbox-crawl/index.ts`
- `supabase/functions/_shared/api.ts`

上記ファイルにある `TODO` は、本ドキュメントの `DT-001`〜`DT-012` と対応している。

## 5. Round 4 レビュー結果 (DT-161~DT-186)

DT-159 (Account-Scoped Cashflow Model) 導入後の5観点再レビュー。

### P0 (即時修正済み ✅)

| ID | Issue | Fix |
|----|-------|-----|
| DT-161 (PROJ-R4-001) | Aggregate timeline がカード払い固定費を二重計上 | ✅ directDebitFixedCosts フィルタ追加 |
| DT-162 (PROJ-R4-002) | evaluateChargeCoverage が aggregate balance 使用 — per-account と矛盾 | ✅ evaluateChargeCoveragePerAccount に書き換え |
| DT-163 (SEC-R4-001) | settlement_account_id FK にユーザー所有権チェックなし — IDOR | ✅ trg_check_settlement_account_ownership trigger 追加 (type=bank も強制) |
| DT-164 (SEC-R4-002) | projected_incomes.bank_account_id 同様の IDOR | ✅ trg_check_income_bank_account_ownership trigger 追加 |
| DT-165 (UX-R4-001) | Layer B tolerance が未観測支出ギャップを無視 | ✅ previous_balance_observed_at > 7日 → Layer B スキップ |
| DT-166 (UX-R4-002) | EXIF DateTimeOriginal を JST オフセットなしでパース | ✅ parseExifDate に +09:00 追加 |
| DT-167 (XDOC-R4-001) | projection.card_charges は存在しない — utilization alert dead code | ✅ charge_coverages に修正 + utilization フィールド追加 |
| DT-168 (XDOC-R4-002) | GET /v1/projection レスポンス例が DT-159 未反映 | ✅ account_projections, aggregate_*, 4-value status 反映 |
| DT-169 (XDOC-R4-003) | system_alerts.income_connection_id FK が DDL にない | ✅ ALTER TABLE 追加 (ON DELETE SET NULL) |
| DT-170 (XDOC-R4-011) | previous_balance が balance update 時に未書き込み → Layer B 永久不活性 | ✅ update_bank_balance SP 追加, OCR handler を rpc 経由に変更 |

### P1 (未修正 — 実装フェーズで対応)

| ID | Issue |
|----|-------|
| DT-171 (XDOC-R4-004) | Email staleness 24h→48h統一 ✅ (P0修正に含めた) |
| DT-172 (XDOC-R4-005) | settlement_account_id が非bank口座を参照可能 ✅ (DT-163 trigger で解決) |
| DT-173 (XDOC-R4-006) | computeFreshness が単一24h閾値 — per-source に修正 ✅ (P0修正に含めた) |
| DT-174 (XDOC-R4-007) | previous_balance_observed_at が Layer B で未読 ✅ (DT-165 で解決) |
| DT-175 (XDOC-R4-008) | PATCH /v1/accounts/:id の body contract 未定義 ✅ (P0修正に含めた) |
| DT-176 (OPS-R4-003) | ~~Quiet hours 通知キュー~~ ✅ iOS側制御 (Focus/おやすみモード)。サーバーキュー不要。CRITICAL=APNs `time-sensitive` |
| DT-177 (OPS-R4-004) | ~~settlement_account_id=NULL migration~~ ✅ SETUP_REQUIRED から除外。unsettled cards は aggregate-only で動作。確認プロンプト表示 (全bank + 「口座追加」選択肢) |
| DT-178 (OPS-R4-007) | renewAllWatches が watch_expiry 未書き込み ✅ (P0修正に含めた) |
| DT-179 (OPS-R4-008) | renewAllWatches success 時に failure_count 未リセット ✅ (DT-178と同時修正) |
| DT-180 (PROJ-R4-003) | ~~fixed cost null guard~~ ✅ next_billing_at null → conservative keep |
| DT-181 (PROJ-R4-004) | ~~accumulating charge UTC~~ ✅ JST-aware upper bound に修正 |
| DT-182 (PROJ-R4-005) | CardChargeCoverage.charge_amount 符号規約 ✅ 正の絶対値で統一 |
| DT-183 (PROJ-R4-006) | ~~daily budget~~ ✅ 削除。給料日前日の予測残高 (min_projected_balance) に置き換え |
| DT-184 (SEC-R4-003) | last_used_at 更新失敗時の alerting — 実装フェーズで対応 |
| DT-185 (SEC-R4-004) | ~~API auth 方式矛盾~~ ✅ 候補B (RLS経由) で統一。DESIGN.md と 07 整合 |
| DT-186 (SEC-R4-005) | ~~resync fallback sender filter~~ ✅ bootstrap 同様の sender query 追加 |
| DT-187 (UX-R4-003) | ~~bank staleness 30d only~~ ✅ payday-relative staleness check 追加 |
| DT-188 (UX-R4-004) | ~~bootstrap サブスク検知重複~~ ✅ bootstrap 30日化 + batch 検知 + 1 Push にまとめ |
| DT-189 (UX-R4-005) | ~~projection alert 重複送信~~ ✅ system_alerts dedup + auto-resolve |
| DT-190 (XDOC-R4-012) | ~~transactions.updated_at 重複 ALTER TABLE~~ ✅ 07 から削除 |
| DT-191 (XDOC-R4-013) | ~~createOrUpdateSubscription next_billing_at 未計算~~ ✅ computeNextBilling 追加 |
| DT-192 (XDOC-R4-014) | renewAllWatches N+1 loop スケーラビリティ — 実装フェーズで対応 |
| DT-193 (XDOC-R4-015) | ~~unknownIncome dead variable~~ ✅ 削除 + コメント修正 |
| DT-194 (SEC-R4-004b) | ~~サブスク金額上書きリスク~~ ✅ ソーストレーサビリティで解決 (last_detected_email_id) |

### P2 (将来対応)

| ID | Issue |
|----|-------|
| DT-195 (OPS-R4-005) | OCR handler が projection を sync await — timeout cascade ✅ (fire-and-forget に修正済み) |
| DT-196 (OPS-R4-006) | Subscription 検知と Push が非アトミック |
| DT-197 (PROJ-R4-005) | 電子マネー (etc_card) チャージ二重計上 — Phase 1 では bank+credit_card のみなので不要。etc_card 追加時に対応 |
