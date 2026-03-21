# credebi

> 「今月の引き落とし、残高足りる？」に即答するアプリ

クレジットカードを使い始めた大学生のための、短期キャッシュフロー予測iOSアプリ。

---

## What it does

クレジットカードの利用通知メールを自動検知し、銀行残高・バイト収入・引き落とし日を組み合わせて「引き落とし日に口座がいくらになるか」をリアルタイムで予測する。

**主な機能：**
- カード利用通知メールの自動解析（SMBC NL/Olive、LifeCard、JCB対応）
- 過去30日・今後60日の残高推移グラフ（Swift Charts）
- SAFE / WARNING / CRITICAL ステータス表示
- freee HR APIによるバイト収入予測
- サブスク自動検出（Netflix、Spotify、Apple Music 等）
- 銀行残高スクリーンショットのOCR読み取り（Gemini Vision）
- 危険水域の事前プッシュ通知（7日・14日前）

**設計思想：**
- 「空振りOK、見逃しNG」— 不確かな場合は支出を多め、収入を少なめに見積もる
- データが古ければ古く見える（`data_as_of` による鮮度表示）
- サイレント障害ゼロ（2-phase idempotency、fail-closed設計）

---

## Tech Stack

| Layer | Technology |
|---|---|
| iOS App | Swift / SwiftUI / Swift Charts |
| Backend | Supabase (PostgreSQL, Edge Functions, Realtime, Vault) |
| Edge Functions | Deno (TypeScript) |
| Email | Gmail API + Google Cloud Pub/Sub |
| LLM | Gemini 2.5 Flash-Lite / Claude Sonnet |
| Income API | freee HR API |
| OCR | Gemini Vision |

---

## Status

🚧 **設計完了・実装着手前**

アーキテクチャ設計・DBスキーマ・APIコントラクト・UIスペックは完成。
iOSアプリ実装とEdge Functions実装はこれから。

---

## Structure

```
credebi/              iOS app (SwiftUI)
supabase/functions/   Edge Functions (Deno)
docs/
  deep-dive/          サブシステム別詳細設計
  ui/                 UIスペック・プロトタイプ
  contracts/          APIスキーマ定義
DESIGN.md             アーキテクチャ全体設計
```

---

## License

[AGPL-3.0](LICENSE)
