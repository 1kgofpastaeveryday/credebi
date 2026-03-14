# ProjectionView UI Spec (v0.5, iOS-First SwiftUI)

## 1. Goal

The first screen answers only:

- `Am I safe or not?`
- `For the selected day, how much did I earn and spend?`

## 2. Platform Priority

- Primary platform: iOS
- Implementation language: Swift + SwiftUI
- Primary display language: Japanese (`ja`)
- Navigation: `NavigationStack`
- Charting: Swift Charts (`Chart`, `LineMark`, `PointMark`, `RuleMark`)

## 3. Apple HIG Alignment

Design decisions are aligned to Apple Human Interface Guidelines:

- Keep visual hierarchy obvious (`status -> chart -> day details`)
- Keep interaction direct and touch friendly (tap chart point, tap Earned/Spent)
- Keep components familiar (cards, capsules, system spacing, system typography)
- Avoid visual noise and decorative complexity

Reference:

- Apple HIG: https://developer.apple.com/design/human-interface-guidelines
- iOS visual design tips: https://developer.apple.com/design/tips/
- SwiftUI framework: https://developer.apple.com/swiftui/

## 4. Data Contract

Source contract:

- `docs/contracts/projection-response.schema.json`

Required fields for this screen:

- `summary.safety_status`
- `summary.first_deficit_date`
- `balance_bars[].date`
- `balance_bars[].end_balance`
- `balance_bars[].below_zero`
- `balance_bars[].daily_breakdown.income_items[]`
- `balance_bars[].daily_breakdown.spend_items[]`

## 5. Screen Structure

- Status card
  - `SAFE FOR NOW` or `WARNING: MAY HIT ZERO`
  - Subtext with first risk date if warning
  - `Jump to risk` action
- Trend chart card
  - Line chart only
  - Zero baseline visible
  - Risk section highlighted in red
  - Point tap selects day
- Day summary card
  - `SAFE` / `NOT SAFE`
  - Two large tappable metrics:
    - `Earned +¥x`
    - `Spent -¥y`
- Detail list card
  - Shows breakdown based on selected metric tab

## 6. Interaction Rules

- Tap any chart point:
  - select nearest day
  - update day status and totals
  - default details tab: `Spent`
- Tap `Earned`:
  - show `income_items` list
- Tap `Spent`:
  - show `spend_items` list
- Tap `Jump to risk`:
  - select first zero-cross day

## 7. Accessibility Rules

- Never color-only status (text label is mandatory)
- Minimum hit target 44x44pt
- Dynamic Type friendly text sizing
- Use semantic colors where possible

## 8. Localization Rule

- Shipping default: Japanese UI copy
- Recommended production setup:
  - `Localizable.strings` (ja as development language)
  - optional en fallback later
- Prototype currently uses direct Japanese strings for speed

## 9. Prototype Files

- SwiftUI prototype: `docs/ui/prototypes/ProjectionViewPrototype.swift`
- Previous web prototype: `docs/ui/prototypes/projection-view-prototype.html`
