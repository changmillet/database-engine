begin;

-- Database #770: restore only the exact release-family manifest after the
-- authenticated-only fallback shape. Never change ACLs or client grants.
do $release_manifest_drift$
declare
  v_spec jsonb := $spec$[
    {"identity":"api.assert_lca_release_manager()","capability":"CLI-RPC-01","anon":false,"service":false},
    {"identity":"api.cmd_lca_release_prepare(uuid,text,text,text,jsonb,text,text,jsonb,text,text,jsonb)","capability":"CLI-RPC-01","anon":false,"service":false},
    {"identity":"api.cmd_lca_release_approve(uuid,text,timestamptz,text,jsonb)","capability":"CLI-RPC-01","anon":false,"service":false},
    {"identity":"api.cmd_lca_release_publish(uuid,uuid,text,text,text,text,text,jsonb)","capability":"CLI-RPC-01","anon":false,"service":false},
    {"identity":"api.cmd_lca_release_readback_verify(uuid,text,jsonb,jsonb)","capability":"CLI-RPC-01","anon":false,"service":false},
    {"identity":"api.cmd_lca_release_unpublish(uuid,text,jsonb)","capability":"CLI-RPC-01","anon":false,"service":false},
    {"identity":"api.get_current_lca_release()","capability":"CLI-RPC-01","anon":true,"service":true},
    {"identity":"api.get_lca_release_run(uuid)","capability":"CLI-RPC-01","anon":false,"service":true},
    {"identity":"api.get_lca_release_artifact_download(uuid)","capability":"CLI-RPC-01","anon":false,"service":true},
    {"identity":"api.get_lcia_result_calculation_bundle(uuid)","capability":"CLI-RPC-01","anon":false,"service":false},
    {"identity":"api.get_current_lca_release_process(uuid,text)","capability":"EDGE-REL-01","anon":true,"service":true}
  ]$spec$::jsonb;
  v_oids oid[];
  v_count integer;
  v_distinct integer;
  v_expected record;
  v_manifest record;
  v_oid oid;
  v_canonical boolean := true;
  v_legacy boolean := true;
begin
  select array_agg(pg_catalog.to_regprocedure(expected.identity)::oid)
    into v_oids
  from jsonb_to_recordset(v_spec) as expected(identity text);
  if array_position(v_oids, null::oid) is not null then
    raise exception 'Release manifest target routine is missing';
  end if;

  lock table private.api_capability_grants in share row exclusive mode;
  select count(*), count(distinct pg_catalog.to_regprocedure(manifest.routine_identity)::oid)
    into v_count, v_distinct
  from private.api_capability_grants manifest
  where pg_catalog.to_regprocedure(manifest.routine_identity)::oid = any(v_oids);
  if v_count <> 11 or v_distinct <> 11 then
    raise exception 'Release capability manifest is incomplete or duplicated';
  end if;

  for v_expected in
    select * from jsonb_to_recordset(v_spec)
      as expected(identity text, capability text, anon boolean, service boolean)
  loop
    v_oid := pg_catalog.to_regprocedure(v_expected.identity)::oid;
    if pg_catalog.has_function_privilege('anon', v_oid, 'execute') is distinct from v_expected.anon
      or not pg_catalog.has_function_privilege('authenticated', v_oid, 'execute')
      or pg_catalog.has_function_privilege('service_role', v_oid, 'execute') is distinct from v_expected.service
      or exists (
        select 1 from pg_catalog.pg_proc routine
        cross join lateral pg_catalog.aclexplode(coalesce(
          routine.proacl, pg_catalog.acldefault('f', routine.proowner)
        )) acl
        where routine.oid = v_oid and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
      ) then
      raise exception 'Release function ACL differs from canonical contract';
    end if;

    select * into strict v_manifest from private.api_capability_grants manifest
    where pg_catalog.to_regprocedure(manifest.routine_identity)::oid = v_oid;
    v_canonical := v_canonical and (
      v_manifest.capability_id = v_expected.capability
      and v_manifest.allow_anon = v_expected.anon
      and v_manifest.allow_authenticated
      and v_manifest.allow_service_role = v_expected.service
    );
    v_legacy := v_legacy and (
      v_manifest.capability_id = 'CLI-RPC-01'
      and not v_manifest.allow_anon
      and v_manifest.allow_authenticated
      and not v_manifest.allow_service_role
    );
  end loop;
  if not (v_canonical or v_legacy) then
    raise exception 'Release capability manifest has an unrecognized prior state';
  end if;

  for v_expected in
    select * from jsonb_to_recordset(v_spec)
      as expected(identity text, capability text, anon boolean, service boolean)
  loop
    update private.api_capability_grants manifest
    set capability_id = v_expected.capability,
      allow_anon = v_expected.anon,
      allow_authenticated = true,
      allow_service_role = v_expected.service
    where pg_catalog.to_regprocedure(manifest.routine_identity) =
      pg_catalog.to_regprocedure(v_expected.identity)
      and (manifest.capability_id, manifest.allow_anon, manifest.allow_authenticated, manifest.allow_service_role)
        is distinct from (v_expected.capability, v_expected.anon, true, v_expected.service);
  end loop;
end
$release_manifest_drift$;

commit;
