-- review_completion and resolve_redemption (20261006000001) treated a null
-- flag as "reject" / "cancel", and resolve_redemption then skipped the refund
-- because `not null` is null. A missing flag is now an error. Bodies are
-- otherwise unchanged.

create or replace function public.review_completion(completion uuid, approve boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  c public.task_completions;
begin
  if approve is null then
    raise exception 'approve is required';
  end if;
  select * into c from public.task_completions where id = completion for update;
  if not found or not public.is_family_parent(c.family_id) then
    raise exception 'not allowed';
  end if;
  update public.task_completions
     set status      = case when approve then 'approved' else 'rejected' end::public.completion_status,
         reviewed_by = public.my_member_id(c.family_id),
         reviewed_at = now()
   where id = completion;
end $$;

create or replace function public.resolve_redemption(redemption uuid, fulfilled boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  d public.reward_redemptions;
begin
  if fulfilled is null then
    raise exception 'fulfilled is required';
  end if;
  select * into d from public.reward_redemptions where id = redemption for update;
  if not found or not public.is_family_parent(d.family_id) then
    raise exception 'not allowed';
  end if;
  if d.status <> 'requested' then
    raise exception 'redemption already resolved';
  end if;
  update public.reward_redemptions
     set status = case when fulfilled then 'fulfilled' else 'cancelled' end::public.redemption_status,
         resolved_at = now()
   where id = redemption;
  if not fulfilled then
    insert into public.points_ledger (family_id, member_id, delta, reason, redemption_id)
    values (d.family_id, d.member_id, d.cost, 'Refund: reward cancelled', d.id);
  end if;
end $$;
