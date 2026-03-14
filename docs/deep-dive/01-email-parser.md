# Deep Dive 01: メールパーサーアーキテクチャ (実メール検証済)

## 1. 実メールから判明した事実

### 送信元アドレス (設計修正)

| カード | 送信元 | 備考 |
|--------|--------|------|
| 三井住友 NL/Olive | `statement@vpass.ne.jp` | ⚠️ 当初想定の `mail@contact.vpass.ne.jp` ではない |
| ライフカード学生 | `lifeweb-entry@lifecard.co.jp` | |
| JALカード navi | `mail@qa.jcb.co.jp` | ⚠️ JCB経由で通知される (JAL独自ではない) |
| JCBカード W | `mail@qa.jcb.co.jp` | JALカードnaviと同一送信元。本文の「カード名称」で区別 |
| セゾンゴールドAMEX | **メール通知なし** | ⚠️ アプリPush通知のみ。要別対応 |
| スターバックス (店舗) | `card_admin@mx.starbucks.co.jp` | 入金通知。店舗決済と紐付け可能 |

### 件名パターン

| カード | 件名 |
|--------|------|
| 三井住友 | `ご利用のお知らせ【三井住友カード】` |
| ライフカード | `カードご利用のお知らせ` |
| JCBカード (利用) | `JCBカード／ショッピングご利用のお知らせ` |
| JCBカード (取消) | `JCBカード／ショッピング取消のお知らせ` |
| スターバックス | `[My Starbucks] スターバックス カード オンライン入金完了のお知らせ（スターバックス コーヒー ジャパン）` |

### エンコーディング

| カード | text/plain | text/html | charset |
|--------|-----------|-----------|---------|
| 三井住友 | ISO-2022-JP (7bit) | ISO-2022-JP (quoted-printable) | iso-2022-jp |
| ライフカード | ISO-2022-JP (quoted-printable) | ISO-2022-JP (quoted-printable) | ISO-2022-JP |
| JCBカード | **UTF-8** (quoted-printable) | なし (text/plainのみ) | utf-8 |
| スターバックス | なし | **UTF-8** (base64) | UTF-8 |

⚠️ **重要**: ISO-2022-JP のデコードが必須。Deno (Edge Function) では `TextDecoder('iso-2022-jp')` が必要。

---

## 2. 実メールから抽出されたデータ

### 2a. 三井住友カード VISA (NL)

```
From: statement@vpass.ne.jp
Subject: ご利用のお知らせ【三井住友カード】

デコード後テキスト:
─────────────────────────
殿下 様

いつも三井住友カードをご利用いただきありがとうございます。
お客様のカードご利用内容をお知らせいたします。

ご利用カード：三井住友カードVISA（NL）

★利用日：2026/02/17 22:43
★利用先：セブン-イレブン
★利用取引：買物
★利用金額：164円
─────────────────────────

HTMLからも同じ情報が取得可能:
- ご利用日時：2026/02/17 22:43
- セブン-イレブン（買物）
- 164円
- カード: 三井住友カードVISA（NL）

Oliveに関する注記:
「本通知はクレジットモードのご利用のお知らせです」
→ Olive Flexible Payのクレジットモード利用も同じメールで来る
```

### 2b. ライフカード (学生)

```
From: lifeweb-entry@lifecard.co.jp
Subject: カードご利用のお知らせ

デコード後テキスト:
─────────────────────────
ワタナベ　ユウマ さま

いつもライフカードをご利用いただきありがとうございます。
ご利用内容をお知らせいたします。

ご利用内容
■ご利用カード
【学生専用】ライフ・マスターカード
■ご利用者
ワタナベ　ユウマさま
■ご利用日時
2026年02月02日 17:14
■ご利用金額
840円
■ご利用先
COSTCOWHOLESALEJAPAN   SAITAMA       JPN
─────────────────────────

注意: ご利用先は国際ブランド経由のカタカナ/英字表記
例: COSTCOWHOLESALEJAPAN = コストコ
```

### 2c. JCBカード (JALカード navi) — 利用通知

```
From: mail@qa.jcb.co.jp (JCB Webmaster)
Subject: JCBカード／ショッピングご利用のお知らせ

デコード後テキスト (UTF-8):
─────────────────────────
渡邉　勇真 様
カード名称　：　ＪＡＬカードｎａｖｉ

いつもＪＡＬカードｎａｖｉをご利用いただきありがとうございます。
JCBカードのご利用がありましたのでご連絡します。

【ご利用日時(日本時間)】　2026/02/16 07:53
【ご利用金額】　4,499円
【ご利用先】　ケースフイニツト
─────────────────────────

注意:
- ご利用先はカタカナ表記 (例: ケースフイニツト = ケーズデンキ?)
- 全角英数字: ＪＡＬ、ｎａｖｉ
- 会費やサブスクでもカード利用時でなくても通知される場合あり
  例: Amazonプライム年会費 5,900円
```

### 2d. JCBカード (JALカード navi) — 取消通知

```
From: mail@qa.jcb.co.jp (JCB Webmaster)
Subject: JCBカード／ショッピング取消のお知らせ

デコード後テキスト (UTF-8):
─────────────────────────
渡邉　勇真 様
カード名称　：　ＪＡＬカードｎａｖｉ

JCBカードでのショッピングの取消がありましたので、ご連絡します。

【日時（日本時間）】　2026/02/14 19:20
【金額】- 155円（取消）
【ご利用先】　JCBクレジットご利用分（海外利用分）
─────────────────────────

注意:
- 「取消」は返金 (refund) として扱う
- 金額にマイナス記号あり
- 海外利用分でも日本国内のインターネット利用の場合あり
```

### 2e. スターバックス カード入金

```
From: card_admin@mx.starbucks.co.jp
Subject: [My Starbucks] スターバックス カード オンライン入金完了のお知らせ

デコード後 (base64 → UTF-8):
─────────────────────────
渡邉勇真様

スターバックス カード オンライン入金完了のお知らせ

取引日時：2026年2月17日（火） 17時20分
入金額：1,000円
入金後残高：1,298円
支払い方法：Apple Pay
─────────────────────────

→ これはスタバカードへのチャージ
→ Apple Pay = 三井住友NLからの決済の可能性が高い
→ ほぼ同時刻に三井住友から1,000円の利用通知が来るはず
→ 紐付けロジックで活用
```

---

## 3. パーサー実装 (実メールベース)

### 3a. メールデコードユーティリティ

```typescript
// utils/email-decoder.ts

/**
 * ISO-2022-JP エンコードされたメール本文をデコードする
 * Deno環境ではTextDecoderが使える
 */
function decodeEmailBody(rawBody: string, charset: string): string {
  if (charset.toLowerCase() === 'utf-8') {
    // quoted-printable デコード
    return decodeQuotedPrintable(rawBody)
  }

  if (charset.toLowerCase() === 'iso-2022-jp') {
    // ISO-2022-JP: $B...(B エスケープシーケンスを含む
    const bytes = decodeQuotedPrintableToBytes(rawBody)
    const decoder = new TextDecoder('iso-2022-jp')
    return decoder.decode(bytes)
  }

  // base64
  if (isBase64(rawBody)) {
    const bytes = Uint8Array.from(atob(rawBody), c => c.charCodeAt(0))
    const decoder = new TextDecoder(charset || 'utf-8')
    return decoder.decode(bytes)
  }

  return rawBody
}

function decodeQuotedPrintable(input: string): string {
  return input
    .replace(/=\r?\n/g, '')  // soft line break
    .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) =>
      String.fromCharCode(parseInt(hex, 16))
    )
}
```

### 3b. 三井住友カード パーサー

```typescript
// parsers/smbc.ts

const SMBC_TEXT_PATTERNS = {
  // ISO-2022-JPデコード後のプレーンテキストから抽出
  date:      /★利用日[：:]\s*(\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2})/,
  merchant:  /★利用先[：:]\s*(.+)/,
  txnType:   /★利用取引[：:]\s*(.+)/,
  amount:    /★利用金額[：:]\s*([\d,]+)円/,
  cardName:  /ご利用カード[：:]\s*(.+)/,
}

const SMBC_HTML_PATTERNS = {
  // HTML版からの抽出 (テキスト版のフォールバック)
  date:      /ご利用日時[：:].*?(\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2})/s,
  amount:    /(\d[\d,]*)円/,  // HTML内の大きな数字表示
}

class SMBCParser implements EmailParser {
  canParse(sender: string, subject: string): boolean {
    return (
      sender.includes('vpass.ne.jp') &&
      (subject.includes('ご利用のお知らせ') || subject.includes('三井住友カード'))
    )
  }

  async parse(email: RawEmail): Promise<ParseResult | null> {
    const body = decodeEmailBody(email.body_text, 'iso-2022-jp')

    const date = body.match(SMBC_TEXT_PATTERNS.date)?.[1]
    const merchant = body.match(SMBC_TEXT_PATTERNS.merchant)?.[1]?.trim()
    const amount = body.match(SMBC_TEXT_PATTERNS.amount)?.[1]
    const cardName = body.match(SMBC_TEXT_PATTERNS.cardName)?.[1]?.trim()
    const txnType = body.match(SMBC_TEXT_PATTERNS.txnType)?.[1]?.trim()

    if (!date || !amount) return null

    // NL / Olive 判定
    const isNL = cardName?.includes('NL') ?? false
    const isOlive = cardName?.includes('Olive') || body.includes('Oliveフレキシブルペイ')

    return {
      type: 'card_use',
      amount: -parseInt(amount.replace(/,/g, ''), 10),
      merchant: merchant ?? null,
      card_last4: null,  // SMBCテキスト版にはカード下4桁は含まれない
      card_name: cardName ?? null,
      transacted_at: this.parseDate(date),
      transaction_type: txnType ?? null,
      raw_subject: email.subject,
      raw_sender: email.sender,
      confidence: 0.95,
      metadata: {
        issuer: 'smbc',
        is_nl: isNL,
        is_olive: isOlive,
        brand: cardName?.includes('VISA') ? 'visa' : cardName?.includes('Mastercard') ? 'mastercard' : null,
      }
    }
  }

  private parseDate(dateStr: string): string {
    // "2026/02/17 22:43" → ISO8601
    const [datePart, timePart] = dateStr.split(/\s+/)
    return `${datePart.replace(/\//g, '-')}T${timePart}:00+09:00`
  }
}
```

### 3c. ライフカード パーサー

> **DT-004 実メール検証済み (2026-03-11)**
> 実際の `カードご利用のお知らせ.eml` から以下を確認:
> - Subject: `カードご利用のお知らせ` (完全一致)
> - From: `ライフカードからのお知らせ <lifeweb-entry@lifecard.co.jp>`
> - Encoding: ISO-2022-JP / quoted-printable / multipart(text+html)
> - **加盟店名は JIS X 0201 半角カナ** (`ESC ( I` エスケープ) で来る場合あり
>   → Python / Deno 標準の ISO-2022-JP デコーダは非対応。専用ハンドラ必要。
> - 例: `\x1b(I:=D:N...\x1b(B(FEP)` → `コストコホールセールジャパン(FEP)`

#### エンコーディング注意: JIS X 0201 半角カナ

ISO-2022-JP のメール本文中、加盟店名が `ESC ( I` (0x1B 0x28 0x49) で始まる
JIS X 0201 カタカナ領域にスイッチされることがある。
標準の `iso-2022-jp` コーデックはこのエスケープを認識しないため、
**デコード前に raw バイト列を走査して半角カナを Unicode に変換**する前処理が必要。

```typescript
/**
 * Decode JIS X 0201 katakana escape sequences in ISO-2022-JP byte stream.
 * ESC ( I (0x1B 0x28 0x49) switches to half-width katakana mode.
 * ESC ( B (0x1B 0x28 0x42) switches back to ASCII.
 * In katakana mode, bytes 0x21-0x5F map to U+FF61-U+FF9F.
 */
function decodeJisX0201Katakana(raw: Uint8Array): Uint8Array {
  const ESC_KANA = new Uint8Array([0x1b, 0x28, 0x49]); // ESC ( I
  const ESC_ASCII = new Uint8Array([0x1b, 0x28, 0x42]); // ESC ( B

  const result: number[] = [];
  let inKatakana = false;
  let i = 0;

  while (i < raw.length) {
    // Check for escape sequences
    if (raw[i] === 0x1b && i + 2 < raw.length) {
      if (raw[i + 1] === 0x28 && raw[i + 2] === 0x49) {
        inKatakana = true;
        i += 3;
        continue;
      }
      if (raw[i + 1] === 0x28 && raw[i + 2] === 0x42) {
        inKatakana = false;
        i += 3;
        continue;
      }
    }

    if (inKatakana && raw[i] >= 0x21 && raw[i] <= 0x5f) {
      // Map to Unicode half-width katakana U+FF61-U+FF9F
      const codePoint = 0xff61 + raw[i] - 0x21;
      // Encode as UTF-8
      if (codePoint <= 0x7ff) {
        result.push(0xc0 | (codePoint >> 6), 0x80 | (codePoint & 0x3f));
      } else {
        result.push(
          0xe0 | (codePoint >> 12),
          0x80 | ((codePoint >> 6) & 0x3f),
          0x80 | (codePoint & 0x3f),
        );
      }
    } else {
      result.push(raw[i]);
    }
    i++;
  }
  return new Uint8Array(result);
}
```

#### パターン定義

```typescript
// parsers/lifecard.ts

const LIFECARD_PATTERNS = {
  cardName:  /■ご利用カード\s*\n(.+)/,
  date:      /■ご利用日時\s*\n(\d{4}年\d{2}月\d{2}日\s+\d{2}:\d{2})/,
  amount:    /■ご利用金額\s*\n([\d,]+)円/,
  merchant:  /■ご利用先\s*\n(.+)/,
  userName:  /■ご利用者\s*\n(.+?)さま/,
}

// Sender/Subject matching (verified from real .eml)
const LIFECARD_USE_SENDER = /lifecard\.co\.jp$/;
const LIFECARD_USE_SUBJECT = /カードご利用のお知らせ/;

class LifeCardParser implements EmailParser {
  canParse(sender: string, subject: string): boolean {
    return LIFECARD_USE_SENDER.test(sender)
      && LIFECARD_USE_SUBJECT.test(subject)
  }

  async parse(email: RawEmail): Promise<ParseResult | null> {
    // Step 1: Pre-process raw bytes to handle JIS X 0201 katakana
    const preprocessed = decodeJisX0201Katakana(email.body_raw);
    // Step 2: Decode the pre-processed bytes as ISO-2022-JP
    const body = new TextDecoder('iso-2022-jp').decode(preprocessed);
    // Step 3: Normalize half-width katakana to full-width (NFKC)
    const normalized = body.normalize('NFKC');

    const date = normalized.match(LIFECARD_PATTERNS.date)?.[1]
    const amount = normalized.match(LIFECARD_PATTERNS.amount)?.[1]
    const rawMerchant = normalized.match(LIFECARD_PATTERNS.merchant)?.[1]?.trim()
    const cardName = normalized.match(LIFECARD_PATTERNS.cardName)?.[1]?.trim()

    if (!date || !amount) return null

    return {
      type: 'card_use',
      amount: -parseInt(amount.replace(/,/g, ''), 10),
      merchant: this.normalizeMerchant(rawMerchant),
      card_last4: null,
      card_name: cardName ?? null,
      transacted_at: this.parseDate(date),
      transaction_type: null,
      raw_subject: email.subject,
      raw_sender: email.sender,
      confidence: 0.95,
      metadata: {
        issuer: 'lifecard',
        brand: cardName?.includes('マスター') ? 'mastercard'
             : cardName?.includes('VISA') ? 'visa' : null,
        is_student: cardName?.includes('学生') ?? false,
        raw_merchant: rawMerchant,  // 正規化前の生データも保持
      }
    }
  }

  private parseDate(dateStr: string): string {
    // "2026年03月03日 18:59" → ISO8601
    const match = dateStr.match(/(\d{4})年(\d{2})月(\d{2})日\s+(\d{2}:\d{2})/)
    if (!match) return new Date().toISOString()
    return `${match[1]}-${match[2]}-${match[3]}T${match[4]}:00+09:00`
  }

  private normalizeMerchant(raw: string | null): string | null {
    if (!raw) return null
    // Strip trailing payment method markers like "(FEP)", "(JPN)"
    const cleaned = raw.replace(/\s*\([A-Z]{2,5}\)\s*$/, '').trim()
    // Known merchant normalization map
    const MERCHANT_MAP: Record<string, string> = {
      'コストコホールセールジャパン': 'コストコ',
      'COSTCOWHOLESALEJAPAN': 'コストコ',
      'AMAZON.CO.JP': 'Amazon',
      'AMAZONDOWNLOADS': 'Amazon (デジタル)',
      // Extensible
    }
    const key = cleaned.replace(/\s+/g, '').toUpperCase()
    return MERCHANT_MAP[key] ?? cleaned
  }
}
```

### 3c-2. ライフカード請求案内パーサー (引き落とし日の自動吸い上げ)

> **DT-004 実メール検証済み (2026-03-11)**
> 実際の `ご請求金額のご案内.eml` から以下を確認:
> - Subject: `ご請求金額のご案内` (完全一致)
> - From: `ライフカードからのお知らせ <mailadm@SVR-W05.lifecard.co.jp>`
>   → 利用通知 (`lifeweb-entry@`) とは **サブドメインが異なる**。ドメイン末尾 `lifecard.co.jp` で統一判定。
> - Encoding: ISO-2022-JP (利用通知と同じ)
> - 名前表記: 漢字+全角スペース (`渡邉　勇真さま`) ※利用通知はカタカナ
> - 複数カードの場合: `■詳細` セクション内に `カード名　金額円` が改行区切りで並ぶ

```typescript
// parsers/lifecard-billing.ts
// 件名: ご請求金額のご案内

const LIFECARD_BILLING_PATTERNS = {
  billingMonth: /(\d{4})年(\d{1,2})月分のご請求内容/,
  totalAmount:  /■合計\s*\n([\d,]+)円/,
  paymentDate:  /■支払日\s*\n\s*(\d{1,2})月(\d{1,2})日/,
  cardDetail:   /■詳細\s*\n([\s\S]+?)(?=■|━)/,   // multi-line: each line = "cardName　amount円"
  bankAccount:  /■ご利用代金のお引落口座\s*\n(.+)\n(.+)\n名義人[：:](.+?)様/,
}

// Single card detail line: "【学生専用】ライフ・マスターカード　4,070円"
const CARD_DETAIL_LINE = /(.+?)[\s　]+([\d,]+)円/;

const LIFECARD_BILLING_SENDER = /lifecard\.co\.jp$/;
const LIFECARD_BILLING_SUBJECT = /ご請求金額のご案内/;

class LifeCardBillingParser implements EmailParser {
  canParse(sender: string, subject: string): boolean {
    return LIFECARD_BILLING_SENDER.test(sender)
      && LIFECARD_BILLING_SUBJECT.test(subject)
  }

  async parse(email: RawEmail): Promise<ParseResult | null> {
    // Same encoding as usage notification (ISO-2022-JP), but no JIS X 0201 katakana concern
    const preprocessed = decodeJisX0201Katakana(email.body_raw);
    const body = new TextDecoder('iso-2022-jp').decode(preprocessed);

    const totalAmountStr = body.match(LIFECARD_BILLING_PATTERNS.totalAmount)?.[1]
    const paymentDateMatch = body.match(LIFECARD_BILLING_PATTERNS.paymentDate)
    const billingMonthMatch = body.match(LIFECARD_BILLING_PATTERNS.billingMonth)
    if (!totalAmountStr || !paymentDateMatch) return null

    const billingDay = parseInt(paymentDateMatch[2], 10)
    const billingMonth = billingMonthMatch
      ? parseInt(billingMonthMatch[2], 10)
      : null;
    const billingYear = billingMonthMatch
      ? parseInt(billingMonthMatch[1], 10)
      : null;

    // Extract per-card breakdown
    const detailBlock = body.match(LIFECARD_BILLING_PATTERNS.cardDetail)?.[1]
    const cardBreakdown: { card_name: string; amount: number }[] = []
    if (detailBlock) {
      for (const line of detailBlock.split('\n')) {
        const m = line.trim().match(CARD_DETAIL_LINE)
        if (m) {
          cardBreakdown.push({
            card_name: m[1].trim(),
            amount: parseInt(m[2].replace(/,/g, ''), 10),
          })
        }
      }
    }

    // Extract bank account info
    const bankMatch = body.match(LIFECARD_BILLING_PATTERNS.bankAccount)

    // Update account schedule from billing email
    // DT-116: closing_day=5 is an issuer default (not extracted from email),
    // but billing_day IS extracted from the email body → mixed source.
    // Use 'billing_email' for billing_day (higher priority), keep closing_day as issuer default.
    await upsertAccountSchedule({
      issuer: 'life',
      billing_day: billingDay,
      closing_day: 5, // ライフカード締め日は毎月5日 (issuer constant)
      schedule_source: 'billing_email',  // applies to billing_day
      closing_day_source: 'issuer_default',  // closing_day is not email-derived
      schedule_confidence: 0.95,
    })

    return {
      type: 'statement',
      amount: -parseInt(totalAmountStr.replace(/,/g, ''), 10),
      merchant: 'ライフカード請求',
      card_last4: null,
      card_name: cardBreakdown.length === 1 ? cardBreakdown[0].card_name : 'ライフカード',
      transacted_at: billingYear && billingMonth
        ? `${billingYear}-${String(billingMonth).padStart(2, '0')}-${String(billingDay).padStart(2, '0')}T00:00:00+09:00`
        : new Date().toISOString(),
      transaction_type: 'billing_notice',
      raw_subject: email.subject,
      raw_sender: email.sender,
      confidence: 0.95,
      metadata: {
        issuer: 'lifecard',
        billing_year: billingYear,
        billing_month: billingMonth,
        extracted_billing_day: billingDay,
        card_breakdown: cardBreakdown,
        bank_name: bankMatch?.[1]?.trim() ?? null,
        bank_branch: bankMatch?.[2]?.trim() ?? null,
      }
    }
  }
}
```

### 3d. JCBカード パーサー (JALカード navi / JCBカード W 等、JCB発行カード共通)

```typescript
// parsers/jcb.ts

const JCB_USE_PATTERNS = {
  cardName:  /カード名称\s*[：:]\s*(.+)/,
  date:      /【ご利用日時\(日本時間\)】\s*(\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2})/,
  amount:    /【ご利用金額】\s*([\d,]+)円/,
  merchant:  /【ご利用先】\s*(.+)/,
}

const JCB_CANCEL_PATTERNS = {
  cardName:  /カード名称\s*[：:]\s*(.+)/,
  date:      /【日時（日本時間）】\s*(\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2})/,
  amount:    /【金額】[- ]*([\d,]+)円/,  // マイナス記号あり
  merchant:  /【ご利用先】\s*(.+)/,
}

class JCBParser implements EmailParser {
  canParse(sender: string, subject: string): boolean {
    return sender.includes('qa.jcb.co.jp')
      && (subject.includes('JCBカード') || subject.includes('ショッピング'))
  }

  async parse(email: RawEmail): Promise<ParseResult | null> {
    // JCBはUTF-8 quoted-printable
    const body = decodeQuotedPrintableUTF8(email.body_text)
    const isCancel = email.subject.includes('取消')

    const patterns = isCancel ? JCB_CANCEL_PATTERNS : JCB_USE_PATTERNS

    const date = body.match(patterns.date)?.[1]
    const amountStr = body.match(patterns.amount)?.[1]
    const merchant = body.match(patterns.merchant)?.[1]?.trim()
    const cardName = body.match(patterns.cardName)?.[1]?.trim()

    if (!date || !amountStr) return null

    const amount = parseInt(amountStr.replace(/,/g, ''), 10)

    return {
      type: isCancel ? 'refund' : 'card_use',
      amount: isCancel ? amount : -amount,  // 取消は正(返金)、利用は負(支出)
      merchant: this.normalizeMerchant(merchant),
      card_last4: null,
      card_name: this.normalizeCardName(cardName),
      transacted_at: this.parseDate(date),
      transaction_type: isCancel ? '取消' : null,
      raw_subject: email.subject,
      raw_sender: email.sender,
      confidence: 0.95,
      metadata: {
        issuer: 'jcb',
        is_jal: cardName?.includes('ＪＡＬ') || cardName?.includes('JAL') || false,
        is_jcb_w: cardName?.includes('Ｗ') || cardName?.includes('W') || false,
        is_cancel: isCancel,
        raw_merchant: merchant,
        // カード名称で自動的にfinancial_accountsと紐付ける
        // 例: "ＪＡＬカードｎａｖｉ" → JALカードnavi
        //     "ＪＣＢカードＷ" → JCBカードW
      }
    }
  }

  private normalizeCardName(name: string | null): string | null {
    if (!name) return null
    // 全角英数字を半角に変換
    return name.replace(/[Ａ-Ｚａ-ｚ０-９]/g, c =>
      String.fromCharCode(c.charCodeAt(0) - 0xFEE0)
    )
    // ＪＡＬカードｎａｖｉ → JALカードnavi
  }

  private normalizeMerchant(raw: string | null): string | null {
    if (!raw) return null
    const MERCHANT_MAP: Record<string, string> = {
      'ケースフイニツト': 'ケーズデンキ',
      // JCBはカタカナ表記が独特。追加していく
    }
    return MERCHANT_MAP[raw] ?? raw
  }

  private parseDate(dateStr: string): string {
    const [datePart, timePart] = dateStr.split(/\s+/)
    return `${datePart.replace(/\//g, '-')}T${timePart}:00+09:00`
  }
}
```

### 3e. スターバックス入金パーサー (マーチャント通知)

```typescript
// parsers/starbucks.ts

const STARBUCKS_PATTERNS = {
  date:    /取引日時[：:]\s*(\d{4}年\d{1,2}月\d{1,2}日（.）\s+\d{1,2}時\d{1,2}分)/,
  amount:  /入金額[：:]\s*([\d,]+)円/,
  balance: /入金後残高[：:]\s*([\d,]+)円/,
  payment: /支払い方法[：:]\s*(.+)/,
}

class StarbucksParser implements EmailParser {
  canParse(sender: string, subject: string): boolean {
    return sender.includes('starbucks.co.jp')
      && subject.includes('入金完了')
  }

  async parse(email: RawEmail): Promise<ParseResult | null> {
    // base64 HTML → デコード → テキスト化
    const body = decodeBase64HTML(email.body_html)

    const date = body.match(STARBUCKS_PATTERNS.date)?.[1]
    const amount = body.match(STARBUCKS_PATTERNS.amount)?.[1]
    const balance = body.match(STARBUCKS_PATTERNS.balance)?.[1]
    const payment = body.match(STARBUCKS_PATTERNS.payment)?.[1]?.trim()

    if (!date || !amount) return null

    return {
      type: 'merchant_notification',  // DT-115: correlation engine の source フィルタと整合
      amount: -parseInt(amount.replace(/,/g, ''), 10),
      merchant: 'スターバックス',
      card_last4: null,
      card_name: null,
      transacted_at: this.parseDate(date),
      transaction_type: 'オンライン入金',
      raw_subject: email.subject,
      raw_sender: email.sender,
      confidence: 0.90,
      metadata: {
        source_type: 'merchant_notification',  // ← カード通知ではなく店舗通知
        payment_method: payment,  // "Apple Pay"
        starbucks_balance_after: balance ? parseInt(balance.replace(/,/g, ''), 10) : null,
        correlatable: true,  // カード利用通知と突合可能フラグ
      }
    }
  }

  private parseDate(dateStr: string): string {
    // "2026年2月17日（火） 17時20分" → ISO8601
    const match = dateStr.match(/(\d{4})年(\d{1,2})月(\d{1,2})日.*?(\d{1,2})時(\d{1,2})分/)
    if (!match) return new Date().toISOString()
    const [, y, m, d, h, min] = match
    return `${y}-${m.padStart(2,'0')}-${d.padStart(2,'0')}T${h.padStart(2,'0')}:${min.padStart(2,'0')}:00+09:00`
  }
}
```

---

## 4. 通知突合システム

カード利用通知メールと、店舗/ECサイトからの注文確認メールを紐付けて、
「何を買ったか」を自動補完し、二重計上を防止する。

### 4a. マーチャント通知突合 — ルールベース (全Tier)

```
ユースケース: スターバックスカードにApple Payで1,000円入金
  → 2通のメールが届く:
     (A) スターバックス: 「入金完了 1,000円 Apple Pay」
     (B) 三井住友NL: 「利用通知 1,000円 スターバックス」

突合ロジック:
  1. (A) merchant_notification として transaction 作成
  2. (B) card_use として transaction 作成
  3. 同一ユーザー × 同一金額 × 時間差5分以内 をマッチング
  4. マッチした場合:
     - card_use の merchant_name を「スターバックス (カード入金)」に更新
     - merchant_notification 側に紐付け (correlation_id)
     - ユーザーにはカード側の1件として表示 (二重計上しない)

コスト: $0 (ルールベースパーサー)
対象: StarbucksParser 等の既知マーチャントパーサー
```

### 4b. EC注文メール突合 — LLM抽出 (Tier 2+)

```
ユースケース: Amazonで3,980円の本を購入
  → 2通のメールが届く:
     (A) Amazon: 「ご注文の確認 ○○○○ ¥3,980」
     (B) JCBカードW: 「利用通知 3,980円 AMAZON.CO.JP」

突合ロジック:
  1. (A) をLLMで解析 → 金額 + 商品名 + 注文日時を抽出
  2. (B) card_use の transaction と金額マッチング
  3. マッチした場合:
     - card_use の description に商品名を追加 (例: 「○○○○」)
     - card_use の category_id を商品カテゴリでサジェスト
     - EC通知側は is_primary = false (二重計上しない)

コスト: LLM API呼び出し ($0.00005/メール @ Gemini 2.5 Flash-Lite)
制限: Tier 2+ のみ (メールをAPIに流すコスト負担のため)
```

#### EC注文メール対応送信元

```typescript
// EC系メールの送信元フィルタ (Tier 2+)
const EC_SENDERS = [
  // 大手EC
  { domain: 'amazon.co.jp',       name: 'Amazon',     subject_hint: '注文' },
  { domain: 'amazon.com',         name: 'Amazon',     subject_hint: 'order' },
  { domain: 'rakuten.co.jp',      name: '楽天市場',    subject_hint: '注文確認' },
  { domain: 'shopping.yahoo.co.jp', name: 'Yahoo!ショッピング', subject_hint: '注文' },
  { domain: 'zozo.jp',            name: 'ZOZOTOWN',   subject_hint: '注文' },
  { domain: 'yodobashi.com',      name: 'ヨドバシ',   subject_hint: '注文' },
  { domain: 'biccamera.com',      name: 'ビックカメラ', subject_hint: '注文' },
  { domain: 'uniqlo.com',         name: 'ユニクロ',   subject_hint: '注文' },

  // デジタル
  { domain: 'email.apple.com',    name: 'Apple',      subject_hint: '領収書' },
  { domain: 'googleplay.com',     name: 'Google Play', subject_hint: 'receipt' },

  // フードデリバリー
  { domain: 'uber.com',           name: 'Uber Eats',  subject_hint: '領収書' },
  { domain: 'demae-can.com',      name: '出前館',     subject_hint: '注文' },

  // 旅行
  { domain: 'booking.com',        name: 'Booking.com', subject_hint: '予約確認' },
  { domain: 'airbnb.com',         name: 'Airbnb',     subject_hint: '予約' },
  { domain: 'jalan.net',          name: 'じゃらん',   subject_hint: '予約' },
]
```

#### LLM抽出プロンプト

```typescript
// Edge Function: parse-ec-email (Tier 2+)

const EC_EXTRACTION_PROMPT = `
以下はECサイトからの注文確認メールです。
以下の情報をJSON形式で抽出してください。

{
  "total_amount": 数値 (税込合計金額、円),
  "items": [
    {
      "name": "商品名",
      "quantity": 数値,
      "price": 数値 (円)
    }
  ],
  "order_date": "YYYY-MM-DD",
  "order_id": "注文番号 (あれば)",
  "store_name": "店舗/サービス名",
  "suggested_category": "食費|日用品|衣服|娯楽|医療|教育|美容|コンビニ|カフェ|交通費|通信費|サブスク|その他"
}

情報が見つからない場合は null としてください。
`

async function parseECEmail(
  emailBody: string,
  senderDomain: string
): Promise<ECParseResult | null> {
  // 個人情報をLLM送信前に最小化
  const redactedBody = redactPII(emailBody)

  const response = await gemini.generateContent({
    model: 'gemini-2.5-flash-lite',
    contents: [{
      role: 'user',
      parts: [{ text: `${EC_EXTRACTION_PROMPT}\n\nメール本文:\n${redactedBody}` }]
    }],
    generationConfig: {
      responseMimeType: 'application/json',
      temperature: 0.1,  // 抽出タスクなので低温
    }
  })

  try {
    return JSON.parse(response.text()) as ECParseResult
  } catch {
    return null
  }
}

function redactPII(text: string): string {
  return text
    // メールアドレス
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[REDACTED_EMAIL]')
    // 電話番号
    .replace(/0\d{1,4}-?\d{1,4}-?\d{3,4}/g, '[REDACTED_PHONE]')
    // 郵便番号
    .replace(/\b\d{3}-\d{4}\b/g, '[REDACTED_POSTAL]')
    // 住所っぽい長文を最低限マスク (都道府県起点)
    .replace(/(東京都|北海道|(?:京都|大阪)府|.{2,3}県).{6,60}/g, '[REDACTED_ADDRESS]')
}

interface ECParseResult {
  total_amount: number | null
  items: { name: string; quantity: number; price: number }[]
  order_date: string | null
  order_id: string | null
  store_name: string | null
  suggested_category: string | null
}
```

#### EC突合ロジック

```typescript
async function correlateECOrder(
  userId: string,
  ecResult: ECParseResult,
  ecEmailReceivedAt: Date
): Promise<void> {
  if (!ecResult.total_amount) return

  // カード利用通知との突合
  // EC注文は決済タイミングがずれることがある (注文確認 → 出荷時決済)
  // → 時間ウィンドウを広く取る: 前後24時間
  const timeWindow = 24 * 60 * 60 * 1000
  const txnTime = ecEmailReceivedAt.getTime()

  const candidates = await supabase
    .from('transactions')
    .select('*')
    .eq('user_id', userId)
    .eq('amount', -ecResult.total_amount)  // 支出は負の値
    .eq('source', 'email_detect')
    .gte('transacted_at', new Date(txnTime - timeWindow).toISOString())
    .lte('transacted_at', new Date(txnTime + timeWindow).toISOString())
    .is('correlation_id', null)
    .limit(5)

  if (!candidates.data?.length) {
    // マッチなし → 保留 (後でカード通知が来た時に再突合)
    await supabase.from('pending_ec_correlations').insert({
      user_id: userId,
      amount: ecResult.total_amount,
      items: ecResult.items,
      store_name: ecResult.store_name,
      suggested_category: ecResult.suggested_category,
      order_id: ecResult.order_id,
      email_received_at: ecEmailReceivedAt.toISOString(),
      expires_at: new Date(txnTime + 7 * 24 * 60 * 60 * 1000).toISOString(),  // 7日後に期限切れ
    })
    return
  }

  // 金額一致候補が見つかった場合
  // 複数候補がある場合はstore_nameとmerchant_nameの類似度で選択
  const bestMatch = selectBestMatch(candidates.data, ecResult)

  if (bestMatch) {
    // カード取引に商品情報を付与
    await supabase.from('transactions').update({
      description: formatItemDescription(ecResult.items),
      // category_id はサジェストのみ (ユーザー確認を優先)
      metadata: {
        ...bestMatch.metadata,
        ec_items: ecResult.items,
        ec_order_id: ecResult.order_id,
        ec_store: ecResult.store_name,
        ec_suggested_category: ecResult.suggested_category,
      }
    }).eq('id', bestMatch.id)
  }
}

function formatItemDescription(items: ECParseResult['items']): string {
  if (items.length === 0) return ''
  if (items.length === 1) return items[0].name
  return `${items[0].name} 他${items.length - 1}点`
}
```

#### コスト試算 (EC突合)

```
前提: Tier 2ユーザー, 月50件のEC注文メール

1メールあたり:
  Input:  ~800 tokens (メール本文 + プロンプト)
  Output: ~200 tokens (JSON)

月間コスト (1ユーザー):
  Input:  50 × 800 / 1M × $0.10 = $0.004
  Output: 50 × 200 / 1M × $0.40 = $0.004
  合計: ~$0.008/月/ユーザー ≒ ¥1.2/月

→ Tier 2 (¥1,200/月) の価格に対して十分吸収可能
→ ただしFree/Tier 1に提供するとユーザー数次第でコスト圧迫の可能性
```

#### pending_ec_correlations テーブル

```sql
-- EC注文メール解析結果の一時保管 (カード通知が後から来る場合用)
CREATE TABLE pending_ec_correlations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID REFERENCES users(id) NOT NULL,
  amount          BIGINT NOT NULL,
  items           JSONB,
  store_name      TEXT,
  suggested_category TEXT,
  order_id        TEXT,
  email_received_at TIMESTAMPTZ NOT NULL,
  matched         BOOLEAN DEFAULT false,
  transaction_id  UUID REFERENCES transactions(id),  -- マッチ後に設定
  expires_at      TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE pending_ec_correlations ENABLE ROW LEVEL SECURITY;
-- RLS: user_id = auth.uid()

-- 期限切れレコードの自動削除 (pg_cron 日次)
-- SELECT cron.schedule('cleanup-ec-correlations', '0 4 * * *',
--   $$DELETE FROM pending_ec_correlations WHERE expires_at < now()$$
-- );
```

### 4c. 突合の統合フロー

```
メール受信
    │
    ▼
[送信元判定]
    │
    ├── カード会社 (vpass.ne.jp, lifecard.co.jp, qa.jcb.co.jp)
    │   → ルールベースパーサー → transaction 作成
    │   → 突合チェック:
    │      ① pending_ec_correlations に同額マッチあるか？ (Tier 2+)
    │      ② 既存の merchant_notification と同額マッチあるか？ (全Tier)
    │
    ├── 既知マーチャント (starbucks.co.jp)
    │   → ルールベースパーサー → transaction 作成 (is_primary=false)
    │   → カード通知との即時突合
    │
    ├── ECサイト (amazon.co.jp, rakuten.co.jp, ...) [Tier 2+ のみ]
    │   → LLMで金額・商品名抽出
    │   → カード通知との突合 or pending_ec_correlations に保留
    │
    └── その他
        → サブスク検知キーワードチェック
        → LLMフォールバック (未知フォーマット)
```

### 4d. 共通突合エンジン

```typescript
// Edge Function: correlate-transactions (統合版)

async function correlateTransactions(
  userId: string,
  newTransaction: Transaction
): Promise<void> {
  // --- 全Tier: マーチャント通知突合 ---

  // マーチャント通知 → 同額のカード通知を探す
  if (newTransaction.source === 'merchant_notification') {
    const cardMatch = await findMatchingCardTransaction(userId, newTransaction, 5 * 60 * 1000)
    if (cardMatch) {
      await linkTransactions(cardMatch.id, newTransaction.id)
      return
    }
  }

  // カード通知 → 同額のマーチャント通知を探す
  if (newTransaction.source === 'email_detect') {
    const merchantMatch = await findMatchingMerchantTransaction(userId, newTransaction, 5 * 60 * 1000)
    if (merchantMatch) {
      await linkTransactions(newTransaction.id, merchantMatch.id)
    }
  }

  // --- Tier 2+: EC注文メール突合 ---

  const user = await getUser(userId)
  if (user.tier < 2) return  // Tier 0, 1 はスキップ

  if (newTransaction.source === 'email_detect') {
    // カード通知が来た → pending_ec_correlations に金額一致があるか？
    const ecMatch = await supabase
      .from('pending_ec_correlations')
      .select('*')
      .eq('user_id', userId)
      .eq('amount', Math.abs(newTransaction.amount))
      .eq('matched', false)
      .gt('expires_at', new Date().toISOString())
      .order('email_received_at', { ascending: false })
      .limit(1)

    if (ecMatch.data?.[0]) {
      const ec = ecMatch.data[0]
      // 商品情報をカード取引に付与
      await supabase.from('transactions').update({
        description: formatItemDescription(ec.items),
        metadata: {
          ...newTransaction.metadata,
          ec_items: ec.items,
          ec_order_id: ec.order_id,
          ec_store: ec.store_name,
          ec_suggested_category: ec.suggested_category,
        }
      }).eq('id', newTransaction.id)

      // pending をマッチ済みに更新
      await supabase.from('pending_ec_correlations').update({
        matched: true,
        transaction_id: newTransaction.id,
      }).eq('id', ec.id)
    }
  }
}

async function findMatchingCardTransaction(
  userId: string,
  merchantTxn: Transaction,
  timeWindowMs: number
): Promise<Transaction | null> {
  const txnTime = new Date(merchantTxn.transacted_at).getTime()

  const candidates = await supabase
    .from('transactions')
    .select('*')
    .eq('user_id', userId)
    .eq('amount', merchantTxn.amount)
    .eq('source', 'email_detect')
    .gte('transacted_at', new Date(txnTime - timeWindowMs).toISOString())
    .lte('transacted_at', new Date(txnTime + timeWindowMs).toISOString())
    .is('correlation_id', null)
    .limit(1)

  return candidates.data?.[0] ?? null
}
```

### DB拡張 (突合関連)

```sql
-- transactions テーブルに突合用カラム追加
ALTER TABLE transactions ADD COLUMN correlation_id UUID REFERENCES transactions(id);
ALTER TABLE transactions ADD COLUMN is_primary BOOLEAN DEFAULT true;
-- is_primary = false のものはUI上では非表示 (二重計上防止)

-- transactions に metadata (JSONB) を追加 (EC商品情報等)
ALTER TABLE transactions ADD COLUMN metadata JSONB DEFAULT '{}';
```

---

## 5. セゾンカード対応 (メール通知なし問題)

セゾンゴールドAMEXはメール利用通知を提供していない。
アプリのプッシュ通知のみ。

### 対応案

```
優先度: Phase 5+ (後回し)

案1: iOSの通知アクセス (UserNotifications framework)
  - セゾンカードアプリのPush通知を読み取る
  - iOS 26+でも通知アクセスには制限あり → 要調査
  - プライバシー面でハードルが高い

案2: セゾンNetアンサー (Web明細) スクレイピング
  - Tier1以上でカード明細APIの一部として対応
  - リアルタイム性は低い (日次)

案3: 手動入力 + LLMサジェスト
  - セゾンカード利用時はユーザーが手動で入力
  - GPSと時間帯でサジェスト
  - 後日明細反映時に突合

→ 当面は案3 (手動入力) で対応。
  セゾンゴールドは年1回利用で年会費無料なので利用頻度は低いはず。
```

---

## 6. パーサーレジストリ (更新版)

```typescript
// parser-registry.ts

const parsers: EmailParser[] = [
  new SMBCParser(),         // 三井住友NL / Olive
  new LifeCardParser(),     // ライフカード利用通知
  new LifeCardBillingParser(), // ライフカード請求案内 (支払日抽出)
  new JCBParser(),          // JCB発行カード共通 (JALカード navi / JCBカード W 等)
  new StarbucksParser(),    // スターバックス入金通知
  // セゾンカードはメール通知なし → パーサー不要
]

const fallback = new LLMFallbackParser()

// 金融メール判定用の送信元リスト (更新版)
const FINANCIAL_SENDERS = [
  'vpass.ne.jp',           // 三井住友
  'lifecard.co.jp',        // ライフカード
  'qa.jcb.co.jp',          // JCB (JALカード含む)
  'starbucks.co.jp',       // スターバックス
  'amazon.co.jp',          // Amazon (注文確認→サブスク検知)
  'apple.com',             // Apple (サブスク)
  'netflix.com',           // Netflix
  'spotify.com',           // Spotify
]
```

---

## 7. テスト用フィクスチャ

実メールをベースに匿名化したテストデータを作成:

```
tests/fixtures/
├── smbc-nl-convenience-store.txt      # 三井住友NL セブン 164円
├── lifecard-student-costco.txt        # ライフ学生 コストコ 7,999円 (半角カナ加盟店名)
├── lifecard-billing-feb.txt           # ライフ請求案内 2月分 4,070円
├── jcb-jal-navi-purchase.txt          # JAL navi 購入 4,499円
├── jcb-jal-navi-cancel.txt            # JAL navi 取消 -155円
├── starbucks-online-charge.txt        # スタバ入金 1,000円 Apple Pay
└── README.md                          # 各フィクスチャの説明
```

匿名化ルール:
- 氏名 → テスト太郎
- メールアドレス → test@example.com
- 金額・日時・店舗はそのまま (パーサーテストに必要)

---

## 8. 品質指標体系

パーサーの品質を3つの独立した指標で計測する。混同しないこと。

### 8a. パーサー抽出正確性 (Parser Correctness)

```text
定義: メールが検知された場合に、金額・日時・店舗名を正しく抽出できるか

目標: 100%
  - 金額: 完全一致必須。1円でもズレたらバグ
  - 日時: 完全一致必須
  - 店舗名: 原文抽出は完全一致。正規化 (表記ゆれ統合) は別指標

理由: カード会社のメールフォーマットは固定。
      正規表現が正しく書かれていれば構造的に誤抽出は起こらない。
      100%を下回ったらパーサーのバグとして即修正する。

LLMフォールバック時: confidence スコアで品質を個別追跡。
  confidence < 0.8 の場合はユーザー確認を挟む。
```

### 8b. メール取得完全性 (Ingestion Completeness)

```text
定義: カード会社が送信したメールのうち、Credebi が最終的に取得・処理できた割合

目標: 100% (eventual completeness)

取得タイミングは2段階:
  1. リアルタイム検知 (Pub/Sub webhook)
     - 目標: 同日検知率 95%以上
     - メール遅延・webhook失敗等で即時検知できない場合がある
  2. バックフィル再取得 (reconciliation)
     - 日次バッチで Gmail History API を使い、未処理メールを再スキャン
     - リアルタイムで漏れた分をここで100%に近づける
     - これは「拾い漏れを後から見返して拾う」仕組み

設計原則:
  リアルタイム検知に100%を求めない。
  ただし「最終的に全件取得する」ことは保証する。
  バックフィルは pg_cron で日次実行。
  History API の history_id で差分取得し、未処理メールを再パースする。
```

### 8c. 発行体通知カバレッジ (Issuer Notification Coverage)

```text
定義: カード明細上の全取引のうち、カード会社がメール通知を送信する割合
      (Credebi 側では制御不能)

実測値 (推定):
  - 三井住友NL: ~85-90% (公共料金・ETC・PiTaPa等は通知されない)
  - JCB (JAL/W): ~85-90% (同上)
  - ライフカード: 要計測
  - セゾンゴールドAMEX: 0% (メール通知なし)

カバレッジの穴を埋める手段:
  1. 請求案内メール (月次) → 未検知取引の差分検出
  2. 能動クロール (Phase 5): 請求メール未着時に受信箱をLLM探索
  3. 明細API同期 (将来): カード明細との突合で漏れを検出
  4. ユーザー手動入力 / レシートOCR: 最終フォールバック

この指標はパーサーの品質とは無関係。
カード会社の仕様変更やユーザーの通知設定に依存する。
```

### 指標サマリー

| 指標 | 対象レイヤー | 目標 | Credebi側で改善可能か |
|------|-------------|------|---------------------|
| パーサー抽出正確性 | 正規表現 / LLM | 100% | ○ (バグ修正で到達可能) |
| メール取得完全性 (リアルタイム) | Pub/Sub webhook | 95%+ | ○ (webhook信頼性改善) |
| メール取得完全性 (最終) | webhook + バックフィル | 100% | ○ (バックフィルで保証) |
| 発行体通知カバレッジ | カード会社の仕様 | 85-90% | △ (請求案内/明細同期で補完) |
