-- Exact preexisting production bodies, read back 2026-10-06.
-- No owner/ACL changes; used only inside the rollback upgrade harness.
CREATE OR REPLACE FUNCTION util.preview_supabase_functions_hooks_retention(p_retention_window interval DEFAULT '14 days'::interval, p_as_of timestamp with time zone DEFAULT now())
 RETURNS TABLE(retention_window interval, cutoff_time timestamp with time zone, total_rows bigint, eligible_rows bigint, protected_recent_rows bigint, protected_live_response_rows bigint, oldest_eligible_created_at timestamp with time zone, newest_eligible_created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
  if p_as_of is null then
    raise exception using
      errcode = '22023',
      message = 'supabase functions hooks retention as_of timestamp must not be null';
  end if;

  if p_retention_window is null or p_retention_window < interval '1 day' then
    raise exception using
      errcode = '22023',
      message = 'supabase functions hooks retention window must be at least 1 day';
  end if;

  return query
  with live_responses as materialized (
    select response.id
    from net._http_response as response
  ), classified as (
    select
      hooks.created_at,
      hooks.created_at < p_as_of - p_retention_window as is_older_than_cutoff,
      live_responses.id is not null as has_live_pg_net_response
    from supabase_functions.hooks as hooks
    left join live_responses on live_responses.id = hooks.request_id
  )
  select
    p_retention_window as retention_window,
    p_as_of - p_retention_window as cutoff_time,
    count(*)::bigint as total_rows,
    count(*) filter (
      where classified.is_older_than_cutoff
        and not classified.has_live_pg_net_response
    )::bigint as eligible_rows,
    count(*) filter (
      where not classified.is_older_than_cutoff
    )::bigint as protected_recent_rows,
    count(*) filter (
      where classified.is_older_than_cutoff
        and classified.has_live_pg_net_response
    )::bigint as protected_live_response_rows,
    min(classified.created_at) filter (
      where classified.is_older_than_cutoff
        and not classified.has_live_pg_net_response
    ) as oldest_eligible_created_at,
    max(classified.created_at) filter (
      where classified.is_older_than_cutoff
        and not classified.has_live_pg_net_response
    ) as newest_eligible_created_at
  from classified;
end;
$function$;

CREATE OR REPLACE FUNCTION util.purge_supabase_functions_hooks(p_retention_window interval DEFAULT '14 days'::interval, p_batch_size integer DEFAULT 50000)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  deleted_count bigint;
begin
  if p_retention_window is null or p_retention_window < interval '1 day' then
    raise exception using
      errcode = '22023',
      message = 'supabase functions hooks retention window must be at least 1 day';
  end if;

  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 100000 then
    raise exception using
      errcode = '22023',
      message = 'supabase functions hooks purge batch size must be between 1 and 100000';
  end if;

  if not pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtext('util.purge_supabase_functions_hooks')
  ) then
    return 0;
  end if;

  with live_responses as materialized (
    select response.id
    from net._http_response as response
  ), candidates as (
    select hooks.id
    from supabase_functions.hooks as hooks
    left join live_responses on live_responses.id = hooks.request_id
    where hooks.created_at < pg_catalog.now() - p_retention_window
      and live_responses.id is null
    order by hooks.created_at, hooks.id
    limit p_batch_size
    for update of hooks skip locked
  )
  delete from supabase_functions.hooks as hooks
  using candidates
  where hooks.id = candidates.id;

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$function$;
