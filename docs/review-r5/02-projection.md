ID: **PROJ-R5-001**  
Severity: **P1**  
Location: `docs/deep-dive/05-projection-engine.md` (lines 705-709, 737-738)  
Issue: `evaluateChargeCoveragePerAccount()` reads `charge.amount`, but card charge objects are built with `charge_amount`.  
Impact: **crash**  
Fix: Use one canonical field (`charge_amount`) end-to-end, update the interface, and add a unit test for unrouted + routed coverage paths.

ID: **PROJ-R5-002**  
Severity: **P1**  
Location: `docs/deep-dive/05-projection-engine.md` (lines 579-583, 639-643)  
Issue: `calculateCardCharges()` uses `jstNow` without defining it, and the upper-bound logic uses a timezone-unsafe conversion path.  
Impact: **crash**  
Fix: Define JST “now” inside the function and compute JST date/time boundaries explicitly (without locale-string → Date → ISO roundtrip).

ID: **PROJ-R5-003**  
Severity: **P0**  
Location: `docs/deep-dive/05-projection-engine.md` (lines 150-154 vs 512-519), `docs/deep-dive/06-income-projection.md` (income sync freshness expectations)  
Issue: `data_as_of` and staleness computation omit income freshness (`income_connections.last_synced_at` / `projected_incomes.data_as_of`), despite design stating income must contribute to staleness.  
Impact: **overestimate**  
Fix: Include income-source timestamps in `data_as_of=min(...)` and add `income_connection` stale-source logic (48h threshold, inactive/degraded states).

ID: **PROJ-R5-004**  
Severity: **P1**  
Location: `docs/deep-dive/05-projection-engine.md` (lines 223-224)  
Issue: JST “today” is derived via `jstNow.toISOString().slice(0,10)`, which can shift day boundaries depending on server timezone.  
Impact: **underestimate**  
Fix: Use `toLocaleDateString('en-CA', { timeZone: 'Asia/Tokyo' })` (or equivalent ZonedDateTime/Temporal path) for all date bucketing/comparisons.

ID: **PROJ-R5-005**  
Severity: **P1**  
Location: `docs/deep-dive/05-projection-engine.md` (lines 1055-1072), `docs/contracts/projection-response.schema.json` (balance bar fields)  
Issue: `computeProjectionSummary()` reads `bar.balance`, but bars define `start_balance` / `end_balance` only.  
Impact: **crash**  
Fix: Replace `bar.balance` with `bar.end_balance` (or explicit chosen balance convention) and enforce with strict typing/tests.

ID: **PROJ-R5-006**  
Severity: **P1**  
Location: `docs/deep-dive/05-projection-engine.md` (lines 112-130, 556-567), `docs/contracts/projection-response.schema.json` (required top-level fields)  
Issue: Projection engine return shape (`aggregate_*`, `status`) does not match the API schema (`generated_at`, `timezone`, `horizon_days`, `currency`, `balance_bars`, `summary`), and status semantics differ.  
Impact: **crash**  
Fix: Add a strict response-mapping layer from internal projection model to schema contract (with schema validation in CI), or unify docs/schema to one source of truth.