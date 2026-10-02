begin;

-- Database #767: the public OAuth CLI already exposes these release commands,
-- but their pre-OAuth Edge capability labels reject its exact CLI-RPC-01 class
-- before the existing actor/manager checks run. Repair only traced CLI routes.
-- Keep client registrations, role flags, function ACLs and RPC bodies unchanged.
do $oauth_release_cli_capabilities$
declare
  v_routines oid[] := array[
    'api.assert_lca_release_manager()'::regprocedure::oid,
    'api.cmd_lca_release_prepare(uuid,text,text,text,jsonb,text,text,jsonb,text,text,jsonb)'::regprocedure::oid,
    'api.cmd_lca_release_approve(uuid,text,timestamptz,text,jsonb)'::regprocedure::oid,
    'api.cmd_lca_release_publish(uuid,uuid,text,text,text,text,text,jsonb)'::regprocedure::oid,
    'api.cmd_lca_release_readback_verify(uuid,text,jsonb,jsonb)'::regprocedure::oid,
    'api.cmd_lca_release_unpublish(uuid,text,jsonb)'::regprocedure::oid,
    'api.get_current_lca_release()'::regprocedure::oid,
    'api.get_lca_release_run(uuid)'::regprocedure::oid,
    'api.get_lca_release_artifact_download(uuid)'::regprocedure::oid,
    'api.get_lcia_result_calculation_bundle(uuid)'::regprocedure::oid
  ];
  v_count integer;
  v_distinct_count integer;
begin
  lock table private.api_capability_grants in share row exclusive mode;

  -- Text identities can alias one routine; row count alone can hide a missing target.
  select count(*), count(distinct pg_catalog.to_regprocedure(manifest.routine_identity)::oid)
    into v_count, v_distinct_count
  from private.api_capability_grants as manifest
  where pg_catalog.to_regprocedure(manifest.routine_identity)::oid = any(v_routines);
  if v_count <> cardinality(v_routines)
     or v_distinct_count <> cardinality(v_routines) then
    raise exception 'OAuth CLI release capability manifest is incomplete or duplicated';
  end if;

  if exists (
    select 1
    from private.api_capability_grants as manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity)::oid = any(v_routines)
      and (
        not manifest.allow_authenticated
        or manifest.capability_id not in (
          'CLI-RPC-01',
          case when pg_catalog.to_regprocedure(manifest.routine_identity) =
            'api.get_lcia_result_calculation_bundle(uuid)'::regprocedure
            then 'EDGE-ACTOR-01' else 'EDGE-REL-01' end
        )
      )
  ) then
    raise exception 'OAuth CLI release capability manifest has an unexpected prior class';
  end if;

  update private.api_capability_grants as manifest
  set capability_id = 'CLI-RPC-01'
  where pg_catalog.to_regprocedure(manifest.routine_identity)::oid = any(v_routines);
end
$oauth_release_cli_capabilities$;

commit;
