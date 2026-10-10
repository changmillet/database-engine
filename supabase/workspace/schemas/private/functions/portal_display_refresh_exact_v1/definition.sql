CREATE OR REPLACE FUNCTION "private"."portal_display_refresh_exact_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare r record; b text; payload jsonb; target text;
begin
 if p_kind not in ('process','flow') then return; end if;
 perform pg_advisory_xact_lock(pg_catalog.hashtextextended('portal-display:'||p_kind||':'||p_id::text||':'||p_version,0));
 select s.brand into b from private.dataset_display_settings s
 where s.dataset_kind=p_kind and s.dataset_id=p_id and s.dataset_version=p_version and s.is_visible;
 execute format('select id,version,state_code,modified_at,json from public.%I where id=$1 and version::text=$2',
   case p_kind when 'process' then 'processes' else 'flows' end) into r using p_id,p_version;
 if not private.portal_dataset_is_visible_v1(p_kind,p_id,p_version) or r.id is null or r.modified_at is null or jsonb_typeof(r.json) is distinct from 'object'
 or jsonb_typeof(r.json->case p_kind when 'process' then 'processDataSet' else 'flowDataSet' end) is distinct from 'object' then
  delete from private.display_catalog_search_rows_v2 where dataset_kind=p_kind and id=p_id and version=p_version;
  delete from private.display_catalog_search_rows_v1 where dataset_kind=p_kind and id=p_id and version=p_version;
  return;
 end if;
 payload:=private.display_catalog_projection_payload_v1(p_kind,r.state_code,r.json);
 insert into private.display_catalog_search_rows_v1(dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version,brand)
 values(p_kind,p_id,p_version,r.state_code,r.modified_at,payload->'card',payload->>'document',1,b)
 on conflict(dataset_kind,id,version) do update set state_code=excluded.state_code,modified_at=excluded.modified_at,
 card=excluded.card,document=excluded.document,brand=excluded.brand;
 if p_kind='process' then
  payload:=private.display_catalog_projection_payload_cn1(p_kind,r.state_code,r.json);
  insert into private.display_catalog_search_rows_v2(dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version,brand)
  values(p_kind,p_id,p_version,r.state_code,r.modified_at,payload->'card',payload->>'document',2,b)
  on conflict(dataset_kind,id,version) do update set state_code=excluded.state_code,modified_at=excluded.modified_at,
  card=excluded.card,document=excluded.document,brand=excluded.brand;
 end if;
end $_$;

ALTER FUNCTION "private"."portal_display_refresh_exact_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_refresh_exact_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;
