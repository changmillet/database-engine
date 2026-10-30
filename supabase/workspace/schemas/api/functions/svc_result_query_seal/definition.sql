CREATE OR REPLACE FUNCTION "api"."svc_result_query_seal"("p_artifact_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_artifact private.result_query_artifacts%rowtype;
  v_package private.lcia_result_packages%rowtype;
begin
  select * into v_artifact from private.result_query_artifacts where id=p_artifact_id for update;
  if not found then raise exception using errcode='22023',message='Query artifact not found'; end if;
  select * into v_package from private.lcia_result_packages where id=v_artifact.package_id for share;
  if v_package.status <> 'preview_ready'
    or (select count(*) from private.result_query_sources where artifact_id=p_artifact_id) <> v_artifact.process_count
    or jsonb_typeof(v_package.input_manifest->'processes') is distinct from 'array' then
    raise exception using errcode='22023',message='Query source axis incomplete';
  end if;
  if jsonb_array_length(v_package.input_manifest->'processes') <> v_package.included_input_count
    or v_package.included_input_count < 1
    or exists (select 1 from jsonb_array_elements(v_package.input_manifest->'processes') p
    where not exists(select 1 from private.result_query_sources s where s.artifact_id=p_artifact_id
      and s.process_id::text=p->>'id' and s.process_version=p->>'version')) then
    raise exception using errcode='22023',message='Query source axis does not cover package';
  end if;
  if v_artifact.status <> 'ready' then
    update private.result_query_artifacts set status='ready',ready_at=now() where id=p_artifact_id;
  end if;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('artifactId',p_artifact_id,'status','ready'));
end;
$$;

ALTER FUNCTION "api"."svc_result_query_seal"("p_artifact_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_result_query_seal"("p_artifact_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."svc_result_query_seal"("p_artifact_id" "uuid") TO "service_role";
