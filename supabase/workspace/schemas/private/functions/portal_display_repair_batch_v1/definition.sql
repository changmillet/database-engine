CREATE OR REPLACE FUNCTION "private"."portal_display_repair_batch_v1"("p_after" "jsonb" DEFAULT NULL::"jsonb", "p_limit" integer DEFAULT 500) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare r record; last_key jsonb; affected integer:=0;
begin
 if p_limit is null or p_limit not between 1 and 1000 then raise exception using errcode='22023',message='invalid repair batch'; end if;
 for r in select dataset_kind,dataset_id,dataset_version from private.dataset_display_settings
 where dataset_kind in ('process','flow') and
 (p_after is null or (dataset_kind,dataset_id,dataset_version::text) > (p_after->>'kind',(p_after->>'id')::uuid,p_after->>'version'))
 order by dataset_kind,dataset_id,dataset_version limit p_limit loop
  perform private.portal_display_refresh_exact_v1(r.dataset_kind,r.dataset_id,r.dataset_version);
  last_key:=jsonb_build_object('kind',r.dataset_kind,'id',r.dataset_id,'version',r.dataset_version);
  affected:=affected+1;
 end loop;
 return jsonb_build_object('processed',affected,'lastKey',last_key);
end $$;

ALTER FUNCTION "private"."portal_display_repair_batch_v1"("p_after" "jsonb", "p_limit" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_repair_batch_v1"("p_after" "jsonb", "p_limit" integer) FROM PUBLIC;
