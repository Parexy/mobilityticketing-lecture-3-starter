# Lecture 3 Reporting Analysis

## Authority

The `payments` table is the authority for captured revenue.

The direct query and SQL function calculate revenue directly from the authoritative data.

The materialized view and `daily_revenue_by_operator` table are derived copies and must therefore have a clear freshness and rebuild strategy.

## Responsibility matrix

| Approach | Correctness | Freshness | Write cost | Read cost | Hidden side effects | Rebuildability | Operational complexity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Direct SQL query | Uses authoritative state directly | Immediate | None beyond normal writes | Highest | None | Not required | Low |
| SQL function | Same result as direct query | Immediate | None beyond normal writes | Similar to direct query | Low | Not required | Low |
| Materialized view | Correct after refresh | Stale between refreshes | No per-payment summary write | Low | None on payment writes | Easy using `REFRESH MATERIALIZED VIEW` | Medium |
| Trigger summary | Correct only for transitions handled by the trigger | Immediate for handled inserts | Extra work on payment writes | Low | High | Can be recalculated from base tables | High |

## Experimental evidence

The `OP-BUS` revenue remained `36.00 / 1` throughout the experiment, so the observations below focus on `OP-METRO`.

### Baseline

After refreshing the materialized view but before backfilling the trigger summary:

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 36.00 | 1 |
| SQL function | 36.00 | 1 |
| Materialized view | 36.00 | 1 |
| Trigger summary | No row | No row |

The trigger summary did not contain the existing seed payments because the trigger was created after those payments had already been inserted.

After rebuilding `daily_revenue_by_operator`, all four approaches returned:

`36.00 / 1`

### Case 1: Captured payment inserted

A new captured payment of `36.00` was inserted.

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 72.00 | 2 |
| SQL function | 72.00 | 2 |
| Materialized view | 36.00 | 1 |
| Trigger summary | 72.00 | 2 |

The materialized view became stale immediately.

The trigger summary remained correct because the supplied trigger handles captured payment inserts.

### Case 2: Failed payment inserted

A failed payment of `50.00` was inserted.

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 72.00 | 2 |
| SQL function | 72.00 | 2 |
| Materialized view | 36.00 | 1 |
| Trigger summary | 72.00 | 2 |

The failed payment correctly contributed nothing to captured revenue.

### Case 3: Failed payment corrected to Captured

The `50.00` failed payment was updated to `Captured`.

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 122.00 | 3 |
| SQL function | 122.00 | 3 |
| Materialized view | 36.00 | 1 |
| Trigger summary | 72.00 | 2 |

This shows an important limitation of the supplied trigger.

The trigger only runs after `INSERT`, so changing a payment from `Failed` to `Captured` does not update the trigger-maintained summary.

### Case 4: Captured payment corrected to Refunded

The earlier test payment of `36.00` was changed from `Captured` to `Refunded`.

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 86.00 | 2 |
| SQL function | 86.00 | 2 |
| Materialized view | 36.00 | 1 |
| Trigger summary | 72.00 | 2 |

The direct query and function correctly removed the refunded payment from captured revenue.

The trigger summary again failed to react because it has no update handling.

### Case 5: Captured test payment deleted

The corrected `50.00` payment was deleted.

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 36.00 | 1 |
| SQL function | 36.00 | 1 |
| Materialized view | 36.00 | 1 |
| Trigger summary | 72.00 | 2 |

The materialized view happened to match the authoritative value again, but it had not been refreshed.

This agreement was therefore accidental and does not mean the materialized view was current.

The trigger summary remained incorrect because the supplied trigger has no delete handling.

### Case 6: Duplicate external payment delivery

A second payment using the existing external payment reference `gateway-capture-0001` was inserted.

The Lecture 3 starter schema allows this duplicate.

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 72.00 | 2 |
| SQL function | 72.00 | 2 |
| Materialized view | 36.00 | 1 |
| Trigger summary | 108.00 | 3 |

The trigger summary had accumulated incorrect historical state and then added the duplicate payment as another captured payment.

## Recovery tests

### Materialized view refresh

After running:

`REFRESH MATERIALIZED VIEW daily_captured_revenue`

the result became:

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 72.00 | 2 |
| SQL function | 72.00 | 2 |
| Materialized view | 72.00 | 2 |
| Trigger summary | 108.00 | 3 |

This demonstrates that the materialized view has a simple and deterministic rebuild path from authoritative data.

### Trigger summary rebuild

After truncating and rebuilding `daily_revenue_by_operator` from the base tables:

| Approach | Amount | Payments |
| --- | ---: | ---: |
| Direct query | 72.00 | 2 |
| SQL function | 72.00 | 2 |
| Materialized view | 72.00 | 2 |
| Trigger summary | 72.00 | 2 |

All four approaches then agreed again.

## Captured disagreement example

After changing the failed `50.00` payment to `Captured`, the approaches disagreed:

- Direct query: `122.00 / 3`
- SQL function: `122.00 / 3`
- Materialized view: `36.00 / 1`
- Trigger summary: `72.00 / 2`

The direct query and function reflected authoritative state immediately.

The materialized view was stale because it had not been refreshed.

The trigger summary was incorrect because the supplied trigger did not handle updates.

## Side-effect trace

For an `INSERT INTO payments` with status `Captured`:

1. PostgreSQL inserts the payment row.
2. The `AFTER INSERT` trigger executes in the same transaction.
3. The trigger reads `tickets`, `trips`, and `routes` to determine the payment's operator.
4. The trigger inserts or updates `daily_revenue_by_operator`.
5. The payment write therefore causes an additional hidden reporting write.
6. If the trigger fails, the payment statement is also rolled back.
7. The direct query and SQL function become current from the authoritative payment data after commit.
8. The trigger summary becomes current immediately for the captured-insert case handled by the trigger.
9. The materialized view remains unchanged until explicitly refreshed.

The application inserting the payment does not have to explicitly update the summary table, which makes the side effect less visible in application code.

## Duplicate delivery

The Lecture 3 schema does not enforce uniqueness of `external_payment_reference`.

The duplicate payment therefore succeeded and contributed to captured revenue.

This shows that reporting logic does not replace transactional integrity or idempotency rules.

If duplicate payment delivery must be prevented, that rule belongs in the transactional model or payment workflow rather than in the reporting mechanism.

## Issue register

### Insert-only trigger can drift from authoritative data

- **Evidence:** Status corrections and deletes changed the direct query and function but did not update `daily_revenue_by_operator`.
- **Problem:** The trigger only handles captured inserts.
- **Consequence:** The stored summary can silently disagree with `payments`.
- **Specific improvement:** Either implement every relevant insert, update and delete transition or avoid maintaining this summary synchronously.
- **Open question:** Is the additional write-side complexity justified by the reporting workload?

## Decision record

### Decision

Use the SQL function over the transactional tables for the current daily captured revenue requirement.

The `payments` table remains authoritative.

### Rationale

The reporting workload can tolerate more read work than correctness-critical purchase and validation operations.

The SQL function centralises the revenue calculation while continuing to read authoritative data. It therefore reflects:

- captured payment inserts;
- failed payments;
- status corrections;
- refunds;
- deletes;
- replacement data.

It does not introduce another stored copy that can become stale or inconsistent.

The supplied trigger-maintained summary demonstrated significant coupling to the payment write path and became incorrect after valid state changes that it did not handle.

The materialized view is a reasonable future optimisation if reporting queries become expensive. Its staleness is explicit and predictable, and it has a simple rebuild path.

## Rebuild paths

### Direct query

No rebuild is required because it reads the authoritative tables directly.

### SQL function

No rebuild is required because the function reads the authoritative tables when executed.

### Materialized view

Rebuild using:

`REFRESH MATERIALIZED VIEW daily_captured_revenue`

### Trigger-maintained summary

Rebuild by truncating `daily_revenue_by_operator` and recalculating it from `payments`, `tickets`, `trips`, and `routes`.

The trigger-maintained table must never be treated as the authoritative revenue source.

## Recommendation

For the current workload, use the SQL function as the reporting interface and keep `payments` as the authority.

If reporting volume later makes direct aggregation too expensive, introduce the materialized view as a derived optimisation with a documented refresh schedule.

The trigger-maintained summary is not recommended for the current case because the experiment showed that it introduces hidden write-side effects and requires every relevant payment state transition to be handled correctly.