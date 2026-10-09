CREATE OR REPLACE FUNCTION "api"."cmd_dataset_display_set_batch"("p_items" "jsonb", "p_is_visible" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '15s'
    AS $_$
declare v_item record; v_table text; v_exists boolean; v_current boolean; v_requested integer:=0; v_changed integer:=0;
begin
  perform private.dataset_display_require_manager();
  if p_is_visible is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode='22023',message='items must be an array and isVisible a boolean';
  end if;
  if jsonb_array_length(p_items) not between 1 and 100 then
    raise exception using errcode='22023',message='items must contain between 1 and 100 exact dataset versions';
  end if;
  if exists(select 1 from jsonb_array_elements(p_items) t(v) where jsonb_typeof(v) is distinct from 'object'
    or jsonb_typeof(v->'datasetKind') is distinct from 'string' or (v->>'datasetKind') not in ('lifecyclemodel','process','flow','flowproperty','unitgroup','source','contact')
    or jsonb_typeof(v->'id') is distinct from 'string' or not ((v->>'id')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    or jsonb_typeof(v->'version') is distinct from 'string' or not ((v->>'version')~'^\d{2}\.\d{2}\.\d{3}$')
    or v - array['datasetKind','id','version']::text[] <> '{}'::jsonb) then
    raise exception using errcode='22023',message='each item must contain only a supported datasetKind, valid id and version';
  end if;
  -- Lock each exact source in the same global order. No state/owner/team predicate.
  -- FOR UPDATE serializes overlapping commands and source deletion/identity changes.
  for v_item in select distinct v->>'datasetKind' as kind,(v->>'id')::uuid as id,(v->>'version')::character(9) as version
    from jsonb_array_elements(p_items) t(v) order by 1,2,3 loop
    v_table:=case v_item.kind when 'lifecyclemodel' then 'lifecyclemodels' when 'process' then 'processes' when 'flow' then 'flows'
      when 'flowproperty' then 'flowproperties' when 'unitgroup' then 'unitgroups' when 'source' then 'sources' when 'contact' then 'contacts' end;
    v_exists:=false;
    execute format('select true from public.%I where id=$1 and version=$2 for update',v_table) into v_exists using v_item.id,v_item.version;
    if v_exists is distinct from true then raise exception using errcode='22023',message='all requested dataset versions must exist'; end if;
    v_requested:=v_requested+1;
    select is_visible into v_current from private.dataset_display_settings
      where dataset_kind=v_item.kind and dataset_id=v_item.id and dataset_version=v_item.version;
    if coalesce(v_current,false) is distinct from p_is_visible then
      insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible)
      values(v_item.kind,v_item.id,v_item.version,p_is_visible)
      on conflict(dataset_kind,dataset_id,dataset_version) do update set is_visible=excluded.is_visible,updated_at=now();
      v_changed:=v_changed+1;
    end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('inputCount',jsonb_array_length(p_items),'requestedCount',v_requested,'changedCount',v_changed,'unchangedCount',v_requested-v_changed,'isVisible',p_is_visible));
end; $_$;

ALTER FUNCTION "api"."cmd_dataset_display_set_batch"("p_items" "jsonb", "p_is_visible" boolean) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_dataset_display_set_batch"("p_items" "jsonb", "p_is_visible" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_dataset_display_set_batch"("p_items" "jsonb", "p_is_visible" boolean) TO "authenticated";

GRANT ALL ON FUNCTION "api"."cmd_dataset_display_set_batch"("p_items" "jsonb", "p_is_visible" boolean) TO "api_internal_executor";
