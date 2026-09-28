-- Direct query
select
    'direct query' as approach,
    r.operator_id,
    p.created_utc::date as revenue_date,
    sum(p.amount) as captured_amount,
    count(*) as captured_payments
from payments p
join tickets t on t.id = p.ticket_id
join trips tr on tr.id = t.trip_id
join routes r on r.id = tr.route_id
where p.status = 'Captured'
group by r.operator_id, p.created_utc::date

union all

-- SQL function
select
    'function',
    o.id,
    date '2026-04-29',
    f.captured_amount,
    f.captured_payments
from operators o
cross join lateral captured_revenue_for_day(
    o.id,
    date '2026-04-29'
) f

union all

-- Materialized view
select
    'materialized view',
    operator_id,
    revenue_date,
    captured_amount,
    captured_payments
from daily_captured_revenue

union all

-- Trigger-maintained summary
select
    'trigger summary',
    operator_id,
    revenue_date,
    captured_amount,
    captured_payments
from daily_revenue_by_operator

order by operator_id, approach;