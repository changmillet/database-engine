-- Database #785: reconcile preexisting source/production drift forward.
-- Recorded May29 migration was later edited for absent Preview hooks (8536605f /
-- 27334523). The engine upgrade did not introduce these body or ACL differences.
-- Both known bodies are admitted; any third definition fails closed.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create temp table issue785_retention_prestate on commit drop as
select p.* from pg_catalog.pg_proc p where oid in(
 'util.preview_supabase_functions_hooks_retention(interval,timestamp with time zone)'::regprocedure,
 'util.purge_supabase_functions_hooks(interval,integer)'::regprocedure);
do $guard$
declare f record; p record;
begin
 for f in select * from(values
    ('util.preview_supabase_functions_hooks_retention(interval,timestamp with time zone)','472ab2a42d522494a838248dff7e9d0f','71a8a8b9c0aa1c61b3d131df634ccb50'),
    ('util.purge_supabase_functions_hooks(interval,integer)','373ab75c0bbb1837142f86828d8e9fc4','2c2bcb184b828f2d34de05ab1031517b')
 ) expected(signature,source_md5,production_md5) loop
  select * into strict p from pg_catalog.pg_proc where oid=f.signature::regprocedure;
  if p.proowner<>'postgres'::regrole or p.prosecdef
     or p.proconfig is distinct from array['search_path=""']
     or pg_catalog.md5(p.prosrc) not in(f.source_md5,f.production_md5) then
   raise exception using errcode='55000',message='Database #785 retention prestate drift';
  end if;
 end loop;
 select * into strict p from pg_catalog.pg_proc where oid=
  'private.lcia_scope_closure_bundle_binding_matches(private.lcia_scope_closure_checks,private.worker_job_artifacts)'::regprocedure;
 if p.proowner<>'postgres'::regrole or not p.prosecdef
    or p.proconfig is distinct from array['search_path=private, api, public, util, extensions, pg_temp']
    or pg_catalog.md5(p.prosrc) is distinct from 'c4b6512785f496f75c04c59983744eed'
    or (select array_agg(x.grantee::regrole::text||':'||x.privilege_type||':'||x.is_grantable order by x.grantee::regrole::text)
        from pg_catalog.aclexplode(p.proacl) x where x.grantee<>'postgres'::regrole)
       is distinct from null::text[]
    and (select array_agg(x.grantee::regrole::text||':'||x.privilege_type||':'||x.is_grantable order by x.grantee::regrole::text)
        from pg_catalog.aclexplode(p.proacl) x where x.grantee<>'postgres'::regrole)
       is distinct from array['api_internal_executor:EXECUTE:false','service_role:EXECUTE:false'] then
  raise exception using errcode='55000',message='Database #785 binding helper prestate drift';
 end if;
end;
$guard$;
CREATE OR REPLACE FUNCTION "util"."preview_supabase_functions_hooks_retention"("p_retention_window" interval DEFAULT '14 days'::interval, "p_as_of" timestamp with time zone DEFAULT "now"()) RETURNS TABLE("retention_window" interval, "cutoff_time" timestamp with time zone, "total_rows" bigint, "eligible_rows" bigint, "protected_recent_rows" bigint, "protected_live_response_rows" bigint, "oldest_eligible_created_at" timestamp with time zone, "newest_eligible_created_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
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

  if to_regclass('supabase_functions.hooks') is null then
    return query
    select
      p_retention_window as retention_window,
      p_as_of - p_retention_window as cutoff_time,
      0::bigint as total_rows,
      0::bigint as eligible_rows,
      0::bigint as protected_recent_rows,
      0::bigint as protected_live_response_rows,
      null::timestamp with time zone as oldest_eligible_created_at,
      null::timestamp with time zone as newest_eligible_created_at;
    return;
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
$$;

CREATE OR REPLACE FUNCTION "util"."purge_supabase_functions_hooks"("p_retention_window" interval DEFAULT '14 days'::interval, "p_batch_size" integer DEFAULT 50000) RETURNS bigint
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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

  if to_regclass('supabase_functions.hooks') is null then
    return 0;
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
$$;

-- Service-role inserts invoke the existing SECURITY INVOKER certificate
-- trigger, which calls this helper. These grants already exist in production;
-- browser roles remain denied and the function body is unchanged.
grant execute on function private.lcia_scope_closure_bundle_binding_matches(
 private.lcia_scope_closure_checks,private.worker_job_artifacts) to service_role,api_internal_executor;
do $postcondition$
begin
 if exists(select 1 from issue785_retention_prestate b join pg_catalog.pg_proc p using(oid)
   where (to_jsonb(b)-'prosrc') is distinct from (to_jsonb(p)-'prosrc')) then
  raise exception using errcode='55000',message='Database #785 retention metadata changed';
 end if;
 if has_function_privilege('anon','private.lcia_scope_closure_bundle_binding_matches(private.lcia_scope_closure_checks,private.worker_job_artifacts)','EXECUTE')
 or has_function_privilege('authenticated','private.lcia_scope_closure_bundle_binding_matches(private.lcia_scope_closure_checks,private.worker_job_artifacts)','EXECUTE') then
  raise exception using errcode='55000',message='Database #785 binding helper external grant';
 end if;
end;
$postcondition$;
commit;
