# Deep Dive 02: Gmail連携アーキテクチャ

## 1. Gmail Push通知の仕組み

Gmail APIはGoogle Cloud Pub/Subを経由してリアルタイム通知を提供する。
ポーリングではなくPush型で、メール受信から数秒で通知が届く。

```
ユーザーのGmail受信
    │
    ▼ (数秒)
Google Cloud Pub/Sub Topic
    │
    ▼ Push Subscription (HTTP POST)
Supabase Edge Function: handle-email-webhook
    │
    ▼
メール取得 → パース → 通知
```

## 2. セットアップフロー

### 2a. GCP側の準備 (一度だけ)

```
1. GCPプロジェクト作成
2. Gmail API 有効化
3. Cloud Pub/Sub API 有効化
4. Pub/Sub Topic 作成
   - Topic名: projects/{project-id}/topics/credebi-gmail-push
5. Gmail APIにPub/Sub publishのIAM権限付与
   - gmail-api-push@system.gserviceaccount.com に
     Pub/Sub Publisher ロールを付与
6. Push Subscription 作成
   - Endpoint: https://{supabase-project}.supabase.co/functions/v1/handle-email-webhook
   - 認証: Pub/Sub からのリクエストにJWTが付与される → Edge Functionで検証
```

### 2b. ユーザーごとのOAuth連携フロー

```
iOS App                          Backend (Edge Function)             Google
  │                                    │                               │
  │  1. "Gmail連携" タップ               │                               │
  │  ──────────────────────►           │                               │
  │                                    │                               │
  │  2. OAuth URL生成                   │                               │
  │  ◄──────────────────────           │                               │
  │                                    │                               │
  │  3. SafariViewController           │                               │
  │     でGoogle OAuth画面表示          │                               │
  │  ────────────────────────────────────────────────────────────►     │
  │                                    │                               │
  │  4. ユーザーが許可                   │                               │
  │  ◄────────────────────────────────────────────────────────────     │
  │                                    │                               │
  │  5. Authorization Code              │                               │
  │  ──────────────────────►           │                               │
  │                                    │  6. Code → Token交換           │
  │                                    │  ────────────────────────►     │
  │                                    │  ◄────────────────────────     │
  │                                    │  access_token + refresh_token  │
  │                                    │                               │
  │                                    │  7. Vault に暗号化保存          │
  │                                    │                               │
  │                                    │  8. Gmail watch() API呼び出し  │
  │                                    │  ────────────────────────►     │
  │                                    │  ◄────────────────────────     │
  │                                    │  historyId (基準点)            │
  │                                    │                               │
  │                                    │  9. Bootstrap inbox scan       │
  │                                    │     (DT-049: 初回バックフィル)   │
  │                                    │  ────────────────────────►     │
  │                                    │  messages.list(q=newer_than)   │
  │                                    │  ◄────────────────────────     │
  │                                    │                               │
  │  10. 連携完了                       │                               │
  │  ◄──────────────────────           │                               │
```

> **DT-049: Bootstrap Inbox Scan**
>
> `watch()` は設定以降の新着のみ通知する。接続直後にledgerが空のまま表示されると
> ユーザーが「動いていない」と判断して離脱するリスクが高い。
>
> Step 9 で過去メールを初回スキャンする:
> ```
> GET /gmail/v1/users/me/messages?q="newer_than:30d from:(vpass.ne.jp OR lifecard.co.jp OR qa.jcb.co.jp)"
> ```
> - 全Tier: 30日分 (月次サブスク検知に1ヶ月分必要。UX-R4-004)
> - `raw_hash` で既存との重複排除 (watch()通知と並行で届く可能性)
> - DT-122: Bootstrap でインポートされた取引は `source = 'bootstrap_import'` タグ付与。
>   今期オープン分のみ `calculateCardCharge` に含め、前期分は `is_committed` で区別する。
>   カードの closing_day が設定済みの場合は、前期の取引を今期請求に混入させない。
> - 初回スキャン完了後:
>   1. 取引の突合 (correlation_id / is_primary) を実行
>   2. `detectSubscriptionsAfterBootstrap(userId)` で一括サブスク検知 (UX-R4-004)
>   3. `email_connections.bootstrap_completed_at` を記録
> - スキャン中はUIに「過去の利用履歴を取り込み中...」を表示

### 2c. 必要なOAuthスコープ

```
https://www.googleapis.com/auth/gmail.readonly
```

**`gmail.readonly` のみで十分**。メールの読み取りだけでよく、送信・削除・変更は不要。
ユーザーの許可画面でも「メールの閲覧」のみが表示されるため、心理的ハードルが低い。

## 3. リアルタイム通知の受信フロー

### 3a. Pub/Sub Webhook受信

```typescript
// Edge Function: handle-email-webhook

import { serve } from 'https://deno.land/std/http/server.ts'

serve(async (req: Request) => {
  // Step 1: Pub/Sub からのリクエストを検証
  const authHeader = req.headers.get('Authorization')
  if (!verifyPubSubJWT(authHeader)) {
    return new Response('Unauthorized', { status: 401 })
  }

  // Step 2: Pub/Sub メッセージをデコード
  const body = await req.json()
  const message = JSON.parse(
    atob(body.message.data)
  )
  // message = { emailAddress: "user@gmail.com", historyId: "12345" }

  // Step 3: emailAddress から user_id を特定
  const emailConnection = await supabase
    .from('email_connections')
    .select('id, user_id, vault_secret_id, last_history_id')
    .eq('provider', 'gmail')
    .eq('email_address', message.emailAddress)
    .single()

  if (!emailConnection.data) {
    // 未登録のメールアドレス → 無視
    return new Response('OK', { status: 200 })
  }

  // Step 4: Vault からOAuthトークンを復号
  const tokens = await getTokensFromVault(emailConnection.data.vault_secret_id)

  // Step 5: Gmail History API で新着メールを取得
  // historyIdが失効していたらフォールバック再同期 (DT-003 仕様確定)
  let newEmails: RawEmail[] = []
  let resyncOccurred = false
  try {
    newEmails = await fetchNewEmails(
      tokens.access_token,
      emailConnection.data.last_history_id,
      message.historyId
    )
  } catch (err) {
    if ((err as Error).message === 'HISTORY_ID_EXPIRED') {
      // ─── DT-003: HISTORY_ID_EXPIRED 復旧仕様 ───
      //
      // Gmail History API の startHistoryId が古すぎると 404 が返る。
      // これは Pub/Sub 通知が長期間受け取れなかった場合に起こる
      // (watch() 失効、サーバー障害、ユーザーの長期非アクティブ等)。
      //
      // 復旧戦略: 直近INBOXメッセージの再スキャン
      //   - 件数上限はTier別 (Free=100, Standard=300, Pro+=500)
      //   - 日数窓は設けない (件数で十分。日付フィルタはGmail API非対応)
      //   - 重複は raw_hash (SHA-256) で排除
      //     → parsed_emails.raw_hash が UNIQUE制約
      //     → 既にパース済みのメールは INSERT 時に自然に弾かれる
      //
      // last_history_id の更新:
      //   - 再同期成功後、Pub/Sub通知の historyId で上書き
      //   - これにより次回以降は通常の差分取得に戻る
      //   - もし再スキャンでもパースできるメールがゼロの場合も、
      //     historyId は更新する (次回の差分起点をリセットするため)
      //
      // エラーレスポンス (再同期自体が失敗した場合):
      //   - code: 'HISTORY_ID_EXPIRED', retryable: true
      //   - Pub/Sub は 5xx 相当を受けてリトライする
      //   - 3回連続失敗でアラート (DT-008 で閾値確定)
      //
      resyncOccurred = true
      const userTier = await getUserTier(emailConnection.data.user_id)
      const resyncLimit = getResyncLimitByTier(userTier)
      newEmails = await fetchRecentInboxEmails(tokens.access_token, resyncLimit)
    } else {
      throw err
    }
  }

  // Step 6: 各メールをパース
  // 重複メールは processEmail 内で raw_hash UNIQUE制約により自然にスキップ
  let parsedCount = 0
  let skippedCount = 0
  for (const email of newEmails) {
    const result = await processEmail(emailConnection.data.user_id, email)
    if (result === 'parsed') parsedCount++
    else if (result === 'duplicate' || result === 'irrelevant') skippedCount++
  }

  // Step 7: historyId を単調増加更新 (並行webhook対策)
  // DESIGN.md の update_history_id_monotonic SP を使い、
  // 古い historyId で新しい値を巻き戻さないことを保証する。
  // bare .update() は禁止 — 必ず RPC 経由。
  await supabase.rpc('update_history_id_monotonic', {
    p_connection_id: emailConnection.data.id,
    p_new_history_id: message.historyId,
  })

  // resync が発生した場合は last_resync_at も更新
  if (resyncOccurred) {
    await supabase
      .from('email_connections')
      .update({ last_resync_at: new Date().toISOString() })
      .eq('id', emailConnection.data.id)
  }

  return new Response('OK', { status: 200 })
})
```

### Gap Detection After Resync

resync 実行後、取得件数が resyncLimit に達した場合、
取得しきれなかったメールが存在する可能性がある。

#### 検知条件
resync_count >= resyncLimit (Tier別: Free=100, Standard=300, Pro=500)

#### アクション
1. system_alert 作成:
   - alert_type: 'resync_gap'
   - message: "{email_display}: 長期間の未接続により、一部のメールが取得できませんでした"
   - user_id: 対象ユーザー

2. projection stale_sources に追加:
   - 'resync_gap:{email_display}'

3. UI 通知 (Push):
   - title: "メール取得に関するお知らせ"
   - body: "長期間ご利用がなかったため、一部の取引が反映されていない可能性があります"
   - notification_level: 'less' 以上で配信

4. UI バナー (アプリ内):
   - projection画面の stale_sources バナーに含まれる
   - タップ → 「手動で取引を追加」画面へ

#### Design Principle #1 適用
「静かに穴が空く」を防ぐため、resync上限に達したことを
必ずユーザーに通知する。データ欠損の可能性を隠さない。

### 3b. Gmail History API でのメール取得

```typescript
async function fetchNewEmails(
  accessToken: string,
  lastHistoryId: string,
  currentHistoryId: string
): Promise<RawEmail[]> {
  // History API: 前回のhistoryIdから差分を取得
  const historyResponse = await fetch(
    `https://gmail.googleapis.com/gmail/v1/users/me/history` +
    `?startHistoryId=${lastHistoryId}` +
    `&historyTypes=messageAdded` +
    `&labelIds=INBOX`,
    {
      headers: { Authorization: `Bearer ${accessToken}` }
    }
  )

  // startHistoryId が古すぎると 404 になる。再同期へフォールバックする。
  if (historyResponse.status === 404) {
    throw new Error('HISTORY_ID_EXPIRED')
  }
  if (!historyResponse.ok) {
    throw new Error(`GMAIL_HISTORY_API_FAILED:${historyResponse.status}`)
  }
  const history = await historyResponse.json()

  if (!history.history) return []

  // 新着メッセージIDを抽出
  const messageIds = history.history
    .flatMap((h: any) => h.messagesAdded ?? [])
    .map((m: any) => m.message.id)

  // 各メッセージの詳細を取得
  const emails: RawEmail[] = []
  for (const msgId of messageIds) {
    const msg = await fetchMessage(accessToken, msgId)
    if (msg && isFinancialEmail(msg)) {
      emails.push(msg)
    }
  }

  return emails
}

async function fetchRecentInboxEmails(
  accessToken: string,
  limit: number
): Promise<RawEmail[]> {
  // SEC-R4-005: Use sender-based query filter (same as bootstrap scan at line 89),
  // not bare INBOX scan. Without this, a high-volume inbox (newsletters, GitHub, etc.)
  // exhausts the maxResults window before reaching financial emails — silent data loss.
  const senderQuery = financialSenders.map(d => `from:${d}`).join(' OR ')
  const q = encodeURIComponent(`newer_than:30d (${senderQuery})`)
  const listRes = await fetch(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages?labelIds=INBOX&maxResults=${limit}&q=${q}`,
    { headers: { Authorization: `Bearer ${accessToken}` } }
  )
  if (!listRes.ok) return []
  const listed = await listRes.json()
  const ids = (listed.messages ?? []).map((m: any) => m.id)

  const emails: RawEmail[] = []
  for (const msgId of ids) {
    const msg = await fetchMessage(accessToken, msgId)
    if (msg && isFinancialEmail(msg)) emails.push(msg)
  }
  return emails
}

async function getUserTier(userId: string): Promise<number> {
  const { data } = await supabase
    .from('users')
    .select('tier')
    .eq('id', userId)
    .single()
  return data?.tier ?? 0
}

function getResyncLimitByTier(tier: number): number {
  if (tier >= 2) return 500
  if (tier === 1) return 300
  return 100
}

// 金融関連メールかどうかのプレフィルター (不要なメールをスキップ)
function isFinancialEmail(email: RawEmail): boolean {
  // 01-email-parser.md の FINANCIAL_SENDERS と同期すること
  const financialSenders = [
    // カード発行元 (パーサー対応済み)
    'vpass.ne.jp',           // 三井住友 (SMBCParser)
    'lifecard.co.jp',        // ライフカード (LifeCardParser, LifeCardBillingParser)
    'qa.jcb.co.jp',          // JCB / JALカード (JCBParser)
    'starbucks.co.jp',       // スターバックス (StarbucksParser)
    // EC・サブスク (LLMFallback / subscription detection)
    'amazon.co.jp',
    'netflix.com',
    'spotify.com',
    'apple.com',
  ]

  // SEC-R3-005: Use exact domain suffix match, NOT String.includes().
  // includes() would match "evil-vpass.ne.jp" or "notvpass.ne.jp.attacker.com".
  // Extract domain from email address, then check if it exactly equals or
  // is a subdomain of the known financial sender domain.
  const senderDomain = extractDomainFromEmail(email.sender.toLowerCase())
  const fromKnownSender = financialSenders.some(domain =>
    senderDomain === domain || senderDomain.endsWith('.' + domain)
  )

  // OPS-R4-009: Subject keywords must NOT bypass sender check.
  // Without this guard, any promotional email with "ご利用" in the subject
  // (extremely common in Japanese commercial email) passes the filter,
  // triggering LLM parse calls and potentially false-positive transaction inserts.
  // Subject keywords are only used as a supplementary signal for known senders.
  const subjectLooksFinancial =
       email.subject.includes('ご利用')
    || email.subject.includes('ご請求金額のご案内')
    || email.subject.includes('お支払い')
    || email.subject.includes('引き落とし')
    || email.subject.includes('ご入金')
    || email.subject.includes('サブスクリプション')

  // Known sender → always process.
  // Unknown sender + financial subject → only process if domain is .co.jp or .ne.jp
  // (likely Japanese financial institution, not a random marketing sender)
  if (fromKnownSender) return true
  if (subjectLooksFinancial) {
    return senderDomain.endsWith('.co.jp') || senderDomain.endsWith('.ne.jp')
  }
  return false
}

// Extract domain from "Name <user@example.com>" or "user@example.com" format
function extractDomainFromEmail(sender: string): string {
  const match = sender.match(/@([^\s>]+)/)
  return match ? match[1].toLowerCase() : ''
}
```

## 4. watch() の維持管理

Gmail watch() は**最大7日で期限切れ**になる。日次バッチで更新が必要。

```typescript
// Edge Function: renew-gmail-watch (pg_cronで日次実行)

async function renewAllWatches() {
  const connections = await supabase
    .from('email_connections')
    .select('*')
    .eq('provider', 'gmail')
    .eq('is_active', true)

  for (const conn of connections.data ?? []) {
    const tokens = await getTokensFromVault(conn.vault_secret_id)

    // トークンリフレッシュ (必要に応じて)
    const freshTokens = await refreshTokenIfNeeded(tokens, conn.vault_secret_id)

    // watch() を再実行
    const watchResponse = await fetch(
      'https://gmail.googleapis.com/gmail/v1/users/me/watch',
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${freshTokens.access_token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          topicName: `projects/${Deno.env.get('GCP_PROJECT_ID')}/topics/credebi-gmail-push`,
          labelIds: ['INBOX']
        })
        // GCP_PROJECT_ID must be set in Edge Function secrets.
        // Fail-closed: if missing, Deno.env.get returns undefined → "projects/undefined/..."
        // → Google returns 400 → caught by !watchResponse.ok below.
      }
    )

    if (watchResponse.ok) {
      // OPS-R4-007 + OPS-R4-008: Success path — write watch_expiry and reset failure counter.
      // Without this:
      // - watch_expiry is always NULL → SEC-R3-010 expired-watch detection never fires
      // - consecutive_failure_count never resets → scattered transient failures accumulate
      //   and eventually false-positive deactivate the connection at count=5
      const watchData = await watchResponse.json()
      await supabase.from('email_connections').update({
        watch_expiry: new Date(Number(watchData.expiration)).toISOString(),
        watch_renewed_at: new Date().toISOString(),
        consecutive_failure_count: 0,
        last_error: null,
      }).eq('id', conn.id)
    } else if (!watchResponse.ok) {
      const errorBody = await watchResponse.text()
      console.error(`watch renewal failed for ${conn.id}: ${watchResponse.status} ${errorBody}`)

      // Increment failure counter (mirrors DT-008 webhook failure pattern)
      await supabase.from('email_connections').update({
        consecutive_failure_count: (conn.consecutive_failure_count ?? 0) + 1,
        last_error: `watch_renewal_${watchResponse.status}: ${errorBody.slice(0, 200)}`,
        last_failure_at: new Date().toISOString(),
      }).eq('id', conn.id)

      const failCount = (conn.consecutive_failure_count ?? 0) + 1

      // At 3 failures: insert system_alert for ops visibility
      if (failCount === 3) {
        // XDOC-R3-007: Include email_connection_id for polymorphic FK tracking
        await supabase.from('system_alerts').insert({
          user_id: conn.user_id,
          alert_type: 'broken_connection',
          email_connection_id: conn.id,
          message: `watch renewal failed ${failCount}x for connection ${conn.id}`,
        })
      }

      // At 5 failures: deactivate and notify user
      if (failCount >= 5) {
        await supabase.from('email_connections').update({
          is_active: false,
        }).eq('id', conn.id)
        await sendPush(conn.user_id, {
          title: 'メール連携が切断されました',
          body: 'Gmailとの接続に問題が発生しています。再認証してください。',
          deepLink: 'credebi://settings/email-connections',
        })
      }
    }
  }
}
```

## 5. OAuth トークン管理

```
Token Lifecycle:

1. 初回認証
   → access_token (有効期限: 1時間)
   → refresh_token (長期有効)
   → Vault に暗号化保存

2. access_token 期限切れ
   → refresh_token で新しいaccess_tokenを取得
   → Vault を更新 (DT-051: 必ずDBに永続化。in-memoryのみは禁止)
   → access_token_expires_at を email_connections に記録
   → Edge Function再起動時はVaultから最新tokenを読み直す

   重要 (DT-051): refresh後のaccess_tokenは必ずVaultに書き戻すこと。
   Edge Functionはstatelessでcold startするため、in-memory変数に保持しても
   次の呼び出しでは消失する。書き戻しに失敗した場合は次回呼び出し時に再refreshされるが、
   Google側のrefresh_token使用回数制限 (25回/6時間) に抵触するリスクがある。

3. refresh_token 失効 (ユーザーがGoogle側でアクセス取り消し等)
   → email_connections.is_active = false
   → email_connections.last_error = 'token_revoked'
   → ユーザーにPush通知「Gmail連携が切れました。再設定してください」
   → アプリ内で再OAuth誘導
   → DT-028: last_synced_at > 48h でもアラート (watch失効の検知)
```

```typescript
async function refreshTokenIfNeeded(
  tokens: { access_token: string, refresh_token: string, expires_at: string },
  vaultSecretId: string,
): Promise<typeof tokens> {
  if (new Date(tokens.expires_at) > new Date()) {
    return tokens  // まだ有効
  }

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      refresh_token: tokens.refresh_token,
      grant_type: 'refresh_token'
    })
  })

  if (!response.ok) {
    throw new Error('TOKEN_REFRESH_FAILED')
  }

  const newTokens = await response.json()
  const refreshedTokens = {
    access_token: newTokens.access_token,
    refresh_token: tokens.refresh_token,  // refresh_tokenは変わらない
    expires_at: new Date(Date.now() + newTokens.expires_in * 1000).toISOString()
  }

  // DT-051: 必ず Vault に書き戻す。
  // Edge Function は stateless — in-memory 保持だけでは次回 cold start で消失。
  // 書き戻さないと毎回 refresh が走り、Google の 25回/6h 制限に抵触する。
  await writeTokensToVault(vaultSecretId, refreshedTokens)

  return refreshedTokens
}
```

### 5a. Token Refresh Race Prevention (DT-228: Compare-and-Swap)

When two concurrent Edge Function invocations both detect an expired `access_token`
for the same `email_connection`, a naive UPDATE creates a race:

1. Worker A refreshes → gets `token_A`, writes to Vault, updates `access_token_expires_at`
2. Worker B refreshes → gets `token_B`, writes to Vault, **overwrites** `token_A`
3. Worker A's token is now invalid (Google revokes the previous access_token on refresh)

**Solution: conditional UPDATE (compare-and-swap)**

After refreshing a token, update `email_connections` with a WHERE guard on the
old expiry value:

```sql
UPDATE email_connections
SET vault_secret_id     = $new_vault_secret_id,
    access_token_expires_at = $new_expiry
WHERE id = $conn_id
  AND access_token_expires_at = $old_expiry;
```

- If the UPDATE returns **1 row**: this worker won the race. Proceed normally.
- If the UPDATE returns **0 rows**: another worker already refreshed. Re-read the
  connection row to get the latest `vault_secret_id` and use the already-refreshed
  token. Do **not** call Google's token endpoint again.

This guarantees exactly one writer succeeds. The losing worker reuses the winner's
token at zero extra cost (no wasted refresh against Google's 25-call/6h limit).

## 6. email_connections テーブル拡張

```sql
-- DESIGN.md 側に統合済み
ALTER TABLE email_connections ADD COLUMN email_address TEXT;  -- Pub/Subからの照合用
ALTER TABLE email_connections ADD COLUMN last_history_id TEXT; -- Gmail History API用
ALTER TABLE email_connections ADD COLUMN watch_expiry TIMESTAMPTZ; -- watch()期限
```

## 7. フォールバック: ポーリング

Pub/Sub webhookが失敗した場合のフォールバック。

```
pg_cron: 5分間隔

各 email_connection に対して:
  1. last_synced_at から5分以上経過していたら
  2. Gmail API で INBOX の新着をチェック
  3. 新着があれば通常のパースフローへ
```

これにより、Pub/Sub障害時もデータ欠損を防ぐ。
ただしリアルタイム性は落ちる (最大5分遅延)。

## 7b. Tier 2+: 予想タイミング未着時の能動クロール (LLM)

通常のPush/ポーリングで拾えなかった場合に、Tier 2+ のみ受信箱を能動探索する。

```text
対象例:
- ライフカード「ご請求金額のご案内」
- 月次で来るはずのカード請求/引き落とし系メール

発火条件:
1. expected_email_rules に定義されたメール種別で
2. 想定ウィンドウ内に parsed_emails が作成されなかった
3. ユーザーTierが2以上
```

```sql
-- 期待メール定義 (運用マスタ)
CREATE TABLE expected_email_rules (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider        TEXT NOT NULL,           -- 'gmail'
  issuer          TEXT NOT NULL,           -- 'life', 'smbc' など
  subject_hint    TEXT NOT NULL,           -- 例: 'ご請求金額のご案内'
  sender_hint     TEXT,                    -- 例: 'lifecard.co.jp'
  expected_day_from INT NOT NULL,          -- 例: 10
  expected_day_to   INT NOT NULL,          -- 例: 16
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ユーザー単位の監視ジョブ
CREATE TABLE expected_email_jobs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  rule_id         UUID REFERENCES expected_email_rules(id) NOT NULL,
  target_month    TEXT NOT NULL,           -- '2026-02'
  status          TEXT DEFAULT 'pending',  -- 'pending'|'found'|'missed'|'crawled'
  attempt_count   INT DEFAULT 0,
  next_run_at     TIMESTAMPTZ,
  last_error      TEXT,
  last_checked_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, rule_id, target_month)
);
```

```typescript
// Edge Function: proactive-inbox-crawl (Tier 2+)
// pg_cron: 1日2回程度 (例: 09:00 / 21:00)

async function proactiveInboxCrawl(userId: string, rule: ExpectedRule): Promise<void> {
  const tier = await getUserTier(userId)
  if (tier < 2) return

  // 1) Gmail検索で候補を絞る (まずは軽量)
  const query = [
    rule.sender_hint ? `from:${rule.sender_hint}` : '',
    `subject:${rule.subject_hint}`,
    'in:inbox newer_than:45d',
  ].filter(Boolean).join(' ')

  const candidateIds = await searchMessageIdsByGmailQuery(userId, query, 120)
  if (candidateIds.length === 0) return

  // 2) LLMで件名+snippetを一次判定 (低コスト)
  const shortlist = await llmClassifyCandidates(candidateIds, {
    mode: 'header_snippet',
    maxCandidates: 40,
  })

  // 3) 本文を取得して二次判定 + 抽出
  for (const msgId of shortlist) {
    const email = await fetchMessageForParsing(userId, msgId)
    const parsed = await parseEmailWithRulesOrLLM(email)
    if (parsed?.type === 'statement' || parsed?.transaction_type === 'billing_notice') {
      await persistParsedEmailAndTransaction(userId, parsed)
      await markExpectedJobFound(userId, rule.id)
      return
    }
  }

  await markExpectedJobCrawled(userId, rule.id)
}
```

```text
コストガード:
- Tier 2+ のみ実行
- 1ユーザー/日あたりクロール回数上限 (例: 2回)
- LLM投入前に Gmail query で候補を最大120件に制限
- 一次判定(件名+snippet) → 二次判定(本文) の2段階でAPIコストを抑制
- ジョブ失敗時は指数バックオフ (next_run_at) で再実行
- 連続失敗上限 (例: 5回) で status='missed' に遷移
```

## 8. レートリミット考慮

```
Gmail API Quotas:
  - 1ユーザーあたり: 250 quota units / 秒
  - messages.get: 5 units / リクエスト
  - history.list: 2 units / リクエスト

1000ユーザーで同時に大量メールが来ても:
  - 各ユーザーの処理は独立
  - Pub/Sub通知は自動的にスロットリングされる
  - Edge Functionの並行実行で吸収

実質的にボトルネックにはならない。
```

### Gmail API Quota Optimization (DT-032)

2段階フェッチで API quota 消費を 50-80% 削減:

#### Step 1: Metadata-only fetch
messages.get(format='metadata', metadataHeaders=['From', 'Subject'])
- API cost: 5 units/request (vs full: 50 units)
- From/Subject でカード発行元メールかどうか判定

#### Step 2: Full fetch (条件付き)
From/Subject が既知の card issuer pattern にマッチした場合のみ:
messages.get(format='full')
- 本文取得 + パース + LLM 抽出

#### HISTORY_ID_EXPIRED 時の最適化
q パラメータでフィルタ:
messages.list(q="newer_than:7d (from:lifecard.co.jp OR from:smbc-card.com OR from:rakuten-card.co.jp)")
- 全メール取得ではなく、カード関連メールのみに限定
- Tier別 resyncLimit は維持 (Free:100, Standard:300, Pro:500)

## 9. Pub/Sub OIDC 認証仕様 (DT-001)

### 9a. 概要

Google Cloud Pub/Sub の Push Subscription は、リクエストに OIDC JWT を
`Authorization: Bearer {token}` ヘッダーで付与する。
Edge Function 側でこのトークンを検証し、正当な Pub/Sub からのリクエストのみ処理する。

### 9b. 検証フロー

```
Authorization: Bearer {JWT}
                        │
                        ▼
              ┌──────────────────┐
              │ 1. JWT デコード    │
              │    (ヘッダー解析)   │
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │ 2. 署名検証       │
              │    Google公開鍵    │
              │    (JWKS endpoint)│
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │ 3. Claims検証     │
              │  iss, aud, exp,  │
              │  email_verified  │
              └────────┬─────────┘
                       │
                  OK ──┴── NG
                  │         │
                  ▼         ▼
              処理続行    401返却
```

### 9c. 検証パラメータ

```
JWT Claims:
  iss (issuer):
    - "https://accounts.google.com" または "accounts.google.com"
    - どちらも受け入れる (Google側で表記揺れあり)

  aud (audience):
    - Push Subscription 作成時に設定した値
    - 推奨: "https://{supabase-project}.supabase.co/functions/v1/handle-email-webhook"
    - 環境変数 PUBSUB_AUDIENCE に格納
    - **fail-closed**: 環境変数未設定時は 500 で拒否 (認証スキップしない)

  email_verified:
    - true であること

  exp (expiration):
    - **必須クレーム**: exp が存在しない JWT は拒否
    - 現在時刻より未来であること
    - clock skew 許容: 30秒

署名検証:
  Google の JWKS エンドポイント: https://www.googleapis.com/oauth2/v3/certs
  キャッシュ: Cache-Control ヘッダーに従う (通常6時間)
  Edge Function 起動ごとにキャッシュが消えるため、初回リクエストで必ず fetch

環境変数 (Supabase Edge Function secrets):
  PUBSUB_AUDIENCE  — aud チェック値
```

### 9d. エラーレスポンス

```
認証失敗時:
  HTTP 401 Unauthorized
  Body: { ok: false, error: { code: "UNAUTHORIZED", message: "...", retryable: false } }

  retryable: false — Pub/Sub側は401を受けるとリトライしない (正しい動作)
  ※ 200系以外のレスポンスでPub/Subはリトライするが、
    401は "メッセージが不正" なのでリトライしても意味がない

  具体的な失敗ケース:
    - Authorization ヘッダーなし → 401 "missing authorization header"
    - Bearer トークン形式不正 → 401 "invalid bearer token format"
    - 署名検証失敗 → 401 "JWT signature verification failed"
    - issuer 不一致 → 401 "invalid issuer"
    - audience 不一致 → 401 "invalid audience"
    - トークン期限切れ → 401 "token expired"
```

## 9e. 冪等性仕様 (DT-002)

### メッセージ重複排除

Pub/Sub は at-least-once 配信を保証するため、同一メッセージが複数回届く可能性がある。
`message.messageId` を冪等キーとして使い、重複処理を防ぐ。

```
保存先: Supabase DB (processed_webhook_messages テーブル)
  ※ Redis/KV は Supabase Edge Functions で利用不可のため DB を使用

テーブル:
  -- ※ 正典は DESIGN.md の定義。ここは概要のみ。
  CREATE TABLE processed_webhook_messages (
    message_id    TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'pending', -- 'pending' | 'done'
    locked_until  TIMESTAMPTZ,  -- DT-034: 並行retry防止
    processed_at  TIMESTAMPTZ DEFAULT now()
  );
  -- RLS不要 (Edge Functionのservice_roleからのみアクセス)

TTL: 7日間 (pg_cron で日次削除)
  DELETE FROM processed_webhook_messages
  WHERE processed_at < now() - INTERVAL '7 days';

2フェーズ冪等性 (クラッシュ安全):
  Edge Functionがクラッシュ/タイムアウトした場合に
  メッセージが静かに消えることを防ぐ。

  Phase 1 (claim): 処理開始前に status='pending' で INSERT
    - INSERT成功 → 新規メッセージ、処理続行
    - INSERT失敗 (既存 status='done') → 重複、200返却でスキップ
    - INSERT失敗 (既存 status='pending') → 前回クラッシュ、再処理を許可

  Phase 2 (confirm): 全DB書き込み成功後に status='done' に UPDATE
    - Phase 2 に到達しなかった場合、status='pending' のまま残る
    - Pub/Sub がリトライ → Phase 1 で 'retry' と判定 → 再処理

  重複時の挙動:
    - status='done' の messageId → 200 OK を返す (正常応答)
    - Pub/Sub は 200 を受けて再送を停止する
    - レスポンス: { ok: true, data: { processed_count: 0, ..., skipped: "duplicate" } }
```

## 9f. セキュリティ考慮事項

```
1. Pub/Sub Webhook の認証
   - 上記 §9a-9d の OIDC 検証を実施

2. OAuth Credentials
   - GOOGLE_CLIENT_ID / CLIENT_SECRET は Supabase Edge Function のシークレットに格納
   - クライアント (iOS) には絶対に渡さない

3. メール本文の取り扱い
   - Edge Function のメモリ上でのみ処理
   - パース完了後、本文は即座に破棄
   - parsed_emails テーブルには件名・送信元・解析結果のみ保存
   - raw_hash (SHA-256) で重複防止
   - Tier 2の能動クロールでも、LLM送信前に本文をマスキング

4. 最小権限の原則
   - gmail.readonly スコープのみ
   - INBOX ラベルのみ watch
```

## 10. Edge Function I/O 契約

```typescript
// 共通レスポンス
type ApiOk<T> = { ok: true; data: T; request_id: string }
type ApiErr = {
  ok: false
  error: {
    code:
      | 'UNAUTHORIZED'
      | 'INVALID_PAYLOAD'
      | 'TOKEN_REFRESH_FAILED'
      | 'GMAIL_HISTORY_API_FAILED'
      | 'HISTORY_ID_EXPIRED'
      | 'RATE_LIMITED'
      | 'INTERNAL_ERROR'
    message: string
    retryable: boolean
  }
  request_id: string
}
```

### 10a. `handle-email-webhook`

```typescript
// Request (Pub/Sub push body)
interface HandleEmailWebhookRequest {
  message: {
    data: string // base64(JSON): { emailAddress: string; historyId: string }
    messageId: string
    publishTime: string
  }
  subscription: string
}

// Response
type HandleEmailWebhookResponse = ApiOk<{
  processed_count: number
  parsed_count: number
  skipped_count: number
  updated_history_id: string
}> | ApiErr
```

### 10b. `renew-gmail-watch`

```typescript
// Trigger: pg_cron (internal)
interface RenewGmailWatchRequest {
  dry_run?: boolean
  limit?: number
}

type RenewGmailWatchResponse = ApiOk<{
  scanned: number
  renewed: number
  failed: number
}> | ApiErr
```

### 10c. `proactive-inbox-crawl` (Tier 2+)

```typescript
// Trigger: pg_cron or internal call
interface ProactiveInboxCrawlRequest {
  user_id?: string        // 指定時は単一ユーザーのみ
  target_month?: string   // 省略時は当月
  max_users?: number      // バッチ時の上限
  dry_run?: boolean
}

type ProactiveInboxCrawlResponse = ApiOk<{
  scanned_jobs: number
  found_jobs: number
  missed_jobs: number
  crawled_jobs: number
}> | ApiErr
```

```text
運用ルール:
- 全関数で `request_id` をログとレスポンスに出す
- 冪等性キー:
  - handle-email-webhook: `message.messageId`
  - proactive-inbox-crawl: `expected_email_jobs.id + target_month`
- `retryable=true` のみ自動リトライ対象
```

## Sources

- [Gmail API Push Notifications](https://developers.google.com/workspace/gmail/api/guides/push)
- [Gmail API users.watch() Reference](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/watch)
