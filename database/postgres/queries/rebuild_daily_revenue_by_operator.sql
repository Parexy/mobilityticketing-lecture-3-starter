truncate table daily_revenue_by_operator;

insert into daily_revenue_by_operator (
    operator_id,
    revenue_date,
    captured_amount,
    captured_payments
)
select
    r.operator_id,
    p.created_utc::date,
    sum(p.amount),
    count(*)
from payments p
join tickets t on t.id = p.ticket_id
join trips tr on tr.id = t.trip_id
join routes r on r.id = tr.route_id
where p.status = 'Captured'
group by
    r.operator_id,
    p.created_utc::date;