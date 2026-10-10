-- Database #807: atomic isolated display projection, scoped readers and fail-closed cutover.
-- No account backfill or rollout activation occurs in this migration.
begin;
do $acl_begin$
declare saved jsonb;
begin
 select jsonb_build_object('admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option) into saved
 from pg_auth_members m where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole and m.grantor=current_user::regrole;
 perform set_config('display_cutover.postgres_grant',coalesce(saved,'null'::jsonb)::text,true);
 perform set_config('display_cutover.private_create',has_schema_privilege('portal_public_executor','private','CREATE')::text,true);
 perform set_config('display_cutover.api_create',has_schema_privilege('portal_public_executor','api','CREATE')::text,true);
end $acl_begin$;
-- Database #807: isolated display projection; no business backfill or activation.
-- Existing state-based projections, writers and immutable contracts are retained.
set local lock_timeout = '5s';
set local check_function_bodies = off;
create role portal_display_executor nologin noinherit nobypassrls;
grant usage on schema private, public, extensions to portal_display_executor;
create table private.portal_display_derivation_contract (contract_version smallint primary key, identity text not null);
insert into private.portal_display_derivation_contract values (1,'portal-display-projection.v1'),(2,'portal-display-composite-projection.v1');
revoke all on private.portal_display_derivation_contract from public,anon,authenticated,service_role;
create table private.portal_display_rollout (
  singleton boolean primary key default true check(singleton),
  mode text not null check(mode in ('legacy','display','unavailable')),
  changed_at timestamptz not null default clock_timestamp()
);
insert into private.portal_display_rollout(singleton,mode) values(true,'legacy');
revoke all on private.portal_display_rollout from public,anon,authenticated,service_role;
create function private.portal_display_request_visible_v1(p_kind text,p_id uuid,p_version text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.dataset_display_settings s
 where s.dataset_kind=p_kind and s.dataset_id=p_id and s.dataset_version=p_version
 and s.is_visible and
 (current_setting('portal.display_global',true)='true' or
 s.brand=any(string_to_array(current_setting('portal.display_brands',true),',')))
 and (nullif(current_setting('portal.display_filter_brand',true),'') is null or
 s.brand=current_setting('portal.display_filter_brand',true)))
$$;
revoke all on function private.portal_display_request_visible_v1(text,uuid,text) from public;
grant execute on function private.portal_display_request_visible_v1(text,uuid,text) to portal_display_executor;


CREATE OR REPLACE FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_publication jsonb := private.portal_publication_root_v1(p_kind, p_json);
  v_license text := private.portal_scalar_text_v1(v_publication -> 'common:licenseType');
  v_exclusive jsonb := v_publication -> 'common:referenceToEntitiesWithExclusiveAccess';
  v_restrictions jsonb := v_publication -> 'common:accessRestrictions';
  v_exclusive_missing boolean;
  v_restrictions_open boolean;
  v_open boolean;
  v_reasons jsonb := '[]'::jsonb;
begin
  v_exclusive_missing := v_exclusive is null
    or v_exclusive = 'null'::jsonb;
  v_restrictions_open := private.portal_access_restrictions_open_v1(v_restrictions);
  v_open := coalesce(v_license = 'Free of charge for all users and uses'
    and v_exclusive_missing
    and v_restrictions_open, false);

  if v_license is distinct from 'Free of charge for all users and uses' then
    v_reasons := v_reasons || '"license_not_fully_open"'::jsonb;
  end if;
  if not v_exclusive_missing then
    v_reasons := v_reasons || '"exclusive_access_declared"'::jsonb;
  end if;
  if not v_restrictions_open then
    v_reasons := v_reasons || '"access_restrictions_present"'::jsonb;
  end if;
  if v_open then
    v_reasons := '[]'::jsonb || '"public_license_confirmed"'::jsonb;
  end if;

  return jsonb_build_object(
    'metadataVisible', true,
    'exchangesVisible', v_open,
    'lciaVisible', false,
    'publicArtifactVisible', false,
    'citationVisible', true,
    'policyVersion', 'portal-capability-policy.v1',
    'reasonCodes', v_reasons
  );
end
$$;

ALTER FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_card_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_capabilities jsonb := private.display_capabilities_v1(p_kind, p_state_code, p_json);
  v_information jsonb;
  v_modelling jsonb;
  v_location jsonb;
  v_names jsonb := '[]'::jsonb;
  v_synonyms jsonb := '[]'::jsonb;
  v_summary jsonb := '[]'::jsonb;
  v_technology jsonb := '[]'::jsonb;
  v_geography jsonb;
  v_classifications jsonb := '[]'::jsonb;
  v_reference_year integer;
  v_process_subtype text;
  v_cas text;
  v_source_metadata jsonb;
  v_source text;
  v_document text;
begin
  if p_kind = 'process' then
    v_information := p_json #> '{processDataSet,processInformation}';
    v_modelling := p_json #> '{processDataSet,modellingAndValidation}';
    v_location := v_information #> '{geography,locationOfOperationSupplyOrProduction}';
    v_names := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,name,baseName}'
    );
    v_summary := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_technology := private.portal_localized_text_v1(
      v_information #> '{technology,technologyDescriptionAndIncludedProcesses}'
    ) || private.portal_localized_text_v1(
      v_information #> '{technology,technologicalApplicability}'
    );
    v_classifications := private.portal_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_reference_year := private.portal_safe_year_v1(
      v_information #>> '{time,common:referenceYear}'
    );
    v_process_subtype := nullif(private.portal_scalar_text_v1(
      v_modelling #> '{LCIMethodAndAllocation,typeOfDataSet}'
    ), '');
    v_geography := jsonb_build_object(
      'code', nullif(private.portal_scalar_text_v1(v_location -> '@location'), ''),
      'label', private.portal_localized_text_v1(v_location -> 'descriptionOfRestrictions'),
      'precision', 'unknown'
    );
  elsif p_kind = 'flow' then
    v_information := p_json #> '{flowDataSet,flowInformation}';
    v_location := v_information -> 'geography';
    v_names := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,name,baseName}'
    );
    v_synonyms := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,common:synonyms}'
    );
    v_summary := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_classifications := private.portal_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_cas := nullif(btrim(coalesce(
      v_information #>> '{dataSetInformation,CASNumber}',
      v_information #>> '{dataSetInformation,common:CASNumber}'
    )), '');
    if v_cas !~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$' then
      v_cas := null;
    end if;
    v_geography := jsonb_build_object(
      'code', case jsonb_typeof(v_location -> 'locationOfSupply')
        when 'string' then nullif(
          private.portal_scalar_text_v1(v_location -> 'locationOfSupply'),
          ''
        )
        when 'object' then nullif(
          private.portal_scalar_text_v1(v_location #> '{locationOfSupply,@location}'),
          ''
        )
        else null
      end,
      'label', private.portal_localized_text_v1(
        v_location #> '{locationOfSupply,descriptionOfRestrictions}'
      ),
      'precision', 'unknown'
    );
  else
    return null;
  end if;

  v_source_metadata := private.portal_source_v1(p_kind, p_json);
  select string_agg(item ->> 'value', ' ' order by item ->> 'language')
  into v_source
  from jsonb_array_elements(v_source_metadata -> 'providerName') as localized(item);
  select lower(concat_ws(' ',
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_names) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_synonyms) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_summary) as localized(item)),
    (select string_agg(item ->> 'code', ' ') from jsonb_array_elements(v_classifications) as classification(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_technology) as localized(item)),
    v_geography ->> 'code',
    v_reference_year::text,
    v_process_subtype,
    v_cas,
    v_source
  )) into v_document;
  return jsonb_build_object(
    'accessLevel', case when (v_capabilities ->> 'exchangesVisible')::boolean then 'open' else 'metadata_only' end,
    'capabilities', v_capabilities,
    'names', v_names,
    'summary', v_summary,
    'geography', v_geography,
    'referenceYear', to_jsonb(v_reference_year),
    'processSubtype', to_jsonb(v_process_subtype),
    'source', to_jsonb(v_source),
    'classifications', v_classifications,
    'casNumber', to_jsonb(v_cas),
    'document', to_jsonb(coalesce(v_document, ''))
  );
end
$_$;

ALTER FUNCTION "private"."display_catalog_card_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_card_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_card_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_capabilities jsonb := private.display_capabilities_v1(p_kind, p_state_code, p_json);
  v_information jsonb;
  v_modelling jsonb;
  v_location jsonb;
  v_names jsonb := '[]'::jsonb;
  v_synonyms jsonb := '[]'::jsonb;
  v_summary jsonb := '[]'::jsonb;
  v_technology jsonb := '[]'::jsonb;
  v_geography jsonb;
  v_classifications jsonb := '[]'::jsonb;
  v_reference_year integer;
  v_process_subtype text;
  v_cas text;
  v_source_metadata jsonb;
  v_source text;
  v_document text;
begin
  if p_kind = 'process' then
    v_information := p_json #> '{processDataSet,processInformation}';
    v_modelling := p_json #> '{processDataSet,modellingAndValidation}';
    v_location := v_information #> '{geography,locationOfOperationSupplyOrProduction}';
    v_names := private.portal_process_names_v1(p_json);
    v_summary := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_technology := private.portal_localized_text_v1(
      v_information #> '{technology,technologyDescriptionAndIncludedProcesses}'
    ) || private.portal_localized_text_v1(
      v_information #> '{technology,technologicalApplicability}'
    );
    v_classifications := private.portal_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_reference_year := private.portal_safe_year_v1(
      v_information #>> '{time,common:referenceYear}'
    );
    v_process_subtype := nullif(private.portal_scalar_text_v1(
      v_modelling #> '{LCIMethodAndAllocation,typeOfDataSet}'
    ), '');
    v_geography := jsonb_build_object(
      'code', nullif(private.portal_scalar_text_v1(v_location -> '@location'), ''),
      'label', private.portal_localized_text_v1(v_location -> 'descriptionOfRestrictions'),
      'precision', 'unknown'
    );
  elsif p_kind = 'flow' then
    v_information := p_json #> '{flowDataSet,flowInformation}';
    v_location := v_information -> 'geography';
    v_names := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,name,baseName}'
    );
    v_synonyms := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,common:synonyms}'
    );
    v_summary := private.portal_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_classifications := private.portal_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_cas := nullif(btrim(coalesce(
      v_information #>> '{dataSetInformation,CASNumber}',
      v_information #>> '{dataSetInformation,common:CASNumber}'
    )), '');
    if v_cas !~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$' then
      v_cas := null;
    end if;
    v_geography := jsonb_build_object(
      'code', case jsonb_typeof(v_location -> 'locationOfSupply')
        when 'string' then nullif(
          private.portal_scalar_text_v1(v_location -> 'locationOfSupply'),
          ''
        )
        when 'object' then nullif(
          private.portal_scalar_text_v1(v_location #> '{locationOfSupply,@location}'),
          ''
        )
        else null
      end,
      'label', private.portal_localized_text_v1(
        v_location #> '{locationOfSupply,descriptionOfRestrictions}'
      ),
      'precision', 'unknown'
    );
  else
    return null;
  end if;

  v_source_metadata := private.portal_source_v1(p_kind, p_json);
  select string_agg(item ->> 'value', ' ' order by item ->> 'language')
  into v_source
  from jsonb_array_elements(v_source_metadata -> 'providerName') as localized(item);
  select lower(concat_ws(' ',
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_names) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_synonyms) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_summary) as localized(item)),
    (select string_agg(item ->> 'code', ' ') from jsonb_array_elements(v_classifications) as classification(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_technology) as localized(item)),
    v_geography ->> 'code',
    v_reference_year::text,
    v_process_subtype,
    v_cas,
    v_source
  )) into v_document;
  return jsonb_build_object(
    'accessLevel', case when (v_capabilities ->> 'exchangesVisible')::boolean then 'open' else 'metadata_only' end,
    'capabilities', v_capabilities,
    'names', v_names,
    'summary', v_summary,
    'geography', v_geography,
    'referenceYear', to_jsonb(v_reference_year),
    'processSubtype', to_jsonb(v_process_subtype),
    'source', to_jsonb(v_source),
    'classifications', v_classifications,
    'casNumber', to_jsonb(v_cas),
    'document', to_jsonb(coalesce(v_document, ''))
  );
end
$_$;

ALTER FUNCTION "private"."display_catalog_card_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_card_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_projection_payload_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
declare
  v_card jsonb;
begin
  v_card := private.display_catalog_card_v1(
    p_kind,
    p_state_code,
    p_json
  );
  if pg_catalog.jsonb_typeof(v_card) <> 'object' then
    return null;
  end if;
  return pg_catalog.jsonb_build_object(
    'card', v_card,
    'document', coalesce(v_card ->> 'document', '')
  );
end
$$;

ALTER FUNCTION "private"."display_catalog_projection_payload_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_projection_payload_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
declare
  v_card jsonb;
begin
  v_card := private.display_catalog_card_cn1(
    p_kind,
    p_state_code,
    p_json
  );
  if pg_catalog.jsonb_typeof(v_card) <> 'object' then
    return null;
  end if;
  return pg_catalog.jsonb_build_object(
    'card', v_card,
    'document', coalesce(v_card ->> 'document', '')
  );
end
$$;

ALTER FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_sync_catalog_character_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  insert into private.display_catalog_character_rows_v1 (
    dataset_kind,
    id,
    version,
    state_code,
    modified_at,
    document_characters,
    name_characters,
    name_exact_characters,
    classification_characters,
    classification_exact_characters,
    character_contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.state_code,
    new.modified_at,
    private.portal_catalog_character_set_v1(new.document),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'names', 'value', false
    ),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'names', 'value', true
    ),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', false
    ),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', true
    ),
    1
  )
  on conflict (dataset_kind, id, version) do update
  set state_code = excluded.state_code,
      modified_at = excluded.modified_at,
      document_characters = excluded.document_characters,
      name_characters = excluded.name_characters,
      name_exact_characters = excluded.name_exact_characters,
      classification_characters = excluded.classification_characters,
      classification_exact_characters =
        excluded.classification_exact_characters,
      character_contract_version = excluded.character_contract_version;
  return new;
end
$$;

ALTER FUNCTION "private"."display_sync_catalog_character_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_catalog_character_row_v1"() FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_sync_catalog_character_row_cn1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  insert into private.display_catalog_character_rows_v2 (
    dataset_kind,
    id,
    version,
    state_code,
    modified_at,
    document_characters,
    name_characters,
    name_exact_characters,
    classification_characters,
    classification_exact_characters,
    character_contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.state_code,
    new.modified_at,
    private.portal_catalog_character_set_v1(new.document),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'names', 'value', false
    ),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'names', 'value', true
    ),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', false
    ),
    private.portal_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', true
    ),
    1
  )
  on conflict (dataset_kind, id, version) do update
  set state_code = excluded.state_code,
      modified_at = excluded.modified_at,
      document_characters = excluded.document_characters,
      name_characters = excluded.name_characters,
      name_exact_characters = excluded.name_exact_characters,
      classification_characters = excluded.classification_characters,
      classification_exact_characters =
        excluded.classification_exact_characters,
      character_contract_version = excluded.character_contract_version;
  return new;
end
$$;

ALTER FUNCTION "private"."display_sync_catalog_character_row_cn1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_catalog_character_row_cn1"() FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_sync_catalog_facet_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
declare
  v_facts record;
begin
  select facts.*
  into strict v_facts
  from private.portal_catalog_facet_facts_v1(
    new.dataset_kind,
    new.card
  ) as facts;

  insert into private.display_catalog_facet_rows_v1 (
    dataset_kind,
    id,
    version,
    state_code,
    modified_at,
    facet_access_level,
    facet_geography,
    facet_reference_year,
    facet_process_subtype,
    facet_source,
    facet_contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.state_code,
    new.modified_at,
    v_facts.facet_access_level,
    v_facts.facet_geography,
    v_facts.facet_reference_year,
    v_facts.facet_process_subtype,
    v_facts.facet_source,
    1
  )
  on conflict (dataset_kind, id, version) do update
  set state_code = excluded.state_code,
      modified_at = excluded.modified_at,
      facet_access_level = excluded.facet_access_level,
      facet_geography = excluded.facet_geography,
      facet_reference_year = excluded.facet_reference_year,
      facet_process_subtype = excluded.facet_process_subtype,
      facet_source = excluded.facet_source,
      facet_contract_version = excluded.facet_contract_version;

  return new;
end
$$;

ALTER FUNCTION "private"."display_sync_catalog_facet_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_catalog_facet_row_v1"() FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_sync_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $_$
declare
  v_entry jsonb;
  v_entry_level integer;
  v_placement text;
  v_placements text[] := '{}'::text[];
  v_node text;
  v_code text;
  v_taxonomy text;
  v_raw_root text;
  v_geography text;
  v_matched integer := 0;
  v_raw_parent text;
begin
  insert into private.display_navigation_versions_v1 (
    dataset_kind,id,version,access_level,geography_code,classification_codes,
    reference_year,process_subtype,source
  ) values (
    p_kind,p_id,p_version,p_card->>'accessLevel',
    lower(btrim(p_card#>>'{geography,code}')),
    array(select distinct lower(btrim(entry->>'code'))
      from jsonb_array_elements(coalesce(p_card->'classifications','[]'::jsonb)) entry
      where nullif(btrim(entry->>'code'),'') is not null),
    (p_card->>'referenceYear')::integer,
    lower(btrim(p_card->>'processSubtype')),lower(btrim(p_card->>'source'))
  ) on conflict (dataset_kind,id,version) do update set
    access_level=excluded.access_level,geography_code=excluded.geography_code,
    classification_codes=excluded.classification_codes,reference_year=excluded.reference_year,
    process_subtype=excluded.process_subtype,source=excluded.source
  where (display_navigation_versions_v1.access_level,display_navigation_versions_v1.geography_code,
    display_navigation_versions_v1.classification_codes,display_navigation_versions_v1.reference_year,
    display_navigation_versions_v1.process_subtype,display_navigation_versions_v1.source)
    is distinct from (excluded.access_level,excluded.geography_code,excluded.classification_codes,
      excluded.reference_year,excluded.process_subtype,excluded.source);
  delete from private.display_navigation_membership_v1
    where dataset_kind=p_kind and id=p_id and version=p_version;
  for v_entry, v_entry_level in
    select distinct entry.value, (entry.ordinality - 1)::integer as level
    from pg_catalog.jsonb_array_elements(
      case pg_catalog.jsonb_typeof(p_card -> 'classifications')
        when 'array' then p_card -> 'classifications'
        else '[]'::jsonb
      end
    ) with ordinality as entry(value, ordinality)
    where pg_catalog.jsonb_typeof(entry.value) = 'object'
  loop
    v_node := private.portal_navigation_resolve_classification_v1(
      p_kind, v_entry -> 'system', v_entry, v_entry_level
    );
    if v_node is null then
      -- Keep the unknown/ambiguous authored code browsable under its own
      -- taxonomy instead of dropping it or guessing a node.
      v_code := private.portal_navigation_classification_code_v1(v_entry);
      if v_code is null then
        continue;
      end if;
      v_taxonomy := private.portal_navigation_raw_taxonomy_v1(v_entry -> 'system');
      if (p_kind='flow' and v_taxonomy='isic') or (p_kind='process' and v_taxonomy in ('cpc','elementary')) then
        v_taxonomy := 'unclassified';
      end if;
      v_raw_root := 'class:' || v_taxonomy || ':~raw';
      perform private.portal_navigation_ensure_virtual_v1(
        v_raw_root, 'classification', v_taxonomy, 'unmapped'
      );
      v_node := private.portal_navigation_raw_node_id_v1('class:' || v_taxonomy, p_kind || '|' || coalesce(v_entry->>'system','') || '|' || v_code);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_root, v_code, v_taxonomy, 'classification', null, null,
        pg_catalog.jsonb_build_object(
          'en', v_code, 'zh-CN', v_code, 'de', v_code, 'fr', v_code
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
    v_matched := v_matched + 1;
    v_placements := pg_catalog.array_append(v_placements, v_node);
  end loop;

  if v_matched = 0 then
    perform private.portal_navigation_ensure_virtual_v1(
      'class:unclassified', 'classification', 'unclassified', 'unclassified'
    );
    v_placements := pg_catalog.array_append(v_placements, 'class:unclassified');
  end if;

  v_geography := private.portal_navigation_geography_code_v1(p_kind, p_card);
  if v_geography is not null then
    v_node := 'geo:' || pg_catalog.lower(v_geography);
    if not exists(select 1 from private.portal_navigation_node_v1 n where n.node_id=v_node and n.dimension='geography') then
      v_node := coalesce(private.portal_navigation_resolve_alias_v1('geography',v_geography),v_node);
    end if;
    if not exists (
      select 1
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_node and node.dimension = 'geography'
    ) then
      perform private.portal_navigation_ensure_virtual_v1(
        'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
      );
      v_raw_parent := 'geo:unmapped';
      -- This verified code family is only a containing province, never proof of
      -- a particular city boundary or geographic precision.
      if upper(v_geography) ~ '^CN-[A-Z]{2}-[A-Z0-9-]+$' then
        select node.node_id into v_raw_parent from private.portal_navigation_node_v1 node
        where node.node_id='geo:' || lower(split_part(v_geography,'-',1)||'-'||split_part(v_geography,'-',2))
          and node.parent_node_id='geo:cn';
      end if;
      v_raw_parent := coalesce(v_raw_parent,'geo:unmapped');
      v_node := private.portal_navigation_raw_node_id_v1('geo', v_geography);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_parent, pg_catalog.upper(v_geography), 'unmapped', 'geography',
        null, null,
        pg_catalog.jsonb_build_object(
          'en', pg_catalog.upper(v_geography), 'zh-CN', pg_catalog.upper(v_geography),
          'de', pg_catalog.upper(v_geography), 'fr', pg_catalog.upper(v_geography)
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
  else
    perform private.portal_navigation_ensure_virtual_v1(
      'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
    );
    v_node := 'geo:unmapped';
  end if;
  v_placements := pg_catalog.array_append(v_placements, v_node);

  -- Materialise every ancestor of every authored placement, so a branch count is
  -- one grouped read instead of a per-node descendant search. A closure row is
  -- `direct` only when the authored placement is exactly that node.
  with recursive ancestors as (
    select n.node_id as leaf,n.parent_node_id as ancestor
    from private.portal_navigation_node_v1 n where n.node_id=any(v_placements)
    union all
    select a.leaf,n.parent_node_id from ancestors a
    join private.portal_navigation_node_v1 n on n.node_id=a.ancestor
    where a.ancestor is not null
  ) select coalesce(array_agg(distinct placement), '{}'::text[]) into v_placements
    from unnest(v_placements) placement
    where not exists(select 1 from ancestors a where a.ancestor=placement);

  foreach v_placement in array v_placements
  loop
    insert into private.display_navigation_membership_v1 (
      dataset_kind, id, version, dimension, node_id, direct
    )
    with recursive chain as (
      select node.node_id,
        node.parent_node_id,
        node.dimension
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_placement
      union all
      select parent.node_id,
        parent.parent_node_id,
        parent.dimension
      from private.portal_navigation_node_v1 as parent
      join chain on parent.node_id = chain.parent_node_id
    )
    select p_kind, p_id, p_version, chain.dimension, chain.node_id,
      chain.node_id = v_placement
    from chain
    on conflict (dataset_kind,id,version,dimension,node_id) do update
      set direct=private.display_navigation_membership_v1.direct or excluded.direct;
  end loop;
end;
$_$;

ALTER FUNCTION "private"."display_sync_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_sync_navigation_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  if tg_op='DELETE' then
    delete from private.display_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
    return old;
  end if;
  if tg_op='UPDATE' and (old.dataset_kind,old.id,old.version) is distinct from (new.dataset_kind,new.id,new.version) then
    delete from private.display_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
  end if;
  perform private.display_sync_navigation_membership_v1(new.dataset_kind,new.id,new.version,new.card);
  return new;
end;
$$;

ALTER FUNCTION "private"."display_sync_navigation_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_navigation_row_v1"() FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_sync_sitemap_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  insert into private.display_sitemap_rows_v1 (
    dataset_kind,
    id,
    version,
    modified_at,
    shard_no,
    contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.modified_at,
    (
      pg_catalog.get_byte(
        pg_catalog.decode(
          pg_catalog.md5(
            new.dataset_kind || ':'::text || new.id::text
          ),
          'hex'::text
        ),
        0
      ) / 4
    )::smallint,
    1
  )
  on conflict (dataset_kind, id, version) do update
  set modified_at = excluded.modified_at,
      shard_no = excluded.shard_no,
      contract_version = excluded.contract_version
  where (
    display_sitemap_rows_v1.modified_at,
    display_sitemap_rows_v1.shard_no,
    display_sitemap_rows_v1.contract_version
  ) is distinct from (
    excluded.modified_at,
    excluded.shard_no,
    excluded.contract_version
  );
  return null;
end
$$;

ALTER FUNCTION "private"."display_sync_sitemap_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_sitemap_row_v1"() FROM PUBLIC;


CREATE TABLE IF NOT EXISTS "private"."display_catalog_search_rows_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "card" "jsonb" NOT NULL,
    "document" "text" NOT NULL,
    "projection_contract_version" smallint NOT NULL,
    CONSTRAINT "d807_portal_catalog_search_rows_contract_version_v1_chk" CHECK (("projection_contract_version" = 1)),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_card_check" CHECK (("jsonb_typeof"("card") = 'object'::"text")),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_check" CHECK ((COALESCE(("card" ->> 'document'::"text"), ''::"text") = "document")),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_catalog_search_rows_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_catalog_search_rows_v1" OWNER TO "postgres";

COMMENT ON TABLE "private"."display_catalog_search_rows_v1" IS 'Private synchronized, public-safe Portal card/document projection. Source embeddings and HNSW indexes remain authoritative and are not duplicated.';

ALTER TABLE ONLY "private"."display_catalog_search_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_search_rows_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_catalog_search_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_search_rows_contract_version_v1_fk" FOREIGN KEY ("projection_contract_version") REFERENCES "private"."portal_display_derivation_contract"("contract_version") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."display_catalog_search_rows_v1" ENABLE ROW LEVEL SECURITY;










create policy display_scope on private.display_catalog_search_rows_v1 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_catalog_search_rows_v1 to portal_display_executor;

alter table private.display_catalog_search_rows_v1 add column brand text check(brand is null or brand in ('tiangong_lca','bafu','uslci','worldsteel'));

CREATE INDEX "d807_portal_catalog_search_flow_cas_v1_idx" ON "private"."display_catalog_search_rows_v1" USING "btree" ((("card" ->> 'casNumber'::"text")), "id", "version" DESC, "modified_at" DESC, "state_code" DESC) WHERE (("dataset_kind" = 'flow'::"text") AND ("jsonb_typeof"(("card" -> 'casNumber'::"text")) = 'string'::"text") AND (("card" ->> 'casNumber'::"text") ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'::"text") AND (("length"(("card" ->> 'casNumber'::"text")) >= 7) AND ("length"(("card" ->> 'casNumber'::"text")) <= 12)));


CREATE INDEX "d807_portal_catalog_search_flow_document_v1_pgroonga" ON "private"."display_catalog_search_rows_v1" USING "pgroonga" ("document") WITH ("tokenizer"='TokenBigram', "normalizer"='NormalizerAuto') WHERE ("dataset_kind" = 'flow'::"text");


CREATE INDEX "d807_portal_catalog_search_rows_latest_v1_idx" ON "private"."display_catalog_search_rows_v1" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC);


CREATE INDEX "d807_portal_catalog_summary_eligibility_v1_idx" ON "private"."display_catalog_search_rows_v1" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC) WHERE ((("dataset_kind" = 'flow'::"text") AND ("jsonb_typeof"(("card" -> 'casNumber'::"text")) = 'string'::"text") AND (("card" ->> 'casNumber'::"text") ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'::"text")) OR (("jsonb_typeof"(("card" -> 'classifications'::"text")) = 'array'::"text") AND ("jsonb_array_length"(("card" -> 'classifications'::"text")) > 0)));


CREATE TABLE IF NOT EXISTS "private"."display_catalog_search_rows_v2" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "card" "jsonb" NOT NULL,
    "document" "text" NOT NULL,
    "projection_contract_version" smallint NOT NULL,
    CONSTRAINT "d807_portal_catalog_search_rows_contract_version_v2_chk" CHECK (("projection_contract_version" = 2)),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_card_check" CHECK (("jsonb_typeof"("card") = 'object'::"text")),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = 'process'::"text")),
    CONSTRAINT "d807_portal_catalog_search_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text")),
    CONSTRAINT "d807_portal_catalog_search_rows_v2_check" CHECK ((COALESCE(("card" ->> 'document'::"text"), ''::"text") = "document"))
);

ALTER TABLE ONLY "private"."display_catalog_search_rows_v2" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_catalog_search_rows_v2" OWNER TO "postgres";

COMMENT ON TABLE "private"."display_catalog_search_rows_v2" IS 'Private synchronized, public-safe Portal card/document projection. Source embeddings and HNSW indexes remain authoritative and are not duplicated.';

ALTER TABLE ONLY "private"."display_catalog_search_rows_v2"
    ADD CONSTRAINT "d807_portal_catalog_search_rows_v2_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_catalog_search_rows_v2"
    ADD CONSTRAINT "d807_portal_catalog_search_rows_contract_version_v2_fk" FOREIGN KEY ("projection_contract_version") REFERENCES "private"."portal_display_derivation_contract"("contract_version") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."display_catalog_search_rows_v2" ENABLE ROW LEVEL SECURITY;










create policy display_scope on private.display_catalog_search_rows_v2 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_catalog_search_rows_v2 to portal_display_executor;

alter table private.display_catalog_search_rows_v2 add column brand text check(brand is null or brand in ('tiangong_lca','bafu','uslci','worldsteel'));

CREATE INDEX "d807_portal_catalog_search_process_document_v2_pgroonga" ON "private"."display_catalog_search_rows_v2" USING "pgroonga" ("document") WITH ("tokenizer"='TokenBigram', "normalizer"='NormalizerAuto') WHERE ("dataset_kind" = 'process'::"text");


CREATE INDEX "d807_portal_catalog_search_process_exact_rank_v2_gin" ON "private"."display_catalog_search_rows_v2" USING "gin" ("private"."portal_process_rank_name_keys_v1"("card"), "private"."portal_process_rank_classification_keys_v1"("card")) WHERE ("dataset_kind" = 'process'::"text");


CREATE INDEX "d807_portal_catalog_search_rows_latest_v2_idx" ON "private"."display_catalog_search_rows_v2" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC);


CREATE INDEX "d807_portal_catalog_summary_eligibility_v2_idx" ON "private"."display_catalog_search_rows_v2" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC) WHERE ((("dataset_kind" = 'flow'::"text") AND ("jsonb_typeof"(("card" -> 'casNumber'::"text")) = 'string'::"text") AND (("card" ->> 'casNumber'::"text") ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'::"text")) OR (("jsonb_typeof"(("card" -> 'classifications'::"text")) = 'array'::"text") AND ("jsonb_array_length"(("card" -> 'classifications'::"text")) > 0)));


CREATE TABLE IF NOT EXISTS "private"."display_catalog_facet_rows_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "facet_access_level" "text",
    "facet_geography" "text",
    "facet_reference_year" "text",
    "facet_process_subtype" "text",
    "facet_source" "text",
    "facet_contract_version" smallint NOT NULL,
    CONSTRAINT "d807_portal_catalog_facet_rows_contract_version_v1_chk" CHECK (("facet_contract_version" = 1)),
    CONSTRAINT "d807_portal_catalog_facet_rows_process_subtype_v1_chk" CHECK ((("dataset_kind" = 'process'::"text") OR ("facet_process_subtype" IS NULL))),
    CONSTRAINT "d807_portal_catalog_facet_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_catalog_facet_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_catalog_facet_rows_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_facet_rows_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_facet_rows_contract_version_v1_fk" FOREIGN KEY ("facet_contract_version") REFERENCES "private"."portal_display_derivation_contract"("contract_version") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE ONLY "private"."display_catalog_facet_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_facet_rows_projection_v1_fk" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_search_rows_v1"("dataset_kind", "id", "version") ON UPDATE RESTRICT ON DELETE CASCADE;

ALTER TABLE "private"."display_catalog_facet_rows_v1" ENABLE ROW LEVEL SECURITY;














create policy display_scope on private.display_catalog_facet_rows_v1 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_catalog_facet_rows_v1 to portal_display_executor;

CREATE INDEX "d807_portal_catalog_facet_flow_access_level_v1_idx" ON "private"."display_catalog_facet_rows_v1" USING "btree" ("facet_access_level") INCLUDE ("id", "version") WHERE (("dataset_kind" = 'flow'::"text") AND ("facet_contract_version" = 1));


CREATE INDEX "d807_portal_catalog_facet_flow_geography_v1_idx" ON "private"."display_catalog_facet_rows_v1" USING "btree" ("facet_geography") INCLUDE ("id", "version") WHERE (("dataset_kind" = 'flow'::"text") AND ("facet_contract_version" = 1));


CREATE INDEX "d807_portal_catalog_facet_process_access_level_v1_idx" ON "private"."display_catalog_facet_rows_v1" USING "btree" ("facet_access_level") INCLUDE ("id", "version") WHERE (("dataset_kind" = 'process'::"text") AND ("facet_contract_version" = 1));


CREATE INDEX "d807_portal_catalog_facet_process_geography_v1_idx" ON "private"."display_catalog_facet_rows_v1" USING "btree" ("facet_geography") INCLUDE ("id", "version") WHERE (("dataset_kind" = 'process'::"text") AND ("facet_contract_version" = 1));


CREATE INDEX "d807_portal_catalog_facet_rows_latest_v1_idx" ON "private"."display_catalog_facet_rows_v1" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC);


CREATE TABLE IF NOT EXISTS "private"."display_catalog_character_rows_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "document_characters" "text" NOT NULL,
    "name_characters" "text" NOT NULL,
    "name_exact_characters" "text" NOT NULL,
    "classification_characters" "text" NOT NULL,
    "classification_exact_characters" "text" NOT NULL,
    "character_contract_version" smallint DEFAULT 1 NOT NULL,
    CONSTRAINT "d807_catalog_character_rows__character_contract_version_check" CHECK (("character_contract_version" = 1)),
    CONSTRAINT "d807_portal_catalog_character_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_catalog_character_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_catalog_character_rows_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_catalog_character_rows_v1" OWNER TO "postgres";

COMMENT ON TABLE "private"."display_catalog_character_rows_v1" IS 'Narrow exact-version public character sets for bounded one-code-point Search pre-limit; parent FK and INSERT/UPDATE trigger keep it synchronized.';

ALTER TABLE ONLY "private"."display_catalog_character_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_character_rows_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_catalog_character_rows_v1"
    ADD CONSTRAINT "d807_portal_catalog_character_parent_v1_fk" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_search_rows_v1"("dataset_kind", "id", "version") ON UPDATE RESTRICT ON DELETE CASCADE;

ALTER TABLE "private"."display_catalog_character_rows_v1" ENABLE ROW LEVEL SECURITY;













create policy display_scope on private.display_catalog_character_rows_v1 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_catalog_character_rows_v1 to portal_display_executor;

CREATE INDEX "d807_portal_catalog_character_rows_latest_v1_idx" ON "private"."display_catalog_character_rows_v1" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC);


CREATE TABLE IF NOT EXISTS "private"."display_catalog_character_rows_v2" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "state_code" integer NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "document_characters" "text" NOT NULL,
    "name_characters" "text" NOT NULL,
    "name_exact_characters" "text" NOT NULL,
    "classification_characters" "text" NOT NULL,
    "classification_exact_characters" "text" NOT NULL,
    "character_contract_version" smallint DEFAULT 1 NOT NULL,
    CONSTRAINT "d807_catalog_character_rows__character_contract_version_check" CHECK (("character_contract_version" = 1)),
    CONSTRAINT "d807_portal_catalog_character_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = 'process'::"text")),
    CONSTRAINT "d807_portal_catalog_character_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_catalog_character_rows_v2" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_catalog_character_rows_v2" OWNER TO "postgres";

COMMENT ON TABLE "private"."display_catalog_character_rows_v2" IS 'Narrow exact-version public character sets for bounded one-code-point Search pre-limit; parent FK and INSERT/UPDATE trigger keep it synchronized.';

ALTER TABLE ONLY "private"."display_catalog_character_rows_v2"
    ADD CONSTRAINT "d807_portal_catalog_character_rows_v2_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_catalog_character_rows_v2"
    ADD CONSTRAINT "d807_portal_catalog_character_parent_v2_fk" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_search_rows_v2"("dataset_kind", "id", "version") ON UPDATE RESTRICT ON DELETE CASCADE;

ALTER TABLE "private"."display_catalog_character_rows_v2" ENABLE ROW LEVEL SECURITY;













create policy display_scope on private.display_catalog_character_rows_v2 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_catalog_character_rows_v2 to portal_display_executor;

CREATE INDEX "d807_portal_catalog_character_rows_latest_v2_idx" ON "private"."display_catalog_character_rows_v2" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC);


CREATE TABLE IF NOT EXISTS "private"."display_navigation_versions_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "process_id" "uuid" GENERATED ALWAYS AS (
CASE
    WHEN ("dataset_kind" = 'process'::"text") THEN "id"
    ELSE NULL::"uuid"
END) STORED,
    "process_version" "text" GENERATED ALWAYS AS (
CASE
    WHEN ("dataset_kind" = 'process'::"text") THEN "version"
    ELSE NULL::"text"
END) STORED,
    "access_level" "text" NOT NULL,
    "geography_code" "text",
    "classification_codes" "text"[] NOT NULL,
    "reference_year" integer,
    "process_subtype" "text",
    "source" "text",
    CONSTRAINT "d807_portal_navigation_versions_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"])))
);

ALTER TABLE ONLY "private"."display_navigation_versions_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_navigation_versions_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."display_navigation_versions_v1"
    ADD CONSTRAINT "d807_portal_navigation_versions_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_navigation_versions_v1"
    ADD CONSTRAINT "d807_rtal_navigation_versions_v1_dataset_kind_id_version_fkey" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_search_rows_v1"("dataset_kind", "id", "version") ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY "private"."display_navigation_versions_v1"
    ADD CONSTRAINT "d807_navigation_versions_v1_dataset_kind_process_id_proc_fkey" FOREIGN KEY ("dataset_kind", "process_id", "process_version") REFERENCES "private"."display_catalog_search_rows_v2"("dataset_kind", "id", "version") ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE "private"."display_navigation_versions_v1" ENABLE ROW LEVEL SECURITY;












create policy display_scope on private.display_navigation_versions_v1 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_navigation_versions_v1 to portal_display_executor;

CREATE INDEX "d807_portal_navigation_versions_geography_v1_idx" ON "private"."display_navigation_versions_v1" USING "btree" ("geography_code", "dataset_kind", "id", "version");


CREATE INDEX "d807_portal_navigation_versions_process_parent_v1_idx" ON "private"."display_navigation_versions_v1" USING "btree" ("dataset_kind", "process_id", "process_version") WHERE ("process_id" IS NOT NULL);


CREATE TABLE IF NOT EXISTS "private"."display_navigation_membership_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "dimension" "text" NOT NULL,
    "node_id" "text" NOT NULL,
    "direct" boolean NOT NULL,
    CONSTRAINT "d807_portal_navigation_membership_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_navigation_membership_v1_dimension_check" CHECK (("dimension" = ANY (ARRAY['classification'::"text", 'geography'::"text"]))),
    CONSTRAINT "d807_portal_navigation_membership_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_navigation_membership_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_navigation_membership_v1" OWNER TO "postgres";

ALTER TABLE ONLY "private"."display_navigation_membership_v1"
    ADD CONSTRAINT "d807_portal_navigation_membership_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version", "dimension", "node_id");

ALTER TABLE ONLY "private"."display_navigation_membership_v1"
    ADD CONSTRAINT "d807_al_navigation_membership_v1_dataset_kind_id_version_fkey" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_navigation_versions_v1"("dataset_kind", "id", "version") ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY "private"."display_navigation_membership_v1"
    ADD CONSTRAINT "d807_portal_navigation_membership_v1_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "private"."portal_navigation_node_v1"("node_id") ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE "private"."display_navigation_membership_v1" ENABLE ROW LEVEL SECURITY;









create policy display_scope on private.display_navigation_membership_v1 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_navigation_membership_v1 to portal_display_executor;

CREATE INDEX "d807_portal_navigation_membership_branch_v1_idx" ON "private"."display_navigation_membership_v1" USING "btree" ("dimension", "node_id", "dataset_kind", "id", "version") INCLUDE ("direct");


CREATE INDEX "d807_portal_navigation_membership_node_v1_idx" ON "private"."display_navigation_membership_v1" USING "btree" ("node_id");


CREATE TABLE IF NOT EXISTS "private"."display_sitemap_rows_v1" (
    "dataset_kind" "text" NOT NULL,
    "id" "uuid" NOT NULL,
    "version" "text" NOT NULL,
    "modified_at" timestamp with time zone NOT NULL,
    "shard_no" smallint NOT NULL,
    "contract_version" smallint NOT NULL,
    CONSTRAINT "d807_portal_sitemap_rows_v1_contract_version_check" CHECK (("contract_version" = 1)),
    CONSTRAINT "d807_portal_sitemap_rows_v1_dataset_kind_check" CHECK (("dataset_kind" = ANY (ARRAY['process'::"text", 'flow'::"text"]))),
    CONSTRAINT "d807_portal_sitemap_rows_v1_shard_no_check" CHECK ((("shard_no" >= 0) AND ("shard_no" <= 63))),
    CONSTRAINT "d807_portal_sitemap_rows_v1_version_check" CHECK (("version" ~ '^\d{2}\.\d{2}\.\d{3}$'::"text"))
);

ALTER TABLE ONLY "private"."display_sitemap_rows_v1" FORCE ROW LEVEL SECURITY;

ALTER TABLE "private"."display_sitemap_rows_v1" OWNER TO "postgres";

COMMENT ON TABLE "private"."display_sitemap_rows_v1" IS 'Exact public Process/Flow version and stable 64-way sitemap bucket; contains no card, document, actor, credential, or locator.';

ALTER TABLE ONLY "private"."display_sitemap_rows_v1"
    ADD CONSTRAINT "d807_portal_sitemap_rows_v1_pkey" PRIMARY KEY ("dataset_kind", "id", "version");

ALTER TABLE ONLY "private"."display_sitemap_rows_v1"
    ADD CONSTRAINT "d807_portal_sitemap_rows_source_v1_fk" FOREIGN KEY ("dataset_kind", "id", "version") REFERENCES "private"."display_catalog_facet_rows_v1"("dataset_kind", "id", "version") ON UPDATE RESTRICT ON DELETE CASCADE;

ALTER TABLE "private"."display_sitemap_rows_v1" ENABLE ROW LEVEL SECURITY;









create policy display_scope on private.display_sitemap_rows_v1 for select to portal_display_executor
 using(private.portal_display_request_visible_v1(dataset_kind,id,version));
grant select on private.display_sitemap_rows_v1 to portal_display_executor;

CREATE INDEX "d807_portal_sitemap_rows_shard_v1_idx" ON "private"."display_sitemap_rows_v1" USING "btree" ("shard_no", "contract_version", "dataset_kind", "id", "version" DESC, "modified_at" DESC);


CREATE OR REPLACE TRIGGER "portal_catalog_character_sync_v1" AFTER INSERT OR UPDATE OF "dataset_kind", "id", "version", "state_code", "modified_at", "card", "document" ON "private"."display_catalog_search_rows_v1" FOR EACH ROW EXECUTE FUNCTION "private"."display_sync_catalog_character_row_v1"();


CREATE OR REPLACE TRIGGER "portal_catalog_facet_sync_v1" AFTER INSERT OR UPDATE OF "dataset_kind", "id", "version", "state_code", "modified_at", "card" ON "private"."display_catalog_search_rows_v1" FOR EACH ROW EXECUTE FUNCTION "private"."display_sync_catalog_facet_row_v1"();


CREATE OR REPLACE TRIGGER "portal_navigation_flow_sync_v1" AFTER INSERT OR UPDATE OF "card" ON "private"."display_catalog_search_rows_v1" FOR EACH ROW WHEN (("new"."dataset_kind" = 'flow'::"text")) EXECUTE FUNCTION "private"."display_sync_navigation_row_v1"();


CREATE OR REPLACE TRIGGER "portal_catalog_character_sync_v2" AFTER INSERT OR UPDATE OF "dataset_kind", "id", "version", "state_code", "modified_at", "card", "document" ON "private"."display_catalog_search_rows_v2" FOR EACH ROW EXECUTE FUNCTION "private"."display_sync_catalog_character_row_cn1"();


CREATE OR REPLACE TRIGGER "portal_navigation_process_sync_v1" AFTER INSERT OR DELETE OR UPDATE OF "card" ON "private"."display_catalog_search_rows_v2" FOR EACH ROW EXECUTE FUNCTION "private"."display_sync_navigation_row_v1"();


CREATE OR REPLACE TRIGGER "portal_sitemap_rows_sync_v1" AFTER INSERT OR UPDATE OF "dataset_kind", "id", "version", "state_code", "modified_at", "facet_contract_version" ON "private"."display_catalog_facet_rows_v1" FOR EACH ROW EXECUTE FUNCTION "private"."display_sync_sitemap_row_v1"();


CREATE OR REPLACE VIEW "private"."display_catalog_search_current_v2" WITH ("security_invoker"='true') AS
 SELECT "display_catalog_search_rows_v2"."dataset_kind",
    "display_catalog_search_rows_v2"."id",
    "display_catalog_search_rows_v2"."version",
    "display_catalog_search_rows_v2"."state_code",
    "display_catalog_search_rows_v2"."modified_at",
    "display_catalog_search_rows_v2"."card",
    "display_catalog_search_rows_v2"."document"
   FROM "private"."display_catalog_search_rows_v2"
  WHERE ("display_catalog_search_rows_v2"."dataset_kind" = 'process'::"text")
UNION ALL
 SELECT "display_catalog_search_rows_v1"."dataset_kind",
    "display_catalog_search_rows_v1"."id",
    "display_catalog_search_rows_v1"."version",
    "display_catalog_search_rows_v1"."state_code",
    "display_catalog_search_rows_v1"."modified_at",
    "display_catalog_search_rows_v1"."card",
    "display_catalog_search_rows_v1"."document"
   FROM "private"."display_catalog_search_rows_v1"
  WHERE ("display_catalog_search_rows_v1"."dataset_kind" = 'flow'::"text");

ALTER VIEW "private"."display_catalog_search_current_v2" OWNER TO "postgres";


grant select on private.display_catalog_search_current_v2 to portal_display_executor;

CREATE OR REPLACE VIEW "private"."display_catalog_character_current_v2" WITH ("security_invoker"='true') AS
 SELECT "display_catalog_character_rows_v2"."dataset_kind",
    "display_catalog_character_rows_v2"."id",
    "display_catalog_character_rows_v2"."version",
    "display_catalog_character_rows_v2"."state_code",
    "display_catalog_character_rows_v2"."modified_at",
    "display_catalog_character_rows_v2"."document_characters",
    "display_catalog_character_rows_v2"."name_characters",
    "display_catalog_character_rows_v2"."name_exact_characters",
    "display_catalog_character_rows_v2"."classification_characters",
    "display_catalog_character_rows_v2"."classification_exact_characters"
   FROM "private"."display_catalog_character_rows_v2"
  WHERE ("display_catalog_character_rows_v2"."dataset_kind" = 'process'::"text")
UNION ALL
 SELECT "display_catalog_character_rows_v1"."dataset_kind",
    "display_catalog_character_rows_v1"."id",
    "display_catalog_character_rows_v1"."version",
    "display_catalog_character_rows_v1"."state_code",
    "display_catalog_character_rows_v1"."modified_at",
    "display_catalog_character_rows_v1"."document_characters",
    "display_catalog_character_rows_v1"."name_characters",
    "display_catalog_character_rows_v1"."name_exact_characters",
    "display_catalog_character_rows_v1"."classification_characters",
    "display_catalog_character_rows_v1"."classification_exact_characters"
   FROM "private"."display_catalog_character_rows_v1"
  WHERE ("display_catalog_character_rows_v1"."dataset_kind" = 'flow'::"text");

ALTER VIEW "private"."display_catalog_character_current_v2" OWNER TO "postgres";


grant select on private.display_catalog_character_current_v2 to portal_display_executor;

grant select (id,version,state_code,modified_at,json,embedding_ft) on public.processes to portal_display_executor;
create policy portal_display_select_v1 on public.processes for select to portal_display_executor
 using(private.portal_dataset_is_visible_v1('process',id,version::text));

grant select (id,version,state_code,modified_at,json,embedding_ft) on public.flows to portal_display_executor;
create policy portal_display_select_v1 on public.flows for select to portal_display_executor
 using(private.portal_dataset_is_visible_v1('flow',id,version::text));

grant select (id,version,state_code,modified_at,json) on public.flowproperties to portal_display_executor;
create policy portal_display_select_v1 on public.flowproperties for select to portal_display_executor
 using(private.portal_dataset_is_visible_v1('flowproperty',id,version::text));

grant select (id,version,state_code,modified_at,json) on public.unitgroups to portal_display_executor;
create policy portal_display_select_v1 on public.unitgroups for select to portal_display_executor
 using(private.portal_dataset_is_visible_v1('unitgroup',id,version::text));

grant execute on function private.portal_dataset_is_visible_v1(text,uuid,text) to portal_display_executor;

-- One exact-key synchronizer for both source changes and setting changes.
-- A read always rechecks authoritative settings even if a repair is still pending.
create function private.portal_display_refresh_exact_v1(p_kind text,p_id uuid,p_version text)
returns void language plpgsql security definer set search_path='' as $$
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
end $$;
revoke all on function private.portal_display_refresh_exact_v1(text,uuid,text) from public;
create function private.portal_display_settings_sync_v1() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='DELETE' then
  perform private.portal_display_refresh_exact_v1(old.dataset_kind,old.dataset_id,old.dataset_version);
  return old;
 end if;
 if tg_op='UPDATE' and (old.dataset_kind,old.dataset_id,old.dataset_version) is distinct from (new.dataset_kind,new.dataset_id,new.dataset_version) then
  perform private.portal_display_refresh_exact_v1(old.dataset_kind,old.dataset_id,old.dataset_version);
 end if;
 perform private.portal_display_refresh_exact_v1(new.dataset_kind,new.dataset_id,new.dataset_version);
 return new;
end $$;
revoke all on function private.portal_display_settings_sync_v1() from public;
create trigger portal_display_projection_sync after insert or update or delete on private.dataset_display_settings
 for each row execute function private.portal_display_settings_sync_v1();
create function private.portal_display_source_sync_v1() returns trigger
language plpgsql security definer set search_path='' as $$
declare k text:=tg_argv[0];
begin
 if tg_op='DELETE' then
  delete from private.dataset_display_settings where dataset_kind=k and dataset_id=old.id and dataset_version=old.version::text;
  perform private.portal_display_refresh_exact_v1(k,old.id,old.version::text);
  return old;
 end if;
 if tg_op='UPDATE' and (old.id,old.version) is distinct from (new.id,new.version) then
  delete from private.dataset_display_settings where dataset_kind=k and dataset_id=old.id and dataset_version=old.version::text;
  perform private.portal_display_refresh_exact_v1(k,old.id,old.version::text);
 end if;
 perform private.portal_display_refresh_exact_v1(k,new.id,new.version::text);
 return new;
end $$;
revoke all on function private.portal_display_source_sync_v1() from public;


create trigger portal_display_source_sync after insert or delete or update of id,version,json,state_code,modified_at on public.processes
 for each row execute function private.portal_display_source_sync_v1('process');

create trigger portal_display_source_sync after insert or delete or update of id,version,json,state_code,modified_at on public.flows
 for each row execute function private.portal_display_source_sync_v1('flow');

create trigger portal_display_source_sync after insert or delete or update of id,version,json,state_code,modified_at on public.flowproperties
 for each row execute function private.portal_display_source_sync_v1('flowproperty');

create trigger portal_display_source_sync after insert or delete or update of id,version,json,state_code,modified_at on public.unitgroups
 for each row execute function private.portal_display_source_sync_v1('unitgroup');

create trigger portal_display_source_sync after insert or delete or update of id,version,json,state_code,modified_at on public.sources
 for each row execute function private.portal_display_source_sync_v1('source');

create trigger portal_display_source_sync after insert or delete or update of id,version,json,state_code,modified_at on public.contacts
 for each row execute function private.portal_display_source_sync_v1('contact');

create trigger portal_display_source_sync after insert or delete or update of id,version,json,state_code,modified_at on public.lifecyclemodels
 for each row execute function private.portal_display_source_sync_v1('lifecyclemodel');



-- Database #807: scoped display readers. Existing frozen kernels stay byte-identical.
set local lock_timeout='5s';
set local check_function_bodies=off;
select extensions.vector_dims('[1]'::extensions.vector);
grant portal_display_executor to postgres with set true;
grant portal_public_executor to postgres with set true;
grant create on schema private to portal_public_executor;
grant usage,create on schema private,api to portal_display_executor;
create function private.portal_display_scope_identity_v1() returns text
language sql stable set search_path='' as $$
 select 'portal-display-scope.v1:' || coalesce(current_setting('portal.display_brands',true),'')
 || ':global=' || coalesce(current_setting('portal.display_global',true),'false')
 || ':filter=' || coalesce(current_setting('portal.display_filter_brand',true),'')
$$;
revoke all on function private.portal_display_scope_identity_v1() from public;
grant execute on function private.portal_display_scope_identity_v1() to portal_display_executor;
create function private.portal_display_begin_request_v1(p_allowed_brands text[],p_filters jsonb default '{}')
returns void language plpgsql security definer set search_path='' as $$
declare b text[]:=private.portal_normalize_brand_scope_v1(p_allowed_brands); f text;
begin
 if (select mode from private.portal_display_rollout where singleton) is distinct from 'display' then
  raise exception using errcode='P0001',message='portal catalog unavailable';
 end if;
 if p_filters ? 'brand' then
  f:=p_filters->>'brand';
  if jsonb_typeof(p_filters->'brand') is distinct from 'string'
   or f is null or f not in ('tiangong_lca','bafu','uslci','worldsteel') then
   raise exception using errcode='22023',message='invalid portal request';
  end if;
 end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands',array_to_string(b,','),true);
 perform set_config('portal.display_global','false',true);
 perform set_config('portal.display_filter_brand',coalesce(f,''),true);
end $$;
revoke all on function private.portal_display_begin_request_v1(text[],jsonb) from public;
grant execute on function private.portal_display_begin_request_v1(text[],jsonb) to portal_display_executor;


create view private.display_read_lcia_projection_headers as select "id", "status", "process_count", "impact_count", "expected_value_count", "content_hash" from private.portal_lcia_projection_headers; grant select on private.display_read_lcia_projection_headers to portal_display_executor,postgres; alter view private.display_read_lcia_projection_headers owner to portal_public_executor;

create view private.display_read_lcia_projection_impact_axis as select "projection_id", "impact_index", "method_id", "method_version", "impact_id", "impact_name", "unit" from private.portal_lcia_projection_impact_axis; grant select on private.display_read_lcia_projection_impact_axis to portal_display_executor,postgres; alter view private.display_read_lcia_projection_impact_axis owner to portal_public_executor;

create view private.display_read_lcia_projection_process_axis as select "projection_id", "process_index", "process_id", "process_version", "functional_unit_amount", "functional_unit_unit", "functional_unit_description", "geography_code", "geography_precision", "reference_year" from private.portal_lcia_projection_process_axis; grant select on private.display_read_lcia_projection_process_axis to portal_display_executor,postgres; alter view private.display_read_lcia_projection_process_axis owner to portal_public_executor;

create view private.display_read_lcia_projection_publications as select "id", "projection_id", "lcia_result_publication_id", "package_id", "package_version", "projection_content_hash", "evidence_hash", "source_published_at", "status", "revoked_at" from private.portal_lcia_projection_publications; grant select on private.display_read_lcia_projection_publications to portal_display_executor,postgres; alter view private.display_read_lcia_projection_publications owner to portal_public_executor;

create view private.display_read_lcia_projection_values as select "projection_id", "ordinal", "process_index", "impact_index", "value_text", "value_numeric" from private.portal_lcia_projection_values; grant select on private.display_read_lcia_projection_values to portal_display_executor,postgres; alter view private.display_read_lcia_projection_values owner to portal_public_executor;

create view private.display_read_navigation_contract_v1 as select "contract_version", "asset_sha256" from private.portal_navigation_contract_v1; grant select on private.display_read_navigation_contract_v1 to portal_display_executor,postgres; alter view private.display_read_navigation_contract_v1 owner to portal_public_executor;

create view private.display_read_navigation_node_v1 as select "node_id", "parent_node_id", "code", "taxonomy", "dimension", "source_index_path", "source_file", "alias_codes", "labels", "label_strategy" from private.portal_navigation_node_v1; grant select on private.display_read_navigation_node_v1 to portal_display_executor,postgres; alter view private.display_read_navigation_node_v1 owner to portal_public_executor;

create view private.display_read_navigation_projection_contract_v1 as select "routine_identity", "definition_sha256", "owner_name" from private.portal_navigation_projection_contract_v1; grant select on private.display_read_navigation_projection_contract_v1 to portal_display_executor,postgres; alter view private.display_read_navigation_projection_contract_v1 owner to portal_public_executor;

CREATE OR REPLACE FUNCTION "private"."display_catalog_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("id" "uuid", "version" "text", "card" "jsonb", "state_code" integer, "modified_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $_$
begin
  if p_kind = 'process' and p_query = '' then
    return query
    select distinct on (projection.id)
      projection.id,
      projection.version,
      projection.card,
      projection.state_code,
      projection.modified_at
    from private.display_catalog_search_current_v2 as projection
    where projection.dataset_kind = 'process'
    order by projection.id,
      projection.version desc,
      projection.modified_at desc,
      projection.state_code desc;
    return;
  end if;

  if p_kind = 'process' and p_exact_id is not null then
    return query
    with matched as materialized (
      select pattern.id,
        pattern.version,
        false as exact_id
      from private.display_catalog_process_pattern_versions_v1(
        p_like_pattern
      ) as pattern
      union
      select projection.id,
        projection.version,
        true
      from private.display_catalog_search_current_v2 as projection
      where projection.dataset_kind = 'process'
        and projection.id = p_exact_id
    ), candidate_ids as materialized (
      select matched.id,
        pg_catalog.bool_or(matched.exact_id) as exact_id
      from matched
      group by matched.id
    ), matched_versions as materialized (
      select distinct matched.id,
        matched.version
      from matched
    ), latest_keys as materialized (
      select latest.id,
        latest.version,
        candidate_ids.exact_id
      from candidate_ids
      cross join lateral (
        select projection.id,
          projection.version
        from private.display_catalog_search_current_v2 as projection
        where projection.dataset_kind = 'process'
          and projection.id = candidate_ids.id
        order by projection.version desc,
          projection.modified_at desc,
          projection.state_code desc
        limit 1
      ) as latest
    ), eligible_keys as materialized (
      select latest.id,
        latest.version
      from latest_keys as latest
      left join matched_versions as latest_match
        on latest_match.id = latest.id
       and latest_match.version = latest.version
      where latest.exact_id
         or latest_match.id is not null
    )
    select projection.id,
      projection.version,
      projection.card,
      projection.state_code,
      projection.modified_at
    from eligible_keys
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = 'process'
     and projection.id = eligible_keys.id
     and projection.version = eligible_keys.version;
    return;
  end if;

  if p_kind = 'process' then
    return query
    with matched as materialized (
      select pattern.id,
        pattern.version
      from private.display_catalog_process_pattern_versions_v1(
        p_like_pattern
      ) as pattern
    ), candidate_ids as materialized (
      select distinct matched.id
      from matched
    ), matched_versions as materialized (
      select distinct matched.id,
        matched.version
      from matched
    ), latest_keys as materialized (
      select latest.id,
        latest.version
      from candidate_ids
      cross join lateral (
        select projection.id,
          projection.version
        from private.display_catalog_search_current_v2 as projection
        where projection.dataset_kind = 'process'
          and projection.id = candidate_ids.id
        order by projection.version desc,
          projection.modified_at desc,
          projection.state_code desc
        limit 1
      ) as latest
    ), eligible_keys as materialized (
      select latest.id,
        latest.version
      from latest_keys as latest
      join matched_versions as latest_match
        on latest_match.id = latest.id
       and latest_match.version = latest.version
    )
    select projection.id,
      projection.version,
      projection.card,
      projection.state_code,
      projection.modified_at
    from eligible_keys
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = 'process'
     and projection.id = eligible_keys.id
     and projection.version = eligible_keys.version;
    return;
  end if;

  if p_kind = 'flow' and p_query = '' then
    return query
    select distinct on (projection.id)
      projection.id,
      projection.version,
      projection.card,
      projection.state_code,
      projection.modified_at
    from private.display_catalog_search_current_v2 as projection
    where projection.dataset_kind = 'flow'
    order by projection.id,
      projection.version desc,
      projection.modified_at desc,
      projection.state_code desc;
    return;
  end if;

  if p_kind = 'flow'
     and private.display_catalog_summary_valid_cas_v1(p_query) then
    return query
    with candidate_ids as materialized (
      select distinct projection.id
      from private.display_catalog_search_current_v2 as projection
      where projection.dataset_kind = 'flow'
        and pg_catalog.jsonb_typeof(
          projection.card -> 'casNumber'
        ) = 'string'
        and projection.card ->> 'casNumber' ~
          '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
        and pg_catalog.length(
          projection.card ->> 'casNumber'
        ) between 7 and 12
        and projection.card ->> 'casNumber' = p_query
    ), latest_rows as materialized (
      select latest.id,
        latest.version,
        latest.card,
        latest.state_code,
        latest.modified_at
      from candidate_ids
      cross join lateral (
        select projection.id,
          projection.version,
          projection.card,
          projection.state_code,
          projection.modified_at
        from private.display_catalog_search_current_v2 as projection
        where projection.dataset_kind = 'flow'
          and projection.id = candidate_ids.id
        order by projection.version desc,
          projection.modified_at desc,
          projection.state_code desc
        limit 1
      ) as latest
      where pg_catalog.jsonb_typeof(
          latest.card -> 'casNumber'
        ) = 'string'
        and latest.card ->> 'casNumber' = p_query
    )
    select latest.id,
      latest.version,
      latest.card,
      latest.state_code,
      latest.modified_at
    from latest_rows as latest;
    return;
  end if;

  if p_kind = 'flow' and p_exact_id is not null then
    return query
    with matched as materialized (
      select pattern.id,
        pattern.version,
        false as exact_id
      from private.display_catalog_flow_pattern_versions_v1(
        p_like_pattern
      ) as pattern
      union
      select projection.id,
        projection.version,
        true
      from private.display_catalog_search_current_v2 as projection
      where projection.dataset_kind = 'flow'
        and projection.id = p_exact_id
    ), candidate_ids as materialized (
      select matched.id,
        pg_catalog.bool_or(matched.exact_id) as exact_id
      from matched
      group by matched.id
    ), matched_versions as materialized (
      select distinct matched.id,
        matched.version
      from matched
    ), latest_keys as materialized (
      select latest.id,
        latest.version,
        candidate_ids.exact_id
      from candidate_ids
      cross join lateral (
        select projection.id,
          projection.version
        from private.display_catalog_search_current_v2 as projection
        where projection.dataset_kind = 'flow'
          and projection.id = candidate_ids.id
        order by projection.version desc,
          projection.modified_at desc,
          projection.state_code desc
        limit 1
      ) as latest
    ), eligible_keys as materialized (
      select latest.id,
        latest.version
      from latest_keys as latest
      left join matched_versions as latest_match
        on latest_match.id = latest.id
       and latest_match.version = latest.version
      where latest.exact_id
         or latest_match.id is not null
    )
    select projection.id,
      projection.version,
      projection.card,
      projection.state_code,
      projection.modified_at
    from eligible_keys
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = 'flow'
     and projection.id = eligible_keys.id
     and projection.version = eligible_keys.version;
    return;
  end if;

  if p_kind = 'flow' then
    return query
    with matched as materialized (
      select pattern.id,
        pattern.version
      from private.display_catalog_flow_pattern_versions_v1(
        p_like_pattern
      ) as pattern
    ), candidate_ids as materialized (
      select distinct matched.id
      from matched
    ), matched_versions as materialized (
      select distinct matched.id,
        matched.version
      from matched
    ), latest_keys as materialized (
      select latest.id,
        latest.version
      from candidate_ids
      cross join lateral (
        select projection.id,
          projection.version
        from private.display_catalog_search_current_v2 as projection
        where projection.dataset_kind = 'flow'
          and projection.id = candidate_ids.id
        order by projection.version desc,
          projection.modified_at desc,
          projection.state_code desc
        limit 1
      ) as latest
    ), eligible_keys as materialized (
      select latest.id,
        latest.version
      from latest_keys as latest
      join matched_versions as latest_match
        on latest_match.id = latest.id
       and latest_match.version = latest.version
    )
    select projection.id,
      projection.version,
      projection.card,
      projection.state_code,
      projection.modified_at
    from eligible_keys
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = 'flow'
     and projection.id = eligible_keys.id
     and projection.version = eligible_keys.version;
  end if;
end
$_$;

ALTER FUNCTION "private"."display_catalog_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("id" "uuid", "version" "text", "card" "jsonb", "state_code" integer, "modified_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $_$
begin
  if p_kind not in ('process','flow') or p_kind is null then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_query = '' then
    return query
    select p.id, p.version, p.card, p.state_code, p.modified_at
    from private.display_catalog_search_current_v2 as p
    where p.dataset_kind = p_kind and true;
    return;
  end if;
  if p_kind = 'flow' and private.display_catalog_summary_valid_cas_v1(p_query) then
    return query
    select p.id, p.version, p.card, p.state_code, p.modified_at
    from private.display_catalog_search_current_v2 as p
    where p.dataset_kind = 'flow' and true
      and pg_catalog.jsonb_typeof(p.card -> 'casNumber') = 'string'
      and p.card ->> 'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(p.card ->> 'casNumber') between 7 and 12
      and p.card ->> 'casNumber' = p_query;
    return;
  end if;
  return query
  with pattern_matches as materialized (
    select pattern.id,pattern.version
    from private.display_catalog_process_pattern_versions_v1(p_like_pattern) as pattern
    where p_kind='process'
    union all
    select pattern.id,pattern.version
    from private.display_catalog_flow_pattern_versions_v1(p_like_pattern) as pattern
    where p_kind='flow'
  ), matched as materialized (
    select pattern.id, pattern.version
    from pattern_matches as pattern
    union
    select p.id, p.version
    from private.display_catalog_search_current_v2 as p
    where p.dataset_kind = p_kind and p.id = p_exact_id and true
  )
  select p.id, p.version, p.card, p.state_code, p.modified_at
  from matched
  join private.display_catalog_search_current_v2 as p
    on p.dataset_kind = p_kind and p.id = matched.id and p.version = matched.version
  where true;
end;
$_$;

ALTER FUNCTION "private"."display_catalog_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("id" "uuid", "version" "text", "card" "jsonb", "state_code" integer, "modified_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "row_security" TO 'on'
    AS $$
  select candidate.id,
    candidate.version,
    candidate.card,
    candidate.state_code,
    candidate.modified_at
  from private.display_catalog_candidate_rows_v2(
    p_kind, p_query, p_exact_id, p_like_pattern
  ) as candidate
$$;

ALTER FUNCTION "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_card_facts_v1"("p_card" "jsonb", "p_filters" "jsonb", "p_query" "text") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select pg_catalog.jsonb_build_object(
    'accessLevel', p_card -> 'accessLevel',
    'nameKey', p_card #> '{names,0,value}',
    'nameExact', pg_catalog.to_jsonb(case when p_query = '' then false else
      exists (
        select 1
        from pg_catalog.jsonb_array_elements(
          coalesce(p_card -> 'names', '[]'::jsonb)
        ) as name(item)
        where pg_catalog.lower(pg_catalog.btrim(name.item ->> 'value')) = p_query
      )
    end),
    'nameContains', pg_catalog.to_jsonb(case when p_query = '' then false else
      exists (
        select 1
        from pg_catalog.jsonb_array_elements(
          coalesce(p_card -> 'names', '[]'::jsonb)
        ) as name(item)
        where pg_catalog.strpos(
          pg_catalog.lower(name.item ->> 'value'),
          p_query
        ) > 0
      )
    end),
    'classificationExact', pg_catalog.to_jsonb(
      case when p_query = '' then false else exists (
        select 1
        from pg_catalog.jsonb_array_elements(
          coalesce(p_card -> 'classifications', '[]'::jsonb)
        ) as classification(item)
        where pg_catalog.lower(pg_catalog.btrim(
          classification.item ->> 'code'
        )) = p_query
      ) end
    ),
    'classificationContains', pg_catalog.to_jsonb(
      case when p_query = '' then false else exists (
        select 1
        from pg_catalog.jsonb_array_elements(
          coalesce(p_card -> 'classifications', '[]'::jsonb)
        ) as classification(item)
        where pg_catalog.strpos(
          pg_catalog.lower(classification.item ->> 'code'),
          p_query
        ) > 0
      ) end
    ),
    'classificationFilterMatch', pg_catalog.to_jsonb(
      case when not (p_filters ? 'classification') then false else exists (
        select 1
        from pg_catalog.jsonb_array_elements(
          coalesce(p_card -> 'classifications', '[]'::jsonb)
        ) as classification(item)
        where pg_catalog.lower(pg_catalog.btrim(
          classification.item ->> 'code'
        )) = p_filters ->> 'classification'
      ) end
    ),
    'geographyCode', p_card #> '{geography,code}',
    'referenceYear', p_card -> 'referenceYear',
    'processSubtype', p_card -> 'processSubtype',
    'source', p_card -> 'source',
    'casNumber', p_card -> 'casNumber'
  )
$$;

ALTER FUNCTION "private"."display_catalog_card_facts_v1"("p_card" "jsonb", "p_filters" "jsonb", "p_query" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_card_facts_v1"("p_card" "jsonb", "p_filters" "jsonb", "p_query" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_facet_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("dataset_kind" "text", "id" "uuid", "version" "text", "card" "jsonb")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
begin
  if p_kind = 'process' then
    return query
    select 'process'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v1(
      'process', p_query, p_exact_id, p_like_pattern
    ) as candidate;
  elsif p_kind = 'flow' then
    return query
    select 'flow'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v1(
      'flow', p_query, p_exact_id, p_like_pattern
    ) as candidate;
  elsif p_kind = 'all' then
    return query
    select 'process'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v1(
      'process', p_query, p_exact_id, p_like_pattern
    ) as candidate;
    return query
    select 'flow'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v1(
      'flow', p_query, p_exact_id, p_like_pattern
    ) as candidate;
  end if;
end
$$;

ALTER FUNCTION "private"."display_catalog_facet_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facet_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_facet_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("dataset_kind" "text", "id" "uuid", "version" "text", "card" "jsonb")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
begin
  if p_kind = 'process' then
    return query
    select 'process'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v2(
      'process', p_query, p_exact_id, p_like_pattern
    ) as candidate;
  elsif p_kind = 'flow' then
    return query
    select 'flow'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v2(
      'flow', p_query, p_exact_id, p_like_pattern
    ) as candidate;
  elsif p_kind = 'all' then
    return query
    select 'process'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v2(
      'process', p_query, p_exact_id, p_like_pattern
    ) as candidate;
    return query
    select 'flow'::text,
      candidate.id,
      candidate.version,
      candidate.card
    from private.display_catalog_candidate_rows_v2(
      'flow', p_query, p_exact_id, p_like_pattern
    ) as candidate;
  end if;
end
$$;

ALTER FUNCTION "private"."display_catalog_facet_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facet_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("dataset_kind" "text", "id" "uuid", "version" "text", "card" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "row_security" TO 'on'
    AS $$
  select candidate.dataset_kind,
    candidate.id,
    candidate.version,
    candidate.card
  from private.display_catalog_facet_candidate_rows_v2(
    p_kind, p_query, p_exact_id, p_like_pattern
  ) as candidate
$$;

ALTER FUNCTION "private"."display_catalog_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_facets_empty_v1_impl"("p_kind" "text", "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "work_mem" TO '32MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
  with latest as materialized (
    select distinct on (facet.dataset_kind, facet.id)
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.facet_access_level,
      facet.facet_geography,
      facet.facet_reference_year,
      facet.facet_process_subtype,
      facet.facet_source
    from private.display_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1
      and (p_kind = 'all' or facet.dataset_kind = p_kind)
    order by facet.dataset_kind,
      facet.id,
      facet.version desc,
      facet.modified_at desc,
      facet.state_code desc
  ), facts as materialized (
    select latest.dataset_kind,
      latest.facet_access_level,
      latest.facet_geography,
      latest.facet_reference_year,
      case when latest.dataset_kind = 'process' then
        latest.facet_process_subtype
      else null::text end as facet_process_subtype,
      latest.facet_source
    from latest
  ), counts_raw as materialized (
    select case
        when grouping(facts.dataset_kind) = 0 then 'kind'
        when grouping(facts.facet_access_level) = 0 then 'accessLevel'
        when grouping(facts.facet_geography) = 0 then 'geography'
        when grouping(facts.facet_reference_year) = 0 then 'referenceYear'
        when grouping(facts.facet_process_subtype) = 0 then 'processSubtype'
        else 'source'
      end as group_id,
      case
        when grouping(facts.dataset_kind) = 0 then 1
        when grouping(facts.facet_access_level) = 0 then 2
        when grouping(facts.facet_geography) = 0 then 3
        when grouping(facts.facet_reference_year) = 0 then 4
        when grouping(facts.facet_process_subtype) = 0 then 5
        else 6
      end as group_order,
      case
        when grouping(facts.dataset_kind) = 0 then facts.dataset_kind
        when grouping(facts.facet_access_level) = 0 then
          facts.facet_access_level
        when grouping(facts.facet_geography) = 0 then facts.facet_geography
        when grouping(facts.facet_reference_year) = 0 then
          facts.facet_reference_year
        when grouping(facts.facet_process_subtype) = 0 then
          facts.facet_process_subtype
        else facts.facet_source
      end as value,
      pg_catalog.count(*) as value_count
    from facts
    group by grouping sets (
      (facts.dataset_kind),
      (facts.facet_access_level),
      (facts.facet_geography),
      (facts.facet_reference_year),
      (facts.facet_process_subtype),
      (facts.facet_source)
    )
  ), counts as materialized (
    select counts_raw.group_id,
      counts_raw.group_order,
      counts_raw.value,
      counts_raw.value as label,
      counts_raw.value_count
    from counts_raw
    where nullif(pg_catalog.btrim(counts_raw.value), '') is not null
      and pg_catalog.length(counts_raw.value) <= 128
      and pg_catalog.octet_length(counts_raw.value) <= 512
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v1',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
$$;

ALTER FUNCTION "private"."display_catalog_facets_empty_v1_impl"("p_kind" "text", "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facets_empty_v1_impl"("p_kind" "text", "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_facets_empty_v2_impl"("p_kind" "text", "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "work_mem" TO '32MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
  with visible_versions as not materialized (
    select
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.facet_access_level,
      facet.facet_geography,
      facet.facet_reference_year,
      facet.facet_process_subtype,
      facet.facet_source
    from private.display_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1 and true
      and (p_kind = 'all' or facet.dataset_kind = p_kind)
  ), facts as not materialized (
    select visible_versions.dataset_kind,
      visible_versions.facet_access_level,
      visible_versions.facet_geography,
      visible_versions.facet_reference_year,
      case when visible_versions.dataset_kind = 'process' then
        visible_versions.facet_process_subtype
      else null::text end as facet_process_subtype,
      visible_versions.facet_source
    from visible_versions
  ), counts_raw as materialized (
    select case
        when grouping(facts.dataset_kind) = 0 then 'kind'
        when grouping(facts.facet_access_level) = 0 then 'accessLevel'
        when grouping(facts.facet_geography) = 0 then 'geography'
        when grouping(facts.facet_reference_year) = 0 then 'referenceYear'
        when grouping(facts.facet_process_subtype) = 0 then 'processSubtype'
        else 'source'
      end as group_id,
      case
        when grouping(facts.dataset_kind) = 0 then 1
        when grouping(facts.facet_access_level) = 0 then 2
        when grouping(facts.facet_geography) = 0 then 3
        when grouping(facts.facet_reference_year) = 0 then 4
        when grouping(facts.facet_process_subtype) = 0 then 5
        else 6
      end as group_order,
      case
        when grouping(facts.dataset_kind) = 0 then facts.dataset_kind
        when grouping(facts.facet_access_level) = 0 then
          facts.facet_access_level
        when grouping(facts.facet_geography) = 0 then facts.facet_geography
        when grouping(facts.facet_reference_year) = 0 then
          facts.facet_reference_year
        when grouping(facts.facet_process_subtype) = 0 then
          facts.facet_process_subtype
        else facts.facet_source
      end as value,
      pg_catalog.count(*) as value_count
    from facts
    group by grouping sets (
      (facts.dataset_kind),
      (facts.facet_access_level),
      (facts.facet_geography),
      (facts.facet_reference_year),
      (facts.facet_process_subtype),
      (facts.facet_source)
    )
  ), counts as materialized (
    select counts_raw.group_id,
      counts_raw.group_order,
      counts_raw.value,
      counts_raw.value as label,
      counts_raw.value_count
    from counts_raw
    where nullif(pg_catalog.btrim(counts_raw.value), '') is not null
      and pg_catalog.length(counts_raw.value) <= 128
      and pg_catalog.octet_length(counts_raw.value) <= 512
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v2',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
$$;

ALTER FUNCTION "private"."display_catalog_facets_empty_v2_impl"("p_kind" "text", "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facets_empty_v2_impl"("p_kind" "text", "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_facets_v1_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
  with matched as materialized (
    select candidate.*
    from private.display_catalog_facet_candidate_rows_v1(
      p_kind,
      p_query,
      p_exact_id,
      p_like_pattern
    ) as candidate
    where (
        not (p_filters ? 'accessLevel')
        or candidate.card ->> 'accessLevel' = p_filters ->> 'accessLevel'
      )
      and (
        not (p_filters ? 'geography')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card #>> '{geography,code}',
          ''
        ))) = p_filters ->> 'geography'
      )
      and (
        not (p_filters ? 'classification')
        or exists (
          select 1
          from pg_catalog.jsonb_array_elements(
            candidate.card -> 'classifications'
          ) as classification(item)
          where pg_catalog.lower(pg_catalog.btrim(
            classification.item ->> 'code'
          )) = p_filters ->> 'classification'
        )
      )
      and (
        not (p_filters ? 'referenceYearFrom')
        or (candidate.card ->> 'referenceYear')::integer
          >= (p_filters ->> 'referenceYearFrom')::integer
      )
      and (
        not (p_filters ? 'referenceYearTo')
        or (candidate.card ->> 'referenceYear')::integer
          <= (p_filters ->> 'referenceYearTo')::integer
      )
      and (
        not (p_filters ? 'processSubtype')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card ->> 'processSubtype',
          ''
        ))) = p_filters ->> 'processSubtype'
      )
      and (
        not (p_filters ? 'source')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card ->> 'source',
          ''
        ))) = p_filters ->> 'source'
      )
  ), facet_values as materialized (
    select 'kind'::text as group_id,
      1 as group_order,
      matched.dataset_kind as value,
      matched.dataset_kind as label
    from matched
    union all
    select 'accessLevel',
      2,
      matched.card ->> 'accessLevel',
      matched.card ->> 'accessLevel'
    from matched
    union all
    select 'geography',
      3,
      pg_catalog.lower(pg_catalog.btrim(
        matched.card #>> '{geography,code}'
      )),
      matched.card #>> '{geography,code}'
    from matched
    union all
    select 'referenceYear',
      4,
      pg_catalog.btrim(matched.card ->> 'referenceYear'),
      pg_catalog.btrim(matched.card ->> 'referenceYear')
    from matched
    union all
    select 'processSubtype',
      5,
      pg_catalog.lower(pg_catalog.btrim(
        matched.card ->> 'processSubtype'
      )),
      matched.card ->> 'processSubtype'
    from matched
    where matched.dataset_kind = 'process'
    union all
    select 'source',
      6,
      pg_catalog.lower(pg_catalog.btrim(matched.card ->> 'source')),
      matched.card ->> 'source'
    from matched
  ), counts as materialized (
    select group_id,
      group_order,
      value,
      pg_catalog.min(value) as label,
      pg_catalog.count(*) as value_count
    from facet_values
    where nullif(pg_catalog.btrim(value), '') is not null
      and pg_catalog.length(value) <= 128
      and pg_catalog.octet_length(value) <= 512
    group by group_id, group_order, value
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v1',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
$$;

ALTER FUNCTION "private"."display_catalog_facets_v1_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facets_v1_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_facets_v2_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $_$
begin
    return (
with pattern_matches as materialized (
    select 'process'::text as dataset_kind,pattern.id,pattern.version
    from private.display_catalog_process_pattern_versions_v1(p_like_pattern) pattern
    where p_kind in ('process','all') and p_query<>''
    union all
    select 'flow'::text,pattern.id,pattern.version
    from private.display_catalog_flow_pattern_versions_v1(p_like_pattern) pattern
    where p_kind in ('flow','all') and p_query<>'' and not private.display_catalog_summary_valid_cas_v1(p_query)
  ), candidate_keys as materialized (
    select dataset_kind,id,version from pattern_matches
    union
    select p.dataset_kind,p.id,p.version from private.display_catalog_search_current_v2 p
    where (p_kind='all' or p.dataset_kind=p_kind) and true
      and p.id=p_exact_id
    union
    select 'flow'::text,p.id,p.version from private.display_catalog_search_rows_v1 p
    where p_kind in ('flow','all') and p_query<>''
      and private.display_catalog_summary_valid_cas_v1(p_query)
      and p.dataset_kind='flow' and true
      and pg_catalog.jsonb_typeof(p.card->'casNumber')='string'
      and p.card->>'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(p.card->>'casNumber') between 7 and 12
      and p.card->>'casNumber'=p_query
  ), matched as materialized (
    select filtered.* from private.display_navigation_matched_versions_v1(p_kind,'',p_filters) filtered
    where p_query='' or (filtered.dataset_kind,filtered.id,filtered.version)
      in (select dataset_kind,id,version from candidate_keys)
  ), visible_versions as materialized (
    select
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.facet_access_level,
      facet.facet_geography,
      facet.facet_reference_year,
      facet.facet_process_subtype,
      facet.facet_source
    from private.display_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1 and true
      and (p_kind = 'all' or facet.dataset_kind = p_kind)
      and (facet.dataset_kind,facet.id,facet.version) in (select dataset_kind,id,version from matched)
  ), facts as materialized (
    select visible_versions.dataset_kind,
      visible_versions.facet_access_level,
      visible_versions.facet_geography,
      visible_versions.facet_reference_year,
      case when visible_versions.dataset_kind = 'process' then
        visible_versions.facet_process_subtype
      else null::text end as facet_process_subtype,
      visible_versions.facet_source
    from visible_versions
  ), counts_raw as materialized (
    select case
        when grouping(facts.dataset_kind) = 0 then 'kind'
        when grouping(facts.facet_access_level) = 0 then 'accessLevel'
        when grouping(facts.facet_geography) = 0 then 'geography'
        when grouping(facts.facet_reference_year) = 0 then 'referenceYear'
        when grouping(facts.facet_process_subtype) = 0 then 'processSubtype'
        else 'source'
      end as group_id,
      case
        when grouping(facts.dataset_kind) = 0 then 1
        when grouping(facts.facet_access_level) = 0 then 2
        when grouping(facts.facet_geography) = 0 then 3
        when grouping(facts.facet_reference_year) = 0 then 4
        when grouping(facts.facet_process_subtype) = 0 then 5
        else 6
      end as group_order,
      case
        when grouping(facts.dataset_kind) = 0 then facts.dataset_kind
        when grouping(facts.facet_access_level) = 0 then
          facts.facet_access_level
        when grouping(facts.facet_geography) = 0 then facts.facet_geography
        when grouping(facts.facet_reference_year) = 0 then
          facts.facet_reference_year
        when grouping(facts.facet_process_subtype) = 0 then
          facts.facet_process_subtype
        else facts.facet_source
      end as value,
      pg_catalog.count(*) as value_count
    from facts
    group by grouping sets (
      (facts.dataset_kind),
      (facts.facet_access_level),
      (facts.facet_geography),
      (facts.facet_reference_year),
      (facts.facet_process_subtype),
      (facts.facet_source)
    )
  ), counts as materialized (
    select counts_raw.group_id,
      counts_raw.group_order,
      counts_raw.value,
      counts_raw.value as label,
      counts_raw.value_count
    from counts_raw
    where nullif(pg_catalog.btrim(counts_raw.value), '') is not null
      and pg_catalog.length(counts_raw.value) <= 128
      and pg_catalog.octet_length(counts_raw.value) <= 512
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v2',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
    );
end;

$_$;

ALTER FUNCTION "private"."display_catalog_facets_v2_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facets_v2_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_facets_v3_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
begin
  if p_query='' then
    return (
with matched as materialized (
    select * from private.display_navigation_matched_versions_v1(p_kind,p_query,p_filters)
  ), visible_versions as materialized (
    select
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.facet_access_level,
      facet.facet_geography,
      facet.facet_reference_year,
      facet.facet_process_subtype,
      facet.facet_source
    from private.display_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1 and true
      and (p_kind = 'all' or facet.dataset_kind = p_kind)
      and (facet.dataset_kind,facet.id,facet.version) in (select dataset_kind,id,version from matched)
  ), facts as materialized (
    select visible_versions.dataset_kind,
      visible_versions.facet_access_level,
      visible_versions.facet_geography,
      visible_versions.facet_reference_year,
      case when visible_versions.dataset_kind = 'process' then
        visible_versions.facet_process_subtype
      else null::text end as facet_process_subtype,
      visible_versions.facet_source
    from visible_versions
  ), counts_raw as materialized (
    select case
        when grouping(facts.dataset_kind) = 0 then 'kind'
        when grouping(facts.facet_access_level) = 0 then 'accessLevel'
        when grouping(facts.facet_geography) = 0 then 'geography'
        when grouping(facts.facet_reference_year) = 0 then 'referenceYear'
        when grouping(facts.facet_process_subtype) = 0 then 'processSubtype'
        else 'source'
      end as group_id,
      case
        when grouping(facts.dataset_kind) = 0 then 1
        when grouping(facts.facet_access_level) = 0 then 2
        when grouping(facts.facet_geography) = 0 then 3
        when grouping(facts.facet_reference_year) = 0 then 4
        when grouping(facts.facet_process_subtype) = 0 then 5
        else 6
      end as group_order,
      case
        when grouping(facts.dataset_kind) = 0 then facts.dataset_kind
        when grouping(facts.facet_access_level) = 0 then
          facts.facet_access_level
        when grouping(facts.facet_geography) = 0 then facts.facet_geography
        when grouping(facts.facet_reference_year) = 0 then
          facts.facet_reference_year
        when grouping(facts.facet_process_subtype) = 0 then
          facts.facet_process_subtype
        else facts.facet_source
      end as value,
      pg_catalog.count(*) as value_count
    from facts
    group by grouping sets (
      (facts.dataset_kind),
      (facts.facet_access_level),
      (facts.facet_geography),
      (facts.facet_reference_year),
      (facts.facet_process_subtype),
      (facts.facet_source)
    )
  ), counts as materialized (
    select counts_raw.group_id,
      counts_raw.group_order,
      counts_raw.value,
      counts_raw.value as label,
      counts_raw.value_count
    from counts_raw
    where nullif(pg_catalog.btrim(counts_raw.value), '') is not null
      and pg_catalog.length(counts_raw.value) <= 128
      and pg_catalog.octet_length(counts_raw.value) <= 512
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v2',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
    );
  end if;

  -- Nonempty lexical candidate and matching semantics remain unchanged.
  return (
with matched as materialized (
    select candidate.*
    from private.display_catalog_facet_candidate_rows_v3(
      p_kind,
      p_query,
      p_exact_id,
      p_like_pattern
    ) as candidate
    where private.display_navigation_version_matches_v3(
        candidate.dataset_kind, p_filters, candidate.id, candidate.version
      )
      and (
        not (p_filters ? 'accessLevel')
        or candidate.card ->> 'accessLevel' = p_filters ->> 'accessLevel'
      )
      and (
        not (p_filters ? 'geography')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card #>> '{geography,code}',
          ''
        ))) = p_filters ->> 'geography'
      )
      and (
        not (p_filters ? 'classification')
        or exists (
          select 1
          from pg_catalog.jsonb_array_elements(
            candidate.card -> 'classifications'
          ) as classification(item)
          where pg_catalog.lower(pg_catalog.btrim(
            classification.item ->> 'code'
          )) = p_filters ->> 'classification'
        )
      )
      and (
        not (p_filters ? 'referenceYearFrom')
        or (candidate.card ->> 'referenceYear')::integer
          >= (p_filters ->> 'referenceYearFrom')::integer
      )
      and (
        not (p_filters ? 'referenceYearTo')
        or (candidate.card ->> 'referenceYear')::integer
          <= (p_filters ->> 'referenceYearTo')::integer
      )
      and (
        not (p_filters ? 'processSubtype')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card ->> 'processSubtype',
          ''
        ))) = p_filters ->> 'processSubtype'
      )
      and (
        not (p_filters ? 'source')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          candidate.card ->> 'source',
          ''
        ))) = p_filters ->> 'source'
      )
  ), facet_values as materialized (
    select 'kind'::text as group_id,
      1 as group_order,
      matched.dataset_kind as value,
      matched.dataset_kind as label
    from matched
    union all
    select 'accessLevel',
      2,
      matched.card ->> 'accessLevel',
      matched.card ->> 'accessLevel'
    from matched
    union all
    select 'geography',
      3,
      pg_catalog.lower(pg_catalog.btrim(
        matched.card #>> '{geography,code}'
      )),
      matched.card #>> '{geography,code}'
    from matched
    union all
    select 'referenceYear',
      4,
      pg_catalog.btrim(matched.card ->> 'referenceYear'),
      pg_catalog.btrim(matched.card ->> 'referenceYear')
    from matched
    union all
    select 'processSubtype',
      5,
      pg_catalog.lower(pg_catalog.btrim(
        matched.card ->> 'processSubtype'
      )),
      matched.card ->> 'processSubtype'
    from matched
    where matched.dataset_kind = 'process'
    union all
    select 'source',
      6,
      pg_catalog.lower(pg_catalog.btrim(matched.card ->> 'source')),
      matched.card ->> 'source'
    from matched
  ), counts as materialized (
    select group_id,
      group_order,
      value,
      pg_catalog.min(value) as label,
      pg_catalog.count(*) as value_count
    from facet_values
    where nullif(pg_catalog.btrim(value), '') is not null
      and pg_catalog.length(value) <= 128
      and pg_catalog.octet_length(value) <= 512
    group by group_id, group_order, value
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v2',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
  );
end;
$$;

ALTER FUNCTION "private"."display_catalog_facets_v3_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facets_v3_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_flow_pattern_versions_v1"("p_like_pattern" "text") RETURNS TABLE("id" "uuid", "version" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $_$
declare
  v_literal text;
begin
  if pg_catalog.char_length(p_like_pattern) = 3
     and pg_catalog.left(p_like_pattern, 1) = '%'
     and pg_catalog.right(p_like_pattern, 1) = '%' then
    v_literal := pg_catalog.substr(p_like_pattern, 2, 1);
    return query
    select candidate.id,
      candidate.version
    from private.display_catalog_flow_single_character_versions_v1(
      v_literal
    ) as candidate;
    return;
  end if;

  return query execute pg_catalog.format($sql$
    select projection.id,
      projection.version
    from private.display_catalog_search_rows_v1 as projection
    where projection.dataset_kind = 'flow'
      and projection.document like %L escape E'\\'
  $sql$, p_like_pattern);
end
$_$;

ALTER FUNCTION "private"."display_catalog_flow_pattern_versions_v1"("p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_flow_pattern_versions_v1"("p_like_pattern" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_flow_single_character_versions_v1"("p_literal" "text") RETURNS TABLE("id" "uuid", "version" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "enable_indexscan" TO 'off'
    SET "enable_indexonlyscan" TO 'off'
    SET "enable_bitmapscan" TO 'off'
    SET "max_parallel_workers_per_gather" TO '4'
    SET "min_parallel_table_scan_size" TO '0'
    SET "parallel_setup_cost" TO '0'
    SET "parallel_tuple_cost" TO '0'
    SET "row_security" TO 'on'
    AS $$
  select projection.id,
    projection.version
  from private.display_catalog_search_rows_v1 as projection
  where projection.dataset_kind = 'flow'
    and pg_catalog.strpos(projection.document, p_literal) > 0
$$;

ALTER FUNCTION "private"."display_catalog_flow_single_character_versions_v1"("p_literal" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_flow_single_character_versions_v1"("p_literal" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_hybrid_pattern_matches_v1"("p_kind" "text", "p_query_terms" "text"[]) RETURNS TABLE("id" "uuid", "version" "text", "term_ordinal" integer)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
declare
  v_pattern text;
begin
  for v_ordinal in 1..pg_catalog.cardinality(p_query_terms)
  loop
    v_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          p_query_terms[v_ordinal],
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
    if p_kind = 'process' then
      return query
      select pattern.id,
        pattern.version,
        v_ordinal
      from private.display_catalog_process_pattern_versions_v1(
        v_pattern
      ) as pattern;
    elsif p_kind = 'flow' then
      return query
      select pattern.id,
        pattern.version,
        v_ordinal
      from private.display_catalog_flow_pattern_versions_v1(
        v_pattern
      ) as pattern;
    end if;
  end loop;
end
$$;

ALTER FUNCTION "private"."display_catalog_hybrid_pattern_matches_v1"("p_kind" "text", "p_query_terms" "text"[]) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_hybrid_pattern_matches_v1"("p_kind" "text", "p_query_terms" "text"[]) FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_process_keyword_keys_cn1"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer) RETURNS TABLE("id" "uuid", "version" "text", "score" numeric)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
declare
  v_like_pattern text;
begin
  v_like_pattern := '%' || pg_catalog.replace(
    pg_catalog.replace(
      pg_catalog.replace(
        p_query,
        pg_catalog.chr(92),
        pg_catalog.chr(92) || pg_catalog.chr(92)
      ),
      '%',
      pg_catalog.chr(92) || '%'
    ),
    '_',
    pg_catalog.chr(92) || '_'
  ) || '%';

  return query
  with matched_versions as materialized (
    select matched.id, matched.version
    from private.display_catalog_process_pattern_versions_v1(
      v_like_pattern
    ) as matched
  ), candidate_ids as materialized (
    select distinct matched.id
    from matched_versions as matched
  ), latest_keys as materialized (
    select distinct on (projection.id)
      projection.id,
      projection.version
    from private.display_catalog_search_rows_v2 as projection
    join candidate_ids using (id)
    where projection.dataset_kind = 'process'
    order by projection.id,
      projection.version desc,
      projection.modified_at desc,
      projection.state_code desc
  ), eligible_keys as materialized (
    select latest.id, latest.version
    from latest_keys as latest
    join matched_versions as matched
      on matched.id = latest.id
     and matched.version = latest.version
  ), exact_source as materialized (
    select projection.id,
      projection.version,
      case
        when private.display_process_rank_name_keys_v1(projection.card)
          @> array[p_query] then 0.95::numeric
        else 0.92::numeric
      end as score
    from private.display_catalog_search_rows_v2 as projection
    where projection.dataset_kind = 'process'
      and (
        private.display_process_rank_name_keys_v1(projection.card)
          @> array[p_query]
        or private.display_process_rank_classification_keys_v1(
          projection.card
        ) @> array[p_query]
      )
  ), exact_keys as materialized (
    select exact_source.*
    from exact_source
    join eligible_keys using (id, version)
    where p_cursor_rank is null
      or exact_source.score < p_cursor_rank::numeric
      or (
        exact_source.score = p_cursor_rank::numeric
        and (
          exact_source.id > p_cursor_id
          or (
            exact_source.id = p_cursor_id
            and exact_source.version < p_cursor_version
          )
        )
      )
  ), general_keys as materialized (
    select eligible.id, eligible.version, 0.70::numeric as score
    from eligible_keys as eligible
    left join exact_source using (id, version)
    where exact_source.id is null
      and (
        p_cursor_rank is null
        or 0.70::numeric < p_cursor_rank::numeric
        or (
          0.70::numeric = p_cursor_rank::numeric
          and (
            eligible.id > p_cursor_id
            or (
              eligible.id = p_cursor_id
              and eligible.version < p_cursor_version
            )
          )
        )
      )
    order by eligible.id, eligible.version desc
    limit p_limit + 1
  ), combined as (
    select exact_keys.* from exact_keys
    union all
    select general_keys.* from general_keys
  )
  select combined.id, combined.version, combined.score
  from combined
  order by combined.score desc, combined.id, combined.version desc
  limit p_limit + 1;
end
$$;

ALTER FUNCTION "private"."display_catalog_process_keyword_keys_cn1"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_process_keyword_keys_cn1"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_process_keyword_relevance_cn1_impl"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
  with selected_keys as materialized (
    select selected.id, selected.version, selected.score,
      pg_catalog.row_number() over (
        order by selected.score desc, selected.id, selected.version desc
      ) as page_rank
    from private.display_catalog_process_keyword_keys_cn1(
      p_query,
      p_cursor_rank,
      p_cursor_id,
      p_cursor_version,
      p_limit
    ) as selected
  ), hydrated as materialized (
    select selected.page_rank,
      projection.id,
      projection.version,
      projection.modified_at,
      projection.card,
      selected.score,
      private.display_catalog_card_facts_v1(
        projection.card,
        '{}'::jsonb,
        p_query
      ) as facts
    from selected_keys as selected
    join private.display_catalog_search_rows_v2 as projection
      on projection.dataset_kind = 'process'
     and projection.id = selected.id
     and projection.version = selected.version
  ), result as (
    select coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key', pg_catalog.jsonb_build_object(
            'kind', 'process',
            'id', hydrated.id::text,
            'version', hydrated.version
          ),
          'accessLevel', hydrated.card -> 'accessLevel',
          'capabilities', hydrated.card -> 'capabilities',
          'names', hydrated.card -> 'names',
          'summary', hydrated.card -> 'summary',
          'geography', hydrated.card -> 'geography',
          'referenceYear', hydrated.card -> 'referenceYear',
          'modifiedAt', pg_catalog.to_char(
            hydrated.modified_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          ),
          'match', pg_catalog.jsonb_build_object(
            'kind', case
              when (hydrated.facts ->> 'nameExact')::boolean
                or (hydrated.facts ->> 'nameContains')::boolean
                then 'lexical'
              when (hydrated.facts ->> 'classificationExact')::boolean
                or (hydrated.facts ->> 'classificationContains')::boolean
                then 'identifier'
              else 'lexical'
            end,
            'score', hydrated.score,
            'reasonCodes', case
              when (hydrated.facts ->> 'nameExact')::boolean
                or (hydrated.facts ->> 'nameContains')::boolean
                then pg_catalog.jsonb_build_array('name')
              when (hydrated.facts ->> 'classificationExact')::boolean
                or (hydrated.facts ->> 'classificationContains')::boolean
                then pg_catalog.jsonb_build_array('classification')
              else pg_catalog.jsonb_build_array('full_text')
            end
          )
        ) order by hydrated.page_rank
      ) filter (where hydrated.page_rank <= p_limit),
      '[]'::jsonb
    ) as items,
    case when pg_catalog.max(hydrated.page_rank) > p_limit then
      (
        pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'v', 1,
            'fp', p_query_fingerprint,
            'rankKey', hydrated.score::text,
            'kind', 'process',
            'id', hydrated.id::text,
            'version', hydrated.version
          ) order by hydrated.page_rank
        ) filter (where hydrated.page_rank = p_limit)
      ) -> 0
    else null end as next_cursor_payload
    from hydrated
  )
  select pg_catalog.jsonb_build_object(
    'items', result.items,
    'nextCursorPayload', result.next_cursor_payload
  )
  from result
$$;

ALTER FUNCTION "private"."display_catalog_process_keyword_relevance_cn1_impl"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_process_keyword_relevance_cn1_impl"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_process_pattern_versions_v1"("p_like_pattern" "text") RETURNS TABLE("id" "uuid", "version" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $_$
declare
  v_literal text;
begin
  if pg_catalog.char_length(p_like_pattern) = 3
     and pg_catalog.left(p_like_pattern, 1) = '%'
     and pg_catalog.right(p_like_pattern, 1) = '%' then
    v_literal := pg_catalog.substr(p_like_pattern, 2, 1);
    return query
    select candidate.id,
      candidate.version
    from private.display_catalog_process_single_character_versions_v1(
      v_literal
    ) as candidate;
    return;
  end if;

  return query execute pg_catalog.format($sql$
    select projection.id,
      projection.version
    from private.display_catalog_search_current_v2 as projection
    where projection.dataset_kind = 'process'
      and projection.document like %L escape E'\\'
  $sql$, p_like_pattern);
end
$_$;

ALTER FUNCTION "private"."display_catalog_process_pattern_versions_v1"("p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_process_pattern_versions_v1"("p_like_pattern" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_process_single_character_versions_v1"("p_literal" "text") RETURNS TABLE("id" "uuid", "version" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "enable_indexscan" TO 'off'
    SET "enable_indexonlyscan" TO 'off'
    SET "enable_bitmapscan" TO 'off'
    SET "max_parallel_workers_per_gather" TO '4'
    SET "min_parallel_table_scan_size" TO '0'
    SET "parallel_setup_cost" TO '0'
    SET "parallel_tuple_cost" TO '0'
    SET "row_security" TO 'on'
    AS $$
  select projection.id,
    projection.version
  from private.display_catalog_search_current_v2 as projection
  where projection.dataset_kind = 'process'
    and pg_catalog.strpos(projection.document, p_literal) > 0
$$;

ALTER FUNCTION "private"."display_catalog_process_single_character_versions_v1"("p_literal" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_process_single_character_versions_v1"("p_literal" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_search_v1_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    AS $_$
declare
  v_items jsonb;
  v_next_cursor_payload jsonb;
  v_exact_id uuid;
  v_like_pattern text;
begin
  if p_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := p_query::uuid;
  end if;
  if p_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          p_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;
  -- Empty unfiltered browse pages do not require search facts for the whole
  -- catalog.  Order/latest/cursor reduction happens before at most limit+1
  -- cards are hydrated.
  if p_query = ''
     and p_filters = '{}'::jsonb
     and p_sort in ('relevance', 'modified_desc', 'name_asc') then
    with portal_prefilter as materialized (
      select p_kind as dataset_kind,
        candidate.*,
        case when p_sort = 'name_asc' then case
          when nullif(candidate.card #>> '{names,0,value}', '') is not null
            and pg_catalog.length(
              candidate.card #>> '{names,0,value}'
            ) <= 500
            and pg_catalog.octet_length(
              candidate.card #>> '{names,0,value}'
            ) <= 2000
            and candidate.card #>> '{names,0,value}' !~ '[[:cntrl:]]'
            then candidate.card #>> '{names,0,value}'
          else '~unnamed:' || candidate.id::text
        end end as name_key
      from private.display_catalog_candidate_rows_v1(
        p_kind,
        p_query,
        v_exact_id,
        v_like_pattern
      ) as candidate
    ), portal_after_cursor as materialized (
      select portal_prefilter.*
      from portal_prefilter
      where p_cursor_rank is null
        or case p_sort
          when 'relevance' then
            0::numeric < p_cursor_rank::numeric
            or (
              0::numeric = p_cursor_rank::numeric
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          when 'modified_desc' then
            portal_prefilter.modified_at < p_cursor_rank::timestamptz
            or (
              portal_prefilter.modified_at = p_cursor_rank::timestamptz
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          else
            pg_catalog.lower(portal_prefilter.name_key)
              > pg_catalog.lower(p_cursor_rank)
            or (
              pg_catalog.lower(portal_prefilter.name_key)
                = pg_catalog.lower(p_cursor_rank)
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
        end
    ), portal_ordered as materialized (
      select portal_after_cursor.*,
        pg_catalog.row_number() over (
          order by
            case when p_sort = 'modified_desc'
              then portal_after_cursor.modified_at end desc,
            case when p_sort = 'name_asc'
              then pg_catalog.lower(portal_after_cursor.name_key) end asc,
            portal_after_cursor.id asc,
            portal_after_cursor.version desc
        ) as page_rank
      from portal_after_cursor
      order by
        case when p_sort = 'modified_desc'
          then portal_after_cursor.modified_at end desc,
        case when p_sort = 'name_asc'
          then pg_catalog.lower(portal_after_cursor.name_key) end asc,
        portal_after_cursor.id asc,
        portal_after_cursor.version desc
      limit p_limit + 1
    ), portal_decorated as materialized (
      select portal_ordered.*
      from portal_ordered
    )
    select
      coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key', pg_catalog.jsonb_build_object(
            'kind', p_kind,
            'id', portal_decorated.id::text,
            'version', portal_decorated.version
          ),
          'accessLevel', portal_decorated.card -> 'accessLevel',
          'capabilities', portal_decorated.card -> 'capabilities',
          'names', portal_decorated.card -> 'names',
          'summary', portal_decorated.card -> 'summary',
          'geography', portal_decorated.card -> 'geography',
          'referenceYear', portal_decorated.card -> 'referenceYear',
          'modifiedAt', pg_catalog.to_char(
            portal_decorated.modified_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          ),
          'match', pg_catalog.jsonb_build_object(
            'kind', 'lexical',
            'score', 0::numeric,
            'reasonCodes', '[]'::jsonb
          )
        ) order by portal_decorated.page_rank
      ) filter (where portal_decorated.page_rank <= p_limit), '[]'::jsonb),
      case when max(portal_decorated.page_rank) > p_limit then
        (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'v', 1,
          'fp', p_query_fingerprint,
          'rankKey', case p_sort
            when 'relevance' then '0'
            when 'modified_desc' then pg_catalog.to_char(
              portal_decorated.modified_at at time zone 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
            )
            else pg_catalog.lower(portal_decorated.name_key)
          end,
          'kind', p_kind,
          'id', portal_decorated.id::text,
          'version', portal_decorated.version
        ) order by portal_decorated.page_rank)
          filter (where portal_decorated.page_rank = p_limit)) -> 0
      else null end
    into v_items, v_next_cursor_payload
    from portal_decorated;

    return pg_catalog.jsonb_build_object(
      'items', v_items,
      'nextCursorPayload', v_next_cursor_payload
    );
  end if;

  -- Geography-only Flow browse can use the synchronized narrow facet child
  -- for latest/filter/order/limit, then hydrate only limit+1 stored cards.
  -- This preserves latest-version and cursor semantics without evaluating
  -- the wide card-facts helper over the full Flow card set.
  if p_kind = 'flow'
     and p_query = ''
     and p_sort = 'relevance'
     and p_filters ? 'geography'
     and (select count(*) from pg_catalog.jsonb_object_keys(p_filters)) = 1 then
    perform private.display_assert_catalog_facet_contract_v1();

    with portal_latest_facts as materialized (
      select distinct on (facet.id)
        facet.id,
        facet.version,
        facet.state_code,
        facet.modified_at,
        facet.facet_geography
      from private.display_catalog_facet_rows_v1 as facet
      where facet.dataset_kind = 'flow'
      order by facet.id,
        facet.version desc,
        facet.modified_at desc,
        facet.state_code desc
    ), portal_filtered_keys as materialized (
      select portal_latest_facts.*
      from portal_latest_facts
      where portal_latest_facts.facet_geography =
          p_filters ->> 'geography'
        and (
          p_cursor_rank is null
          or 0::numeric < p_cursor_rank::numeric
          or (
            0::numeric = p_cursor_rank::numeric
            and (
              portal_latest_facts.id > p_cursor_id
              or (
                portal_latest_facts.id = p_cursor_id
                and portal_latest_facts.version < p_cursor_version
              )
            )
          )
        )
    ), portal_ordered_keys as materialized (
      select portal_filtered_keys.*,
        pg_catalog.row_number() over (
          order by portal_filtered_keys.id,
            portal_filtered_keys.version desc
        ) as page_rank
      from portal_filtered_keys
      order by portal_filtered_keys.id,
        portal_filtered_keys.version desc
      limit p_limit + 1
    ), portal_hydrated as materialized (
      select portal_ordered_keys.*,
        projection.card
      from portal_ordered_keys
      join private.display_catalog_search_current_v2 as projection
        on projection.dataset_kind = 'flow'
       and projection.id = portal_ordered_keys.id
       and projection.version = portal_ordered_keys.version
    )
    select
      coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key', pg_catalog.jsonb_build_object(
            'kind', p_kind,
            'id', portal_hydrated.id::text,
            'version', portal_hydrated.version
          ),
          'accessLevel', portal_hydrated.card -> 'accessLevel',
          'capabilities', portal_hydrated.card -> 'capabilities',
          'names', portal_hydrated.card -> 'names',
          'summary', portal_hydrated.card -> 'summary',
          'geography', portal_hydrated.card -> 'geography',
          'referenceYear', portal_hydrated.card -> 'referenceYear',
          'modifiedAt', pg_catalog.to_char(
            portal_hydrated.modified_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          ),
          'match', pg_catalog.jsonb_build_object(
            'kind', 'lexical',
            'score', 0::numeric,
            'reasonCodes', '[]'::jsonb
          )
        ) order by portal_hydrated.page_rank
      ) filter (where portal_hydrated.page_rank <= p_limit), '[]'::jsonb),
      case when max(portal_hydrated.page_rank) > p_limit then
        (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'v', 1,
          'fp', p_query_fingerprint,
          'rankKey', '0',
          'kind', p_kind,
          'id', portal_hydrated.id::text,
          'version', portal_hydrated.version
        ) order by portal_hydrated.page_rank)
          filter (where portal_hydrated.page_rank = p_limit)) -> 0
      else null end
    into v_items, v_next_cursor_payload
    from portal_hydrated;

    return pg_catalog.jsonb_build_object(
      'items', v_items,
      'nextCursorPayload', v_next_cursor_payload
    );
  end if;

  with portal_prefilter as materialized (
    select p_kind as dataset_kind,
      candidate.*
    from private.display_catalog_candidate_rows_v1(
      p_kind,
      p_query,
      v_exact_id,
      v_like_pattern
    ) as candidate
  ), portal_facts as materialized (
    select portal_prefilter.*,
      private.display_catalog_card_facts_v1(
        portal_prefilter.card,
        p_filters,
        p_query
      ) as facts
    from portal_prefilter
  ), portal_scored as materialized (
    select portal_facts.*,
      case
        when nullif(portal_facts.facts ->> 'nameKey', '') is not null
          and pg_catalog.length(portal_facts.facts ->> 'nameKey') <= 500
          and pg_catalog.octet_length(portal_facts.facts ->> 'nameKey') <= 2000
          and portal_facts.facts ->> 'nameKey' !~ '[[:cntrl:]]'
          then portal_facts.facts ->> 'nameKey'
        else '~unnamed:' || portal_facts.id::text
      end as name_key,
      case
        when p_query = '' then 0::numeric
        when pg_catalog.lower(portal_facts.id::text) = p_query then 1::numeric
        when pg_catalog.lower(coalesce(portal_facts.facts ->> 'casNumber', '')) = p_query
          then 0.98::numeric
        when (portal_facts.facts ->> 'nameExact')::boolean then 0.95::numeric
        when (portal_facts.facts ->> 'classificationExact')::boolean
          then 0.92::numeric
        when p_query <> '' then 0.70::numeric
        else 0::numeric
      end as score,
      case
        when pg_catalog.lower(portal_facts.id::text) = p_query
          then pg_catalog.jsonb_build_array('exact_id')
        when pg_catalog.lower(coalesce(portal_facts.facts ->> 'casNumber', '')) = p_query
          then pg_catalog.jsonb_build_array('cas')
        when (portal_facts.facts ->> 'nameExact')::boolean
          or (portal_facts.facts ->> 'nameContains')::boolean
          then pg_catalog.jsonb_build_array('name')
        when (portal_facts.facts ->> 'classificationExact')::boolean
          or (portal_facts.facts ->> 'classificationContains')::boolean
          then pg_catalog.jsonb_build_array('classification')
        when p_query <> '' then pg_catalog.jsonb_build_array('full_text')
        else '[]'::jsonb
      end as reason_codes
    from portal_facts
  ), portal_filtered as materialized (
    select portal_scored.*,
      case p_sort
        when 'relevance' then portal_scored.score::text
        when 'modified_desc' then pg_catalog.to_char(
          portal_scored.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
        else pg_catalog.lower(portal_scored.name_key)
      end as rank_key
    from portal_scored
    where (p_query = '' or portal_scored.score > 0)
      and (
        not (p_filters ? 'accessLevel')
        or portal_scored.facts ->> 'accessLevel' = p_filters ->> 'accessLevel'
      )
      and (
        not (p_filters ? 'geography')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'geographyCode',
          ''
        ))) = p_filters ->> 'geography'
      )
      and (
        not (p_filters ? 'classification')
        or (portal_scored.facts ->> 'classificationFilterMatch')::boolean
      )
      and (
        not (p_filters ? 'referenceYearFrom')
        or (portal_scored.facts ->> 'referenceYear')::integer
          >= (p_filters ->> 'referenceYearFrom')::integer
      )
      and (
        not (p_filters ? 'referenceYearTo')
        or (portal_scored.facts ->> 'referenceYear')::integer
          <= (p_filters ->> 'referenceYearTo')::integer
      )
      and (
        not (p_filters ? 'processSubtype')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'processSubtype',
          ''
        ))) = p_filters ->> 'processSubtype'
      )
      and (
        not (p_filters ? 'source')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'source',
          ''
        ))) = p_filters ->> 'source'
      )
  ), portal_after_cursor as materialized (
    select portal_filtered.*
    from portal_filtered
    where p_cursor_rank is null
      or case p_sort
        when 'relevance' then
          portal_filtered.score < p_cursor_rank::numeric
          or (
            portal_filtered.score = p_cursor_rank::numeric
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        when 'modified_desc' then
          portal_filtered.modified_at < p_cursor_rank::timestamptz
          or (
            portal_filtered.modified_at = p_cursor_rank::timestamptz
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        else
          pg_catalog.lower(portal_filtered.name_key) > pg_catalog.lower(p_cursor_rank)
          or (
            pg_catalog.lower(portal_filtered.name_key) = pg_catalog.lower(p_cursor_rank)
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
      end
  ), portal_ordered as materialized (
    select portal_after_cursor.*,
      pg_catalog.row_number() over (
        order by
          case when p_sort = 'relevance' then portal_after_cursor.score end desc,
          case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
          case when p_sort = 'name_asc'
            then pg_catalog.lower(portal_after_cursor.name_key) end asc,
          portal_after_cursor.id asc,
          portal_after_cursor.version desc
      ) as page_rank
    from portal_after_cursor
    order by
      case when p_sort = 'relevance' then portal_after_cursor.score end desc,
      case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
      case when p_sort = 'name_asc'
        then pg_catalog.lower(portal_after_cursor.name_key) end asc,
      portal_after_cursor.id asc,
      portal_after_cursor.version desc
    limit p_limit + 1
  ), portal_hydrated as materialized (
    select portal_ordered.*
    from portal_ordered
  )
  select
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'key', pg_catalog.jsonb_build_object(
          'kind', p_kind,
          'id', portal_hydrated.id::text,
          'version', portal_hydrated.version
        ),
        'accessLevel', portal_hydrated.card -> 'accessLevel',
        'capabilities', portal_hydrated.card -> 'capabilities',
        'names', portal_hydrated.card -> 'names',
        'summary', portal_hydrated.card -> 'summary',
        'geography', portal_hydrated.card -> 'geography',
        'referenceYear', portal_hydrated.card -> 'referenceYear',
        'modifiedAt', pg_catalog.to_char(
          portal_hydrated.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        ),
        'match', pg_catalog.jsonb_build_object(
          'kind', case when portal_hydrated.reason_codes
            ?| array['exact_id', 'cas', 'classification']
            then 'identifier' else 'lexical' end,
          'score', portal_hydrated.score,
          'reasonCodes', portal_hydrated.reason_codes
        )
      ) order by portal_hydrated.page_rank
    ) filter (where portal_hydrated.page_rank <= p_limit), '[]'::jsonb),
    case when max(portal_hydrated.page_rank) > p_limit then
      (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'v', 1,
        'fp', p_query_fingerprint,
        'rankKey', portal_hydrated.rank_key,
        'kind', p_kind,
        'id', portal_hydrated.id::text,
        'version', portal_hydrated.version
      ) order by portal_hydrated.page_rank)
        filter (where portal_hydrated.page_rank = p_limit)) -> 0
    else null end
  into v_items, v_next_cursor_payload
  from portal_hydrated;

  return pg_catalog.jsonb_build_object(
    'items', v_items,
    'nextCursorPayload', v_next_cursor_payload
  );
end
$_$;

ALTER FUNCTION "private"."display_catalog_search_v1_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_search_v1_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_search_v2_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    AS $_$
declare
  v_items jsonb;
  v_next_cursor_payload jsonb;
  v_exact_id uuid;
  v_like_pattern text;
begin
  if p_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := p_query::uuid;
  end if;
  if p_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          p_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;
  -- Browse filtering and paging use synchronized narrow facts. Relevance/date
  -- ordering reads full cards only for the page. Name ordering still detoasts
  -- each matched card once for its name key, without materializing full cards.
  if p_query = ''
     and p_sort in ('relevance', 'modified_desc', 'name_asc') then
    with matched_keys as materialized (
      select id,version from private.display_navigation_matched_versions_v1(p_kind,p_query,p_filters)
    ), portal_matches as materialized (
      select f.id,f.version,f.modified_at,null::text as name_value
      from private.display_catalog_facet_rows_v1 f
      where p_sort<>'name_asc' and f.dataset_kind=p_kind
        and true and f.facet_contract_version=1
        and (p_filters='{}'::jsonb or (f.id,f.version) in (select id,version from matched_keys))
      union all
      select p.id,p.version,p.modified_at,p.card #>> '{names,0,value}' as name_value
      from private.display_catalog_search_current_v2 p
      where p_sort='name_asc' and p.dataset_kind=p_kind and true
        and (p_filters='{}'::jsonb or (p.id,p.version) in (select id,version from matched_keys))
    ), portal_prefilter as materialized (
      select id,version,modified_at,
        case when p_sort='name_asc' then case
          when nullif(name_value,'') is not null and length(name_value)<=500
            and octet_length(name_value)<=2000 and name_value !~ '[[:cntrl:]]'
            then name_value else '~unnamed:' || id::text
        end end as name_key
      from portal_matches
    ), portal_after_cursor as materialized (
      select portal_prefilter.*
      from portal_prefilter
      where p_cursor_rank is null
        or case p_sort
          when 'relevance' then
            0::numeric < p_cursor_rank::numeric
            or (
              0::numeric = p_cursor_rank::numeric
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          when 'modified_desc' then
            portal_prefilter.modified_at < p_cursor_rank::timestamptz
            or (
              portal_prefilter.modified_at = p_cursor_rank::timestamptz
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          else
            pg_catalog.lower(portal_prefilter.name_key)
              > pg_catalog.lower(p_cursor_rank)
            or (
              pg_catalog.lower(portal_prefilter.name_key)
                = pg_catalog.lower(p_cursor_rank)
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
        end
    ), portal_ordered as materialized (
      select portal_after_cursor.*,
        pg_catalog.row_number() over (
          order by
            case when p_sort = 'modified_desc'
              then portal_after_cursor.modified_at end desc,
            case when p_sort = 'name_asc'
              then pg_catalog.lower(portal_after_cursor.name_key) end asc,
            portal_after_cursor.id asc,
            portal_after_cursor.version desc
        ) as page_rank
      from portal_after_cursor
      order by
        case when p_sort = 'modified_desc'
          then portal_after_cursor.modified_at end desc,
        case when p_sort = 'name_asc'
          then pg_catalog.lower(portal_after_cursor.name_key) end asc,
        portal_after_cursor.id asc,
        portal_after_cursor.version desc
      limit p_limit + 1
    ), portal_decorated as materialized (
      select portal_ordered.*,
        case p_kind
          when 'process' then (select p.card from private.display_catalog_search_rows_v2 p
            where p.dataset_kind='process' and p.id=portal_ordered.id and p.version=portal_ordered.version)
          else (select p.card from private.display_catalog_search_rows_v1 p
            where p.dataset_kind='flow' and p.id=portal_ordered.id and p.version=portal_ordered.version)
        end as card
      from portal_ordered
    )
    select
      coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key', pg_catalog.jsonb_build_object(
            'kind', p_kind,
            'id', portal_decorated.id::text,
            'version', portal_decorated.version
          ),
          'accessLevel', portal_decorated.card -> 'accessLevel',
          'capabilities', portal_decorated.card -> 'capabilities',
          'names', portal_decorated.card -> 'names',
          'summary', portal_decorated.card -> 'summary',
          'geography', portal_decorated.card -> 'geography',
          'referenceYear', portal_decorated.card -> 'referenceYear',
          'modifiedAt', pg_catalog.to_char(
            portal_decorated.modified_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          ),
          'match', pg_catalog.jsonb_build_object(
            -- Keep the retained filtered-empty-query match metadata byte-identical.
            'kind', case when p_filters <> '{}'::jsonb
                and coalesce(portal_decorated.card ->> 'casNumber','') = ''
              then 'identifier' else 'lexical' end,
            'score', 0::numeric,
            'reasonCodes', case when p_filters <> '{}'::jsonb
                and coalesce(portal_decorated.card ->> 'casNumber','') = ''
              then pg_catalog.jsonb_build_array('cas') else '[]'::jsonb end
          )
        ) order by portal_decorated.page_rank
      ) filter (where portal_decorated.page_rank <= p_limit), '[]'::jsonb),
      case when max(portal_decorated.page_rank) > p_limit then
        (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'v', 1,
          'fp', p_query_fingerprint,
          'rankKey', case p_sort
            when 'relevance' then '0'
            when 'modified_desc' then pg_catalog.to_char(
              portal_decorated.modified_at at time zone 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
            )
            else pg_catalog.lower(portal_decorated.name_key)
          end,
          'kind', p_kind,
          'id', portal_decorated.id::text,
          'version', portal_decorated.version
        ) order by portal_decorated.page_rank)
          filter (where portal_decorated.page_rank = p_limit)) -> 0
      else null end
    into v_items, v_next_cursor_payload
    from portal_decorated;

    return pg_catalog.jsonb_build_object(
      'items', v_items,
      'nextCursorPayload', v_next_cursor_payload
    );
  end if;


  with pattern_matches as materialized (
    select pattern.id,pattern.version
    from private.display_catalog_process_pattern_versions_v1(v_like_pattern) pattern
    where p_kind='process'
    union all
    select pattern.id,pattern.version
    from private.display_catalog_flow_pattern_versions_v1(v_like_pattern) pattern
    where p_kind='flow' and not private.display_catalog_summary_valid_cas_v1(p_query)
  ), portal_facts as materialized (
    -- Inline the exact immutable card-facts expression to avoid one SPI call
    -- per candidate; only narrow facts cross the materialization boundary.
    -- The authoritative legacy pattern/CAS candidate universe is unchanged.
    select p.id,p.version,p.state_code,p.modified_at,
      pg_catalog.jsonb_build_object(
        'nameKey',case when p_sort='name_asc' then card_attrs.names #> '{0,value}' else null::jsonb end,
        'nameExact',exists(select 1 from pg_catalog.jsonb_array_elements(coalesce(card_attrs.names,p.card->'names','[]'::jsonb)) n(item)
          where pg_catalog.lower(pg_catalog.btrim(n.item->>'value'))=p_query),
        'classificationExact',exists(select 1 from pg_catalog.jsonb_array_elements(coalesce(card_attrs.classifications,p.card->'classifications','[]'::jsonb)) c(item)
          where pg_catalog.lower(pg_catalog.btrim(c.item->>'code'))=p_query),
        'casNumber',card_attrs."casNumber"
      ) as facts
    from private.display_catalog_search_current_v2 p
    cross join lateral pg_catalog.jsonb_to_record(p.card)
      as card_attrs(names jsonb,classifications jsonb,"casNumber" jsonb)
    where p.dataset_kind=p_kind and true
      and case when p_kind='flow' and private.display_catalog_summary_valid_cas_v1(p_query) then
        pg_catalog.jsonb_typeof(p.card->'casNumber')='string'
        and p.card->>'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
        and pg_catalog.length(p.card->>'casNumber') between 7 and 12
        and p.card->>'casNumber'=p_query
      else p.id=v_exact_id or (p.id,p.version) in (select id,version from pattern_matches) end
      and (p_filters='{}'::jsonb or (p.id,p.version) in (select id,version from private.display_navigation_matched_versions_v1(p_kind,'',p_filters)))
  ), portal_scored as materialized (
    select portal_facts.*,
      case
        when nullif(portal_facts.facts ->> 'nameKey', '') is not null
          and pg_catalog.length(portal_facts.facts ->> 'nameKey') <= 500
          and pg_catalog.octet_length(portal_facts.facts ->> 'nameKey') <= 2000
          and portal_facts.facts ->> 'nameKey' !~ '[[:cntrl:]]'
          then portal_facts.facts ->> 'nameKey'
        else '~unnamed:' || portal_facts.id::text
      end as name_key,
      case
        when p_query = '' then 0::numeric
        when pg_catalog.lower(portal_facts.id::text) = p_query then 1::numeric
        when pg_catalog.lower(coalesce(portal_facts.facts ->> 'casNumber', '')) = p_query
          then 0.98::numeric
        when (portal_facts.facts ->> 'nameExact')::boolean then 0.95::numeric
        when (portal_facts.facts ->> 'classificationExact')::boolean
          then 0.92::numeric
        when p_query <> '' then 0.70::numeric
        else 0::numeric
      end as score
    from portal_facts
  ), portal_filtered as materialized (
    select portal_scored.*,
      case p_sort
        when 'relevance' then portal_scored.score::text
        when 'modified_desc' then pg_catalog.to_char(
          portal_scored.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
        else pg_catalog.lower(portal_scored.name_key)
      end as rank_key
    from portal_scored
    where (p_query = '' or portal_scored.score > 0)
  ), portal_after_cursor as materialized (
    select portal_filtered.*
    from portal_filtered
    where p_cursor_rank is null
      or case p_sort
        when 'relevance' then
          portal_filtered.score < p_cursor_rank::numeric
          or (
            portal_filtered.score = p_cursor_rank::numeric
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        when 'modified_desc' then
          portal_filtered.modified_at < p_cursor_rank::timestamptz
          or (
            portal_filtered.modified_at = p_cursor_rank::timestamptz
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        else
          pg_catalog.lower(portal_filtered.name_key) > pg_catalog.lower(p_cursor_rank)
          or (
            pg_catalog.lower(portal_filtered.name_key) = pg_catalog.lower(p_cursor_rank)
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
      end
  ), portal_ordered as materialized (
    select portal_after_cursor.*,
      pg_catalog.row_number() over (
        order by
          case when p_sort = 'relevance' then portal_after_cursor.score end desc,
          case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
          case when p_sort = 'name_asc'
            then pg_catalog.lower(portal_after_cursor.name_key) end asc,
          portal_after_cursor.id asc,
          portal_after_cursor.version desc
      ) as page_rank
    from portal_after_cursor
    order by
      case when p_sort = 'relevance' then portal_after_cursor.score end desc,
      case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
      case when p_sort = 'name_asc'
        then pg_catalog.lower(portal_after_cursor.name_key) end asc,
      portal_after_cursor.id asc,
      portal_after_cursor.version desc
    limit p_limit + 1
  ), portal_hydrated as materialized (
    select portal_ordered.*,case p_kind
      when 'process' then (select p.card from private.display_catalog_search_rows_v2 p
        where p.dataset_kind='process' and p.id=portal_ordered.id and p.version=portal_ordered.version
          and p.state_code=portal_ordered.state_code and p.modified_at=portal_ordered.modified_at
          and true)
      else (select p.card from private.display_catalog_search_rows_v1 p
        where p.dataset_kind='flow' and p.id=portal_ordered.id and p.version=portal_ordered.version
          and p.state_code=portal_ordered.state_code and p.modified_at=portal_ordered.modified_at
          and true) end as card
    from portal_ordered
  ), portal_page_facts as materialized (
    select portal_hydrated.*,private.display_catalog_card_facts_v1(portal_hydrated.card,p_filters,p_query) as page_facts
    from portal_hydrated
  ), portal_decorated as materialized (
    select portal_page_facts.*,
      case
        when pg_catalog.lower(portal_page_facts.id::text) = p_query
          then pg_catalog.jsonb_build_array('exact_id')
        when pg_catalog.lower(coalesce(portal_page_facts.page_facts ->> 'casNumber', '')) = p_query
          then pg_catalog.jsonb_build_array('cas')
        when (portal_page_facts.page_facts ->> 'nameExact')::boolean
          or (portal_page_facts.page_facts ->> 'nameContains')::boolean
          then pg_catalog.jsonb_build_array('name')
        when (portal_page_facts.page_facts ->> 'classificationExact')::boolean
          or (portal_page_facts.page_facts ->> 'classificationContains')::boolean
          then pg_catalog.jsonb_build_array('classification')
        when p_query <> '' then pg_catalog.jsonb_build_array('full_text')
        else '[]'::jsonb
      end as reason_codes
    from portal_page_facts
  )
  select
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'key', pg_catalog.jsonb_build_object(
          'kind', p_kind,
          'id', portal_decorated.id::text,
          'version', portal_decorated.version
        ),
        'accessLevel', portal_decorated.card -> 'accessLevel',
        'capabilities', portal_decorated.card -> 'capabilities',
        'names', portal_decorated.card -> 'names',
        'summary', portal_decorated.card -> 'summary',
        'geography', portal_decorated.card -> 'geography',
        'referenceYear', portal_decorated.card -> 'referenceYear',
        'modifiedAt', pg_catalog.to_char(
          portal_decorated.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        ),
        'match', pg_catalog.jsonb_build_object(
          'kind', case when portal_decorated.reason_codes
            ?| array['exact_id', 'cas', 'classification']
            then 'identifier' else 'lexical' end,
          'score', portal_decorated.score,
          'reasonCodes', portal_decorated.reason_codes
        )
      ) order by portal_decorated.page_rank
    ) filter (where portal_decorated.page_rank <= p_limit), '[]'::jsonb),
    case when max(portal_decorated.page_rank) > p_limit then
      (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'v', 1,
        'fp', p_query_fingerprint,
        'rankKey', portal_decorated.rank_key,
        'kind', p_kind,
        'id', portal_decorated.id::text,
        'version', portal_decorated.version
      ) order by portal_decorated.page_rank)
        filter (where portal_decorated.page_rank = p_limit)) -> 0
    else null end
  into v_items, v_next_cursor_payload
  from portal_decorated;

  return pg_catalog.jsonb_build_object(
    'items', v_items,
    'nextCursorPayload', v_next_cursor_payload
  );
end;
$_$;

ALTER FUNCTION "private"."display_catalog_search_v2_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_search_v2_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_search_v3_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    AS $_$
declare
  v_items jsonb;
  v_next_cursor_payload jsonb;
  v_exact_id uuid;
  v_like_pattern text;
begin
  if p_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := p_query::uuid;
  end if;
  if p_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          p_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;
  -- Browse filtering and paging use synchronized narrow facts. Relevance/date
  -- ordering reads full cards only for the page. Name ordering still detoasts
  -- each matched card once for its name key, without materializing full cards.
  if p_query = ''
     and p_sort in ('relevance', 'modified_desc', 'name_asc') then
    with portal_matches as materialized (
      select matched.id,matched.version,facet.modified_at,
        case when p_sort='name_asc' then case p_kind
          when 'process' then (select p.card #>> '{names,0,value}'
            from private.display_catalog_search_rows_v2 p
            where p.dataset_kind='process' and p.id=matched.id and p.version=matched.version)
          else (select p.card #>> '{names,0,value}'
            from private.display_catalog_search_rows_v1 p
            where p.dataset_kind='flow' and p.id=matched.id and p.version=matched.version)
        end end as name_value
      from private.display_navigation_matched_versions_v1(p_kind,p_query,p_filters) matched
      join private.display_catalog_facet_rows_v1 facet
        on (facet.dataset_kind,facet.id,facet.version)=(matched.dataset_kind,matched.id,matched.version)
      where facet.facet_contract_version=1 and true
    ), portal_prefilter as materialized (
      select id,version,modified_at,
        case when p_sort='name_asc' then case
          when nullif(name_value,'') is not null and length(name_value)<=500
            and octet_length(name_value)<=2000 and name_value !~ '[[:cntrl:]]'
            then name_value else '~unnamed:' || id::text
        end end as name_key
      from portal_matches
    ), portal_after_cursor as materialized (
      select portal_prefilter.*
      from portal_prefilter
      where p_cursor_rank is null
        or case p_sort
          when 'relevance' then
            0::numeric < p_cursor_rank::numeric
            or (
              0::numeric = p_cursor_rank::numeric
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          when 'modified_desc' then
            portal_prefilter.modified_at < p_cursor_rank::timestamptz
            or (
              portal_prefilter.modified_at = p_cursor_rank::timestamptz
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
          else
            pg_catalog.lower(portal_prefilter.name_key)
              > pg_catalog.lower(p_cursor_rank)
            or (
              pg_catalog.lower(portal_prefilter.name_key)
                = pg_catalog.lower(p_cursor_rank)
              and (
                portal_prefilter.id > p_cursor_id
                or (
                  portal_prefilter.id = p_cursor_id
                  and portal_prefilter.version < p_cursor_version
                )
              )
            )
        end
    ), portal_ordered as materialized (
      select portal_after_cursor.*,
        pg_catalog.row_number() over (
          order by
            case when p_sort = 'modified_desc'
              then portal_after_cursor.modified_at end desc,
            case when p_sort = 'name_asc'
              then pg_catalog.lower(portal_after_cursor.name_key) end asc,
            portal_after_cursor.id asc,
            portal_after_cursor.version desc
        ) as page_rank
      from portal_after_cursor
      order by
        case when p_sort = 'modified_desc'
          then portal_after_cursor.modified_at end desc,
        case when p_sort = 'name_asc'
          then pg_catalog.lower(portal_after_cursor.name_key) end asc,
        portal_after_cursor.id asc,
        portal_after_cursor.version desc
      limit p_limit + 1
    ), portal_decorated as materialized (
      select portal_ordered.*,
        case p_kind
          when 'process' then (select p.card from private.display_catalog_search_rows_v2 p
            where p.dataset_kind='process' and p.id=portal_ordered.id and p.version=portal_ordered.version)
          else (select p.card from private.display_catalog_search_rows_v1 p
            where p.dataset_kind='flow' and p.id=portal_ordered.id and p.version=portal_ordered.version)
        end as card
      from portal_ordered
    )
    select
      coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key', pg_catalog.jsonb_build_object(
            'kind', p_kind,
            'id', portal_decorated.id::text,
            'version', portal_decorated.version
          ),
          'accessLevel', portal_decorated.card -> 'accessLevel',
          'capabilities', portal_decorated.card -> 'capabilities',
          'names', portal_decorated.card -> 'names',
          'summary', portal_decorated.card -> 'summary',
          'geography', portal_decorated.card -> 'geography',
          'referenceYear', portal_decorated.card -> 'referenceYear',
          'modifiedAt', pg_catalog.to_char(
            portal_decorated.modified_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          ),
          'match', pg_catalog.jsonb_build_object(
            -- Keep the retained filtered-empty-query match metadata byte-identical.
            'kind', case when p_filters <> '{}'::jsonb
                and coalesce(portal_decorated.card ->> 'casNumber','') = ''
              then 'identifier' else 'lexical' end,
            'score', 0::numeric,
            'reasonCodes', case when p_filters <> '{}'::jsonb
                and coalesce(portal_decorated.card ->> 'casNumber','') = ''
              then pg_catalog.jsonb_build_array('cas') else '[]'::jsonb end
          )
        ) order by portal_decorated.page_rank
      ) filter (where portal_decorated.page_rank <= p_limit), '[]'::jsonb),
      case when max(portal_decorated.page_rank) > p_limit then
        (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'v', 1,
          'fp', p_query_fingerprint,
          'rankKey', case p_sort
            when 'relevance' then '0'
            when 'modified_desc' then pg_catalog.to_char(
              portal_decorated.modified_at at time zone 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
            )
            else pg_catalog.lower(portal_decorated.name_key)
          end,
          'kind', p_kind,
          'id', portal_decorated.id::text,
          'version', portal_decorated.version
        ) order by portal_decorated.page_rank)
          filter (where portal_decorated.page_rank = p_limit)) -> 0
      else null end
    into v_items, v_next_cursor_payload
    from portal_decorated;

    return pg_catalog.jsonb_build_object(
      'items', v_items,
      'nextCursorPayload', v_next_cursor_payload
    );
  end if;


  with portal_prefilter as materialized (
    select p_kind as dataset_kind,
      candidate.*
    from private.display_catalog_candidate_rows_v3(
      p_kind,
      p_query,
      v_exact_id,
      v_like_pattern
    ) as candidate
    where private.display_navigation_version_matches_v3(
      p_kind, p_filters, candidate.id, candidate.version
    )
  ), portal_facts as materialized (
    select portal_prefilter.*,
      private.display_catalog_card_facts_v1(
        portal_prefilter.card,
        p_filters,
        p_query
      ) as facts
    from portal_prefilter
  ), portal_scored as materialized (
    select portal_facts.*,
      case
        when nullif(portal_facts.facts ->> 'nameKey', '') is not null
          and pg_catalog.length(portal_facts.facts ->> 'nameKey') <= 500
          and pg_catalog.octet_length(portal_facts.facts ->> 'nameKey') <= 2000
          and portal_facts.facts ->> 'nameKey' !~ '[[:cntrl:]]'
          then portal_facts.facts ->> 'nameKey'
        else '~unnamed:' || portal_facts.id::text
      end as name_key,
      case
        when p_query = '' then 0::numeric
        when pg_catalog.lower(portal_facts.id::text) = p_query then 1::numeric
        when pg_catalog.lower(coalesce(portal_facts.facts ->> 'casNumber', '')) = p_query
          then 0.98::numeric
        when (portal_facts.facts ->> 'nameExact')::boolean then 0.95::numeric
        when (portal_facts.facts ->> 'classificationExact')::boolean
          then 0.92::numeric
        when p_query <> '' then 0.70::numeric
        else 0::numeric
      end as score,
      case
        when pg_catalog.lower(portal_facts.id::text) = p_query
          then pg_catalog.jsonb_build_array('exact_id')
        when pg_catalog.lower(coalesce(portal_facts.facts ->> 'casNumber', '')) = p_query
          then pg_catalog.jsonb_build_array('cas')
        when (portal_facts.facts ->> 'nameExact')::boolean
          or (portal_facts.facts ->> 'nameContains')::boolean
          then pg_catalog.jsonb_build_array('name')
        when (portal_facts.facts ->> 'classificationExact')::boolean
          or (portal_facts.facts ->> 'classificationContains')::boolean
          then pg_catalog.jsonb_build_array('classification')
        when p_query <> '' then pg_catalog.jsonb_build_array('full_text')
        else '[]'::jsonb
      end as reason_codes
    from portal_facts
  ), portal_filtered as materialized (
    select portal_scored.*,
      case p_sort
        when 'relevance' then portal_scored.score::text
        when 'modified_desc' then pg_catalog.to_char(
          portal_scored.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        )
        else pg_catalog.lower(portal_scored.name_key)
      end as rank_key
    from portal_scored
    where (p_query = '' or portal_scored.score > 0)
      and (
        not (p_filters ? 'accessLevel')
        or portal_scored.facts ->> 'accessLevel' = p_filters ->> 'accessLevel'
      )
      and (
        not (p_filters ? 'geography')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'geographyCode',
          ''
        ))) = p_filters ->> 'geography'
      )
      and (
        not (p_filters ? 'classification')
        or (portal_scored.facts ->> 'classificationFilterMatch')::boolean
      )
      and (
        not (p_filters ? 'referenceYearFrom')
        or (portal_scored.facts ->> 'referenceYear')::integer
          >= (p_filters ->> 'referenceYearFrom')::integer
      )
      and (
        not (p_filters ? 'referenceYearTo')
        or (portal_scored.facts ->> 'referenceYear')::integer
          <= (p_filters ->> 'referenceYearTo')::integer
      )
      and (
        not (p_filters ? 'processSubtype')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'processSubtype',
          ''
        ))) = p_filters ->> 'processSubtype'
      )
      and (
        not (p_filters ? 'source')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_scored.facts ->> 'source',
          ''
        ))) = p_filters ->> 'source'
      )
  ), portal_after_cursor as materialized (
    select portal_filtered.*
    from portal_filtered
    where p_cursor_rank is null
      or case p_sort
        when 'relevance' then
          portal_filtered.score < p_cursor_rank::numeric
          or (
            portal_filtered.score = p_cursor_rank::numeric
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        when 'modified_desc' then
          portal_filtered.modified_at < p_cursor_rank::timestamptz
          or (
            portal_filtered.modified_at = p_cursor_rank::timestamptz
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
        else
          pg_catalog.lower(portal_filtered.name_key) > pg_catalog.lower(p_cursor_rank)
          or (
            pg_catalog.lower(portal_filtered.name_key) = pg_catalog.lower(p_cursor_rank)
            and (
              portal_filtered.id > p_cursor_id
              or (
                portal_filtered.id = p_cursor_id
                and portal_filtered.version < p_cursor_version
              )
            )
          )
      end
  ), portal_ordered as materialized (
    select portal_after_cursor.*,
      pg_catalog.row_number() over (
        order by
          case when p_sort = 'relevance' then portal_after_cursor.score end desc,
          case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
          case when p_sort = 'name_asc'
            then pg_catalog.lower(portal_after_cursor.name_key) end asc,
          portal_after_cursor.id asc,
          portal_after_cursor.version desc
      ) as page_rank
    from portal_after_cursor
    order by
      case when p_sort = 'relevance' then portal_after_cursor.score end desc,
      case when p_sort = 'modified_desc' then portal_after_cursor.modified_at end desc,
      case when p_sort = 'name_asc'
        then pg_catalog.lower(portal_after_cursor.name_key) end asc,
      portal_after_cursor.id asc,
      portal_after_cursor.version desc
    limit p_limit + 1
  ), portal_hydrated as materialized (
    select portal_ordered.*
    from portal_ordered
  )
  select
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'key', pg_catalog.jsonb_build_object(
          'kind', p_kind,
          'id', portal_hydrated.id::text,
          'version', portal_hydrated.version
        ),
        'accessLevel', portal_hydrated.card -> 'accessLevel',
        'capabilities', portal_hydrated.card -> 'capabilities',
        'names', portal_hydrated.card -> 'names',
        'summary', portal_hydrated.card -> 'summary',
        'geography', portal_hydrated.card -> 'geography',
        'referenceYear', portal_hydrated.card -> 'referenceYear',
        'modifiedAt', pg_catalog.to_char(
          portal_hydrated.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        ),
        'match', pg_catalog.jsonb_build_object(
          'kind', case when portal_hydrated.reason_codes
            ?| array['exact_id', 'cas', 'classification']
            then 'identifier' else 'lexical' end,
          'score', portal_hydrated.score,
          'reasonCodes', portal_hydrated.reason_codes
        )
      ) order by portal_hydrated.page_rank
    ) filter (where portal_hydrated.page_rank <= p_limit), '[]'::jsonb),
    case when max(portal_hydrated.page_rank) > p_limit then
      (pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'v', 1,
        'fp', p_query_fingerprint,
        'rankKey', portal_hydrated.rank_key,
        'kind', p_kind,
        'id', portal_hydrated.id::text,
        'version', portal_hydrated.version
      ) order by portal_hydrated.page_rank)
        filter (where portal_hydrated.page_rank = p_limit)) -> 0
    else null end
  into v_items, v_next_cursor_payload
  from portal_hydrated;

  return pg_catalog.jsonb_build_object(
    'items', v_items,
    'nextCursorPayload', v_next_cursor_payload
  );
end;
$_$;

ALTER FUNCTION "private"."display_catalog_search_v3_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_search_v3_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_single_character_search_v1_impl"("p_kind" "text", "p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "work_mem" TO '32MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_items jsonb;
  v_next_cursor_payload jsonb;
begin
  perform private.display_assert_catalog_character_contract_cn1();

  if p_kind not in ('process', 'flow')
     or pg_catalog.char_length(p_query) <> 1
     or p_limit not between 1 and 50 then
    raise exception 'invalid Portal character Search'
      using errcode = '22023';
  end if;

  with latest as materialized (
    select distinct on (character_row.id)
      character_row.id,
      character_row.version,
      character_row.state_code,
      character_row.modified_at,
      character_row.document_characters,
      character_row.name_characters,
      character_row.name_exact_characters,
      character_row.classification_characters,
      character_row.classification_exact_characters
    from private.display_catalog_character_current_v2 as character_row
    where character_row.dataset_kind = p_kind
    order by character_row.id,
      character_row.version desc,
      character_row.modified_at desc,
      character_row.state_code desc
  ), scored as materialized (
    select latest.*,
      case
        when pg_catalog.strpos(
          latest.name_exact_characters, p_query
        ) > 0 then 0.95::numeric
        when pg_catalog.strpos(
          latest.classification_exact_characters, p_query
        ) > 0 then 0.92::numeric
        else 0.70::numeric
      end as score,
      case
        when pg_catalog.strpos(latest.name_characters, p_query) > 0
          then pg_catalog.jsonb_build_array('name')
        when pg_catalog.strpos(
          latest.classification_characters, p_query
        ) > 0 then pg_catalog.jsonb_build_array('classification')
        else pg_catalog.jsonb_build_array('full_text')
      end as reason_codes
    from latest
    where pg_catalog.strpos(latest.document_characters, p_query) > 0
  ), after_cursor as materialized (
    select scored.*
    from scored
    where p_cursor_rank is null
      or scored.score < p_cursor_rank::numeric
      or (
        scored.score = p_cursor_rank::numeric
        and (
          scored.id > p_cursor_id
          or (
            scored.id = p_cursor_id
            and scored.version < p_cursor_version
          )
        )
      )
  ), ordered as materialized (
    select after_cursor.*,
      pg_catalog.row_number() over (
        order by after_cursor.score desc,
          after_cursor.id asc,
          after_cursor.version desc
      ) as page_rank
    from after_cursor
    order by after_cursor.score desc,
      after_cursor.id asc,
      after_cursor.version desc
    limit p_limit + 1
  ), hydrated as materialized (
    select ordered.*,
      projection.card
    from ordered
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = p_kind
     and projection.id = ordered.id
     and projection.version = ordered.version
  )
  select coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key', pg_catalog.jsonb_build_object(
            'kind', p_kind,
            'id', hydrated.id::text,
            'version', hydrated.version
          ),
          'accessLevel', hydrated.card -> 'accessLevel',
          'capabilities', hydrated.card -> 'capabilities',
          'names', hydrated.card -> 'names',
          'summary', hydrated.card -> 'summary',
          'geography', hydrated.card -> 'geography',
          'referenceYear', hydrated.card -> 'referenceYear',
          'modifiedAt', pg_catalog.to_char(
            hydrated.modified_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          ),
          'match', pg_catalog.jsonb_build_object(
            'kind', 'lexical',
            'score', hydrated.score,
            'reasonCodes', hydrated.reason_codes
          )
        )
        order by hydrated.page_rank
      ) filter (where hydrated.page_rank <= p_limit),
      '[]'::jsonb
    ),
    case
      when pg_catalog.max(hydrated.page_rank) > p_limit then
        (
          pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'v', 1,
              'fp', p_query_fingerprint,
              'rankKey', hydrated.score::text,
              'kind', p_kind,
              'id', hydrated.id::text,
              'version', hydrated.version
            )
            order by hydrated.page_rank
          ) filter (where hydrated.page_rank = p_limit)
        ) -> 0
      else null
    end
  into v_items, v_next_cursor_payload
  from hydrated;

  return pg_catalog.jsonb_build_object(
    'items', v_items,
    'nextCursorPayload', v_next_cursor_payload
  );
end
$$;

ALTER FUNCTION "private"."display_catalog_single_character_search_v1_impl"("p_kind" "text", "p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_single_character_search_v1_impl"("p_kind" "text", "p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_access_restrictions_open_v1"("p_value" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case
    when p_value is null or p_value = 'null'::jsonb then true
    when jsonb_typeof(p_value) not in ('array', 'object', 'string') then false
    else not exists (
      select 1
      from jsonb_array_elements(
        case jsonb_typeof(p_value)
          when 'array' then p_value
          else jsonb_build_array(p_value)
        end
      ) as restriction(value)
      where case jsonb_typeof(restriction.value)
        when 'object' then case
          when restriction.value ? '#text'
            and jsonb_typeof(restriction.value -> '#text') = 'string'
            then lower(private.display_scalar_text_v1(restriction.value -> '#text'))
          else '__invalid__'
        end
        when 'string' then lower(private.display_scalar_text_v1(restriction.value))
        else '__invalid__'
      end not in ('', 'none')
    )
  end
$$;

ALTER FUNCTION "private"."display_access_restrictions_open_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_access_restrictions_open_v1"("p_value" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_admin jsonb;
  v_publication jsonb;
  v_commissioner jsonb;
  v_data_generator jsonb;
  v_data_entry jsonb;
  v_copyright_text text;
  v_copyright boolean;
  v_permalink text;
begin
  v_admin := case p_kind
    when 'process' then p_json #> '{processDataSet,administrativeInformation}'
    when 'flow' then p_json #> '{flowDataSet,administrativeInformation}'
    else null
  end;
  v_publication := v_admin -> 'publicationAndOwnership';
  v_commissioner := v_admin #> '{common:commissionerAndGoal,common:referenceToCommissioner}';
  v_data_generator := v_admin #> '{dataGenerator,common:referenceToPersonOrEntityGeneratingTheDataSet}';
  v_data_entry := v_admin #> '{dataEntryBy,common:referenceToPersonOrEntityEnteringTheData}';
  v_copyright_text := lower(coalesce(
    private.display_scalar_text_v1(v_publication -> 'common:copyright'),
    ''
  ));
  v_copyright := case
    when v_copyright_text in ('true', 'yes', '1') then true
    when v_copyright_text in ('false', 'no', '0') then false
    else null
  end;
  -- No public-origin allowlist exists in v1. A syntactically valid HTTPS URL
  -- is not proof that an authored URI is public rather than a private object
  -- or service locator, so this field stays closed until such a contract lands.
  v_permalink := null;

  return jsonb_build_object(
    'workflowStatus', nullif(private.display_scalar_text_v1(v_publication -> 'common:workflowAndPublicationStatus'), ''),
    'copyright', v_copyright,
    'owner', private.display_named_reference_v1(v_publication -> 'common:referenceToOwnershipOfDataSet'),
    'commissioner', private.display_named_reference_v1(v_commissioner),
    'dataGenerator', private.display_named_reference_v1(v_data_generator),
    'dataEntryBy', private.display_named_reference_v1(v_data_entry),
    'project', private.display_localized_text_v1(v_admin #> '{common:commissionerAndGoal,common:project}'),
    'intendedApplications', private.display_localized_text_v1(v_admin #> '{common:commissionerAndGoal,common:intendedApplications}'),
    'accessRestrictions', private.display_localized_text_v1(v_publication -> 'common:accessRestrictions'),
    'licenseType', nullif(private.display_scalar_text_v1(v_publication -> 'common:licenseType'), ''),
    'registrationNumber', nullif(private.display_scalar_text_v1(v_publication -> 'common:registrationNumber'), ''),
    'lastRevisionAt', private.display_datetime_v1(v_publication ->> 'common:dateOfLastRevision'),
    'permanentDataSetUri', v_permalink,
    'precedingVersion', private.display_named_reference_v1(v_publication -> 'common:referenceToPrecedingDataSetVersion')
  );
end
$$;

ALTER FUNCTION "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_canonical_decimal_v1"("p_value" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_input text := btrim(p_value);
  v_match text[];
  v_exponent integer;
  v_number numeric;
  v_output text;
  v_digits text;
begin
  if p_value is null
     or length(v_input) = 0
     or length(v_input) > 128 then
    return null;
  end if;

  v_match := regexp_match(
    v_input,
    '^([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?$'
  );
  if v_match is null
     or coalesce(length(v_match[2]), 0) + coalesce(length(v_match[3]), 0) = 0 then
    return null;
  end if;

  if v_match[4] is not null then
    if length(ltrim(v_match[4], '+-')) > 4 then
      return null;
    end if;
    v_exponent := v_match[4]::integer;
    if abs(v_exponent) > 1000 then
      return null;
    end if;
  end if;

  begin
    v_number := v_input::numeric;
    v_output := trim_scale(v_number)::text;
  exception
    when others then
      return null;
  end;

  if v_output ~ '[eE+]' or length(v_output) > 2048 then
    return null;
  end if;
  if v_number = 0 then
    return '0';
  end if;

  v_digits := regexp_replace(v_output, '[^0-9]', '', 'g');
  if length(v_digits) not between 1 and 38 then
    return null;
  end if;

  return v_output;
end
$_$;

ALTER FUNCTION "private"."display_canonical_decimal_v1"("p_value" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_canonical_decimal_v1"("p_value" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_card_context_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
declare
  v_information jsonb;
  v_modelling jsonb;
  v_reference_name jsonb := '[]'::jsonb;
  v_functional_unit jsonb := 'null'::jsonb;
  v_technology jsonb := '[]'::jsonb;
  v_source jsonb;
  v_review_status jsonb := 'null'::jsonb;
  v_flow_property jsonb;
begin
  if pg_catalog.jsonb_typeof(p_json) <> 'object' then
    return null;
  end if;

  if p_kind = 'process'
     and pg_catalog.jsonb_typeof(p_json -> 'processDataSet') = 'object' then
    v_information := p_json #> '{processDataSet,processInformation}';
    v_modelling := p_json #> '{processDataSet,modellingAndValidation}';
    v_reference_name := private.display_process_reference_product_v1(p_json);

    -- Functional-unit amount/unit are public metadata, not permission to read
    -- Exchanges. Reuse the exact open support-chain validator for both public
    -- Process states, then emit null unless the evidence is complete.
    v_functional_unit := private.display_process_functional_unit_v1(p_state_code, p_json);
    if pg_catalog.jsonb_typeof(v_functional_unit) <> 'object'
       or pg_catalog.jsonb_typeof(
         v_functional_unit -> 'amount'
       ) <> 'string'
       or pg_catalog.jsonb_typeof(
         v_functional_unit -> 'unit'
       ) <> 'string' then
      v_functional_unit := 'null'::jsonb;
    end if;

    v_technology := private.display_localized_text_v1(
      v_information #> '{technology,technologyDescriptionAndIncludedProcesses}'
    ) || private.display_localized_text_v1(
      v_information #> '{technology,technologicalApplicability}'
    );
    select coalesce(
      pg_catalog.to_jsonb(nullif(
        private.display_scalar_text_v1(review_item -> '@type'),
        ''
      )),
      'null'::jsonb
    )
    into v_review_status
    from private.display_json_items_v1(
      v_modelling #> '{validation,review}'
    ) as review_item
    limit 1;
    v_review_status := coalesce(v_review_status, 'null'::jsonb);
  elsif p_kind = 'flow'
     and pg_catalog.jsonb_typeof(p_json -> 'flowDataSet') = 'object' then
    v_flow_property := private.display_reference_flowproperty_v1(p_json);
    v_reference_name := coalesce(
      v_flow_property -> 'name',
      '[]'::jsonb
    );
  else
    return null;
  end if;

  v_source := private.display_source_v1(p_kind, p_json);
  if pg_catalog.jsonb_typeof(v_reference_name) <> 'array'
     or pg_catalog.jsonb_typeof(v_technology) <> 'array'
     or pg_catalog.jsonb_typeof(v_source) <> 'object' then
    return null;
  end if;

  return pg_catalog.jsonb_build_object(
    'reference', pg_catalog.jsonb_build_object(
      'kind', case p_kind
        when 'process' then 'reference_product'
        else 'reference_flow_property'
      end,
      'name', v_reference_name
    ),
    'functionalUnit', v_functional_unit,
    'technology', v_technology,
    'source', v_source,
    'quality', pg_catalog.jsonb_build_object(
      'reviewStatus', v_review_status
    )
  );
end
$$;

ALTER FUNCTION "private"."display_card_context_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_card_context_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_card_matches_filters_v2"("p_card" "jsonb", "p_filters" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select
    (not (p_filters ? 'accessLevel') or p_card ->> 'accessLevel' = p_filters ->> 'accessLevel')
    and (not (p_filters ? 'geography') or pg_catalog.lower(pg_catalog.btrim(coalesce(
      p_card #>> '{geography,code}', ''))) = p_filters ->> 'geography')
    and (not (p_filters ? 'classification') or exists (
      select 1 from pg_catalog.jsonb_array_elements(coalesce(
        p_card -> 'classifications', '[]'::jsonb)) as classification(item)
      where pg_catalog.lower(pg_catalog.btrim(classification.item ->> 'code'))
        = p_filters ->> 'classification'))
    and (not (p_filters ? 'referenceYearFrom') or (p_card ->> 'referenceYear')::integer
      >= (p_filters ->> 'referenceYearFrom')::integer)
    and (not (p_filters ? 'referenceYearTo') or (p_card ->> 'referenceYear')::integer
      <= (p_filters ->> 'referenceYearTo')::integer)
    and (not (p_filters ? 'processSubtype') or pg_catalog.lower(pg_catalog.btrim(coalesce(
      p_card ->> 'processSubtype', ''))) = p_filters ->> 'processSubtype')
    and (not (p_filters ? 'source') or pg_catalog.lower(pg_catalog.btrim(coalesce(
      p_card ->> 'source', ''))) = p_filters ->> 'source');
$$;

ALTER FUNCTION "private"."display_card_matches_filters_v2"("p_card" "jsonb", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_card_matches_filters_v2"("p_card" "jsonb", "p_filters" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_character_field_set_v1"("p_items" "jsonb", "p_key" "text", "p_exact_one" boolean) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select private.display_catalog_character_set_v1(
    coalesce(
      pg_catalog.string_agg(normalized.value, '' order by normalized.ordinality),
      ''
    )
  )
  from (
    select item.ordinality,
      pg_catalog.lower(pg_catalog.btrim(item.value ->> p_key)) as value
    from pg_catalog.jsonb_array_elements(
      case
        when pg_catalog.jsonb_typeof(p_items) = 'array' then p_items
        else '[]'::jsonb
      end
    ) with ordinality as item(value, ordinality)
    where p_key in ('value', 'code')
      and pg_catalog.jsonb_typeof(item.value) = 'object'
      and pg_catalog.jsonb_typeof(item.value -> p_key) = 'string'
      and nullif(pg_catalog.btrim(item.value ->> p_key), '') is not null
      and (
        not p_exact_one
        or pg_catalog.char_length(
          pg_catalog.lower(pg_catalog.btrim(item.value ->> p_key))
        ) = 1
      )
  ) as normalized
$$;

ALTER FUNCTION "private"."display_catalog_character_field_set_v1"("p_items" "jsonb", "p_key" "text", "p_exact_one" boolean) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_character_field_set_v1"("p_items" "jsonb", "p_key" "text", "p_exact_one" boolean) FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_character_set_v1"("p_value" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select coalesce(
    pg_catalog.string_agg(
      distinct_character.value,
      ''
      order by distinct_character.value collate pg_catalog."C"
    ),
    ''
  )
  from (
    select distinct character.value
    from pg_catalog.regexp_split_to_table(
      coalesce(p_value, ''),
      ''
    ) as character(value)
    where character.value <> ''
  ) as distinct_character
$$;

ALTER FUNCTION "private"."display_catalog_character_set_v1"("p_value" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_character_set_v1"("p_value" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_catalog_facet_facts_v1"("p_kind" "text", "p_card" "jsonb") RETURNS TABLE("facet_access_level" "text", "facet_geography" "text", "facet_reference_year" "text", "facet_process_subtype" "text", "facet_source" "text")
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select
    p_card ->> 'accessLevel',
    pg_catalog.lower(pg_catalog.btrim(
      p_card #>> '{geography,code}'
    )),
    pg_catalog.btrim(p_card ->> 'referenceYear'),
    case when p_kind = 'process' then
      pg_catalog.lower(pg_catalog.btrim(
        p_card ->> 'processSubtype'
      ))
    else null::text end,
    pg_catalog.lower(pg_catalog.btrim(p_card ->> 'source'))
$$;

ALTER FUNCTION "private"."display_catalog_facet_facts_v1"("p_kind" "text", "p_card" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_facet_facts_v1"("p_kind" "text", "p_card" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_rows_v1"("p_kind" "text") RETURNS TABLE("id" "uuid", "version" "text", "json_data" "jsonb", "state_code" integer, "modified_at" timestamp with time zone, "lexical_text" "text")
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
begin
  if p_kind = 'process' then
    return query
    select row.id, row.version::text, row.json, row.state_code, row.modified_at,
      ''::text
    from public.processes as row
    where private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'processDataSet') = 'object'
      and row.modified_at is not null;
  elsif p_kind = 'flow' then
    return query
    select row.id, row.version::text, row.json, row.state_code, row.modified_at,
      ''::text
    from public.flows as row
    where private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'flowDataSet') = 'object'
      and row.modified_at is not null;
  end if;
end
$$;

ALTER FUNCTION "private"."display_catalog_rows_v1"("p_kind" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_rows_v1"("p_kind" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_summary_label_v1"("p_card" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'language', label_item.language,
    'value', label_item.label_value
  ) order by label_item.preference,
      pg_catalog.lower(label_item.language) collate pg_catalog."C",
      label_item.label_value collate pg_catalog."C",
      label_item.ordinality), '[]'::jsonb)
  from (
    select
      pg_catalog.btrim(item.value ->> 'language') as language,
      pg_catalog.btrim(item.value ->> 'value') as label_value,
      item.ordinality,
      case pg_catalog.lower(pg_catalog.btrim(item.value ->> 'language'))
        when 'zh-cn' then 0
        when 'en' then 1
        else 2
      end as preference
    from pg_catalog.jsonb_array_elements(
      case pg_catalog.jsonb_typeof(p_card -> 'names')
        when 'array' then p_card -> 'names'
        else '[]'::jsonb
      end
    ) with ordinality as item(value, ordinality)
    where pg_catalog.jsonb_typeof(item.value) = 'object'
      and pg_catalog.jsonb_typeof(item.value -> 'language') = 'string'
      and pg_catalog.jsonb_typeof(item.value -> 'value') = 'string'
      and pg_catalog.btrim(item.value ->> 'language') ~
        '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$'
      and pg_catalog.length(
        pg_catalog.btrim(item.value ->> 'language')
      ) <= 35
      and nullif(pg_catalog.btrim(item.value ->> 'value'), '') is not null
      and pg_catalog.length(
        pg_catalog.btrim(item.value ->> 'value')
      ) <= 160
      and pg_catalog.octet_length(
        pg_catalog.btrim(item.value ->> 'value')
      ) <= 640
    order by preference,
      pg_catalog.lower(
        pg_catalog.btrim(item.value ->> 'language')
      ) collate pg_catalog."C",
      pg_catalog.btrim(item.value ->> 'value') collate pg_catalog."C",
      item.ordinality
    limit 2
  ) as label_item
$_$;

ALTER FUNCTION "private"."display_catalog_summary_label_v1"("p_card" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_summary_label_v1"("p_card" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_catalog_summary_valid_cas_v1"("p_value" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
  select case
    when p_value ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$' then
      pg_catalog.right(p_value, 1)::integer = (
        select pg_catalog.mod(
          pg_catalog.sum(
            digit.value::integer * digit.ordinality::integer
          ),
          10
        )
        from pg_catalog.regexp_split_to_table(
          pg_catalog.reverse(pg_catalog.replace(
            pg_catalog.left(p_value, pg_catalog.length(p_value) - 2),
            '-',
            ''
          )),
          ''
        ) with ordinality as digit(value, ordinality)
      )
    else false
  end
$_$;

ALTER FUNCTION "private"."display_catalog_summary_valid_cas_v1"("p_value" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_summary_valid_cas_v1"("p_value" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_classifications_v1"("p_information" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb := '[]'::jsonb;
  v_classification jsonb;
  v_class jsonb;
  v_category jsonb;
  v_system text;
  v_code text;
begin
  for v_classification in
    select private.display_json_items_v1(p_information -> 'common:classification')
  loop
    v_system := coalesce(
      nullif(private.display_scalar_text_v1(v_classification -> '@name'), ''),
      'ILCD'
    );
    for v_class in
      select private.display_json_items_v1(v_classification -> 'common:class')
    loop
      v_code := coalesce(
        nullif(private.display_scalar_text_v1(v_class -> '@classId'), ''),
        nullif(private.display_scalar_text_v1(v_class -> '#text'), '')
      );
      if v_code is not null then
        v_result := v_result || jsonb_build_array(jsonb_build_object(
          'system', v_system,
          'code', v_code,
          'label', private.display_localized_text_v1(v_class)
        ));
      end if;
    end loop;
  end loop;

  for v_category in
    select private.display_json_items_v1(
      p_information #> '{common:elementaryFlowCategorization,common:category}'
    )
  loop
    v_code := coalesce(
      nullif(private.display_scalar_text_v1(v_category -> '@catId'), ''),
      nullif(private.display_scalar_text_v1(v_category -> '@classId'), ''),
      nullif(private.display_scalar_text_v1(v_category -> '#text'), '')
    );
    if v_code is not null then
      v_result := v_result || jsonb_build_array(jsonb_build_object(
        'system', 'elementary-flow',
        'code', v_code,
        'label', private.display_localized_text_v1(v_category)
      ));
    end if;
  end loop;
  return v_result;
end
$$;

ALTER FUNCTION "private"."display_classifications_v1"("p_information" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_classifications_v1"("p_information" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_value jsonb;
  v_item jsonb;
  v_result jsonb := '[]'::jsonb;
begin
  v_value := case p_kind
    when 'process' then p_json #> '{processDataSet,modellingAndValidation,complianceDeclarations,compliance}'
    when 'flow' then p_json #> '{flowDataSet,modellingAndValidation,complianceDeclarations,compliance}'
    else null
  end;
  for v_item in select private.display_json_items_v1(v_value)
  loop
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'system', private.display_named_reference_v1(v_item -> 'common:referenceToComplianceSystem'),
      'overall', nullif(private.display_scalar_text_v1(v_item -> 'common:approvalOfOverallCompliance'), ''),
      'nomenclature', nullif(private.display_scalar_text_v1(v_item -> 'common:nomenclatureCompliance'), ''),
      'methodological', nullif(private.display_scalar_text_v1(v_item -> 'common:methodologicalCompliance'), ''),
      'review', nullif(private.display_scalar_text_v1(v_item -> 'common:reviewCompliance'), ''),
      'documentation', nullif(private.display_scalar_text_v1(v_item -> 'common:documentationCompliance'), ''),
      'quality', nullif(private.display_scalar_text_v1(v_item -> 'common:qualityCompliance'), '')
    ));
  end loop;
  return v_result;
end
$$;

ALTER FUNCTION "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_current_lcia_publication_for_process_v1"("p_process_id" "uuid", "p_process_version" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
  with visible as materialized (
    select
      binding.projection_id,
      binding.lcia_result_publication_id,
      binding.package_id,
      binding.package_version,
      binding.source_published_at
    from private.portal_lcia_projection_publications as binding
    join private.portal_lcia_projection_headers as projection
      on projection.id = binding.projection_id
    join private.portal_lcia_projection_process_axis as process_axis
      on process_axis.projection_id = binding.projection_id
     and process_axis.process_id = p_process_id
     and process_axis.process_version = p_process_version
    join private.lcia_result_publications as publication
      on publication.id = binding.lcia_result_publication_id
     and publication.package_id = binding.package_id
    join private.lcia_result_packages as package
      on package.id = binding.package_id
    join public.processes as process
      on process.id = process_axis.process_id
     and process.version::text = process_axis.process_version
    where p_process_id is not null
      and p_process_version ~ '^\d{2}\.\d{2}\.\d{3}$'
      and binding.status = 'finalized'
      and binding.revoked_at is null
      and projection.status = 'prepared'
      and projection.content_hash = binding.projection_content_hash
      and publication.is_current
      and publication.status = 'current'
      and publication.publication_series_key = 'global'
      and publication.publication_channel = 'public'
      and publication.visibility_scope = 'public'
      and publication.published_at = binding.source_published_at
      and package.status = 'preview_ready'
      and package.package_version = binding.package_version
      and package.package_result_hash = binding.package_result_hash
      and private.portal_display_request_visible_v1('process',process.id,process.version::text)
      and jsonb_typeof(process.json) = 'object'
      and private.display_process_open_capability_bridge_v1(
        process.state_code, process.json
      )
      and private.display_lcia_projection_is_public_v1(binding.projection_id)
    order by binding.source_published_at desc, binding.id
    limit 1
  ), methods as materialized (
    select
      visible.projection_id,
      jsonb_agg(
        jsonb_build_object(
          'id', method.method_id::text,
          'version', method.method_version
        )
        order by method.method_id, method.method_version
      ) as lcia_methods
    from visible
    cross join lateral (
      select distinct impact.method_id, impact.method_version
      from private.portal_lcia_projection_impact_axis as impact
      where impact.projection_id = visible.projection_id
    ) as method
    group by visible.projection_id
  )
  select jsonb_build_object(
    'publicationId', visible.lcia_result_publication_id::text,
    'packageId', visible.package_id::text,
    'packageVersion', visible.package_version,
    'publishedAt', private.display_timestamp_v1(visible.source_published_at),
    'lciaMethods', methods.lcia_methods
  )
  from visible
  join methods using (projection_id)
  where jsonb_array_length(methods.lcia_methods) > 0
$_$;

ALTER FUNCTION "private"."display_current_lcia_publication_for_process_v1"("p_process_id" "uuid", "p_process_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_current_lcia_publication_for_process_v1"("p_process_id" "uuid", "p_process_version" "text") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_cursor_decode_v1"("p_cursor" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_base64 text;
  v_result jsonb;
begin
  if p_cursor is null
     or length(p_cursor) = 0
     or length(p_cursor) > 4096
     or p_cursor !~ '^[A-Za-z0-9_-]+$' then
    return null;
  end if;
  v_base64 := translate(p_cursor, '-_', '+/');
  v_base64 := v_base64 || repeat('=', (4 - length(v_base64) % 4) % 4);
  begin
    v_result := convert_from(decode(v_base64, 'base64'), 'UTF8')::jsonb;
  exception
    when others then
      return null;
  end;
  if jsonb_typeof(v_result) <> 'object' then
    return null;
  end if;
  if v_result->>'displayScope' is distinct from private.portal_display_scope_identity_v1() then
    raise exception using errcode='22023',message='invalid portal request';
  end if;
  return v_result - 'displayScope';
end
$_$;

ALTER FUNCTION "private"."display_cursor_decode_v1"("p_cursor" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_cursor_decode_v1"("p_cursor" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_cursor_encode_v1"("p_payload" "jsonb") RETURNS "text"
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select rtrim(
    translate(
      replace(
        replace(encode(convert_to((p_payload || jsonb_build_object('displayScope',private.portal_display_scope_identity_v1()))::text, 'UTF8'), 'base64'), E'\n', ''),
        E'\r',
        ''
      ),
      '+/',
      '-_'
    ),
    '='
  )
$$;

ALTER FUNCTION "private"."display_cursor_encode_v1"("p_payload" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_cursor_encode_v1"("p_payload" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_information jsonb;
  v_modelling jsonb;
  v_location jsonb;
  v_location_code text;
  v_cas text;
begin
  if p_kind = 'process' then
    v_information := p_json #> '{processDataSet,processInformation}';
    v_modelling := p_json #> '{processDataSet,modellingAndValidation}';
    v_location := v_information #> '{geography,locationOfOperationSupplyOrProduction}';
    v_location_code := nullif(
      private.display_scalar_text_v1(v_location -> '@location'),
      ''
    );
    return jsonb_build_object(
      'kind', 'process',
      'names', private.display_process_names_v1(p_json),
      'generalComment', private.display_localized_text_v1(v_information #> '{dataSetInformation,common:generalComment}'),
      'referenceProduct', private.display_process_reference_product_v1(p_json),
      'functionalUnit', private.display_process_functional_unit_v1(p_state_code, p_json),
      'classifications', private.display_classifications_v1(v_information #> '{dataSetInformation,classificationInformation}'),
      'geography', jsonb_build_object(
        'code', v_location_code,
        'label', private.display_localized_text_v1(v_location -> 'descriptionOfRestrictions'),
        'precision', private.display_geography_precision_v1(v_location_code)
      ),
      'referenceYear', private.display_safe_year_v1(v_information #>> '{time,common:referenceYear}'),
      'validUntilYear', private.display_safe_year_v1(v_information #>> '{time,common:dataSetValidUntil}'),
      'technology',
        private.display_localized_text_v1(
          v_information #> '{technology,technologyDescriptionAndIncludedProcesses}'
        ) || private.display_localized_text_v1(
          v_information #> '{technology,technologicalApplicability}'
        ),
      'dataSetType', nullif(private.display_scalar_text_v1(
        v_modelling #> '{LCIMethodAndAllocation,typeOfDataSet}'
      ), ''),
      'allocationAndModeling',
        private.display_localized_text_v1(
          v_modelling #> '{LCIMethodAndAllocation,deviationsFromLCIMethodPrinciple}'
        ) || private.display_localized_text_v1(
          v_modelling #> '{LCIMethodAndAllocation,deviationsFromModellingConstants}'
        ),
      'cutoffRules', private.display_localized_text_v1(
        v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,deviationsFromCutOffAndCompletenessPrinciples}'
      ),
      'quality', jsonb_build_object(
        'reviewStatus', (
          select nullif(private.display_scalar_text_v1(review_item -> '@type'), '')
          from private.display_json_items_v1(v_modelling #> '{validation,review}') as review_item
          limit 1
        ),
        'timeRepresentativeness', private.display_first_text_v1(
          v_information #> '{time,common:timeRepresentativenessDescription}'
        ),
        'geographyRepresentativeness', private.display_first_text_v1(
          v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,geographicalRepresentativenessDescription}'
        ),
        'technologyRepresentativeness', private.display_first_text_v1(
          v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,technologicalRepresentativenessDescription}'
        ),
        'completeness', private.display_first_text_v1(
          v_modelling #> '{completeness,completenessOtherProblemField}'
        ),
        'uncertainty', private.display_first_text_v1(
          v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,uncertaintyAdjustments}'
        )
      ),
      'source', private.display_source_v1('process', p_json),
      'compliance', private.display_compliance_v1('process', p_json),
      'administration', private.display_administration_v1('process', p_json)
    );
  elsif p_kind = 'flow' then
    v_information := p_json #> '{flowDataSet,flowInformation}';
    v_modelling := p_json #> '{flowDataSet,modellingAndValidation}';
    v_location := v_information -> 'geography';
    v_location_code := case jsonb_typeof(v_location -> 'locationOfSupply')
      when 'string' then nullif(
        private.display_scalar_text_v1(v_location -> 'locationOfSupply'),
        ''
      )
      when 'object' then nullif(
        private.display_scalar_text_v1(v_location #> '{locationOfSupply,@location}'),
        ''
      )
      else null
    end;
    v_cas := nullif(btrim(coalesce(
      v_information #>> '{dataSetInformation,CASNumber}',
      v_information #>> '{dataSetInformation,common:CASNumber}'
    )), '');
    if v_cas !~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$' then
      v_cas := null;
    end if;
    return jsonb_build_object(
      'kind', 'flow',
      'names', private.display_localized_text_v1(v_information #> '{dataSetInformation,name,baseName}'),
      'synonyms', private.display_localized_text_v1(v_information #> '{dataSetInformation,common:synonyms}'),
      'generalComment', private.display_localized_text_v1(v_information #> '{dataSetInformation,common:generalComment}'),
      'casNumber', v_cas,
      'flowType', private.display_flow_kind_v1(private.display_scalar_text_v1(
        v_modelling #> '{LCIMethod,typeOfDataSet}'
      )),
      'classifications', private.display_classifications_v1(v_information #> '{dataSetInformation,classificationInformation}'),
      'locationOfSupply', jsonb_build_object(
        'code', v_location_code,
        'label', private.display_localized_text_v1(v_location #> '{locationOfSupply,descriptionOfRestrictions}')
      ),
      'referenceFlowProperty', private.display_reference_flowproperty_v1(p_json),
      'source', private.display_source_v1('flow', p_json),
      'compliance', private.display_compliance_v1('flow', p_json),
      'administration', private.display_administration_v1('flow', p_json)
    );
  end if;
  return null;
end
$_$;

ALTER FUNCTION "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_dataset_projection_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_json jsonb;
  v_state_code integer;
  v_modified_at timestamptz;
  v_capabilities jsonb;
begin
  if p_kind not in ('process', 'flow')
     or p_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    return null;
  end if;
  if p_kind = 'process' then
    select row.json, row.state_code, row.modified_at
    into v_json, v_state_code, v_modified_at
    from public.processes as row
    where row.id = p_id
      and row.version::text = p_version
      and private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'processDataSet') = 'object'
    limit 1;
  else
    select row.json, row.state_code, row.modified_at
    into v_json, v_state_code, v_modified_at
    from public.flows as row
    where row.id = p_id
      and row.version::text = p_version
      and private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'flowDataSet') = 'object'
    limit 1;
  end if;
  if v_json is null or v_modified_at is null then
    return null;
  end if;
  v_capabilities := private.display_capabilities_v1(p_kind, v_state_code, v_json);
  return jsonb_build_object(
    'schemaVersion', 'portal.public-dataset.v1',
    'key', jsonb_build_object('kind', p_kind, 'id', p_id::text, 'version', p_version),
    'accessLevel', case when (v_capabilities ->> 'exchangesVisible')::boolean then 'open' else 'metadata_only' end,
    'capabilities', v_capabilities,
    'metadata', private.display_dataset_metadata_v1(p_kind, v_state_code, v_json),
    'provenance', jsonb_build_object(
      'importBatchId', null,
      'normalizationRuleVersion', null,
      'fieldOrigins', '[]'::jsonb
    ),
    'publication', null,
    'modifiedAt', private.display_timestamp_v1(v_modified_at)
  );
end
$_$;

ALTER FUNCTION "private"."display_dataset_projection_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_dataset_projection_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_dataset_rows_v1"("p_kind" "text", "p_id" "uuid") RETURNS TABLE("id" "uuid", "version" "text", "json_data" "jsonb", "state_code" integer, "modified_at" timestamp with time zone, "lexical_text" "text")
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
begin
  if p_kind = 'process' then
    return query
    select row.id, row.version::text, row.json, row.state_code, row.modified_at,
      ''::text
    from public.processes as row
    where row.id = p_id
      and private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'processDataSet') = 'object'
      and row.modified_at is not null;
  elsif p_kind = 'flow' then
    return query
    select row.id, row.version::text, row.json, row.state_code, row.modified_at,
      ''::text
    from public.flows as row
    where row.id = p_id
      and private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'flowDataSet') = 'object'
      and row.modified_at is not null;
  end if;
end
$$;

ALTER FUNCTION "private"."display_dataset_rows_v1"("p_kind" "text", "p_id" "uuid") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_dataset_rows_v1"("p_kind" "text", "p_id" "uuid") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_datetime_v1"("p_value" "text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_timestamp timestamptz;
begin
  if nullif(btrim(coalesce(p_value, '')), '') is null
     or length(p_value) > 64
     or p_value !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$' then
    return null;
  end if;
  begin
    v_timestamp := p_value::timestamptz;
  exception
    when others then
      return null;
  end;
  return private.display_timestamp_v1(v_timestamp);
end
$_$;

ALTER FUNCTION "private"."display_datetime_v1"("p_value" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_datetime_v1"("p_value" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_decorate_card_context_v1"("p_page" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $_$
declare
  v_schema_version text := p_page ->> 'schemaVersion';
  v_kind text := p_page ->> 'kind';
  v_expected integer;
  v_actual integer;
  v_items jsonb;
begin
  perform private.display_assert_card_context_contract_v1();

  if pg_catalog.jsonb_typeof(p_page) <> 'object'
     or pg_catalog.jsonb_typeof(p_page -> 'items') <> 'array'
     or v_schema_version not in (
       'portal.public-search-page.v1',
       'portal.public-hybrid-candidate-page.v1'
     )
     or v_kind not in ('process', 'flow') then
    raise exception 'Portal card context page is invalid'
      using errcode = '55000';
  end if;
  v_expected := pg_catalog.jsonb_array_length(p_page -> 'items');
  if v_expected > (
    case
      when v_schema_version = 'portal.public-search-page.v1' then 50
      else 20
    end
  ) then
    raise exception 'Portal card context page exceeds its fixed bound'
      using errcode = '54000';
  end if;

  if v_kind = 'process' then
    with input as materialized (
      select item.value, item.ordinality,
        case
          when item.value #>> '{key,id}'
            ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then (item.value #>> '{key,id}')::uuid
          else null
        end as id,
        item.value #>> '{key,version}' as version
      from pg_catalog.jsonb_array_elements(p_page -> 'items')
        with ordinality as item(value, ordinality)
      where pg_catalog.jsonb_typeof(item.value) = 'object'
        and item.value #>> '{key,kind}' = 'process'
        and item.value #>> '{key,version}' ~ '^\d{2}\.\d{2}\.\d{3}$'
    ), hydrated as materialized (
      select input.value, input.ordinality,
        private.display_card_context_v1(
          'process', source.state_code, source.json
        ) as card_context
      from input
      join public.processes as source
        on source.id = input.id
       and source.version::text = input.version
       and private.portal_display_request_visible_v1(v_kind,source.id,source.version::text)
    )
    select count(*), coalesce(
      pg_catalog.jsonb_agg(
        hydrated.value || pg_catalog.jsonb_build_object(
          'context', hydrated.card_context
        ) order by hydrated.ordinality
      ),
      '[]'::jsonb
    )
    into v_actual, v_items
    from hydrated
    where pg_catalog.jsonb_typeof(hydrated.card_context) = 'object';
  else
    with input as materialized (
      select item.value, item.ordinality,
        case
          when item.value #>> '{key,id}'
            ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then (item.value #>> '{key,id}')::uuid
          else null
        end as id,
        item.value #>> '{key,version}' as version
      from pg_catalog.jsonb_array_elements(p_page -> 'items')
        with ordinality as item(value, ordinality)
      where pg_catalog.jsonb_typeof(item.value) = 'object'
        and item.value #>> '{key,kind}' = 'flow'
        and item.value #>> '{key,version}' ~ '^\d{2}\.\d{2}\.\d{3}$'
    ), hydrated as materialized (
      select input.value, input.ordinality,
        private.display_card_context_v1(
          'flow', source.state_code, source.json
        ) as card_context
      from input
      join public.flows as source
        on source.id = input.id
       and source.version::text = input.version
       and private.portal_display_request_visible_v1(v_kind,source.id,source.version::text)
    )
    select count(*), coalesce(
      pg_catalog.jsonb_agg(
        hydrated.value || pg_catalog.jsonb_build_object(
          'context', hydrated.card_context
        ) order by hydrated.ordinality
      ),
      '[]'::jsonb
    )
    into v_actual, v_items
    from hydrated
    where pg_catalog.jsonb_typeof(hydrated.card_context) = 'object';
  end if;

  if v_actual is distinct from v_expected then
    raise exception 'Portal card context exact-key hydration failed'
      using errcode = '55000';
  end if;
  return pg_catalog.jsonb_set(p_page, '{items}', v_items, false);
end
$_$;

ALTER FUNCTION "private"."display_decorate_card_context_v1"("p_page" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_decorate_card_context_v1"("p_page" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_exchange_support_v1"("p_process_state" integer, "p_process_json" "jsonb", "p_exchange" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_process_capabilities jsonb;
  v_internal_id text := btrim(coalesce(p_exchange ->> '@dataSetInternalID', ''));
  v_amount text;
  v_direction text;
  v_flow_reference jsonb := p_exchange -> 'referenceToFlowDataSet';
  v_flow_id_text text;
  v_flow_version text;
  v_flow_id uuid;
  v_flow_json jsonb;
  v_flow_state integer;
  v_flow_type text;
  v_exchange_kind text;
  v_flow_property_internal text;
  v_flow_property_item jsonb;
  v_flow_property_reference jsonb;
  v_flow_property_id_text text;
  v_flow_property_version text;
  v_flow_property_id uuid;
  v_flow_property_json jsonb;
  v_flow_property_state integer;
  v_unit_group_reference jsonb;
  v_unit_group_id_text text;
  v_unit_group_version text;
  v_unit_group_id uuid;
  v_unit_group_json jsonb;
  v_unit_group_state integer;
  v_unit_internal text;
  v_unit_item jsonb;
  v_unit text;
  v_unit_factor text;
  v_flow_factor text;
  v_classifications jsonb;
  v_uncertainty_type text;
  v_minimum text;
  v_maximum text;
  v_row jsonb;
  v_match_count integer;
begin
  v_process_capabilities := private.display_capabilities_v1('process', p_process_state, p_process_json);
  if coalesce((v_process_capabilities ->> 'exchangesVisible')::boolean, false) is not true
     or v_internal_id !~ '^(0|[1-9][0-9]{0,5})$' then
    return null;
  end if;

  v_amount := private.display_canonical_decimal_v1(
    coalesce(p_exchange ->> 'resultingAmount', p_exchange ->> 'meanAmount')
  );
  v_direction := case lower(btrim(coalesce(p_exchange ->> 'exchangeDirection', '')))
    when 'input' then 'input'
    when 'output' then 'output'
    else null
  end;
  v_flow_id_text := lower(btrim(coalesce(v_flow_reference ->> '@refObjectId', '')));
  v_flow_version := btrim(coalesce(v_flow_reference ->> '@version', ''));
  if v_amount is null
     or v_flow_reference->>'@type' is distinct from 'flow data set'
     or v_direction is null
     or v_flow_id_text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or v_flow_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    return null;
  end if;
  v_flow_id := v_flow_id_text::uuid;

  select row.json, row.state_code
  into v_flow_json, v_flow_state
  from public.flows as row
  where row.id = v_flow_id
    and row.version::text = v_flow_version
    and true
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'flowDataSet') = 'object'
  limit 1;
  if v_flow_json is null
     or coalesce((private.display_capabilities_v1('flow', v_flow_state, v_flow_json) ->> 'exchangesVisible')::boolean, false) is not true then
    return null;
  end if;

  v_flow_type := private.display_flow_kind_v1(
    private.display_scalar_text_v1(
      v_flow_json #> '{flowDataSet,modellingAndValidation,LCIMethod,typeOfDataSet}'
    )
  );
  v_exchange_kind := case v_flow_type
    when 'product' then 'technosphere'
    when 'elementary' then 'elementary'
    when 'waste' then 'waste'
    else null
  end;
  if v_exchange_kind is null then
    return null;
  end if;

  v_flow_property_internal := v_flow_json #>> '{flowDataSet,flowInformation,quantitativeReference,referenceToReferenceFlowProperty}';
  if v_flow_property_internal !~ '^(0|[1-9][0-9]{0,4})$' then
    return null;
  end if;
  select count(*), (jsonb_agg(item) -> 0)
  into v_match_count, v_flow_property_item
  from private.display_json_items_v1(v_flow_json #> '{flowDataSet,flowProperties,flowProperty}') as item
  where item ->> '@dataSetInternalID' = v_flow_property_internal
    and item ->> '@dataSetInternalID' ~ '^(0|[1-9][0-9]{0,4})$';
  if v_match_count <> 1 then
    return null;
  end if;
  v_flow_factor := private.display_canonical_decimal_v1(v_flow_property_item ->> 'meanValue');
  v_flow_property_reference := v_flow_property_item -> 'referenceToFlowPropertyDataSet';
  v_flow_property_id_text := lower(btrim(coalesce(v_flow_property_reference ->> '@refObjectId', '')));
  v_flow_property_version := btrim(coalesce(v_flow_property_reference ->> '@version', ''));
  if v_flow_property_reference->>'@type' is distinct from 'flow property data set'
     or v_flow_factor is distinct from '1'
     or v_flow_property_id_text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or v_flow_property_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    return null;
  end if;
  v_flow_property_id := v_flow_property_id_text::uuid;

  select row.json, row.state_code
  into v_flow_property_json, v_flow_property_state
  from public.flowproperties as row
  where row.id = v_flow_property_id
    and row.version::text = v_flow_property_version
    and true
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'flowPropertyDataSet') = 'object'
  limit 1;
  if v_flow_property_json is null
     or coalesce((private.display_capabilities_v1('flowproperty', v_flow_property_state, v_flow_property_json) ->> 'exchangesVisible')::boolean, false) is not true then
    return null;
  end if;

  v_unit_group_reference := v_flow_property_json #> '{flowPropertyDataSet,flowPropertiesInformation,quantitativeReference,referenceToReferenceUnitGroup}';
  v_unit_group_id_text := lower(btrim(coalesce(v_unit_group_reference ->> '@refObjectId', '')));
  v_unit_group_version := btrim(coalesce(v_unit_group_reference ->> '@version', ''));
  if v_unit_group_reference->>'@type' is distinct from 'unit group data set'
     or v_unit_group_id_text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or v_unit_group_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    return null;
  end if;
  v_unit_group_id := v_unit_group_id_text::uuid;

  select row.json, row.state_code
  into v_unit_group_json, v_unit_group_state
  from public.unitgroups as row
  where row.id = v_unit_group_id
    and row.version::text = v_unit_group_version
    and true
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'unitGroupDataSet') = 'object'
  limit 1;
  if v_unit_group_json is null
     or coalesce((private.display_capabilities_v1('unitgroup', v_unit_group_state, v_unit_group_json) ->> 'exchangesVisible')::boolean, false) is not true then
    return null;
  end if;

  v_unit_internal := v_unit_group_json #>> '{unitGroupDataSet,unitGroupInformation,quantitativeReference,referenceToReferenceUnit}';
  if v_unit_internal !~ '^(0|[1-9][0-9]{0,4})$' then
    return null;
  end if;
  select count(*), (jsonb_agg(item) -> 0)
  into v_match_count, v_unit_item
  from private.display_json_items_v1(v_unit_group_json #> '{unitGroupDataSet,units,unit}') as item
  where item ->> '@dataSetInternalID' = v_unit_internal
    and item ->> '@dataSetInternalID' ~ '^(0|[1-9][0-9]{0,4})$';
  if v_match_count <> 1 then
    return null;
  end if;
  v_unit := nullif(private.display_scalar_text_v1(v_unit_item -> 'name'), '');
  v_unit_factor := private.display_canonical_decimal_v1(v_unit_item ->> 'meanValue');
  if v_unit is null or v_unit_factor is distinct from '1' then
    return null;
  end if;

  v_classifications := private.display_classifications_v1(
    v_flow_json #> '{flowDataSet,flowInformation,dataSetInformation,classificationInformation}'
  );
  v_uncertainty_type := nullif(
    private.display_scalar_text_v1(p_exchange -> 'uncertaintyDistributionType'),
    ''
  );
  v_minimum := private.display_canonical_decimal_v1(p_exchange ->> 'minimumAmount');
  if v_minimum is null then
    v_minimum := private.display_canonical_decimal_v1(p_exchange ->> 'minimumValue');
  end if;
  v_maximum := private.display_canonical_decimal_v1(p_exchange ->> 'maximumAmount');
  if v_maximum is null then
    v_maximum := private.display_canonical_decimal_v1(p_exchange ->> 'maximumValue');
  end if;

  v_row := jsonb_build_object(
    'internalId', v_internal_id,
    'kind', v_exchange_kind,
    'direction', v_direction,
    'flow', jsonb_build_object(
      'id', v_flow_id_text,
      'version', v_flow_version,
      'name', private.display_localized_text_v1(
        v_flow_json #> '{flowDataSet,flowInformation,dataSetInformation,name,baseName}'
      )
    ),
    'classification', case when jsonb_array_length(v_classifications) > 0 then v_classifications -> 0 else null end,
    'amount', v_amount,
    'unit', v_unit,
    'isQuantitativeReference', v_internal_id = (
      p_process_json #>> '{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}'
    ),
    'uncertainty', case when v_uncertainty_type is null then null else jsonb_build_object(
      'type', v_uncertainty_type,
      'minimum', v_minimum,
      'maximum', v_maximum
    ) end,
    'origin', '[]'::jsonb
  );
  return jsonb_build_object(
    'row', v_row,
    'functionalUnit', jsonb_build_object(
      'amount', v_amount,
      'unit', v_unit,
      'description', private.display_localized_text_v1(
        p_process_json #> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther}'
      )
    )
  );
end
$_$;

ALTER FUNCTION "private"."display_exchange_support_v1"("p_process_state" integer, "p_process_json" "jsonb", "p_exchange" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_exchange_support_v1"("p_process_state" integer, "p_process_json" "jsonb", "p_exchange" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_first_text_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select item ->> 'value'
  from jsonb_array_elements(private.display_localized_text_v1(p_value)) as localized(item)
  order by case item ->> 'language' when 'en' then 0 when 'zh' then 1 else 2 end
  limit 1
$$;

ALTER FUNCTION "private"."display_first_text_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_first_text_v1"("p_value" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_flow_kind_v1"("p_type" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case lower(btrim(coalesce(p_type, '')))
    when 'elementary flow' then 'elementary'
    when 'waste flow' then 'waste'
    when 'product flow' then 'product'
    when 'other flow' then 'other'
    else 'unknown'
  end
$$;

ALTER FUNCTION "private"."display_flow_kind_v1"("p_type" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_flow_kind_v1"("p_type" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_geography_precision_v1"("p_code" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select 'unknown'::text
$$;

ALTER FUNCTION "private"."display_geography_precision_v1"("p_code" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_geography_precision_v1"("p_code" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_json_items_v1"("p_value" "jsonb") RETURNS SETOF "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select item.value
  from jsonb_array_elements(
    case jsonb_typeof(p_value)
      when 'array' then p_value
      when 'object' then jsonb_build_array(p_value)
      else '[]'::jsonb
    end
  ) as item(value)
$$;

ALTER FUNCTION "private"."display_json_items_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_json_items_v1"("p_value" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_lcia_decorate_dataset_v1"("p_envelope" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select case
    when p_envelope is null then null
    when jsonb_typeof(p_envelope) <> 'object'
      or jsonb_typeof(p_envelope -> 'key') <> 'object'
      or jsonb_typeof(p_envelope -> 'capabilities') <> 'object'
      then null
    else jsonb_set(
      jsonb_set(
        p_envelope,
        '{capabilities,lciaVisible}',
        to_jsonb(evidence.publication is not null),
        false
      ),
      '{publication}',
      coalesce(evidence.publication, 'null'::jsonb),
      false
    )
  end
  from lateral (
    select case
      when p_envelope #>> '{key,kind}' = 'process'
        and p_envelope ->> 'accessLevel' = 'open'
        then private.display_current_lcia_publication_for_process_v1(
          (p_envelope #>> '{key,id}')::uuid,
          p_envelope #>> '{key,version}'
        )
      else null
    end as publication
  ) as evidence
$$;

ALTER FUNCTION "private"."display_lcia_decorate_dataset_v1"("p_envelope" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_lcia_decorate_dataset_v1"("p_envelope" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_lcia_decorate_item_page_v1"("p_page" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select case
    when jsonb_typeof(p_page) <> 'object'
      or jsonb_typeof(p_page -> 'items') <> 'array'
      then null
    else jsonb_set(
      p_page,
      '{items}',
      coalesce((
        select jsonb_agg(
          item.value || jsonb_build_object(
            'capabilities',
            jsonb_set(
              item.value -> 'capabilities',
              '{lciaVisible}',
              to_jsonb(evidence.publication is not null),
              false
            )
          )
          order by item.ordinality
        )
        from jsonb_array_elements(p_page -> 'items')
          with ordinality as item(value, ordinality)
        cross join lateral (
          select case
            when item.value #>> '{key,kind}' = 'process'
              and item.value ->> 'accessLevel' = 'open'
              then private.display_current_lcia_publication_for_process_v1(
                (item.value #>> '{key,id}')::uuid,
                item.value #>> '{key,version}'
              )
            else null
          end as publication
        ) as evidence
      ), '[]'::jsonb),
      false
    )
  end
$$;

ALTER FUNCTION "private"."display_lcia_decorate_item_page_v1"("p_page" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_lcia_decorate_item_page_v1"("p_page" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_lcia_json_object_has_keys_v1"("p_value" "jsonb", "p_keys" "text"[]) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select jsonb_typeof(p_value) = 'object'
    and (select count(*) from jsonb_object_keys(p_value)) = cardinality(p_keys)
    and not exists (
      select 1
      from jsonb_object_keys(p_value) as key(value)
      where not (key.value = any (p_keys))
    )
$$;

ALTER FUNCTION "private"."display_lcia_json_object_has_keys_v1"("p_value" "jsonb", "p_keys" "text"[]) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_lcia_json_object_has_keys_v1"("p_value" "jsonb", "p_keys" "text"[]) FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_lcia_projection_frame_v1"(VARIADIC "p_fields" "text"[]) RETURNS "bytea"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_field text;
  v_bytes bytea;
  v_result bytea := ''::bytea;
begin
  foreach v_field in array p_fields loop
    if v_field is null then
      v_result := v_result || pg_catalog.int4send(-1);
    else
      v_bytes := pg_catalog.convert_to(v_field, 'UTF8');
      v_result := v_result
        || pg_catalog.int4send(pg_catalog.octet_length(v_bytes))
        || v_bytes;
    end if;
  end loop;
  return v_result;
end
$$;

ALTER FUNCTION "private"."display_lcia_projection_frame_v1"(VARIADIC "p_fields" "text"[]) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_lcia_projection_frame_v1"(VARIADIC "p_fields" "text"[]) FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_lcia_projection_is_public_v1"("p_projection_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from private.portal_lcia_projection_publications as binding
    join private.portal_lcia_projection_headers as projection
      on projection.id = binding.projection_id
    join private.lcia_result_publications as publication
      on publication.id = binding.lcia_result_publication_id
    join private.lcia_result_packages as package
      on package.id = binding.package_id
     and package.id = publication.package_id
    join private.worker_jobs as job
      on job.id = projection.build_worker_job_id
     and job.id = package.build_worker_job_id
    where binding.projection_id = p_projection_id
      and binding.status = 'finalized'
      and binding.revoked_at is null
      and projection.status = 'prepared'
      and projection.content_hash = binding.projection_content_hash
      and publication.is_current
      and publication.status = 'current'
      and publication.publication_series_key = 'global'
      and publication.publication_channel = 'public'
      and publication.visibility_scope = 'public'
      and publication.published_at = binding.source_published_at
      and package.status = 'preview_ready'
      and package.package_version = binding.package_version
      and package.package_result_hash = binding.package_result_hash
      and package.artifact_manifest ->> 'portalProjectionId'
            = projection.id::text
      and package.artifact_manifest ->> 'portalProjectionContentHash'
            = projection.content_hash
      and job.job_kind = 'lcia_result.package_build'
      and job.payload_schema_version = 'lcia_result.package_build.request.v3'
      and job.payload_json ->> 'portalProjectionContractVersion'
            = 'portal.lcia-projection.v1'
  )
$$;

ALTER FUNCTION "private"."display_lcia_projection_is_public_v1"("p_projection_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_lcia_projection_is_public_v1"("p_projection_id" "uuid") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_lcia_projection_sha256_fields_v1"(VARIADIC "p_fields" "text"[]) RETURNS "text"
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select pg_catalog.encode(
    extensions.digest(
      private.display_lcia_projection_frame_v1(variadic p_fields),
      'sha256'
    ),
    'hex'
  )
$$;

ALTER FUNCTION "private"."display_lcia_projection_sha256_fields_v1"(VARIADIC "p_fields" "text"[]) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_lcia_projection_sha256_fields_v1"(VARIADIC "p_fields" "text"[]) FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_localized_text_v1"("p_value" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
  with items as (
    select item.value, item.ordinality
    from jsonb_array_elements(
      case jsonb_typeof(p_value)
        when 'array' then p_value
        when 'null' then '[]'::jsonb
        else jsonb_build_array(p_value)
      end
    ) with ordinality as item(value, ordinality)
  ), normalized as (
    select
      case
        when jsonb_typeof(value) = 'object'
          and btrim(coalesce(value ->> '@xml:lang', '')) ~ '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$'
          and length(btrim(value ->> '@xml:lang')) <= 35
          then btrim(value ->> '@xml:lang')
        else 'und'
      end as language,
      case
        when jsonb_typeof(value) = 'object'
          then private.display_scalar_text_v1(value -> '#text')
        when jsonb_typeof(value) = 'string'
          then private.display_scalar_text_v1(value)
        else null
      end as text_value,
      ordinality
    from items
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object('language', language, 'value', btrim(text_value))
      order by ordinality
    ) filter (where nullif(btrim(text_value), '') is not null),
    '[]'::jsonb
  )
  from normalized
$_$;

ALTER FUNCTION "private"."display_localized_text_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_localized_text_v1"("p_value" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_named_reference_v1"("p_reference" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_reference jsonb;
  v_id text;
  v_version text;
  v_name jsonb;
begin
  v_reference := case
    when jsonb_typeof(p_reference) = 'object' then p_reference
    when jsonb_typeof(p_reference) = 'array'
      and jsonb_array_length(p_reference) = 1 then p_reference -> 0
    else null
  end;
  v_id := nullif(lower(private.display_scalar_text_v1(v_reference -> '@refObjectId')), '');
  v_version := nullif(private.display_scalar_text_v1(v_reference -> '@version'), '');
  v_name := private.display_localized_text_v1(v_reference -> 'common:shortDescription');
  if coalesce(
       v_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
       false
     ) is not true
     or coalesce(v_version ~ '^\d{2}\.\d{2}\.\d{3}$', false) is not true then
    v_id := null;
    v_version := null;
  end if;
  return jsonb_build_object('id', v_id, 'version', v_version, 'name', v_name);
end
$_$;

ALTER FUNCTION "private"."display_named_reference_v1"("p_reference" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_named_reference_v1"("p_reference" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_classification_code_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select nullif(
    pg_catalog.btrim(coalesce(
      p_value ->> '@classId',
      p_value ->> 'code',
      p_value ->> '#text'
    )),
    ''
  )
$$;

ALTER FUNCTION "private"."display_navigation_classification_code_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_classification_code_v1"("p_value" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_classification_label_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select nullif(
    pg_catalog.btrim(coalesce(
      p_value ->> '#text',
      p_value #>> '{label,0,value}'
    )),
    ''
  )
$$;

ALTER FUNCTION "private"."display_navigation_classification_label_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_classification_label_v1"("p_value" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case pg_catalog.lower(pg_catalog.btrim(coalesce(
    p_system ->> '#text',
    p_system ->> '@name',
    case when pg_catalog.jsonb_typeof(p_system) = 'string' then p_system #>> '{}' end,
    ''
  )))
    when 'isic' then array['isic']::text[]
    when 'cpc' then array['cpc']::text[]
    when 'elementary-flow' then array['elementary']::text[]
    when 'ilcd-flow-categorization' then array['elementary']::text[]
    when 'ilcd' then array['isic','cpc']::text[]
    else '{}'::text[]
  end;
$$;

ALTER FUNCTION "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_ensure_virtual_v1"("p_node_id" "text", "p_dimension" "text", "p_taxonomy" "text", "p_labels_key" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
  insert into private.portal_navigation_node_v1 (
    node_id, parent_node_id, code, taxonomy, dimension,
    source_index_path, source_file, labels, label_strategy
  ) values (
    p_node_id, null, '~', p_taxonomy, p_dimension, null, null,
    private.display_navigation_virtual_labels_v1(p_labels_key),
    pg_catalog.jsonb_build_object(
      'en', 'database-virtual-container', 'zh-CN', 'database-virtual-container',
      'de', 'database-virtual-container', 'fr', 'database-virtual-container'
    )
  )
  on conflict (node_id) do nothing
$$;

ALTER FUNCTION "private"."display_navigation_ensure_virtual_v1"("p_node_id" "text", "p_dimension" "text", "p_taxonomy" "text", "p_labels_key" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_navigation_ensure_virtual_v1"("p_node_id" "text", "p_dimension" "text", "p_taxonomy" "text", "p_labels_key" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select nullif(pg_catalog.btrim(coalesce(
    p_card #>> '{geography,code}',
    case when p_kind = 'flow' then p_card #>> '{geography,locationOfSupply}' end
  )), '')
$$;

ALTER FUNCTION "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "statement_timeout" TO '8s'
    SET "work_mem" TO '32MB'
    AS $$
declare
  v_parent jsonb;
  v_ancestors jsonb:='[]';
  v_nodes jsonb;
  v_totals jsonb;
  v_next text;
  v_result jsonb;
  v_after_code text;
  v_trimmed boolean:=false;
begin
  perform private.display_assert_navigation_contract_v1();
  if p_parent_node_id is not null and not exists (
    select 1 from private.display_read_navigation_node_v1 n
    where n.node_id=p_parent_node_id and n.dimension=p_dimension
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped')
        or exists(select 1 from private.display_navigation_membership_v1 m where m.node_id=n.node_id))
  ) then raise exception using errcode='22023',message='invalid portal request'; end if;
  if p_cursor_node_id is not null then
    select n.code into v_after_code from private.display_read_navigation_node_v1 n
    where n.node_id=p_cursor_node_id and n.dimension=p_dimension
      and n.parent_node_id is not distinct from p_parent_node_id;
    if not found then raise exception using errcode='22023',message='invalid portal request'; end if;
  end if;

  with matched as materialized (
    select * from private.display_navigation_matched_versions_v1('all',p_query,p_filters)
  ), children as materialized (
    select n.* from private.display_read_navigation_node_v1 n
    where n.dimension=p_dimension and n.parent_node_id is not distinct from p_parent_node_id
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped') or exists (
        select 1 from private.display_navigation_membership_v1 m
        where m.node_id=n.node_id and (p_kind='all' or m.dataset_kind=p_kind)
          and ((p_query='' and p_filters='{}'::jsonb)
            or (m.dataset_kind,m.id,m.version) in (select dataset_kind,id,version from matched))))
      and (p_dimension<>'classification' or p_kind='all' or n.taxonomy not in ('isic','cpc','elementary')
        or (p_kind='process' and n.taxonomy='isic') or (p_kind='flow' and n.taxonomy in ('cpc','elementary')))
      and (p_cursor_node_id is null or (n.code collate "C",n.node_id collate "C")>(v_after_code collate "C",p_cursor_node_id collate "C"))
    order by n.code collate "C",n.node_id collate "C" limit p_limit+1
  ), targets as materialized (
    select * from children
    union all
    select n.* from private.display_read_navigation_node_v1 n where n.node_id=p_parent_node_id
  ), counted as materialized (
    select m.node_id,count(*) as count,count(*) filter(where m.direct) as direct_count
    from private.display_navigation_membership_v1 m
    where m.dimension=p_dimension and (p_kind='all' or m.dataset_kind=p_kind)
      and ((p_query='' and p_filters='{}'::jsonb)
        or (m.dataset_kind,m.id,m.version) in (select dataset_kind,id,version from matched))
      and m.node_id in(select n.node_id from targets n)
    group by m.node_id
  ), decorated as materialized (
    select n.node_id,n.code,jsonb_build_object(
      'nodeId',n.node_id,'parentNodeId',n.parent_node_id,'code',n.code,'taxonomy',n.taxonomy,
      'count',coalesce(c.count,0),'directCount',coalesce(c.direct_count,0),
      'hasChildren',exists(select 1 from private.display_read_navigation_node_v1 child where child.parent_node_id=n.node_id
        and (child.source_file is not null or exists(select 1 from private.display_navigation_membership_v1 m where m.node_id=child.node_id)))
    ) as value from targets n left join counted c on c.node_id=n.node_id
  ), paged as (
    select d.*,row_number() over(order by d.code collate "C",d.node_id collate "C") as rn
    from decorated d where d.node_id is distinct from p_parent_node_id
  ) select
    coalesce((select jsonb_agg(value order by rn) from paged where rn<=p_limit),'[]'::jsonb),
    (select case when count(*)>p_limit then (array_agg(node_id order by rn))[p_limit] else null end from paged),
    (select value from decorated where node_id=p_parent_node_id),
    (case when p_query='' and p_filters='{}'::jsonb then
      (select jsonb_build_object('process',count(*) filter(where dataset_kind='process'),'flow',count(*) filter(where dataset_kind='flow'))
       from private.display_navigation_versions_v1)
     else (select jsonb_build_object('process',count(*) filter(where dataset_kind='process'),'flow',count(*) filter(where dataset_kind='flow')) from matched) end)
  into v_nodes,v_next,v_parent,v_totals;

  with recursive ancestors as (
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,1 as depth
    from private.display_read_navigation_node_v1 n
    where n.node_id=(select p.parent_node_id from private.display_read_navigation_node_v1 p where p.node_id=p_parent_node_id)
    union all
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,a.depth+1
    from ancestors a join private.display_read_navigation_node_v1 n on n.node_id=a.parent_node_id
    where a.depth<32
  ) select coalesce(jsonb_agg(jsonb_build_object('nodeId',node_id,'parentNodeId',parent_node_id,'code',code,'taxonomy',taxonomy) order by depth desc),'[]'::jsonb)
    into v_ancestors from ancestors;

  loop
    v_result:=jsonb_build_object('schemaVersion','portal.public-navigation.v1','countBasis','public_versions',
      'dimension',p_dimension,'kind',p_kind,'totals',v_totals,'parent',v_parent,'ancestors',v_ancestors,'nodes',v_nodes,
      'nextCursor',case when v_next is null then null else private.display_cursor_encode_v1(jsonb_build_object(
        'v',1,'fp',p_fingerprint,'dimension',p_dimension,'kind',p_kind,'parent',p_parent_node_id,'node',v_next)) end);
    exit when octet_length(v_result::text)<=65536;
    if jsonb_array_length(v_nodes)<=1 then
      raise exception using errcode='54000',message='Portal navigation response exceeds its byte budget';
    end if;
    v_nodes:=v_nodes-(jsonb_array_length(v_nodes)-1);
    v_next:=v_nodes->(jsonb_array_length(v_nodes)-1)->>'nodeId';
  end loop;
  return v_result;
end;
$$;

ALTER FUNCTION "private"."display_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_matched_versions_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") RETURNS TABLE("dataset_kind" "text", "id" "uuid", "version" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    SET "plan_cache_mode" TO 'force_custom_plan'
    AS $_$
declare
  v_exact uuid;
  v_pattern text;
begin
  if p_query='' then
    -- Empty/query-free navigation never detoasts public cards or raw source JSON.
    return query select v.dataset_kind,v.id,v.version
    from private.display_navigation_versions_v1 v
    where (p_kind='all' or v.dataset_kind=p_kind) and
      (not (p_filters ? 'accessLevel') or v.access_level=p_filters->>'accessLevel')
      and (not (p_filters ? 'geography') or v.geography_code=p_filters->>'geography')
      and (not (p_filters ? 'classification') or v.classification_codes @> array[p_filters->>'classification'])
      and (not (p_filters ? 'referenceYearFrom') or v.reference_year >= (p_filters->>'referenceYearFrom')::integer)
      and (not (p_filters ? 'referenceYearTo') or v.reference_year <= (p_filters->>'referenceYearTo')::integer)
      and (not (p_filters ? 'processSubtype') or v.process_subtype=p_filters->>'processSubtype')
      and (not (p_filters ? 'source') or v.source=p_filters->>'source')
      and (
        not (p_filters ? 'classificationNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='classification'
            and m.node_id=p_filters->>'classificationNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'classificationScope','subtree')<>'direct' or m.direct)
        )
      ) and (
        not (p_filters ? 'geographyNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='geography'
            and m.node_id=p_filters->>'geographyNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'geographyScope','subtree')<>'direct' or m.direct)
        )
      )
;
  else
    if p_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_exact:=p_query::uuid; end if;
    v_pattern := '%' || replace(replace(replace(p_query,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_') || '%';
    -- Reuse the exact UUID/CAS/literal/one-character candidate contract of V2.
    return query select v.dataset_kind,v.id,v.version
    from private.display_catalog_facet_candidate_rows_v2(p_kind,p_query,v_exact,v_pattern) c
    join private.display_navigation_versions_v1 v
      on (v.dataset_kind,v.id,v.version)=(c.dataset_kind,c.id,c.version)
    where
      (not (p_filters ? 'accessLevel') or v.access_level=p_filters->>'accessLevel')
      and (not (p_filters ? 'geography') or v.geography_code=p_filters->>'geography')
      and (not (p_filters ? 'classification') or v.classification_codes @> array[p_filters->>'classification'])
      and (not (p_filters ? 'referenceYearFrom') or v.reference_year >= (p_filters->>'referenceYearFrom')::integer)
      and (not (p_filters ? 'referenceYearTo') or v.reference_year <= (p_filters->>'referenceYearTo')::integer)
      and (not (p_filters ? 'processSubtype') or v.process_subtype=p_filters->>'processSubtype')
      and (not (p_filters ? 'source') or v.source=p_filters->>'source')
      and (
        not (p_filters ? 'classificationNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='classification'
            and m.node_id=p_filters->>'classificationNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'classificationScope','subtree')<>'direct' or m.direct)
        )
      ) and (
        not (p_filters ? 'geographyNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='geography'
            and m.node_id=p_filters->>'geographyNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'geographyScope','subtree')<>'direct' or m.direct)
        )
      )
;
  end if;
end;
$_$;

ALTER FUNCTION "private"."display_navigation_matched_versions_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_matched_versions_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select p_scope || ':~' || pg_catalog.substr(
    pg_catalog.encode(
      extensions.digest(
        pg_catalog.convert_to(p_scope || '|' || pg_catalog.upper(pg_catalog.btrim(p_code)), 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    1,
    16
  )
$$;

ALTER FUNCTION "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_raw_taxonomy_v1"("p_system" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case pg_catalog.lower(pg_catalog.btrim(coalesce(
    p_system ->> '#text',
    p_system ->> '@name',
    case when pg_catalog.jsonb_typeof(p_system) = 'string' then p_system #>> '{}' end,
    ''
  )))
    when 'isic' then 'isic'
    when 'cpc' then 'cpc'
    when 'elementary-flow' then 'elementary'
    when 'ilcd-flow-categorization' then 'elementary'
    else 'unclassified'
  end;
$$;

ALTER FUNCTION "private"."display_navigation_raw_taxonomy_v1"("p_system" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_raw_taxonomy_v1"("p_system" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_resolve_alias_v1"("p_dimension" "text", "p_code" "text") RETURNS "text"
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case when count(*)=1 then min(n.node_id) else null end
  from private.display_read_navigation_node_v1 n
  where n.dimension=p_dimension and cardinality(n.alias_codes)>0
    and n.alias_codes @> array[upper(btrim(p_code))]
$$;

ALTER FUNCTION "private"."display_navigation_resolve_alias_v1"("p_dimension" "text", "p_code" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_resolve_alias_v1"("p_dimension" "text", "p_code" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_resolve_classification_v1"("p_kind" "text", "p_system" "jsonb", "p_value" "jsonb", "p_level" integer DEFAULT NULL::integer) RETURNS "text"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_taxonomies text[];
  v_code text;
  v_label text;
  v_depth integer;
  v_node text;
  v_hits integer;
begin
  select coalesce(array_agg(taxonomy), '{}'::text[]) into v_taxonomies
  from unnest(private.display_navigation_classification_taxonomy_v1(p_system)) taxonomy
  where (p_kind='process' and taxonomy='isic') or (p_kind='flow' and taxonomy in ('cpc','elementary'));
  v_code := private.display_navigation_classification_code_v1(p_value);
  v_label := private.display_navigation_classification_label_v1(p_value);
  v_depth := coalesce(
    p_level,
    case
      when pg_catalog.jsonb_typeof(p_value -> '@level') = 'string'
        and (p_value ->> '@level') ~ '^[0-9]{1,2}$'
        then (p_value ->> '@level')::integer
      else null
    end
  );

  if v_code is null then
    return null;
  end if;

  select pg_catalog.count(*)::integer, pg_catalog.min(node.node_id)
  into v_hits, v_node
  from private.display_read_navigation_node_v1 as node
  where node.dimension = 'classification'
    and node.taxonomy = any (v_taxonomies)
    and node.taxonomy <> 'database-virtual'
    and node.source_file is not null
    and pg_catalog.lower(node.code) = pg_catalog.lower(v_code);

  -- Two applicable taxonomies can share a spelling (ISIC and CPC share 337
  -- codes), so an ambiguous hit is never guessed.
  if v_hits = 1 then return v_node; end if;
  -- Some authored elementary categories contain a name instead of an id. Only
  -- a unique source label is admissible; array position is never a tree depth.
  if v_hits=0 and v_taxonomies = array['elementary']::text[] then
    select count(*), min(node.node_id) into v_hits,v_node
    from private.display_read_navigation_node_v1 node
    where node.taxonomy='elementary' and exists (
      select 1 from jsonb_each_text(node.labels) label
      where lower(label.value)=lower(v_code)
    );
    if v_hits=1 then return v_node; end if;
  end if;
  return null;
end;
$_$;

ALTER FUNCTION "private"."display_navigation_resolve_classification_v1"("p_kind" "text", "p_system" "jsonb", "p_value" "jsonb", "p_level" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_resolve_classification_v1"("p_kind" "text", "p_system" "jsonb", "p_value" "jsonb", "p_level" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_query text:=lower(btrim(coalesce(p_query,'')));
  v_filters jsonb;
  v_limit integer:=coalesce(p_limit,100);
  v_fingerprint text;
  v_cursor jsonb;
  v_cursor_node text;
begin
  if p_dimension is null or p_dimension not in ('classification','geography')
    or v_limit<1 or v_limit>500 then
    raise exception using errcode='22023',message='invalid portal request';
  end if;
  perform private.display_validate_search_v3(p_kind,coalesce(p_query,''),coalesce(p_filters,'{}'::jsonb),'relevance',1);
  v_filters:=private.display_normalize_filters_v1(p_filters);
  v_fingerprint:=encode(extensions.digest(convert_to(
    'portal-navigation-v1:' || (select asset_sha256 from private.display_read_navigation_contract_v1 where contract_version=1) || ':' ||
    private.display_query_fingerprint_v1(p_kind,v_query,v_filters,p_dimension || ':' || coalesce(p_parent_node_id,'')),
    'UTF8'),'sha256'),'hex');
  if p_cursor is not null then
    v_cursor:=private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null or jsonb_typeof(v_cursor)<>'object'
      or (select count(*) from jsonb_object_keys(v_cursor))<>6
      or v_cursor->>'v' is distinct from '1' or v_cursor->>'fp' is distinct from v_fingerprint
      or v_cursor->>'kind' is distinct from p_kind or v_cursor->>'dimension' is distinct from p_dimension
      or v_cursor->>'parent' is distinct from p_parent_node_id
      or coalesce(v_cursor->>'node','') !~ '^[a-z][a-z0-9-]*:[!-~]{1,96}$'
    then raise exception using errcode='22023',message='invalid portal request'; end if;
    v_cursor_node:=v_cursor->>'node';
  end if;
  return private.display_navigation_impl_v1(p_kind,v_query,v_filters,p_dimension,p_parent_node_id,v_cursor_node,v_limit,v_fingerprint);
end;
$_$;

ALTER FUNCTION "private"."display_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_version_matches_v3"("p_kind" "text", "p_filters" "jsonb", "p_id" "uuid", "p_version" "text") RETURNS boolean
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select
    (
      not (p_filters ? 'classificationNodeId')
      or exists (
        select 1
        from private.display_navigation_membership_v1 as member
        where member.dataset_kind = p_kind
          and member.id = p_id
          and member.version = p_version
          and member.dimension = 'classification'
          and (
            case coalesce(p_filters ->> 'classificationScope', 'subtree')
              when 'direct' then
                member.node_id = p_filters ->> 'classificationNodeId'
                and member.direct
              else member.node_id = p_filters ->> 'classificationNodeId'
            end
          )
      )
    )
    and (
      not (p_filters ? 'geographyNodeId')
      or exists (
        select 1
        from private.display_navigation_membership_v1 as member
        where member.dataset_kind = p_kind
          and member.id = p_id
          and member.version = p_version
          and member.dimension = 'geography'
          and (
            case coalesce(p_filters ->> 'geographyScope', 'subtree')
              when 'direct' then
                member.node_id = p_filters ->> 'geographyNodeId'
                and member.direct
              else member.node_id = p_filters ->> 'geographyNodeId'
            end
          )
      )
    )
$$;

ALTER FUNCTION "private"."display_navigation_version_matches_v3"("p_kind" "text", "p_filters" "jsonb", "p_id" "uuid", "p_version" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_version_matches_v3"("p_kind" "text", "p_filters" "jsonb", "p_id" "uuid", "p_version" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_navigation_virtual_labels_v1"("p_key" "text") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case p_key
    when 'unclassified' then pg_catalog.jsonb_build_object(
      'en', 'Unclassified', 'zh-CN', '未分类', 'de', 'Nicht klassifiziert', 'fr', 'Non classé'
    )
    else pg_catalog.jsonb_build_object(
      'en', 'Unmapped locations', 'zh-CN', '未映射地区',
      'de', 'Nicht zugeordnete Standorte', 'fr', 'Localisations non mappées'
    )
  end;
$$;

ALTER FUNCTION "private"."display_navigation_virtual_labels_v1"("p_key" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_virtual_labels_v1"("p_key" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_normalize_filters_v1"("p_filters" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select coalesce(
    jsonb_object_agg(
      filter.key,
      case
        when filter.key in (
          'accessLevel', 'geography', 'classification', 'processSubtype', 'source'
        ) and jsonb_typeof(filter.value) = 'string'
          then to_jsonb(lower(btrim(filter.value #>> '{}')))
        else filter.value
      end
      order by filter.key
    ),
    '{}'::jsonb
  )
  from jsonb_each(coalesce(p_filters, '{}'::jsonb)) as filter(key, value)
$$;

ALTER FUNCTION "private"."display_normalize_filters_v1"("p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_normalize_filters_v1"("p_filters" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_process_functional_unit_v1"("p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
declare
  v_reference_internal text := p_json #>> '{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}';
  v_exchange jsonb;
  v_support jsonb;
  v_match_count integer;
begin
  select count(*), jsonb_agg(item) -> 0
  into v_match_count, v_exchange
  from private.display_json_items_v1(p_json #> '{processDataSet,exchanges,exchange}') as item
  where item ->> '@dataSetInternalID' = v_reference_internal;
  if v_match_count <> 1 then
    return jsonb_build_object(
      'amount', null,
      'unit', null,
      'description', private.display_localized_text_v1(
        p_json #> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther}'
      )
    );
  end if;
  v_support := private.display_exchange_support_v1(p_state_code, p_json, v_exchange);
  return coalesce(
    v_support -> 'functionalUnit',
    jsonb_build_object(
      'amount', null,
      'unit', null,
      'description', private.display_localized_text_v1(
        p_json #> '{processDataSet,processInformation,quantitativeReference,functionalUnitOrOther}'
      )
    )
  );
end
$$;

ALTER FUNCTION "private"."display_process_functional_unit_v1"("p_state_code" integer, "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_process_functional_unit_v1"("p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_process_names_v1"("p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  with parts as (
    select part.ordinality as part_order, item.ordinality as item_order,
      item.value ->> 'language' as language,
      pg_catalog.lower(item.value ->> 'language') as language_key,
      item.value ->> 'value' as value
    from pg_catalog.unnest(array[
      'baseName', 'treatmentStandardsRoutes', 'mixAndLocationTypes',
      'functionalUnitFlowProperties'
    ]) with ordinality as part(field, ordinality)
    cross join lateral pg_catalog.jsonb_array_elements(
      private.display_localized_text_v1(
        p_json #> array['processDataSet','processInformation','dataSetInformation','name',part.field]
      )
    ) with ordinality as item(value, ordinality)
  ), first_values as (
    select distinct on (part_order, language_key) * from parts
    order by part_order, language_key, item_order
  ), names as (
    select base.language, base.item_order,
      pg_catalog.string_agg(part.value, '; ' order by part.part_order) as value
    from first_values as base
    join first_values as part on part.language_key = base.language_key
    where base.part_order = 1
    group by base.language, base.item_order
  )
  select coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object('language', language, 'value', value)
    order by item_order
  ), '[]'::jsonb) from names
$$;

ALTER FUNCTION "private"."display_process_names_v1"("p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_process_names_v1"("p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_process_open_capability_bridge_v1"("p_state_code" integer, "p_json" "jsonb") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce((
    private.display_capabilities_v1('process', p_state_code, p_json)
      ->> 'exchangesVisible'
  )::boolean, false)
$$;

ALTER FUNCTION "private"."display_process_open_capability_bridge_v1"("p_state_code" integer, "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_process_open_capability_bridge_v1"("p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_process_rank_classification_keys_v1"("p_card" "jsonb") RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select coalesce(
    pg_catalog.array_agg(
      distinct normalized.value order by normalized.value
    ),
    '{}'::text[]
  )
  from pg_catalog.jsonb_array_elements(
    case when pg_catalog.jsonb_typeof(p_card -> 'classifications') = 'array'
      then p_card -> 'classifications' else '[]'::jsonb end
  ) as item(value)
  cross join lateral (
    select pg_catalog.lower(
      pg_catalog.btrim(item.value ->> 'code')
    ) as value
  ) as normalized
  where nullif(normalized.value, '') is not null
$$;

ALTER FUNCTION "private"."display_process_rank_classification_keys_v1"("p_card" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_process_rank_classification_keys_v1"("p_card" "jsonb") FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_process_rank_name_keys_v1"("p_card" "jsonb") RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select coalesce(
    pg_catalog.array_agg(
      distinct normalized.value order by normalized.value
    ),
    '{}'::text[]
  )
  from pg_catalog.jsonb_array_elements(
    case when pg_catalog.jsonb_typeof(p_card -> 'names') = 'array'
      then p_card -> 'names' else '[]'::jsonb end
  ) as item(value)
  cross join lateral (
    select pg_catalog.lower(
      pg_catalog.btrim(item.value ->> 'value')
    ) as value
  ) as normalized
  where nullif(normalized.value, '') is not null
$$;

ALTER FUNCTION "private"."display_process_rank_name_keys_v1"("p_card" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_process_rank_name_keys_v1"("p_card" "jsonb") FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_process_reference_product_v1"("p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_reference_internal text := p_json #>> '{processDataSet,processInformation,quantitativeReference,referenceToReferenceFlow}';
  v_exchange jsonb;
  v_reference jsonb;
  v_id_text text;
  v_version text;
  v_id uuid;
  v_flow_json jsonb;
  v_match_count integer;
begin
  select count(*), jsonb_agg(item) -> 0
  into v_match_count, v_exchange
  from private.display_json_items_v1(p_json #> '{processDataSet,exchanges,exchange}') as item
  where item ->> '@dataSetInternalID' = v_reference_internal;
  if v_match_count <> 1 then
    return '[]'::jsonb;
  end if;
  v_reference := v_exchange -> 'referenceToFlowDataSet';
  v_id_text := lower(btrim(coalesce(v_reference ->> '@refObjectId', '')));
  v_version := btrim(coalesce(v_reference ->> '@version', ''));
  if v_id_text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and v_version ~ '^\d{2}\.\d{2}\.\d{3}$' then
    v_id := v_id_text::uuid;
    select row.json
    into v_flow_json
    from public.flows as row
    where row.id = v_id
      and row.version::text = v_version
      and true
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'flowDataSet') = 'object'
    limit 1;
  end if;
  return coalesce(
    private.display_localized_text_v1(
      v_flow_json #> '{flowDataSet,flowInformation,dataSetInformation,name,baseName}'
    ),
    '[]'::jsonb
  );
end
$_$;

ALTER FUNCTION "private"."display_process_reference_product_v1"("p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_process_reference_product_v1"("p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_projection_hybrid_candidates_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") RETURNS TABLE("id" "uuid", "version" "text", "lexical_rank" integer, "semantic_rank" integer, "semantic_distance" double precision, "score" numeric)
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
  with lexical_counts as materialized (
    select match.id, match.version, pg_catalog.count(distinct match.term_ordinal)::integer as hit_count
    from private.display_catalog_hybrid_pattern_matches_v1(p_kind,p_query_terms) as match
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = p_kind and projection.id = match.id
        and projection.version = match.version
    where true
      and (p_filters = '{}'::jsonb or private.display_card_matches_filters_v2(projection.card,p_filters))
    group by match.id, match.version
  ), lexical_candidates as materialized (
    select * from lexical_counts
    where hit_count > 0
    order by hit_count desc, id, version desc
    limit 200
  ), lexical as materialized (
    select candidate.*,
      pg_catalog.row_number() over(order by hit_count desc,id,version desc)::integer as ordinal
    from lexical_candidates as candidate
  ), semantic as materialized (
    select candidate.*,
      pg_catalog.row_number() over(order by semantic_distance,id,version desc)::integer as ordinal
    from private.display_projection_semantic_candidates_v2(p_kind,p_query_embedding,p_filters) as candidate
  )
  select coalesce(lexical.id,semantic.id), coalesce(lexical.version,semantic.version),
    lexical.ordinal, semantic.ordinal, semantic.semantic_distance,
    pg_catalog.round(least(1::numeric,greatest(0::numeric,(
      coalesce(0.5::numeric / (60 + lexical.ordinal),0::numeric)
      + coalesce(0.5::numeric / (60 + semantic.ordinal),0::numeric)
    ) * 61::numeric)),12)
  from lexical full outer join semantic
    on semantic.id = lexical.id and semantic.version = lexical.version;
$$;

ALTER FUNCTION "private"."display_projection_hybrid_candidates_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_hybrid_candidates_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_projection_hybrid_search_v1_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "hnsw.iterative_scan" TO 'strict_order'
    SET "row_security" TO 'on'
    AS $$
declare
  v_items jsonb;
  v_result jsonb;
begin
  perform private.display_assert_catalog_projection_contract_cn1();

  with portal_lexical_matches as materialized (
    select match.id,
      match.version,
      match.term_ordinal
    from private.display_catalog_hybrid_pattern_matches_v1(
      p_kind,
      p_query_terms
    ) as match
  ), portal_latest_keys as materialized (
    select distinct on (projection.id)
      projection.id,
      projection.version
    from private.display_catalog_search_current_v2 as projection
    where projection.dataset_kind = p_kind
    order by projection.id,
      projection.version desc,
      projection.modified_at desc,
      projection.state_code desc
  ), portal_lexical_counts as materialized (
    select portal_lexical_matches.id,
      portal_lexical_matches.version,
      pg_catalog.count(distinct portal_lexical_matches.term_ordinal)::integer
        as lexical_hit_count
    from portal_lexical_matches
    join portal_latest_keys
      on portal_latest_keys.id = portal_lexical_matches.id
     and portal_latest_keys.version = portal_lexical_matches.version
    group by portal_lexical_matches.id,
      portal_lexical_matches.version
  ), portal_lexical_candidates as materialized (
    select portal_lexical_counts.*
    from portal_lexical_counts
    where portal_lexical_counts.lexical_hit_count > 0
    order by portal_lexical_counts.lexical_hit_count desc,
      portal_lexical_counts.id asc,
      portal_lexical_counts.version desc
    limit 200
  ), portal_lexical_ranked as materialized (
    select portal_lexical_candidates.*,
      pg_catalog.row_number() over (
        order by portal_lexical_candidates.lexical_hit_count desc,
          portal_lexical_candidates.id asc,
          portal_lexical_candidates.version desc
      )::integer as lexical_rank
    from portal_lexical_candidates
  ), portal_semantic_candidates as materialized (
    select semantic.*
    from private.display_projection_semantic_candidates_v1(
      p_kind,
      p_query_embedding
    ) as semantic
  ), portal_semantic_ranked as materialized (
    select portal_semantic_candidates.*,
      pg_catalog.row_number() over (
        order by portal_semantic_candidates.semantic_distance asc,
          portal_semantic_candidates.id asc,
          portal_semantic_candidates.version desc
      )::integer as semantic_rank
    from portal_semantic_candidates
  ), portal_fused as materialized (
    select
      coalesce(portal_lexical_ranked.id, portal_semantic_ranked.id) as id,
      coalesce(portal_lexical_ranked.version, portal_semantic_ranked.version)
        as version,
      portal_lexical_ranked.lexical_rank,
      portal_semantic_ranked.semantic_rank,
      portal_semantic_ranked.semantic_distance,
      pg_catalog.round(
        least(
          1::numeric,
          greatest(
            0::numeric,
            (
              coalesce(
                0.5::numeric / (60 + portal_lexical_ranked.lexical_rank),
                0::numeric
              )
              + coalesce(
                0.5::numeric / (60 + portal_semantic_ranked.semantic_rank),
                0::numeric
              )
            ) * 61::numeric
          )
        ),
        12
      ) as normalized_score
    from portal_lexical_ranked
    full outer join portal_semantic_ranked
      on portal_semantic_ranked.id = portal_lexical_ranked.id
     and portal_semantic_ranked.version = portal_lexical_ranked.version
  ), portal_fused_decorated as materialized (
    select portal_fused.*,
      projection.card,
      projection.state_code,
      projection.modified_at
    from portal_fused
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = p_kind
     and projection.id = portal_fused.id
     and projection.version = portal_fused.version
  ), portal_filtered as materialized (
    select portal_fused_decorated.*
    from portal_fused_decorated
    where (
        not (p_filters ? 'accessLevel')
        or portal_fused_decorated.card ->> 'accessLevel'
          = p_filters ->> 'accessLevel'
      )
      and (
        not (p_filters ? 'geography')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_fused_decorated.card #>> '{geography,code}',
          ''
        ))) = p_filters ->> 'geography'
      )
      and (
        not (p_filters ? 'classification')
        or exists (
          select 1
          from pg_catalog.jsonb_array_elements(coalesce(
            portal_fused_decorated.card -> 'classifications',
            '[]'::jsonb
          )) as classification(item)
          where pg_catalog.lower(pg_catalog.btrim(classification.item ->> 'code'))
            = p_filters ->> 'classification'
        )
      )
      and (
        not (p_filters ? 'referenceYearFrom')
        or (portal_fused_decorated.card ->> 'referenceYear')::integer
          >= (p_filters ->> 'referenceYearFrom')::integer
      )
      and (
        not (p_filters ? 'referenceYearTo')
        or (portal_fused_decorated.card ->> 'referenceYear')::integer
          <= (p_filters ->> 'referenceYearTo')::integer
      )
      and (
        not (p_filters ? 'processSubtype')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_fused_decorated.card ->> 'processSubtype',
          ''
        ))) = p_filters ->> 'processSubtype'
      )
      and (
        not (p_filters ? 'source')
        or pg_catalog.lower(pg_catalog.btrim(coalesce(
          portal_fused_decorated.card ->> 'source',
          ''
        ))) = p_filters ->> 'source'
      )
  ), portal_ordered as materialized (
    select portal_filtered.*
    from portal_filtered
    order by portal_filtered.normalized_score desc,
      portal_filtered.id asc,
      portal_filtered.version desc
    limit p_limit
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'key', pg_catalog.jsonb_build_object(
          'kind', p_kind,
          'id', portal_ordered.id::text,
          'version', portal_ordered.version
        ),
        'accessLevel', portal_ordered.card -> 'accessLevel',
        'capabilities', portal_ordered.card -> 'capabilities',
        'names', portal_ordered.card -> 'names',
        'summary', portal_ordered.card -> 'summary',
        'geography', portal_ordered.card -> 'geography',
        'referenceYear', portal_ordered.card -> 'referenceYear',
        'modifiedAt', pg_catalog.to_char(
          portal_ordered.modified_at at time zone 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
        ),
        'match', pg_catalog.jsonb_build_object(
          'kind', 'hybrid',
          'algorithmVersion', 'portal-hybrid-rank-v1',
          'score', portal_ordered.normalized_score,
          'reasonCodes', pg_catalog.to_jsonb(pg_catalog.array_remove(array[
            case when portal_ordered.lexical_rank is not null
              then 'lexical_public_projection'::text end,
            case when portal_ordered.semantic_rank is not null
              then 'semantic_public_projection'::text end
          ], null)),
          'evidence', pg_catalog.jsonb_build_object(
            'lexicalRank', portal_ordered.lexical_rank,
            'semanticRank', portal_ordered.semantic_rank,
            'semanticDistance', case
              when portal_ordered.semantic_distance is null then null
              else pg_catalog.trim_scale(
                portal_ordered.semantic_distance::numeric
              )::text
            end
          )
        )
      )
      order by portal_ordered.normalized_score desc,
        portal_ordered.id asc,
        portal_ordered.version desc
    ),
    '[]'::jsonb
  )
  into v_items
  from portal_ordered;

  v_result := pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-hybrid-candidate-page.v1',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'items', v_items
  );
  if pg_catalog.octet_length(
    pg_catalog.convert_to(v_result::text, 'UTF8')
  ) > 524288 then
    raise exception using
      errcode = '54000',
      message = 'portal hybrid response too large';
  end if;
  return v_result;
end
$$;

ALTER FUNCTION "private"."display_projection_hybrid_search_v1_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_hybrid_search_v1_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text") FROM PUBLIC;

REVOKE ALL ON FUNCTION "private"."display_projection_hybrid_search_v1_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text") FROM "api_internal_executor";



CREATE OR REPLACE FUNCTION "private"."display_projection_hybrid_search_v2_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text", "p_cursor" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
declare
  v_items jsonb;
  v_next jsonb;
  v_count integer;
  v_dataset_count integer;
  v_groups jsonb;
begin
  perform private.display_assert_catalog_projection_contract_cn1();
  with candidates as materialized (
    select candidate.*
    from private.display_projection_hybrid_candidates_v2(
      p_kind,p_query_terms,p_query_embedding,p_filters) as candidate
  ), eligible as materialized (
    -- Recheck the exact public key before hydration; never substitute a newer version.
    select candidate.*, projection.card, projection.modified_at,
      pg_catalog.jsonb_build_object(
        'kind','hybrid','algorithmVersion','portal-hybrid-rank-v2','score',candidate.score,
        'reasonCodes',pg_catalog.to_jsonb(pg_catalog.array_remove(array[
          case when candidate.lexical_rank is not null then 'lexical_public_projection'::text end,
          case when candidate.semantic_rank is not null then 'semantic_public_projection'::text end
        ],null)),
        'evidence',pg_catalog.jsonb_build_object(
          'lexicalRank',candidate.lexical_rank,'semanticRank',candidate.semantic_rank,
          'semanticDistance',case when candidate.semantic_distance is null then null
            else pg_catalog.trim_scale(candidate.semantic_distance::numeric)::text end
        )
      ) as match_data
    from candidates as candidate
    join private.display_catalog_search_current_v2 as projection
      on projection.dataset_kind = p_kind and projection.id = candidate.id
        and projection.version = candidate.version
    where true
      and (p_filters = '{}'::jsonb or private.display_card_matches_filters_v2(projection.card,p_filters))
  ), representative as materialized (
    -- Rank a dataset by its BEST matching version, never the number of versions.
    -- Group before pagination, so one version-rich dataset cannot consume a page.
    select distinct on (candidate.id) candidate.* from eligible as candidate
    order by candidate.id,candidate.score desc,candidate.version desc
  ), after_cursor as materialized (
    select * from representative as candidate
    where p_cursor is null
      or candidate.score < (p_cursor ->> 'rankKey')::numeric
      or (candidate.score = (p_cursor ->> 'rankKey')::numeric and (
        candidate.id > (p_cursor ->> 'id')::uuid
        or (candidate.id = (p_cursor ->> 'id')::uuid and candidate.version < (p_cursor ->> 'version'))
      ))
  ), page as materialized (
    select candidate.*,
      pg_catalog.row_number() over(order by score desc,id,version desc) as ordinal
    from after_cursor as candidate
    order by score desc,id,version desc
    limit p_limit + 1
  )
  select
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'key', pg_catalog.jsonb_build_object('kind',p_kind,'id',page.id::text,'version',page.version),
      'accessLevel',page.card -> 'accessLevel',
      'capabilities',page.card -> 'capabilities',
      'names',page.card -> 'names',
      'summary',page.card -> 'summary',
      'geography',page.card -> 'geography',
      'referenceYear',page.card -> 'referenceYear',
      'modifiedAt',pg_catalog.to_char(page.modified_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'match',page.match_data
    ) order by page.ordinal) filter(where page.ordinal <= p_limit),'[]'::jsonb),
    case when max(page.ordinal) > p_limit then (
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'v',1,'fp',p_query_fingerprint,'rankKey',page.score::text,
        'kind',p_kind,'id',page.id::text,'version',page.version
      ) order by page.ordinal) filter(where page.ordinal = p_limit)
    ) -> 0 else null end,
    (select count(*)::integer from eligible),
    (select count(*)::integer from representative),
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'key',pg_catalog.jsonb_build_object('kind',p_kind,'id',page.id::text,'version',page.version),
      'matches',(
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'key',pg_catalog.jsonb_build_object('kind',p_kind,'id',member.id::text,'version',member.version),
          'match',member.match_data
        ) order by member.score desc,member.version desc)
        from eligible as member where member.id=page.id
      )
    ) order by page.ordinal) filter(where page.ordinal<=p_limit),'[]'::jsonb)
  into v_items,v_next,v_count,v_dataset_count,v_groups from page;

  -- The immutable context decorator accepts only the v1 internal envelope.
  -- Adapt that envelope here; the new API relabels ONLY after exact-key context/LCIA decoration.
  return pg_catalog.jsonb_build_object(
    'schemaVersion','portal.public-hybrid-candidate-page.v1',
    'kind',p_kind,'queryFingerprint',p_query_fingerprint,
    'items',v_items,'candidateCount',v_count,'datasetCount',v_dataset_count,
    'versionGroups',v_groups,'nextCursorPayload',v_next
  );
end;
$$;

ALTER FUNCTION "private"."display_projection_hybrid_search_v2_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text", "p_cursor" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_hybrid_search_v2_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text", "p_cursor" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "row_security" TO 'on'
    AS $$
begin
  if p_kind = 'process' then
    return query
    select candidate.*
    from private.display_projection_semantic_process_v1(
      p_query_embedding
    ) as candidate;
  elsif p_kind = 'flow' then
    return query
    select candidate.*
    from private.display_projection_semantic_flow_v1(
      p_query_embedding
    ) as candidate;
  end if;
end
$$;

ALTER FUNCTION "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "row_security" TO 'on'
    AS $$
begin
  if p_kind = 'process' then
    return query select * from private.display_projection_semantic_process_v2(p_query_embedding,p_filters);
  elsif p_kind = 'flow' then
    return query select * from private.display_projection_semantic_flow_v2(p_query_embedding,p_filters);
  else
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
end;
$$;

ALTER FUNCTION "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_flow_exact_v1"("p_query_embedding" "extensions"."vector") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "work_mem" TO '32MB'
    SET "enable_hashjoin" TO 'on'
    SET "enable_nestloop" TO 'off'
    SET "enable_mergejoin" TO 'off'
    SET "enable_sort" TO 'on'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
  with latest_keys as materialized (
    select distinct on (projection.id)
      projection.id,
      projection.version
    from private.display_catalog_search_rows_v1 as projection
    where projection.dataset_kind = 'flow'
    order by projection.id,
      projection.version desc,
      projection.modified_at desc,
      projection.state_code desc
  ), eligible as materialized (
    select flow.id,
      flow.version::text as version,
      flow.embedding_ft operator(extensions.<=>) p_query_embedding
        as semantic_distance
    from public.flows as flow
    join latest_keys as latest
      on latest.id = flow.id
     and flow.version = latest.version::character(9)
    where private.portal_display_request_visible_v1('flow',flow.id,flow.version::text)
      and flow.embedding_ft is not null
  )
  select eligible.id,
    eligible.version,
    eligible.semantic_distance
  from eligible
  where eligible.semantic_distance is not null
    and eligible.semantic_distance >= 0::double precision
    and eligible.semantic_distance <= 0.5::double precision
  order by eligible.semantic_distance,
    eligible.id,
    eligible.version desc
  limit 200
$$;

ALTER FUNCTION "private"."display_projection_semantic_flow_exact_v1"("p_query_embedding" "extensions"."vector") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_flow_exact_v1"("p_query_embedding" "extensions"."vector") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_flow_v1"("p_query_embedding" "extensions"."vector") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "hnsw.iterative_scan" TO 'relaxed_order'
    SET "hnsw.ef_search" TO '1000'
    SET "hnsw.max_scan_tuples" TO '200000'
    SET "hnsw.scan_mem_multiplier" TO '4'
    SET "enable_sort" TO 'off'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_ids uuid[];
  v_versions text[];
  v_distances double precision[];
  v_source_ids uuid[];
  v_source_versions text[];
  v_source_distances double precision[];
  v_source_rows integer;
begin
  if p_query_embedding is null then
    raise exception using
      errcode = '22023',
      message = 'invalid portal semantic query';
  end if;

  select pg_catalog.array_agg(
      candidate.id
      order by candidate.semantic_distance, candidate.id, candidate.version desc
    ),
    pg_catalog.array_agg(
      candidate.version
      order by candidate.semantic_distance, candidate.id, candidate.version desc
    ),
    pg_catalog.array_agg(
      candidate.semantic_distance
      order by candidate.semantic_distance, candidate.id, candidate.version desc
    )
  into v_ids, v_versions, v_distances
  from (
    select approximate.id,
      approximate.version,
      approximate.semantic_distance
    from (
      select flow.id,
        flow.version::text as version,
        flow.embedding_ft operator(extensions.<=>) p_query_embedding
          as semantic_distance
      from public.flows as flow
      where private.portal_display_request_visible_v1('flow',flow.id,flow.version::text)
        and flow.embedding_ft is not null
        and exists (
          select 1
          from private.display_catalog_search_rows_v1 as projection
          where projection.dataset_kind = 'flow'
            and projection.id = flow.id
            and projection.version = flow.version::text
            and not exists (
              select 1
              from private.display_catalog_search_rows_v1 as newer
              where newer.dataset_kind = projection.dataset_kind
                and newer.id = projection.id
                and (
                  newer.version > projection.version
                  or (
                    newer.version = projection.version
                    and newer.modified_at > projection.modified_at
                  )
                  or (
                    newer.version = projection.version
                    and newer.modified_at = projection.modified_at
                    and newer.state_code > projection.state_code
                  )
                )
            )
        )
      order by flow.embedding_ft
        operator(extensions.<=>) p_query_embedding
      limit 5000
    ) as approximate
    where approximate.semantic_distance is not null
      and approximate.semantic_distance >= 0::double precision
    order by approximate.semantic_distance + 0::double precision,
      approximate.id,
      approximate.version desc
    limit 200
  ) as candidate;

  if coalesce(pg_catalog.cardinality(v_ids), 0) >= 200 then
    return query
    select v_ids[candidate.ordinal],
      v_versions[candidate.ordinal],
      v_distances[candidate.ordinal]
    from pg_catalog.generate_subscripts(v_ids, 1)
      as candidate(ordinal)
    where v_distances[candidate.ordinal] <= 0.5::double precision
    order by candidate.ordinal;
    return;
  end if;

  select pg_catalog.array_agg(
      bounded_source.id order by bounded_source.id, bounded_source.version desc
    ),
    pg_catalog.array_agg(
      bounded_source.version
      order by bounded_source.id, bounded_source.version desc
    ),
    pg_catalog.array_agg(
      bounded_source.semantic_distance
      order by bounded_source.id, bounded_source.version desc
    )
  into v_source_ids, v_source_versions, v_source_distances
  from (
    select flow.id,
      flow.version::text as version,
      flow.embedding_ft operator(extensions.<=>) p_query_embedding
        as semantic_distance
    from public.flows as flow
    where private.portal_display_request_visible_v1('flow',flow.id,flow.version::text)
      and flow.embedding_ft is not null
    limit 200
  ) as bounded_source;

  v_source_rows := coalesce(pg_catalog.cardinality(v_source_ids), 0);

  if v_source_rows < 200 then
    return query
    select v_source_ids[source.ordinal],
      v_source_versions[source.ordinal],
      v_source_distances[source.ordinal]
    from pg_catalog.generate_subscripts(v_source_ids, 1)
      as source(ordinal)
    where v_source_distances[source.ordinal] is not null
      and v_source_distances[source.ordinal] >= 0::double precision
      and v_source_distances[source.ordinal] <= 0.5::double precision
      and exists (
        select 1
        from private.display_catalog_search_rows_v1 as projection
        where projection.dataset_kind = 'flow'
          and projection.id = v_source_ids[source.ordinal]
          and projection.version = v_source_versions[source.ordinal]
          and not exists (
            select 1
            from private.display_catalog_search_rows_v1 as newer
            where newer.dataset_kind = projection.dataset_kind
              and newer.id = projection.id
              and (
                newer.version > projection.version
                or (
                  newer.version = projection.version
                  and newer.modified_at > projection.modified_at
                )
                or (
                  newer.version = projection.version
                  and newer.modified_at = projection.modified_at
                  and newer.state_code > projection.state_code
                )
              )
          )
        offset 0
      )
    order by v_source_distances[source.ordinal],
      v_source_ids[source.ordinal],
      v_source_versions[source.ordinal] desc;
    return;
  end if;

  return query
  select exact.*
  from private.display_projection_semantic_flow_exact_v1(
    p_query_embedding
  ) as exact;
  return;
end
$$;

ALTER FUNCTION "private"."display_projection_semantic_flow_v1"("p_query_embedding" "extensions"."vector") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_flow_v1"("p_query_embedding" "extensions"."vector") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_flow_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "hnsw.iterative_scan" TO 'strict_order'
    SET "hnsw.ef_search" TO '200'
    SET "hnsw.max_scan_tuples" TO '20000'
    SET "hnsw.scan_mem_multiplier" TO '2'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_exact_cutover constant integer := 2000;
  v_candidate_ids uuid[];
  v_candidate_versions text[];
  v_candidate_count integer;
  v_indexed_probe boolean := false;
begin
  if p_query_embedding is null
     or extensions.vector_dims(p_query_embedding) <> 1024 then
    raise exception using
      errcode = '22023',
      message = 'invalid portal request';
  end if;

  -- Geography and access level are exact, normalized facts in the
  -- transactionally synchronized facet child.  Additional filters remain a
  -- final canonical card recheck, so this key set is a safe candidate
  -- superset for combined filter requests.
  if (p_filters ? 'geography') and (p_filters ? 'accessLevel') then
    v_indexed_probe := true;
    select
      pg_catalog.array_agg(candidate.id),
      pg_catalog.array_agg(candidate.version)
    into v_candidate_ids, v_candidate_versions
    from (
      select facet.id, facet.version
      from private.display_catalog_facet_rows_v1 as facet
      where facet.dataset_kind = 'flow'
        and true
        and facet.facet_contract_version = 1
        and facet.facet_geography = p_filters ->> 'geography'
        and facet.facet_access_level = p_filters ->> 'accessLevel'
      limit v_exact_cutover + 1
    ) as candidate;
  elsif p_filters ? 'geography' then
    v_indexed_probe := true;
    select
      pg_catalog.array_agg(candidate.id),
      pg_catalog.array_agg(candidate.version)
    into v_candidate_ids, v_candidate_versions
    from (
      select facet.id, facet.version
      from private.display_catalog_facet_rows_v1 as facet
      where facet.dataset_kind = 'flow'
        and true
        and facet.facet_contract_version = 1
        and facet.facet_geography = p_filters ->> 'geography'
      limit v_exact_cutover + 1
    ) as candidate;
  elsif p_filters ? 'accessLevel' then
    v_indexed_probe := true;
    select
      pg_catalog.array_agg(candidate.id),
      pg_catalog.array_agg(candidate.version)
    into v_candidate_ids, v_candidate_versions
    from (
      select facet.id, facet.version
      from private.display_catalog_facet_rows_v1 as facet
      where facet.dataset_kind = 'flow'
        and true
        and facet.facet_contract_version = 1
        and facet.facet_access_level = p_filters ->> 'accessLevel'
      limit v_exact_cutover + 1
    ) as candidate;
  end if;

  v_candidate_count := coalesce(
    pg_catalog.cardinality(v_candidate_ids),
    0
  );

  if v_indexed_probe
     and v_candidate_count <= v_exact_cutover then
    return query
    with candidate_keys as materialized (
      select
        v_candidate_ids[key.ordinal] as id,
        v_candidate_versions[key.ordinal] as version
      from pg_catalog.generate_subscripts(
        v_candidate_ids,
        1
      ) as key(ordinal)
    ), nearest as materialized (
      select
        source.id,
        source.version::text as version,
        source.embedding_ft operator(extensions.<=>) p_query_embedding
          as distance
      from candidate_keys as candidate
      join public.flows as source
        on source.id = candidate.id
       and source.version::text = candidate.version
      join private.display_catalog_search_rows_v1 as projection
        on projection.dataset_kind = 'flow'
       and projection.id = candidate.id
       and projection.version = candidate.version
      where private.portal_display_request_visible_v1('flow',source.id,source.version::text)
        and source.embedding_ft is not null
        and true
        and private.display_card_matches_filters_v2(
          projection.card,
          p_filters
        )
      -- The no-op addition deliberately prevents the global HNSW index from
      -- satisfying this ORDER BY.  Only the bounded exact-key rows are scored.
      order by
        (
          source.embedding_ft operator(extensions.<=>) p_query_embedding
        ) + 0::double precision,
        source.id,
        source.version::text desc
      limit 200
    )
    select nearest.id, nearest.version, nearest.distance
    from nearest
    where nearest.distance >= 0::double precision
      and nearest.distance <= 0.5::double precision
    order by
      nearest.distance + 0::double precision,
      nearest.id,
      nearest.version desc;
    return;
  end if;

  -- Unfiltered, unsupported-filter-only, and broad indexed-filter requests
  -- retain the predecessor HNSW path byte-for-byte.
  return query
  with nearest as materialized (
    select source.id, source.version::text as version,
      source.embedding_ft operator(extensions.<=>) p_query_embedding as distance
    from public.flows as source
    where private.portal_display_request_visible_v1('flow',source.id,source.version::text)
      and source.embedding_ft is not null
      and exists (
        select 1 from private.display_catalog_search_rows_v1 as projection
        where projection.dataset_kind = 'flow'
          and projection.id = source.id and projection.version = source.version::text
          and true
          and (p_filters = '{}'::jsonb
            or private.display_card_matches_filters_v2(projection.card, p_filters))
        offset 0
      )
    order by source.embedding_ft operator(extensions.<=>) p_query_embedding
    limit 200
  )
  select nearest.id, nearest.version, nearest.distance
  from nearest
  where nearest.distance >= 0::double precision and nearest.distance <= 0.5::double precision
  order by nearest.distance + 0::double precision, nearest.id, nearest.version desc;
end;
$$;

ALTER FUNCTION "private"."display_projection_semantic_flow_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_flow_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_process_exact_cn1"("p_query_embedding" "extensions"."vector") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "work_mem" TO '32MB'
    SET "enable_hashjoin" TO 'on'
    SET "enable_nestloop" TO 'off'
    SET "enable_mergejoin" TO 'off'
    SET "enable_sort" TO 'on'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
  with latest_keys as materialized (
    select distinct on (projection.id)
      projection.id,
      projection.version
    from private.display_catalog_search_rows_v2 as projection
    where projection.dataset_kind = 'process'
    order by projection.id,
      projection.version desc,
      projection.modified_at desc,
      projection.state_code desc
  ), eligible as materialized (
    select process.id,
      process.version::text as version,
      process.embedding_ft operator(extensions.<=>) p_query_embedding
        as semantic_distance
    from public.processes as process
    join latest_keys as latest
      on latest.id = process.id
     and process.version = latest.version::character(9)
    where private.portal_display_request_visible_v1('process',process.id,process.version::text)
      and process.embedding_ft is not null
  )
  select eligible.id,
    eligible.version,
    eligible.semantic_distance
  from eligible
  where eligible.semantic_distance is not null
    and eligible.semantic_distance >= 0::double precision
    and eligible.semantic_distance <= 0.5::double precision
  order by eligible.semantic_distance,
    eligible.id,
    eligible.version desc
  limit 200
$$;

ALTER FUNCTION "private"."display_projection_semantic_process_exact_cn1"("p_query_embedding" "extensions"."vector") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_process_exact_cn1"("p_query_embedding" "extensions"."vector") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_process_v1"("p_query_embedding" "extensions"."vector") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "hnsw.iterative_scan" TO 'relaxed_order'
    SET "hnsw.ef_search" TO '1000'
    SET "hnsw.max_scan_tuples" TO '200000'
    SET "hnsw.scan_mem_multiplier" TO '4'
    SET "enable_sort" TO 'off'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_ids uuid[];
  v_versions text[];
  v_distances double precision[];
  v_source_ids uuid[];
  v_source_versions text[];
  v_source_distances double precision[];
  v_source_rows integer;
begin
  if p_query_embedding is null then
    raise exception using
      errcode = '22023',
      message = 'invalid portal semantic query';
  end if;

  select pg_catalog.array_agg(
      candidate.id
      order by candidate.semantic_distance, candidate.id, candidate.version desc
    ),
    pg_catalog.array_agg(
      candidate.version
      order by candidate.semantic_distance, candidate.id, candidate.version desc
    ),
    pg_catalog.array_agg(
      candidate.semantic_distance
      order by candidate.semantic_distance, candidate.id, candidate.version desc
    )
  into v_ids, v_versions, v_distances
  from (
    select approximate.id,
      approximate.version,
      approximate.semantic_distance
    from (
      select process.id,
        process.version::text as version,
        process.embedding_ft operator(extensions.<=>) p_query_embedding
          as semantic_distance
      from public.processes as process
      where private.portal_display_request_visible_v1('process',process.id,process.version::text)
        and process.embedding_ft is not null
        and exists (
          select 1
          from private.display_catalog_search_current_v2 as projection
          where projection.dataset_kind = 'process'
            and projection.id = process.id
            and projection.version = process.version::text
            and not exists (
              select 1
              from private.display_catalog_search_current_v2 as newer
              where newer.dataset_kind = projection.dataset_kind
                and newer.id = projection.id
                and (
                  newer.version > projection.version
                  or (
                    newer.version = projection.version
                    and newer.modified_at > projection.modified_at
                  )
                  or (
                    newer.version = projection.version
                    and newer.modified_at = projection.modified_at
                    and newer.state_code > projection.state_code
                  )
                )
            )
        )
      order by process.embedding_ft
        operator(extensions.<=>) p_query_embedding
      limit 5000
    ) as approximate
    where approximate.semantic_distance is not null
      and approximate.semantic_distance >= 0::double precision
    order by approximate.semantic_distance + 0::double precision,
      approximate.id,
      approximate.version desc
    limit 200
  ) as candidate;

  if coalesce(pg_catalog.cardinality(v_ids), 0) >= 200 then
    return query
    select v_ids[candidate.ordinal],
      v_versions[candidate.ordinal],
      v_distances[candidate.ordinal]
    from pg_catalog.generate_subscripts(v_ids, 1)
      as candidate(ordinal)
    where v_distances[candidate.ordinal] <= 0.5::double precision
    order by candidate.ordinal;
    return;
  end if;

  select pg_catalog.array_agg(
      bounded_source.id order by bounded_source.id, bounded_source.version desc
    ),
    pg_catalog.array_agg(
      bounded_source.version
      order by bounded_source.id, bounded_source.version desc
    ),
    pg_catalog.array_agg(
      bounded_source.semantic_distance
      order by bounded_source.id, bounded_source.version desc
    )
  into v_source_ids, v_source_versions, v_source_distances
  from (
    select process.id,
      process.version::text as version,
      process.embedding_ft operator(extensions.<=>) p_query_embedding
        as semantic_distance
    from public.processes as process
    where private.portal_display_request_visible_v1('process',process.id,process.version::text)
      and process.embedding_ft is not null
    limit 200
  ) as bounded_source;

  v_source_rows := coalesce(pg_catalog.cardinality(v_source_ids), 0);

  if v_source_rows < 200 then
    return query
    select v_source_ids[source.ordinal],
      v_source_versions[source.ordinal],
      v_source_distances[source.ordinal]
    from pg_catalog.generate_subscripts(v_source_ids, 1)
      as source(ordinal)
    where v_source_distances[source.ordinal] is not null
      and v_source_distances[source.ordinal] >= 0::double precision
      and v_source_distances[source.ordinal] <= 0.5::double precision
      and exists (
        select 1
        from private.display_catalog_search_current_v2 as projection
        where projection.dataset_kind = 'process'
          and projection.id = v_source_ids[source.ordinal]
          and projection.version = v_source_versions[source.ordinal]
          and not exists (
            select 1
            from private.display_catalog_search_current_v2 as newer
            where newer.dataset_kind = projection.dataset_kind
              and newer.id = projection.id
              and (
                newer.version > projection.version
                or (
                  newer.version = projection.version
                  and newer.modified_at > projection.modified_at
                )
                or (
                  newer.version = projection.version
                  and newer.modified_at = projection.modified_at
                  and newer.state_code > projection.state_code
                )
              )
          )
        offset 0
      )
    order by v_source_distances[source.ordinal],
      v_source_ids[source.ordinal],
      v_source_versions[source.ordinal] desc;
    return;
  end if;

  return query
  select exact.*
  from private.display_projection_semantic_process_exact_cn1(
    p_query_embedding
  ) as exact;
  return;
end
$$;

ALTER FUNCTION "private"."display_projection_semantic_process_v1"("p_query_embedding" "extensions"."vector") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_process_v1"("p_query_embedding" "extensions"."vector") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_process_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "hnsw.iterative_scan" TO 'strict_order'
    SET "hnsw.ef_search" TO '200'
    SET "hnsw.max_scan_tuples" TO '20000'
    SET "hnsw.scan_mem_multiplier" TO '2'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_exact_cutover constant integer := 2000;
  v_candidate_ids uuid[];
  v_candidate_versions text[];
  v_candidate_count integer;
  v_indexed_probe boolean := false;
begin
  if p_query_embedding is null
     or extensions.vector_dims(p_query_embedding) <> 1024 then
    raise exception using
      errcode = '22023',
      message = 'invalid portal request';
  end if;

  -- Geography and access level are exact, normalized facts in the
  -- transactionally synchronized facet child.  Additional filters remain a
  -- final canonical card recheck, so this key set is a safe candidate
  -- superset for combined filter requests.
  if (p_filters ? 'geography') and (p_filters ? 'accessLevel') then
    v_indexed_probe := true;
    select
      pg_catalog.array_agg(candidate.id),
      pg_catalog.array_agg(candidate.version)
    into v_candidate_ids, v_candidate_versions
    from (
      select facet.id, facet.version
      from private.display_catalog_facet_rows_v1 as facet
      where facet.dataset_kind = 'process'
        and true
        and facet.facet_contract_version = 1
        and facet.facet_geography = p_filters ->> 'geography'
        and facet.facet_access_level = p_filters ->> 'accessLevel'
      limit v_exact_cutover + 1
    ) as candidate;
  elsif p_filters ? 'geography' then
    v_indexed_probe := true;
    select
      pg_catalog.array_agg(candidate.id),
      pg_catalog.array_agg(candidate.version)
    into v_candidate_ids, v_candidate_versions
    from (
      select facet.id, facet.version
      from private.display_catalog_facet_rows_v1 as facet
      where facet.dataset_kind = 'process'
        and true
        and facet.facet_contract_version = 1
        and facet.facet_geography = p_filters ->> 'geography'
      limit v_exact_cutover + 1
    ) as candidate;
  elsif p_filters ? 'accessLevel' then
    v_indexed_probe := true;
    select
      pg_catalog.array_agg(candidate.id),
      pg_catalog.array_agg(candidate.version)
    into v_candidate_ids, v_candidate_versions
    from (
      select facet.id, facet.version
      from private.display_catalog_facet_rows_v1 as facet
      where facet.dataset_kind = 'process'
        and true
        and facet.facet_contract_version = 1
        and facet.facet_access_level = p_filters ->> 'accessLevel'
      limit v_exact_cutover + 1
    ) as candidate;
  end if;

  v_candidate_count := coalesce(
    pg_catalog.cardinality(v_candidate_ids),
    0
  );

  if v_indexed_probe
     and v_candidate_count <= v_exact_cutover then
    return query
    with candidate_keys as materialized (
      select
        v_candidate_ids[key.ordinal] as id,
        v_candidate_versions[key.ordinal] as version
      from pg_catalog.generate_subscripts(
        v_candidate_ids,
        1
      ) as key(ordinal)
    ), nearest as materialized (
      select
        source.id,
        source.version::text as version,
        source.embedding_ft operator(extensions.<=>) p_query_embedding
          as distance
      from candidate_keys as candidate
      join public.processes as source
        on source.id = candidate.id
       and source.version::text = candidate.version
      join private.display_catalog_search_current_v2 as projection
        on projection.dataset_kind = 'process'
       and projection.id = candidate.id
       and projection.version = candidate.version
      where private.portal_display_request_visible_v1('process',source.id,source.version::text)
        and source.embedding_ft is not null
        and true
        and private.display_card_matches_filters_v2(
          projection.card,
          p_filters
        )
      -- The no-op addition deliberately prevents the global HNSW index from
      -- satisfying this ORDER BY.  Only the bounded exact-key rows are scored.
      order by
        (
          source.embedding_ft operator(extensions.<=>) p_query_embedding
        ) + 0::double precision,
        source.id,
        source.version::text desc
      limit 200
    )
    select nearest.id, nearest.version, nearest.distance
    from nearest
    where nearest.distance >= 0::double precision
      and nearest.distance <= 0.5::double precision
    order by
      nearest.distance + 0::double precision,
      nearest.id,
      nearest.version desc;
    return;
  end if;

  -- Unfiltered, unsupported-filter-only, and broad indexed-filter requests
  -- retain the predecessor HNSW path byte-for-byte.
  return query
  with nearest as materialized (
    select source.id, source.version::text as version,
      source.embedding_ft operator(extensions.<=>) p_query_embedding as distance
    from public.processes as source
    where private.portal_display_request_visible_v1('process',source.id,source.version::text)
      and source.embedding_ft is not null
      and exists (
        select 1 from private.display_catalog_search_current_v2 as projection
        where projection.dataset_kind = 'process'
          and projection.id = source.id and projection.version = source.version::text
          and true
          and (p_filters = '{}'::jsonb
            or private.display_card_matches_filters_v2(projection.card, p_filters))
        offset 0
      )
    order by source.embedding_ft operator(extensions.<=>) p_query_embedding
    limit 200
  )
  select nearest.id, nearest.version, nearest.distance
  from nearest
  where nearest.distance >= 0::double precision and nearest.distance <= 0.5::double precision
  order by nearest.distance + 0::double precision, nearest.id, nearest.version desc;
end;
$$;

ALTER FUNCTION "private"."display_projection_semantic_process_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_process_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_public_hybrid_input_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_terms text[];
  v_term text;
  v_filters jsonb;
  v_key text;
  v_year numeric;
  v_embedding extensions.vector(1024);
  v_embedding_components text[];
  v_embedding_text text;
  v_embedding_sha256 text;
  v_fingerprint text;
begin
  if p_kind is null
     or p_kind not in ('process', 'flow')
     or p_limit is null
     or p_limit not between 1 and 20
     or p_query_terms is null
     or pg_catalog.array_ndims(p_query_terms) <> 1
     or pg_catalog.cardinality(p_query_terms) not between 1 and 12
     or exists (
       select 1
       from pg_catalog.unnest(p_query_terms) as supplied(term)
       where supplied.term is null
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  select pg_catalog.array_agg(
    pg_catalog.lower(
      pg_catalog.btrim(supplied.term) collate pg_catalog."und-x-icu"
    )
    order by supplied.ordinality
  )
  into v_terms
  from pg_catalog.unnest(p_query_terms) with ordinality as supplied(term, ordinality);

  foreach v_term in array v_terms
  loop
    if pg_catalog.char_length(v_term) not between 1 and 512
       or pg_catalog.octet_length(v_term) > 2048
       or exists (
         select 1
         from pg_catalog.generate_series(1, pg_catalog.char_length(v_term)) as position(value)
         where pg_catalog.ascii(pg_catalog.substr(v_term, position.value, 1))
           between 0 and 31
            or pg_catalog.ascii(pg_catalog.substr(v_term, position.value, 1))
              between 127 and 159
       ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;
  if (
    select count(distinct supplied.term)
    from pg_catalog.unnest(v_terms) as supplied(term)
  ) <> pg_catalog.cardinality(v_terms) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  if p_query_embedding is null
     or pg_catalog.octet_length(p_query_embedding) > 65536
     or pg_catalog.left(p_query_embedding, 1) <> '['
     or pg_catalog.right(p_query_embedding, 1) <> ']' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_embedding_components := pg_catalog.string_to_array(
    pg_catalog.substr(p_query_embedding, 2, pg_catalog.char_length(p_query_embedding) - 2),
    ','
  );
  if pg_catalog.cardinality(v_embedding_components) <> 1024
     or exists (
       select 1
       from pg_catalog.unnest(v_embedding_components) as component(value)
       where component.value
         !~ '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$'
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  begin
    v_embedding := p_query_embedding::extensions.vector(1024);
  exception
    when others then
      raise exception using errcode = '22023', message = 'invalid portal request';
  end;
  if extensions.vector_dims(v_embedding) <> 1024 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_embedding_text := v_embedding::text;
  v_embedding_sha256 := pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(v_embedding_text, 'UTF8'), 'sha256'),
    'hex'
  );

  if p_filters is null or pg_catalog.jsonb_typeof(p_filters) <> 'object' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if exists (
    select 1
    from pg_catalog.jsonb_object_keys(p_filters) as supplied(key)
    where supplied.key not in (
      'accessLevel', 'geography', 'classification', 'referenceYearFrom',
      'referenceYearTo', 'processSubtype', 'source'
    )
  ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select coalesce(
    pg_catalog.jsonb_object_agg(
      supplied.key,
      case
        when supplied.key in (
          'geography', 'classification', 'processSubtype', 'source'
        ) and pg_catalog.jsonb_typeof(supplied.value) = 'string'
          then pg_catalog.to_jsonb(pg_catalog.lower(
            pg_catalog.btrim(supplied.value #>> '{}') collate pg_catalog."und-x-icu"
          ))
        else supplied.value
      end
      order by supplied.key
    ),
    '{}'::jsonb
  )
  into v_filters
  from pg_catalog.jsonb_each(p_filters) as supplied(key, value);
  if pg_catalog.octet_length(pg_catalog.convert_to(v_filters::text, 'UTF8')) > 4096
     or (p_kind = 'flow' and v_filters ? 'processSubtype')
     or (
       v_filters ? 'accessLevel'
       and (
         pg_catalog.jsonb_typeof(v_filters -> 'accessLevel') <> 'string'
         or v_filters ->> 'accessLevel' not in ('open', 'metadata_only')
       )
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  foreach v_key in array array['geography', 'classification', 'processSubtype', 'source']
  loop
    if v_filters ? v_key
       and (
         pg_catalog.jsonb_typeof(v_filters -> v_key) <> 'string'
         or pg_catalog.char_length(v_filters ->> v_key) not between 1 and 128
         or pg_catalog.octet_length(v_filters ->> v_key) > 1024
         or exists (
           select 1
           from pg_catalog.generate_series(
             1,
             pg_catalog.char_length(v_filters ->> v_key)
           ) as position(value)
           where pg_catalog.ascii(
             pg_catalog.substr(v_filters ->> v_key, position.value, 1)
           ) between 0 and 31
              or pg_catalog.ascii(
                pg_catalog.substr(v_filters ->> v_key, position.value, 1)
              ) between 127 and 159
         )
       ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;

  foreach v_key in array array['referenceYearFrom', 'referenceYearTo']
  loop
    if v_filters ? v_key then
      if pg_catalog.jsonb_typeof(v_filters -> v_key) <> 'number' then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
      v_year := (v_filters ->> v_key)::numeric;
      if v_year <> pg_catalog.trunc(v_year) or v_year not between 0 and 9999 then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
    end if;
  end loop;
  if v_filters ? 'referenceYearFrom'
     and v_filters ? 'referenceYearTo'
     and (v_filters ->> 'referenceYearFrom')::numeric
       > (v_filters ->> 'referenceYearTo')::numeric then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  v_fingerprint := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'algorithmVersion', 'portal-hybrid-rank-v1',
          'kind', p_kind,
          'queryTerms', pg_catalog.to_jsonb(v_terms),
          'queryEmbeddingSha256', v_embedding_sha256,
          'filters', v_filters,
          'limit', p_limit
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  return pg_catalog.jsonb_build_object(
    'kind', p_kind,
    'queryTerms', pg_catalog.to_jsonb(v_terms),
    'queryEmbedding', v_embedding_text,
    'filters', v_filters,
    'limit', p_limit,
    'queryFingerprint', v_fingerprint
  );
end
$_$;

ALTER FUNCTION "private"."display_public_hybrid_input_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_public_hybrid_input_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case p_kind
    when 'process' then p_json #> '{processDataSet,administrativeInformation,publicationAndOwnership}'
    when 'flow' then p_json #> '{flowDataSet,administrativeInformation,publicationAndOwnership}'
    when 'flowproperty' then p_json #> '{flowPropertyDataSet,administrativeInformation,publicationAndOwnership}'
    when 'unitgroup' then p_json #> '{unitGroupDataSet,administrativeInformation,publicationAndOwnership}'
    else null
  end
$$;

ALTER FUNCTION "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") RETURNS "text"
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'scope', private.portal_display_scope_identity_v1(),
          'kind', p_kind,
          'query', p_query,
          'filters', p_filters,
          'sort', p_sort
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
$$;

ALTER FUNCTION "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_reference_flowproperty_v1"("p_flow_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_internal_id text := p_flow_json #>> '{flowDataSet,flowInformation,quantitativeReference,referenceToReferenceFlowProperty}';
  v_flow_property jsonb;
  v_reference jsonb;
  v_id_text text;
  v_version text;
  v_id uuid;
  v_row_json jsonb;
  v_match_count bigint;
begin
  if v_internal_id !~ '^(0|[1-9][0-9]{0,4})$' then
    return null;
  end if;
  select count(*), (jsonb_agg(item) -> 0)
  into v_match_count, v_flow_property
  from private.display_json_items_v1(p_flow_json #> '{flowDataSet,flowProperties,flowProperty}') as item
  where item ->> '@dataSetInternalID' = v_internal_id
    and item ->> '@dataSetInternalID' ~ '^(0|[1-9][0-9]{0,4})$';
  if v_match_count <> 1 then
    return null;
  end if;
  v_reference := v_flow_property -> 'referenceToFlowPropertyDataSet';
  v_id_text := lower(btrim(coalesce(v_reference ->> '@refObjectId', '')));
  v_version := btrim(coalesce(v_reference ->> '@version', ''));
  if v_id_text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or v_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    return null;
  end if;
  v_id := v_id_text::uuid;
  select row.json
  into v_row_json
  from public.flowproperties as row
  where row.id = v_id
    and row.version::text = v_version
    and true
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'flowPropertyDataSet') = 'object'
  limit 1;
  if v_row_json is null then
    return null;
  end if;
  return jsonb_build_object(
    'id', v_id_text,
    'version', v_version,
    'name', private.display_localized_text_v1(
      v_row_json #> '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name}'
    )
  );
end
$_$;

ALTER FUNCTION "private"."display_reference_flowproperty_v1"("p_flow_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_reference_flowproperty_v1"("p_flow_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_safe_year_v1"("p_value" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
  select case
    when btrim(coalesce(p_value, '')) ~ '^[0-9]{4}$'
      then btrim(p_value)::integer
    else null
  end
$_$;

ALTER FUNCTION "private"."display_safe_year_v1"("p_value" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_safe_year_v1"("p_value" "text") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_scalar_text_v1"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case
    when jsonb_typeof(p_value) = 'string' then btrim(p_value #>> '{}')
    else null
  end
$$;

ALTER FUNCTION "private"."display_scalar_text_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_scalar_text_v1"("p_value" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_query text;
  v_filters jsonb;
  v_sort text;
  v_limit integer := coalesce(p_limit, 20);
  v_fingerprint text;
  v_cursor jsonb;
  v_cursor_rank text;
  v_cursor_id uuid;
  v_cursor_version text;
  v_kernel jsonb;
  v_next_cursor_payload jsonb;
begin
  perform private.display_assert_catalog_projection_contract_cn1();

  perform private.display_validate_search_v1(
    p_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    coalesce(p_sort, 'relevance'),
    v_limit
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.display_normalize_filters_v1(p_filters);
  v_sort := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort, 'relevance')));
  v_fingerprint := private.display_query_fingerprint_v1(
    p_kind,
    v_query,
    v_filters,
    v_sort
  );
  if p_kind = 'process' then
  v_fingerprint := pg_catalog.encode(extensions.digest(pg_catalog.convert_to('composite-names-v2:' || v_fingerprint, 'UTF8'), 'sha256'), 'hex');
  end if;
  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'fp' <> v_fingerprint
       or v_cursor ->> 'kind' <> p_kind
       or coalesce(v_cursor ->> 'rankKey', '') = ''
       or coalesce(v_cursor ->> 'id', '')
         !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_rank := v_cursor ->> 'rankKey';
    v_cursor_id := (v_cursor ->> 'id')::uuid;
    v_cursor_version := v_cursor ->> 'version';
    if v_sort = 'relevance'
       and v_cursor_rank !~ '^(0(\.\d+)?|1(\.0+)?)$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    elsif v_sort = 'modified_desc'
       and private.display_datetime_v1(v_cursor_rank) is null then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;

  if pg_catalog.char_length(v_query) = 1
     and v_filters = '{}'::jsonb
     and v_sort = 'relevance' then
    v_kernel := private.display_catalog_single_character_search_v1_impl(
      p_kind,
      v_query,
      v_cursor_rank,
      v_cursor_id,
      v_cursor_version,
      v_limit,
      v_fingerprint
    );
  elsif p_kind = 'process'
     and pg_catalog.char_length(v_query) > 1
     and v_query !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and v_filters = '{}'::jsonb
     and v_sort = 'relevance' then
    perform private.display_assert_process_keyword_rank_contract_cn1();
    v_kernel := private.display_catalog_process_keyword_relevance_cn1_impl(
      v_query,
      v_cursor_rank,
      v_cursor_id,
      v_cursor_version,
      v_limit,
      v_fingerprint
    );
  else
    v_kernel := private.display_catalog_search_v1_impl(
      p_kind,
      v_query,
      v_filters,
      v_sort,
      v_cursor_rank,
      v_cursor_id,
      v_cursor_version,
      v_limit,
      v_fingerprint
    );
  end if;

  v_next_cursor_payload := nullif(
    v_kernel -> 'nextCursorPayload',
    'null'::jsonb
  );

  return pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-search-page.v1',
    'kind', p_kind,
    'queryFingerprint', v_fingerprint,
    'items', coalesce(v_kernel -> 'items', '[]'::jsonb),
    'nextCursor', case when v_next_cursor_payload is null then null
      else private.display_cursor_encode_v1(v_next_cursor_payload)
    end
  );
end
$_$;

ALTER FUNCTION "private"."display_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_search_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_query text;
  v_filters jsonb;
  v_sort text;
  v_limit integer := coalesce(p_limit, 20);
  v_fingerprint text;
  v_cursor jsonb;
  v_cursor_rank text;
  v_cursor_id uuid;
  v_cursor_version text;
  v_kernel jsonb;
  v_next_cursor_payload jsonb;
begin
  perform private.display_assert_catalog_projection_contract_cn1();

  perform private.display_validate_search_v1(
    p_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    coalesce(p_sort, 'relevance'),
    v_limit
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.display_normalize_filters_v1(p_filters);
  v_sort := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort, 'relevance')));
  v_fingerprint := private.display_query_fingerprint_v1(
    p_kind,
    v_query,
    v_filters,
    v_sort
  );
  if p_kind = 'process' then
  v_fingerprint := pg_catalog.encode(extensions.digest(pg_catalog.convert_to('composite-names-v2:' || v_fingerprint, 'UTF8'), 'sha256'), 'hex');
  end if;
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v2:' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'fp' <> v_fingerprint
       or v_cursor ->> 'kind' <> p_kind
       or coalesce(v_cursor ->> 'rankKey', '') = ''
       or coalesce(v_cursor ->> 'id', '')
         !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_rank := v_cursor ->> 'rankKey';
    v_cursor_id := (v_cursor ->> 'id')::uuid;
    v_cursor_version := v_cursor ->> 'version';
    if v_sort = 'relevance'
       and v_cursor_rank !~ '^(0(\.\d+)?|1(\.0+)?)$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    elsif v_sort = 'modified_desc'
       and private.display_datetime_v1(v_cursor_rank) is null then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;

  v_kernel := private.display_catalog_search_v2_impl(
    p_kind,v_query,v_filters,v_sort,v_cursor_rank,v_cursor_id,v_cursor_version,v_limit,v_fingerprint
  );

  v_next_cursor_payload := nullif(
    v_kernel -> 'nextCursorPayload',
    'null'::jsonb
  );

  return pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-search-page.v1',
    'kind', p_kind,
    'queryFingerprint', v_fingerprint,
    'items', coalesce(v_kernel -> 'items', '[]'::jsonb),
    'nextCursor', case when v_next_cursor_payload is null then null
      else private.display_cursor_encode_v1(v_next_cursor_payload)
    end
  );
end
$_$;

ALTER FUNCTION "private"."display_search_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_search_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_query text;
  v_filters jsonb;
  v_sort text;
  v_limit integer := coalesce(p_limit, 20);
  v_fingerprint text;
  v_cursor jsonb;
  v_cursor_rank text;
  v_cursor_id uuid;
  v_cursor_version text;
  v_kernel jsonb;
  v_next_cursor_payload jsonb;
begin
  perform private.display_assert_catalog_projection_contract_cn1();

  perform private.display_validate_search_v3(
    p_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    coalesce(p_sort, 'relevance'),
    v_limit
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.display_normalize_filters_v1(p_filters);
  v_sort := pg_catalog.lower(pg_catalog.btrim(coalesce(p_sort, 'relevance')));
  v_fingerprint := private.display_query_fingerprint_v1(
    p_kind,
    v_query,
    v_filters,
    v_sort
  );
  if p_kind = 'process' then
  v_fingerprint := pg_catalog.encode(extensions.digest(pg_catalog.convert_to('composite-names-v2:' || v_fingerprint, 'UTF8'), 'sha256'), 'hex');
  end if;
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v3:' || (select asset_sha256 from private.display_read_navigation_contract_v1 where contract_version=1) || ':' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'fp' <> v_fingerprint
       or v_cursor ->> 'kind' <> p_kind
       or coalesce(v_cursor ->> 'rankKey', '') = ''
       or coalesce(v_cursor ->> 'id', '')
         !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_rank := v_cursor ->> 'rankKey';
    v_cursor_id := (v_cursor ->> 'id')::uuid;
    v_cursor_version := v_cursor ->> 'version';
    if v_sort = 'relevance'
       and v_cursor_rank !~ '^(0(\.\d+)?|1(\.0+)?)$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    elsif v_sort = 'modified_desc'
       and private.display_datetime_v1(v_cursor_rank) is null then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;

  v_kernel := private.display_catalog_search_v3_impl(
    p_kind,v_query,v_filters,v_sort,v_cursor_rank,v_cursor_id,v_cursor_version,v_limit,v_fingerprint
  );

  v_next_cursor_payload := nullif(
    v_kernel -> 'nextCursorPayload',
    'null'::jsonb
  );

  return pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-search-page.v1',
    'kind', p_kind,
    'queryFingerprint', v_fingerprint,
    'items', coalesce(v_kernel -> 'items', '[]'::jsonb),
    'nextCursor', case when v_next_cursor_payload is null then null
      else private.display_cursor_encode_v1(v_next_cursor_payload)
    end
  );
end;
$_$;

ALTER FUNCTION "private"."display_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_source_v1"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_publication jsonb := private.display_publication_root_v1(p_kind, p_json);
  v_database jsonb := v_publication -> 'common:referenceToUnchangedRepublication';
  v_source jsonb;
begin
  v_source := case p_kind
    when 'process' then p_json #> '{processDataSet,modellingAndValidation,dataSourcesTreatmentAndRepresentativeness,referenceToDataSource}'
    when 'flow' then p_json #> '{flowDataSet,modellingAndValidation,dataSourcesTreatmentAndRepresentativeness,referenceToDataSource}'
    else null
  end;
  if jsonb_typeof(v_source) = 'array' and jsonb_array_length(v_source) = 1 then
    v_source := v_source -> 0;
  elsif jsonb_typeof(v_source) <> 'object' then
    v_source := null;
  end if;
  return jsonb_build_object(
    'databaseId', case
      when lower(coalesce(v_database ->> '@refObjectId', '')) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then lower(v_database ->> '@refObjectId')
      else null
    end,
    'databaseVersion', case
      when coalesce(v_database ->> '@version', '') ~ '^\d{2}\.\d{2}\.\d{3}$'
        then v_database ->> '@version'
      else null
    end,
    'sourceRecordId', case
      when lower(coalesce(v_source ->> '@refObjectId', '')) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then lower(v_source ->> '@refObjectId')
      else null
    end,
    'providerName', private.display_localized_text_v1(
      v_publication #> '{common:referenceToOwnershipOfDataSet,common:shortDescription}'
    ),
    'licenseId', nullif(private.display_scalar_text_v1(v_publication -> 'common:licenseType'), ''),
    'licenseUrl', null
  );
end
$_$;

ALTER FUNCTION "private"."display_source_v1"("p_kind" "text", "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_source_v1"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_support_capabilities_v1"("p_kind" "text", "p_state_code" integer) RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select jsonb_build_object('exchangesVisible',p_kind in ('flow','flowproperty','unitgroup'),
    'policyVersion','portal-capability-policy.v1',
    'reasonCodes',jsonb_build_array('public_license_confirmed'))
$$;

ALTER FUNCTION "private"."display_support_capabilities_v1"("p_kind" "text", "p_state_code" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_support_capabilities_v1"("p_kind" "text", "p_state_code" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_timestamp_v1"("p_value" timestamp with time zone) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select to_char(p_value at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

ALTER FUNCTION "private"."display_timestamp_v1"("p_value" timestamp with time zone) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_timestamp_v1"("p_value" timestamp with time zone) FROM PUBLIC;



CREATE OR REPLACE FUNCTION "private"."display_validate_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) RETURNS "void"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_key text;
  v_allowed text[] := array[
    'accessLevel', 'geography', 'classification', 'referenceYearFrom',
    'referenceYearTo', 'source'
  ];
begin
  if p_kind not in ('process', 'flow', 'all')
     or p_query is null
     or length(p_query) > 512
     or pg_catalog.octet_length(p_query) > 2048
     or p_query ~ '[[:cntrl:]]'
     or p_sort is null
     or length(p_sort) > 32
     or pg_catalog.octet_length(p_sort) > 64
     or lower(btrim(p_sort)) not in ('relevance', 'modified_desc', 'name_asc')
     or p_limit is null
     or p_limit < 1
     or p_limit > 50
     or p_filters is null
     or jsonb_typeof(p_filters) <> 'object'
     or pg_catalog.pg_column_size(p_filters) > 4096
     or (select count(*) from jsonb_object_keys(p_filters)) > 7 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_kind in ('process', 'all') then
    v_allowed := pg_catalog.array_append(v_allowed, 'processSubtype');
  end if;
  for v_key in select jsonb_object_keys(p_filters)
  loop
    if not (v_key = any(v_allowed)) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;
  if p_filters ? 'accessLevel'
     and (
       jsonb_typeof(p_filters -> 'accessLevel') <> 'string'
       or p_filters ->> 'accessLevel' not in ('open', 'metadata_only')
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  foreach v_key in array array['geography', 'classification', 'processSubtype', 'source']
  loop
    if p_filters ? v_key
       and (
         jsonb_typeof(p_filters -> v_key) <> 'string'
         or length(btrim(p_filters ->> v_key)) not between 1 and 128
       ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;
  foreach v_key in array array['referenceYearFrom', 'referenceYearTo']
  loop
    if p_filters ? v_key
       and (
         jsonb_typeof(p_filters -> v_key) <> 'number'
         or (p_filters ->> v_key) !~ '^[0-9]{1,4}$'
       ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;
  if p_filters ? 'referenceYearFrom'
     and p_filters ? 'referenceYearTo'
     and (p_filters ->> 'referenceYearFrom')::integer > (p_filters ->> 'referenceYearTo')::integer then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
end
$_$;

ALTER FUNCTION "private"."display_validate_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_validate_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "private"."display_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) RETURNS "void"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  v_base jsonb;
  v_key text;
  v_node_pattern constant text := '^[a-z][a-z0-9-]*:[!-~]{1,96}$';
begin
  perform private.display_assert_navigation_projection_v1();
  if p_kind is null or p_kind not in ('process','flow','all') or p_filters is null or pg_catalog.jsonb_typeof(p_filters) <> 'object' or octet_length(p_filters::text)>4096 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  for v_key in select pg_catalog.jsonb_object_keys(p_filters)
  loop
    if v_key not in (
      'accessLevel', 'geography', 'classification', 'referenceYearFrom',
      'referenceYearTo', 'source', 'processSubtype',
      'classificationNodeId', 'classificationScope',
      'geographyNodeId', 'geographyScope'
    ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;

  for v_key in select unnest(array['classificationNodeId', 'geographyNodeId'])
  loop
    if p_filters ? v_key then
      if pg_catalog.jsonb_typeof(p_filters -> v_key) <> 'string'
         or (p_filters ->> v_key) !~ v_node_pattern then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
      -- The node must exist in the vocabulary and belong to the right axis.
      if not exists (
        select 1
        from private.display_read_navigation_node_v1 as node
        where node.node_id = p_filters ->> v_key
          and node.dimension = case v_key
            when 'classificationNodeId' then 'classification'
            else 'geography'
          end
      ) then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
    end if;
  end loop;

  for v_key in select unnest(array['classificationScope', 'geographyScope'])
  loop
    if p_filters ? v_key and (
      pg_catalog.jsonb_typeof(p_filters -> v_key) <> 'string'
      or p_filters ->> v_key not in ('subtree', 'direct')
    ) then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end loop;

  -- A scope without its node is invalid, and a classification node that the
  -- dataset kind can never carry is refused rather than silently empty.
  if p_filters ? 'classificationScope' and not (p_filters ? 'classificationNodeId') then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_filters ? 'geographyScope' and not (p_filters ? 'geographyNodeId') then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  select pg_catalog.jsonb_object_agg(filter.key, filter.value)
  into v_base
  from pg_catalog.jsonb_each(p_filters) as filter(key, value)
  where filter.key in (
    'accessLevel', 'geography', 'classification', 'referenceYearFrom',
    'referenceYearTo', 'source', 'processSubtype'
  );

  perform private.display_validate_search_v1(
    p_kind, p_query, coalesce(v_base, '{}'::jsonb), p_sort, p_limit
  );
end;
$_$;

ALTER FUNCTION "private"."display_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) FROM PUBLIC;



create function private.display_assert_card_context_contract_v1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_card_context_contract_v1()';

alter function private.display_assert_card_context_contract_v1() owner to portal_public_executor;

revoke all on function private.display_assert_card_context_contract_v1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_card_context_contract_v1() to portal_display_executor; reset role;

create function private.display_assert_catalog_character_contract_cn1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_catalog_character_contract_cn1()';

alter function private.display_assert_catalog_character_contract_cn1() owner to portal_public_executor;

revoke all on function private.display_assert_catalog_character_contract_cn1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_catalog_character_contract_cn1() to portal_display_executor; reset role;

create function private.display_assert_catalog_facet_contract_v1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_catalog_facet_contract_v1()';

alter function private.display_assert_catalog_facet_contract_v1() owner to portal_public_executor;

revoke all on function private.display_assert_catalog_facet_contract_v1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_catalog_facet_contract_v1() to portal_display_executor; reset role;

create function private.display_assert_catalog_projection_contract_cn1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_catalog_projection_contract_cn1()';

alter function private.display_assert_catalog_projection_contract_cn1() owner to portal_public_executor;

revoke all on function private.display_assert_catalog_projection_contract_cn1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_catalog_projection_contract_cn1() to portal_display_executor; reset role;

create function private.display_assert_catalog_projection_contract_v1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_catalog_projection_contract_v1()';

alter function private.display_assert_catalog_projection_contract_v1() owner to portal_public_executor;

revoke all on function private.display_assert_catalog_projection_contract_v1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_catalog_projection_contract_v1() to portal_display_executor; reset role;

create function private.display_assert_navigation_contract_v1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_navigation_contract_v1()';

alter function private.display_assert_navigation_contract_v1() owner to portal_public_executor;

revoke all on function private.display_assert_navigation_contract_v1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_navigation_contract_v1() to portal_display_executor; reset role;

create function private.display_assert_navigation_projection_v1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_navigation_projection_v1()';

alter function private.display_assert_navigation_projection_v1() owner to portal_public_executor;

revoke all on function private.display_assert_navigation_projection_v1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_navigation_projection_v1() to portal_display_executor; reset role;

create function private.display_assert_process_keyword_rank_contract_cn1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_process_keyword_rank_contract_cn1()';

alter function private.display_assert_process_keyword_rank_contract_cn1() owner to portal_public_executor;

revoke all on function private.display_assert_process_keyword_rank_contract_cn1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_process_keyword_rank_contract_cn1() to portal_display_executor; reset role;

create function private.display_assert_sitemap_projection_v1() returns void language sql stable security definer set search_path='' as 'select private.assert_portal_sitemap_projection_v1()';

alter function private.display_assert_sitemap_projection_v1() owner to portal_public_executor;

revoke all on function private.display_assert_sitemap_projection_v1() from public;

set local role portal_public_executor; grant execute on function private.display_assert_sitemap_projection_v1() to portal_display_executor; reset role;

CREATE OR REPLACE FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_publication jsonb := private.display_publication_root_v1(p_kind, p_json);
  v_license text := private.display_scalar_text_v1(v_publication -> 'common:licenseType');
  v_exclusive jsonb := v_publication -> 'common:referenceToEntitiesWithExclusiveAccess';
  v_restrictions jsonb := v_publication -> 'common:accessRestrictions';
  v_exclusive_missing boolean;
  v_restrictions_open boolean;
  v_open boolean;
  v_reasons jsonb := '[]'::jsonb;
begin
  v_exclusive_missing := v_exclusive is null
    or v_exclusive = 'null'::jsonb;
  v_restrictions_open := private.display_access_restrictions_open_v1(v_restrictions);
  v_open := coalesce(v_license = 'Free of charge for all users and uses'
    and v_exclusive_missing
    and v_restrictions_open, false);

  if v_license is distinct from 'Free of charge for all users and uses' then
    v_reasons := v_reasons || '"license_not_fully_open"'::jsonb;
  end if;
  if not v_exclusive_missing then
    v_reasons := v_reasons || '"exclusive_access_declared"'::jsonb;
  end if;
  if not v_restrictions_open then
    v_reasons := v_reasons || '"access_restrictions_present"'::jsonb;
  end if;
  if v_open then
    v_reasons := '[]'::jsonb || '"public_license_confirmed"'::jsonb;
  end if;

  return jsonb_build_object(
    'metadataVisible', true,
    'exchangesVisible', v_open,
    'lciaVisible', false,
    'publicArtifactVisible', false,
    'citationVisible', true,
    'policyVersion', 'portal-capability-policy.v1',
    'reasonCodes', v_reasons
  );
end
$$;

ALTER FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_catalog_card_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_capabilities jsonb := private.display_capabilities_v1(p_kind, p_state_code, p_json);
  v_information jsonb;
  v_modelling jsonb;
  v_location jsonb;
  v_names jsonb := '[]'::jsonb;
  v_synonyms jsonb := '[]'::jsonb;
  v_summary jsonb := '[]'::jsonb;
  v_technology jsonb := '[]'::jsonb;
  v_geography jsonb;
  v_classifications jsonb := '[]'::jsonb;
  v_reference_year integer;
  v_process_subtype text;
  v_cas text;
  v_source_metadata jsonb;
  v_source text;
  v_document text;
begin
  if p_kind = 'process' then
    v_information := p_json #> '{processDataSet,processInformation}';
    v_modelling := p_json #> '{processDataSet,modellingAndValidation}';
    v_location := v_information #> '{geography,locationOfOperationSupplyOrProduction}';
    v_names := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,name,baseName}'
    );
    v_summary := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_technology := private.display_localized_text_v1(
      v_information #> '{technology,technologyDescriptionAndIncludedProcesses}'
    ) || private.display_localized_text_v1(
      v_information #> '{technology,technologicalApplicability}'
    );
    v_classifications := private.display_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_reference_year := private.display_safe_year_v1(
      v_information #>> '{time,common:referenceYear}'
    );
    v_process_subtype := nullif(private.display_scalar_text_v1(
      v_modelling #> '{LCIMethodAndAllocation,typeOfDataSet}'
    ), '');
    v_geography := jsonb_build_object(
      'code', nullif(private.display_scalar_text_v1(v_location -> '@location'), ''),
      'label', private.display_localized_text_v1(v_location -> 'descriptionOfRestrictions'),
      'precision', 'unknown'
    );
  elsif p_kind = 'flow' then
    v_information := p_json #> '{flowDataSet,flowInformation}';
    v_location := v_information -> 'geography';
    v_names := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,name,baseName}'
    );
    v_synonyms := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,common:synonyms}'
    );
    v_summary := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_classifications := private.display_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_cas := nullif(btrim(coalesce(
      v_information #>> '{dataSetInformation,CASNumber}',
      v_information #>> '{dataSetInformation,common:CASNumber}'
    )), '');
    if v_cas !~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$' then
      v_cas := null;
    end if;
    v_geography := jsonb_build_object(
      'code', case jsonb_typeof(v_location -> 'locationOfSupply')
        when 'string' then nullif(
          private.display_scalar_text_v1(v_location -> 'locationOfSupply'),
          ''
        )
        when 'object' then nullif(
          private.display_scalar_text_v1(v_location #> '{locationOfSupply,@location}'),
          ''
        )
        else null
      end,
      'label', private.display_localized_text_v1(
        v_location #> '{locationOfSupply,descriptionOfRestrictions}'
      ),
      'precision', 'unknown'
    );
  else
    return null;
  end if;

  v_source_metadata := private.display_source_v1(p_kind, p_json);
  select string_agg(item ->> 'value', ' ' order by item ->> 'language')
  into v_source
  from jsonb_array_elements(v_source_metadata -> 'providerName') as localized(item);
  select lower(concat_ws(' ',
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_names) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_synonyms) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_summary) as localized(item)),
    (select string_agg(item ->> 'code', ' ') from jsonb_array_elements(v_classifications) as classification(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_technology) as localized(item)),
    v_geography ->> 'code',
    v_reference_year::text,
    v_process_subtype,
    v_cas,
    v_source
  )) into v_document;
  return jsonb_build_object(
    'accessLevel', case when (v_capabilities ->> 'exchangesVisible')::boolean then 'open' else 'metadata_only' end,
    'capabilities', v_capabilities,
    'names', v_names,
    'summary', v_summary,
    'geography', v_geography,
    'referenceYear', to_jsonb(v_reference_year),
    'processSubtype', to_jsonb(v_process_subtype),
    'source', to_jsonb(v_source),
    'classifications', v_classifications,
    'casNumber', to_jsonb(v_cas),
    'document', to_jsonb(coalesce(v_document, ''))
  );
end
$_$;

ALTER FUNCTION "private"."display_catalog_card_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_card_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_catalog_card_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_capabilities jsonb := private.display_capabilities_v1(p_kind, p_state_code, p_json);
  v_information jsonb;
  v_modelling jsonb;
  v_location jsonb;
  v_names jsonb := '[]'::jsonb;
  v_synonyms jsonb := '[]'::jsonb;
  v_summary jsonb := '[]'::jsonb;
  v_technology jsonb := '[]'::jsonb;
  v_geography jsonb;
  v_classifications jsonb := '[]'::jsonb;
  v_reference_year integer;
  v_process_subtype text;
  v_cas text;
  v_source_metadata jsonb;
  v_source text;
  v_document text;
begin
  if p_kind = 'process' then
    v_information := p_json #> '{processDataSet,processInformation}';
    v_modelling := p_json #> '{processDataSet,modellingAndValidation}';
    v_location := v_information #> '{geography,locationOfOperationSupplyOrProduction}';
    v_names := private.display_process_names_v1(p_json);
    v_summary := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_technology := private.display_localized_text_v1(
      v_information #> '{technology,technologyDescriptionAndIncludedProcesses}'
    ) || private.display_localized_text_v1(
      v_information #> '{technology,technologicalApplicability}'
    );
    v_classifications := private.display_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_reference_year := private.display_safe_year_v1(
      v_information #>> '{time,common:referenceYear}'
    );
    v_process_subtype := nullif(private.display_scalar_text_v1(
      v_modelling #> '{LCIMethodAndAllocation,typeOfDataSet}'
    ), '');
    v_geography := jsonb_build_object(
      'code', nullif(private.display_scalar_text_v1(v_location -> '@location'), ''),
      'label', private.display_localized_text_v1(v_location -> 'descriptionOfRestrictions'),
      'precision', 'unknown'
    );
  elsif p_kind = 'flow' then
    v_information := p_json #> '{flowDataSet,flowInformation}';
    v_location := v_information -> 'geography';
    v_names := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,name,baseName}'
    );
    v_synonyms := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,common:synonyms}'
    );
    v_summary := private.display_localized_text_v1(
      v_information #> '{dataSetInformation,common:generalComment}'
    );
    v_classifications := private.display_classifications_v1(
      v_information #> '{dataSetInformation,classificationInformation}'
    );
    v_cas := nullif(btrim(coalesce(
      v_information #>> '{dataSetInformation,CASNumber}',
      v_information #>> '{dataSetInformation,common:CASNumber}'
    )), '');
    if v_cas !~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$' then
      v_cas := null;
    end if;
    v_geography := jsonb_build_object(
      'code', case jsonb_typeof(v_location -> 'locationOfSupply')
        when 'string' then nullif(
          private.display_scalar_text_v1(v_location -> 'locationOfSupply'),
          ''
        )
        when 'object' then nullif(
          private.display_scalar_text_v1(v_location #> '{locationOfSupply,@location}'),
          ''
        )
        else null
      end,
      'label', private.display_localized_text_v1(
        v_location #> '{locationOfSupply,descriptionOfRestrictions}'
      ),
      'precision', 'unknown'
    );
  else
    return null;
  end if;

  v_source_metadata := private.display_source_v1(p_kind, p_json);
  select string_agg(item ->> 'value', ' ' order by item ->> 'language')
  into v_source
  from jsonb_array_elements(v_source_metadata -> 'providerName') as localized(item);
  select lower(concat_ws(' ',
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_names) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_synonyms) as localized(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_summary) as localized(item)),
    (select string_agg(item ->> 'code', ' ') from jsonb_array_elements(v_classifications) as classification(item)),
    (select string_agg(item ->> 'value', ' ') from jsonb_array_elements(v_technology) as localized(item)),
    v_geography ->> 'code',
    v_reference_year::text,
    v_process_subtype,
    v_cas,
    v_source
  )) into v_document;
  return jsonb_build_object(
    'accessLevel', case when (v_capabilities ->> 'exchangesVisible')::boolean then 'open' else 'metadata_only' end,
    'capabilities', v_capabilities,
    'names', v_names,
    'summary', v_summary,
    'geography', v_geography,
    'referenceYear', to_jsonb(v_reference_year),
    'processSubtype', to_jsonb(v_process_subtype),
    'source', to_jsonb(v_source),
    'classifications', v_classifications,
    'casNumber', to_jsonb(v_cas),
    'document', to_jsonb(coalesce(v_document, ''))
  );
end
$_$;

ALTER FUNCTION "private"."display_catalog_card_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_card_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_catalog_projection_payload_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
declare
  v_card jsonb;
begin
  v_card := private.display_catalog_card_v1(
    p_kind,
    p_state_code,
    p_json
  );
  if pg_catalog.jsonb_typeof(v_card) <> 'object' then
    return null;
  end if;
  return pg_catalog.jsonb_build_object(
    'card', v_card,
    'document', coalesce(v_card ->> 'document', '')
  );
end
$$;

ALTER FUNCTION "private"."display_catalog_projection_payload_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_projection_payload_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;





CREATE OR REPLACE FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
declare
  v_card jsonb;
begin
  v_card := private.display_catalog_card_cn1(
    p_kind,
    p_state_code,
    p_json
  );
  if pg_catalog.jsonb_typeof(v_card) <> 'object' then
    return null;
  end if;
  return pg_catalog.jsonb_build_object(
    'card', v_card,
    'document', coalesce(v_card ->> 'document', '')
  );
end
$$;

ALTER FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;





CREATE OR REPLACE FUNCTION "private"."display_sync_catalog_character_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  insert into private.display_catalog_character_rows_v1 (
    dataset_kind,
    id,
    version,
    state_code,
    modified_at,
    document_characters,
    name_characters,
    name_exact_characters,
    classification_characters,
    classification_exact_characters,
    character_contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.state_code,
    new.modified_at,
    private.display_catalog_character_set_v1(new.document),
    private.display_catalog_character_field_set_v1(
      new.card -> 'names', 'value', false
    ),
    private.display_catalog_character_field_set_v1(
      new.card -> 'names', 'value', true
    ),
    private.display_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', false
    ),
    private.display_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', true
    ),
    1
  )
  on conflict (dataset_kind, id, version) do update
  set state_code = excluded.state_code,
      modified_at = excluded.modified_at,
      document_characters = excluded.document_characters,
      name_characters = excluded.name_characters,
      name_exact_characters = excluded.name_exact_characters,
      classification_characters = excluded.classification_characters,
      classification_exact_characters =
        excluded.classification_exact_characters,
      character_contract_version = excluded.character_contract_version;
  return new;
end
$$;

ALTER FUNCTION "private"."display_sync_catalog_character_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_catalog_character_row_v1"() FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_sync_catalog_character_row_cn1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  insert into private.display_catalog_character_rows_v2 (
    dataset_kind,
    id,
    version,
    state_code,
    modified_at,
    document_characters,
    name_characters,
    name_exact_characters,
    classification_characters,
    classification_exact_characters,
    character_contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.state_code,
    new.modified_at,
    private.display_catalog_character_set_v1(new.document),
    private.display_catalog_character_field_set_v1(
      new.card -> 'names', 'value', false
    ),
    private.display_catalog_character_field_set_v1(
      new.card -> 'names', 'value', true
    ),
    private.display_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', false
    ),
    private.display_catalog_character_field_set_v1(
      new.card -> 'classifications', 'code', true
    ),
    1
  )
  on conflict (dataset_kind, id, version) do update
  set state_code = excluded.state_code,
      modified_at = excluded.modified_at,
      document_characters = excluded.document_characters,
      name_characters = excluded.name_characters,
      name_exact_characters = excluded.name_exact_characters,
      classification_characters = excluded.classification_characters,
      classification_exact_characters =
        excluded.classification_exact_characters,
      character_contract_version = excluded.character_contract_version;
  return new;
end
$$;

ALTER FUNCTION "private"."display_sync_catalog_character_row_cn1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_catalog_character_row_cn1"() FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_sync_catalog_facet_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
declare
  v_facts record;
begin
  select facts.*
  into strict v_facts
  from private.display_catalog_facet_facts_v1(
    new.dataset_kind,
    new.card
  ) as facts;

  insert into private.display_catalog_facet_rows_v1 (
    dataset_kind,
    id,
    version,
    state_code,
    modified_at,
    facet_access_level,
    facet_geography,
    facet_reference_year,
    facet_process_subtype,
    facet_source,
    facet_contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.state_code,
    new.modified_at,
    v_facts.facet_access_level,
    v_facts.facet_geography,
    v_facts.facet_reference_year,
    v_facts.facet_process_subtype,
    v_facts.facet_source,
    1
  )
  on conflict (dataset_kind, id, version) do update
  set state_code = excluded.state_code,
      modified_at = excluded.modified_at,
      facet_access_level = excluded.facet_access_level,
      facet_geography = excluded.facet_geography,
      facet_reference_year = excluded.facet_reference_year,
      facet_process_subtype = excluded.facet_process_subtype,
      facet_source = excluded.facet_source,
      facet_contract_version = excluded.facet_contract_version;

  return new;
end
$$;

ALTER FUNCTION "private"."display_sync_catalog_facet_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_catalog_facet_row_v1"() FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_sync_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $_$
declare
  v_entry jsonb;
  v_entry_level integer;
  v_placement text;
  v_placements text[] := '{}'::text[];
  v_node text;
  v_code text;
  v_taxonomy text;
  v_raw_root text;
  v_geography text;
  v_matched integer := 0;
  v_raw_parent text;
begin
  insert into private.display_navigation_versions_v1 (
    dataset_kind,id,version,access_level,geography_code,classification_codes,
    reference_year,process_subtype,source
  ) values (
    p_kind,p_id,p_version,p_card->>'accessLevel',
    lower(btrim(p_card#>>'{geography,code}')),
    array(select distinct lower(btrim(entry->>'code'))
      from jsonb_array_elements(coalesce(p_card->'classifications','[]'::jsonb)) entry
      where nullif(btrim(entry->>'code'),'') is not null),
    (p_card->>'referenceYear')::integer,
    lower(btrim(p_card->>'processSubtype')),lower(btrim(p_card->>'source'))
  ) on conflict (dataset_kind,id,version) do update set
    access_level=excluded.access_level,geography_code=excluded.geography_code,
    classification_codes=excluded.classification_codes,reference_year=excluded.reference_year,
    process_subtype=excluded.process_subtype,source=excluded.source
  where (display_navigation_versions_v1.access_level,display_navigation_versions_v1.geography_code,
    display_navigation_versions_v1.classification_codes,display_navigation_versions_v1.reference_year,
    display_navigation_versions_v1.process_subtype,display_navigation_versions_v1.source)
    is distinct from (excluded.access_level,excluded.geography_code,excluded.classification_codes,
      excluded.reference_year,excluded.process_subtype,excluded.source);
  delete from private.display_navigation_membership_v1
    where dataset_kind=p_kind and id=p_id and version=p_version;
  for v_entry, v_entry_level in
    select distinct entry.value, (entry.ordinality - 1)::integer as level
    from pg_catalog.jsonb_array_elements(
      case pg_catalog.jsonb_typeof(p_card -> 'classifications')
        when 'array' then p_card -> 'classifications'
        else '[]'::jsonb
      end
    ) with ordinality as entry(value, ordinality)
    where pg_catalog.jsonb_typeof(entry.value) = 'object'
  loop
    v_node := private.display_navigation_resolve_classification_v1(
      p_kind, v_entry -> 'system', v_entry, v_entry_level
    );
    if v_node is null then
      -- Keep the unknown/ambiguous authored code browsable under its own
      -- taxonomy instead of dropping it or guessing a node.
      v_code := private.display_navigation_classification_code_v1(v_entry);
      if v_code is null then
        continue;
      end if;
      v_taxonomy := private.display_navigation_raw_taxonomy_v1(v_entry -> 'system');
      if (p_kind='flow' and v_taxonomy='isic') or (p_kind='process' and v_taxonomy in ('cpc','elementary')) then
        v_taxonomy := 'unclassified';
      end if;
      v_raw_root := 'class:' || v_taxonomy || ':~raw';
      perform private.display_navigation_ensure_virtual_v1(
        v_raw_root, 'classification', v_taxonomy, 'unmapped'
      );
      v_node := private.display_navigation_raw_node_id_v1('class:' || v_taxonomy, p_kind || '|' || coalesce(v_entry->>'system','') || '|' || v_code);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_root, v_code, v_taxonomy, 'classification', null, null,
        pg_catalog.jsonb_build_object(
          'en', v_code, 'zh-CN', v_code, 'de', v_code, 'fr', v_code
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
    v_matched := v_matched + 1;
    v_placements := pg_catalog.array_append(v_placements, v_node);
  end loop;

  if v_matched = 0 then
    perform private.display_navigation_ensure_virtual_v1(
      'class:unclassified', 'classification', 'unclassified', 'unclassified'
    );
    v_placements := pg_catalog.array_append(v_placements, 'class:unclassified');
  end if;

  v_geography := private.display_navigation_geography_code_v1(p_kind, p_card);
  if v_geography is not null then
    v_node := 'geo:' || pg_catalog.lower(v_geography);
    if not exists(select 1 from private.portal_navigation_node_v1 n where n.node_id=v_node and n.dimension='geography') then
      v_node := coalesce(private.display_navigation_resolve_alias_v1('geography',v_geography),v_node);
    end if;
    if not exists (
      select 1
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_node and node.dimension = 'geography'
    ) then
      perform private.display_navigation_ensure_virtual_v1(
        'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
      );
      v_raw_parent := 'geo:unmapped';
      -- This verified code family is only a containing province, never proof of
      -- a particular city boundary or geographic precision.
      if upper(v_geography) ~ '^CN-[A-Z]{2}-[A-Z0-9-]+$' then
        select node.node_id into v_raw_parent from private.portal_navigation_node_v1 node
        where node.node_id='geo:' || lower(split_part(v_geography,'-',1)||'-'||split_part(v_geography,'-',2))
          and node.parent_node_id='geo:cn';
      end if;
      v_raw_parent := coalesce(v_raw_parent,'geo:unmapped');
      v_node := private.display_navigation_raw_node_id_v1('geo', v_geography);
      insert into private.portal_navigation_node_v1 (
        node_id, parent_node_id, code, taxonomy, dimension,
        source_index_path, source_file, labels, label_strategy
      ) values (
        v_node, v_raw_parent, pg_catalog.upper(v_geography), 'unmapped', 'geography',
        null, null,
        pg_catalog.jsonb_build_object(
          'en', pg_catalog.upper(v_geography), 'zh-CN', pg_catalog.upper(v_geography),
          'de', pg_catalog.upper(v_geography), 'fr', pg_catalog.upper(v_geography)
        ),
        pg_catalog.jsonb_build_object(
          'en', 'unavailable', 'zh-CN', 'unavailable',
          'de', 'unavailable', 'fr', 'unavailable'
        )
      )
      on conflict (node_id) do nothing;
    end if;
  else
    perform private.display_navigation_ensure_virtual_v1(
      'geo:unmapped', 'geography', 'database-virtual', 'unmapped'
    );
    v_node := 'geo:unmapped';
  end if;
  v_placements := pg_catalog.array_append(v_placements, v_node);

  -- Materialise every ancestor of every authored placement, so a branch count is
  -- one grouped read instead of a per-node descendant search. A closure row is
  -- `direct` only when the authored placement is exactly that node.
  with recursive ancestors as (
    select n.node_id as leaf,n.parent_node_id as ancestor
    from private.portal_navigation_node_v1 n where n.node_id=any(v_placements)
    union all
    select a.leaf,n.parent_node_id from ancestors a
    join private.portal_navigation_node_v1 n on n.node_id=a.ancestor
    where a.ancestor is not null
  ) select coalesce(array_agg(distinct placement), '{}'::text[]) into v_placements
    from unnest(v_placements) placement
    where not exists(select 1 from ancestors a where a.ancestor=placement);

  foreach v_placement in array v_placements
  loop
    insert into private.display_navigation_membership_v1 (
      dataset_kind, id, version, dimension, node_id, direct
    )
    with recursive chain as (
      select node.node_id,
        node.parent_node_id,
        node.dimension
      from private.portal_navigation_node_v1 as node
      where node.node_id = v_placement
      union all
      select parent.node_id,
        parent.parent_node_id,
        parent.dimension
      from private.portal_navigation_node_v1 as parent
      join chain on parent.node_id = chain.parent_node_id
    )
    select p_kind, p_id, p_version, chain.dimension, chain.node_id,
      chain.node_id = v_placement
    from chain
    on conflict (dataset_kind,id,version,dimension,node_id) do update
      set direct=private.display_navigation_membership_v1.direct or excluded.direct;
  end loop;
end;
$_$;

ALTER FUNCTION "private"."display_sync_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_navigation_membership_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_card" "jsonb") FROM PUBLIC;





CREATE OR REPLACE FUNCTION "private"."display_sync_navigation_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  if tg_op='DELETE' then
    delete from private.display_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
    return old;
  end if;
  if tg_op='UPDATE' and (old.dataset_kind,old.id,old.version) is distinct from (new.dataset_kind,new.id,new.version) then
    delete from private.display_navigation_versions_v1 where dataset_kind=old.dataset_kind and id=old.id and version=old.version;
  end if;
  perform private.display_sync_navigation_membership_v1(new.dataset_kind,new.id,new.version,new.card);
  return new;
end;
$$;

ALTER FUNCTION "private"."display_sync_navigation_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_navigation_row_v1"() FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_sync_sitemap_row_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
begin
  insert into private.display_sitemap_rows_v1 (
    dataset_kind,
    id,
    version,
    modified_at,
    shard_no,
    contract_version
  ) values (
    new.dataset_kind,
    new.id,
    new.version,
    new.modified_at,
    (
      pg_catalog.get_byte(
        pg_catalog.decode(
          pg_catalog.md5(
            new.dataset_kind || ':'::text || new.id::text
          ),
          'hex'::text
        ),
        0
      ) / 4
    )::smallint,
    1
  )
  on conflict (dataset_kind, id, version) do update
  set modified_at = excluded.modified_at,
      shard_no = excluded.shard_no,
      contract_version = excluded.contract_version
  where (
    display_sitemap_rows_v1.modified_at,
    display_sitemap_rows_v1.shard_no,
    display_sitemap_rows_v1.contract_version
  ) is distinct from (
    excluded.modified_at,
    excluded.shard_no,
    excluded.contract_version
  );
  return null;
end
$$;

ALTER FUNCTION "private"."display_sync_sitemap_row_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_sync_sitemap_row_v1"() FROM PUBLIC;




set local role portal_display_executor; grant execute on function "private"."display_catalog_facet_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_source_v1"("p_kind" "text", "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_cursor_encode_v1"("p_payload" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facets_v1_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_matched_versions_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_hybrid_search_v1_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_search_v1_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_classification_label_v1"("p_value" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_process_exact_cn1"("p_query_embedding" "extensions"."vector") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_named_reference_v1"("p_reference" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_reference_flowproperty_v1"("p_flow_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_resolve_classification_v1"("p_kind" "text", "p_system" "jsonb", "p_value" "jsonb", "p_level" integer) to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_navigation_ensure_virtual_v1"("p_node_id" "text", "p_dimension" "text", "p_taxonomy" "text", "p_labels_key" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_dataset_rows_v1"("p_kind" "text", "p_id" "uuid") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_rows_v1"("p_kind" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_process_rank_classification_keys_v1"("p_card" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_summary_valid_cas_v1"("p_value" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facet_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_character_set_v1"("p_value" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_search_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_lcia_decorate_dataset_v1"("p_envelope" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_canonical_decimal_v1"("p_value" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_process_keyword_keys_cn1"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_timestamp_v1"("p_value" timestamp with time zone) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facets_empty_v1_impl"("p_kind" "text", "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_flow_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_lcia_projection_is_public_v1"("p_projection_id" "uuid") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_single_character_search_v1_impl"("p_kind" "text", "p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_validate_search_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_version_matches_v3"("p_kind" "text", "p_filters" "jsonb", "p_id" "uuid", "p_version" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_decorate_card_context_v1"("p_page" "jsonb") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_catalog_card_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_cursor_decode_v1"("p_cursor" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_card_facts_v1"("p_card" "jsonb", "p_filters" "jsonb", "p_query" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_process_open_capability_bridge_v1"("p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_exchange_support_v1"("p_process_state" integer, "p_process_json" "jsonb", "p_exchange" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_process_v2"("p_query_embedding" "extensions"."vector", "p_filters" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_json_items_v1"("p_value" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_public_hybrid_input_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_process_names_v1"("p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_flow_v1"("p_query_embedding" "extensions"."vector") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_character_field_set_v1"("p_items" "jsonb", "p_key" "text", "p_exact_one" boolean) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_flow_single_character_versions_v1"("p_literal" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_summary_label_v1"("p_card" "jsonb") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_card_matches_filters_v2"("p_card" "jsonb", "p_filters" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_process_keyword_relevance_cn1_impl"("p_query" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_catalog_projection_payload_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_lcia_projection_frame_v1"(VARIADIC "p_fields" "text"[]) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_classifications_v1"("p_information" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_process_functional_unit_v1"("p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_datetime_v1"("p_value" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_safe_year_v1"("p_value" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_geography_precision_v1"("p_code" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_search_v3_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_raw_taxonomy_v1"("p_system" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_classification_code_v1"("p_value" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_support_capabilities_v1"("p_kind" "text", "p_state_code" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_hybrid_search_v2_impl"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb", "p_limit" integer, "p_query_fingerprint" "text", "p_cursor" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_lcia_decorate_item_page_v1"("p_page" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_geography_code_v1"("p_kind" "text", "p_card" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_raw_node_id_v1"("p_scope" "text", "p_code" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_process_v1"("p_query_embedding" "extensions"."vector") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_first_text_v1"("p_value" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_card_context_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_dataset_projection_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_hybrid_candidates_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facets_v2_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_localized_text_v1"("p_value" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_lcia_json_object_has_keys_v1"("p_value" "jsonb", "p_keys" "text"[]) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_process_single_character_versions_v1"("p_literal" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facet_facts_v1"("p_kind" "text", "p_card" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_hybrid_pattern_matches_v1"("p_kind" "text", "p_query_terms" "text"[]) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_flow_kind_v1"("p_type" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_validate_search_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_catalog_card_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_access_restrictions_open_v1"("p_value" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_normalize_filters_v1"("p_filters" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_scalar_text_v1"("p_value" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_process_pattern_versions_v1"("p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_resolve_alias_v1"("p_dimension" "text", "p_code" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_process_reference_product_v1"("p_json" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_process_rank_name_keys_v1"("p_card" "jsonb") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_candidate_rows_v2"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facet_candidate_rows_v1"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facets_v3_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_lcia_projection_sha256_fields_v1"(VARIADIC "p_fields" "text"[]) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_virtual_labels_v1"("p_key" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_facets_empty_v2_impl"("p_kind" "text", "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_projection_semantic_flow_exact_v1"("p_query_embedding" "extensions"."vector") to portal_display_executor,postgres; reset role;

set local role postgres; grant execute on function "private"."display_current_lcia_publication_for_process_v1"("p_process_id" "uuid", "p_process_version" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_search_v2_impl"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor_rank" "text", "p_cursor_id" "uuid", "p_cursor_version" "text", "p_limit" integer, "p_query_fingerprint" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_catalog_flow_pattern_versions_v1"("p_like_pattern" "text") to portal_display_executor,postgres; reset role;

set local role portal_display_executor; grant execute on function "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") to portal_display_executor,postgres; reset role;

create function private.portal_display_brand_decorate_v1(p_value jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb:=p_value; k jsonb; b text; a jsonb; e record;
begin
 if jsonb_typeof(r)='array' then
  select coalesce(jsonb_agg(private.portal_display_brand_decorate_v1(value) order by ord),'[]') into r
  from jsonb_array_elements(r) with ordinality x(value,ord); return r;
 elsif jsonb_typeof(r) is distinct from 'object' then return r; end if;
 k:=r->'key';
 if k->>'kind' in ('process','flow') and k->>'id' is not null and not (r ? 'matches') then
  select brand into b from private.dataset_display_settings
  where dataset_kind=k->>'kind' and dataset_id=(k->>'id')::uuid and dataset_version=k->>'version' and is_visible;
  r:=r||jsonb_build_object('brand',private.portal_brand_v1(b));
 end if;
 foreach b in array array['items','versionGroups','versions','matches'] loop
  if r ? b then r:=jsonb_set(r,array[b],private.portal_display_brand_decorate_v1(r->b)); end if;
 end loop;
 return r;
end $$;
revoke all on function private.portal_display_brand_decorate_v1(jsonb) from public;
grant execute on function private.portal_display_brand_decorate_v1(jsonb) to portal_display_executor;


CREATE OR REPLACE FUNCTION "private"."display_api_search_processes_v3"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.display_decorate_card_context_v1(
    private.display_lcia_decorate_item_page_v1(
      private.display_search_v3(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;

ALTER FUNCTION "private"."display_api_search_processes_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_search_processes_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




grant execute on function private.display_api_search_processes_v3("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor;

create function api.portal_search_processes_v4(p_allowed_brands text[], "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_search_processes_v3(p_query, p_filters - 'brand', p_sort, p_cursor, p_limit)),'{schemaVersion}',to_jsonb('portal.public-search-page.v3'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_search_processes_v4(text[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) owner to portal_display_executor;
revoke all on function api.portal_search_processes_v4(text[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) from public;
grant execute on function api.portal_search_processes_v4(text[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_search_flows_v3"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.display_decorate_card_context_v1(
    private.display_search_v3(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;

ALTER FUNCTION "private"."display_api_search_flows_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_search_flows_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




grant execute on function private.display_api_search_flows_v3("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor;

create function api.portal_search_flows_v4(p_allowed_brands text[], "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_search_flows_v3(p_query, p_filters - 'brand', p_sort, p_cursor, p_limit)),'{schemaVersion}',to_jsonb('portal.public-search-page.v3'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_search_flows_v4(text[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) owner to portal_display_executor;
revoke all on function api.portal_search_flows_v4(text[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) from public;
grant execute on function api.portal_search_flows_v4(text[], "p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.display_assert_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.display_validate_search_v3(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.display_normalize_filters_v1(p_filters);
  v_fingerprint := private.display_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v3:' || (select asset_sha256 from private.display_read_navigation_contract_v1 where contract_version=1) || ':' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.display_assert_catalog_facet_contract_v1();
    return private.display_catalog_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.display_catalog_facets_v3_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_api_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;




grant execute on function private.display_api_facets_v3("p_kind" "text", "p_query" "text", "p_filters" "jsonb") to portal_display_executor;

create function api.portal_facets_v4(p_allowed_brands text[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=private.portal_display_brand_facets_v1(jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_facets_v3(p_kind, p_query, p_filters - 'brand')),'{schemaVersion}',to_jsonb('portal.public-facets.v3'::text)),p_kind,p_query,p_filters - 'brand');
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_facets_v4(text[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb") owner to portal_display_executor;
revoke all on function api.portal_facets_v4(text[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb") from public;
grant execute on function api.portal_facets_v4(text[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb") to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_navigation_v1"("p_kind" "text", "p_query" "text" DEFAULT ''::"text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_dimension" "text" DEFAULT 'classification'::"text", "p_parent_node_id" "text" DEFAULT NULL::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "row_security" TO 'on'
    AS $$
declare
  v_diagnostic_message text;
  v_diagnostic_context text;
  v_diagnostic_state text;
begin
  return private.display_navigation_v1(p_kind,p_query,p_filters,p_dimension,p_parent_node_id,p_cursor,p_limit);
exception
  when sqlstate '22023' then
    get stacked diagnostics v_diagnostic_context = PG_EXCEPTION_CONTEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'display_navigation_v1',
        'category', 'validation', 'reason', case
          when v_diagnostic_context ~ '^PL/pgSQL function private\.display_validate_search_v1\(' then 'search_input'
          when v_diagnostic_context ~ '^PL/pgSQL function private\.display_validate_search_v3\(' then 'hierarchy_input'
          when v_diagnostic_context ~ '^PL/pgSQL function private\.display_navigation_impl_v1\(' then
            case when p_cursor is null then 'parent' else 'parent_or_cursor_node' end
          when v_diagnostic_context ~ '^PL/pgSQL function private\.display_navigation_v1\(' then
            case
              when p_dimension is null or p_dimension not in ('classification', 'geography')
                or coalesce(p_limit, 100) not between 1 and 500 then 'navigation_options'
              when p_cursor is not null then 'cursor_binding'
              else 'unknown'
            end
          else 'unknown'
        end
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'display_navigation_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'display_navigation_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;

ALTER FUNCTION "private"."display_api_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




grant execute on function private.display_api_navigation_v1("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor;

create function api.portal_navigation_v2(p_allowed_brands text[], "p_kind" "text", "p_query" "text" DEFAULT ''::"text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_dimension" "text" DEFAULT 'classification'::"text", "p_parent_node_id" "text" DEFAULT NULL::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 100) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_navigation_v1(p_kind, p_query, p_filters - 'brand', p_dimension, p_parent_node_id, p_cursor, p_limit)),'{schemaVersion}',to_jsonb('portal.public-navigation.v2'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_navigation_v2(text[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) owner to portal_display_executor;
revoke all on function api.portal_navigation_v2(text[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) from public;
grant execute on function api.portal_navigation_v2(text[], "p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
begin
  if p_kind not in ('process', 'flow')
     or p_id is null
     or p_version is null
     or p_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  return private.display_lcia_decorate_dataset_v1(
    private.display_dataset_projection_v1(p_kind, p_id, p_version)
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_api_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;




grant execute on function private.display_api_get_dataset_v1("p_kind" "text", "p_id" "uuid", "p_version" "text") to portal_display_executor;

create function api.portal_get_dataset_v2(p_allowed_brands text[], "p_kind" "text", "p_id" "uuid", "p_version" "text") returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_get_dataset_v1(p_kind, p_id, p_version)),'{schemaVersion}',to_jsonb('portal.public-dataset.v2'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_get_dataset_v2(text[], "p_kind" "text", "p_id" "uuid", "p_version" "text") owner to portal_display_executor;
revoke all on function api.portal_get_dataset_v2(text[], "p_kind" "text", "p_id" "uuid", "p_version" "text") from public;
grant execute on function api.portal_get_dataset_v2(text[], "p_kind" "text", "p_id" "uuid", "p_version" "text") to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_list_versions_v1"("p_kind" "text", "p_id" "uuid", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_cursor jsonb;
  v_cursor_version text;
  v_items jsonb;
  v_next_cursor text;
begin
  if p_kind not in ('process', 'flow')
     or p_id is null
     or p_limit is null
     or p_limit not between 1 and 50 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 4
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'kind' <> p_kind
       or v_cursor ->> 'id' <> p_id::text
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_version := v_cursor ->> 'version';
  end if;

  with all_versions as materialized (
    select source.*,
      row_number() over (order by source.version desc) = 1 as is_latest,
      private.display_capabilities_v1(
        p_kind, source.state_code, source.json_data
      ) as capabilities
    from private.display_dataset_rows_v1(p_kind, p_id) as source
  ), ordered as materialized (
    select all_versions.*,
      row_number() over (order by all_versions.version desc) as page_rank
    from all_versions
    where v_cursor_version is null or all_versions.version < v_cursor_version
    order by all_versions.version desc
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'key', jsonb_build_object(
        'kind', p_kind,
        'id', ordered.id::text,
        'version', ordered.version
      ),
      'accessLevel', case
        when (ordered.capabilities ->> 'exchangesVisible')::boolean
          then 'open'
        else 'metadata_only'
      end,
      'capabilities', ordered.capabilities,
      'modifiedAt', private.display_timestamp_v1(ordered.modified_at),
      'isLatest', ordered.is_latest
    ) order by ordered.page_rank)
      filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit
      then private.display_cursor_encode_v1(
        (jsonb_agg(jsonb_build_object(
          'v', 1,
          'kind', p_kind,
          'id', p_id::text,
          'version', ordered.version
        ) order by ordered.page_rank)
          filter (where ordered.page_rank = p_limit)) -> 0
      )
      else null
    end
  into v_items, v_next_cursor
  from ordered;

  return private.display_lcia_decorate_item_page_v1(
    jsonb_build_object(
      'schemaVersion', 'portal.public-version-page.v1',
      'dataset', jsonb_build_object('kind', p_kind, 'id', p_id::text),
      'items', v_items,
      'nextCursor', v_next_cursor
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_list_versions_v1"("p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_list_versions_v1"("p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




grant execute on function private.display_api_list_versions_v1("p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) to portal_display_executor;

create function api.portal_list_versions_v2(p_allowed_brands text[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_list_versions_v1(p_kind, p_id, p_cursor, p_limit)),'{schemaVersion}',to_jsonb('portal.public-version-page.v2'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_list_versions_v2(text[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) owner to portal_display_executor;
revoke all on function api.portal_list_versions_v2(text[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) from public;
grant execute on function api.portal_list_versions_v2(text[], "p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text" DEFAULT 'all'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_process_json jsonb;
  v_process_state integer;
  v_functional_unit jsonb;
  v_cursor jsonb;
  v_cursor_internal integer;
  v_cursor_internal_text text;
  v_cursor_kind text;
  v_rows jsonb;
  v_next_cursor text;
begin
  if pg_catalog.octet_length(coalesce(p_exchange_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := lower(btrim(coalesce(p_exchange_kind, 'all')));
  if p_process_id is null
     or p_process_version is null
     or p_process_version !~ '^\d{2}\.\d{2}\.\d{3}$'
     or v_kind not in ('all', 'technosphere', 'elementary', 'waste')
     or p_limit is null
     or p_limit not between 1 and 50 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select row.json, row.state_code
  into v_process_json, v_process_state
  from public.processes as row
  where row.id = p_process_id
    and row.version::text = p_process_version
    and private.portal_display_request_visible_v1('process',row.id,row.version::text)
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'processDataSet') = 'object'
  limit 1;
  if v_process_json is null then
    return null;
  end if;
  v_functional_unit := private.display_process_functional_unit_v1(v_process_state, v_process_json);

  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'processId' <> p_process_id::text
       or v_cursor ->> 'processVersion' <> p_process_version
       or v_cursor ->> 'filterKind' <> v_kind
       or coalesce(v_cursor ->> 'internalId', '') !~ '^(0|[1-9][0-9]{0,5})$'
       or v_cursor ->> 'kind' not in ('technosphere', 'elementary', 'waste') then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_internal_text := v_cursor ->> 'internalId';
    v_cursor_internal := v_cursor_internal_text::integer;
    v_cursor_kind := v_cursor ->> 'kind';
  end if;

  with raw_exchanges as materialized (
    select exchange.item,
      exchange.item ->> '@dataSetInternalID' as internal_id,
      count(*) over (partition by exchange.item ->> '@dataSetInternalID') as identity_count
    from private.display_json_items_v1(v_process_json #> '{processDataSet,exchanges,exchange}') as exchange(item)
  ), supported as materialized (
    select support -> 'row' as row_data
    from raw_exchanges
    cross join lateral private.display_exchange_support_v1(v_process_state, v_process_json, raw_exchanges.item) as support
    where raw_exchanges.identity_count = 1
      and nullif(v_functional_unit ->> 'amount', '') is not null
      and nullif(v_functional_unit ->> 'unit', '') is not null
      and support is not null
  ), filtered as materialized (
    select supported.row_data,
      (supported.row_data ->> 'internalId')::integer as internal_number,
      supported.row_data ->> 'internalId' as internal_text,
      supported.row_data ->> 'kind' as row_kind
    from supported
    where v_kind = 'all' or supported.row_data ->> 'kind' = v_kind
  ), ordered as materialized (
    select filtered.*,
      row_number() over (order by filtered.internal_number, filtered.internal_text, filtered.row_kind) as page_rank
    from filtered
    where v_cursor is null
      or (filtered.internal_number, filtered.internal_text, filtered.row_kind) >
         (v_cursor_internal, v_cursor_internal_text, v_cursor_kind)
    order by filtered.internal_number, filtered.internal_text, filtered.row_kind
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(ordered.row_data order by ordered.page_rank)
      filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit then private.display_cursor_encode_v1(
      (jsonb_agg(jsonb_build_object(
        'v', 1,
        'processId', p_process_id::text,
        'processVersion', p_process_version,
        'filterKind', v_kind,
        'internalId', ordered.internal_text,
        'kind', ordered.row_kind
      ) order by ordered.page_rank) filter (where ordered.page_rank = p_limit)) -> 0
    ) else null end
  into v_rows, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.public-exchange-page.v1',
    'process', jsonb_build_object('id', p_process_id::text, 'version', p_process_version),
    'processContext', jsonb_build_object(
      'functionalUnit', v_functional_unit,
      'capabilityPolicyVersion', 'portal-capability-policy.v1'
    ),
    'rows', v_rows,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




grant execute on function private.display_api_list_process_exchanges_v1("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor;

create function api.portal_list_process_exchanges_v2(p_allowed_brands text[], "p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text" DEFAULT 'all'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=private.display_api_list_process_exchanges_v1(p_process_id, p_process_version, p_exchange_kind, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_list_process_exchanges_v2(text[], "p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) owner to portal_display_executor;
revoke all on function api.portal_list_process_exchanges_v2(text[], "p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) from public;
grant execute on function api.portal_list_process_exchanges_v2(text[], "p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_catalog_summary_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '2s'
    SET "work_mem" TO '32MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $_$

declare
  v_diagnostic_message text;
  v_diagnostic_state text;
  v_counts jsonb;
  v_latest_modified_at text;
  v_uuid_example jsonb;
  v_cas_example jsonb;
  v_classification_example jsonb;
  v_result jsonb;
begin
  perform private.display_assert_catalog_projection_contract_cn1();
  perform private.display_assert_catalog_facet_contract_v1();

  with latest as materialized (
    select distinct on (facet.dataset_kind, facet.id)
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.modified_at,
      facet.state_code
    from private.display_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1
    order by facet.dataset_kind,
      facet.id,
      facet.version desc,
      facet.modified_at desc,
      facet.state_code desc
  ), counts as (
    select pg_catalog.jsonb_build_object(
        'process', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'process'
        ),
        'flow', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'flow'
        ),
        'total', pg_catalog.count(*)
      ) as value,
      private.display_timestamp_v1(
        pg_catalog.max(latest.modified_at)
      ) as latest_modified_at
    from latest
  ), uuid_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.display_catalog_summary_label_v1(candidate.card) as label
      from private.display_catalog_search_rows_v2 as candidate
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.display_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.display_catalog_summary_label_v1(candidate.card) as label
      from private.display_catalog_search_rows_v1 as candidate
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.display_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
  ), uuid_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'uuid',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.id::text,
      'label', candidate.label
    ) as value
    from uuid_candidates as candidate
    order by candidate.preference
    limit 1
  ), cas_unique_values as materialized (
    select candidate.card ->> 'casNumber' as cas_number,
      pg_catalog.min(candidate.id::text)::uuid as id
    from private.display_catalog_search_rows_v1 as candidate
    where candidate.dataset_kind = 'flow'
      and pg_catalog.jsonb_typeof(candidate.card -> 'casNumber') = 'string'
      and candidate.card ->> 'casNumber' ~
        '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(
        candidate.card ->> 'casNumber'
      ) between 7 and 12
      and private.display_catalog_summary_valid_cas_v1(
        candidate.card ->> 'casNumber'
      )
    group by candidate.card ->> 'casNumber'
    having pg_catalog.count(*) = 1
    order by candidate.card ->> 'casNumber'
    limit 64
  ), cas_candidates as materialized (
    select candidate.dataset_kind,
      candidate.id,
      candidate.version,
      candidate.modified_at,
      candidate.state_code,
      unique_cas.cas_number,
      private.display_catalog_summary_label_v1(candidate.card) as label
    from cas_unique_values as unique_cas
    join private.display_catalog_search_rows_v1 as candidate
      on candidate.dataset_kind = 'flow'
     and candidate.id = unique_cas.id
     and candidate.card ->> 'casNumber' = unique_cas.cas_number
    where exists (
        select 1
        from latest
        where latest.dataset_kind = candidate.dataset_kind
          and latest.id = candidate.id
          and latest.version = candidate.version
      )
      and pg_catalog.jsonb_array_length(
      private.display_catalog_summary_label_v1(candidate.card)
    ) > 0
    order by unique_cas.cas_number,
      candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), cas_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'cas',
      'datasetKind', 'flow',
      'query', candidate.cas_number,
      'label', candidate.label
    ) as value
    from cas_candidates as candidate
    order by candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), classification_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.display_catalog_summary_label_v1(candidate.card) as label
      from private.display_catalog_search_rows_v2 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.display_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.display_catalog_summary_label_v1(candidate.card) as label
      from private.display_catalog_search_rows_v1 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.display_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
  ), classification_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'classification',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.code,
      'label', candidate.label
    ) as value
    from classification_candidates as candidate
    order by candidate.preference
    limit 1
  )
  select counts.value,
    counts.latest_modified_at,
    uuid_example.value,
    cas_example.value,
    classification_example.value
  into v_counts,
    v_latest_modified_at,
    v_uuid_example,
    v_cas_example,
    v_classification_example
  from counts
  left join uuid_example on true
  left join cas_example on true
  left join classification_example on true;

  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-catalog-summary.v1',
    'counts', v_counts,
    'latestModifiedAt', v_latest_modified_at,
    'examples', coalesce(pg_catalog.jsonb_agg(
      example.value order by example.ordinality
    ) filter (where example.value is not null), '[]'::jsonb)
  )
  into v_result
  from (values
    (1, v_uuid_example),
    (2, v_cas_example),
    (3, v_classification_example)
  ) as example(ordinality, value);

  if pg_catalog.octet_length(v_result::text) > 16384 then
    raise exception using
      errcode = '54000',
      message = 'Portal catalog summary exceeded its response budget';
  end if;

  return v_result;
exception
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_catalog_summary_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_catalog_summary_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_api_catalog_summary_v1"() OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_catalog_summary_v1"() FROM PUBLIC;




grant execute on function private.display_api_catalog_summary_v1() to portal_display_executor;

create function api.portal_catalog_summary_v2(p_allowed_brands text[]) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=private.display_api_catalog_summary_v1();
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_catalog_summary_v2(text[]) owner to portal_display_executor;
revoke all on function api.portal_catalog_summary_v2(text[]) from public;
grant execute on function api.portal_catalog_summary_v2(text[]) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_hybrid_search_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $_$
declare
  v_input jsonb;
  v_fingerprint text;
  v_cursor jsonb;
  v_page jsonb;
begin
  v_input := private.display_public_hybrid_input_v1(
    p_kind,p_query_terms,p_query_embedding,p_filters,p_limit);
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-hybrid-rank-v2:' || private.portal_display_scope_identity_v1() || ':' || case when v_input ->> 'kind' = 'process' then 'composite-names-v2:' else '' end || (v_input ->> 'queryFingerprint'),'UTF8'),
    'sha256'),'hex');
  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
      or (select count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
      or not (v_cursor ?& array['v','fp','kind','rankKey','id','version'])
      or v_cursor ->> 'v' is distinct from '1'
      or v_cursor ->> 'fp' is distinct from v_fingerprint
      or v_cursor ->> 'kind' is distinct from p_kind
      or pg_catalog.jsonb_typeof(v_cursor -> 'rankKey') is distinct from 'string'
      or coalesce(v_cursor ->> 'rankKey','') !~ '^(0(\.\d{1,12})?|1(\.0{1,12})?)$'
      or coalesce(v_cursor ->> 'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(v_cursor ->> 'version','') !~ '^\d{2}\.\d{2}\.\d{3}$'
      or private.display_cursor_encode_v1(v_cursor) is distinct from p_cursor then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;
  v_page := private.display_decorate_card_context_v1(private.display_lcia_decorate_item_page_v1(
    private.display_projection_hybrid_search_v2_impl(
      p_kind,
      array(select term.value from pg_catalog.jsonb_array_elements_text(v_input -> 'queryTerms')
        with ordinality as term(value,ordinality) order by term.ordinality),
      (v_input ->> 'queryEmbedding')::extensions.vector(1024),
      v_input -> 'filters',p_limit,v_fingerprint,v_cursor
    )
  ));
  v_page := pg_catalog.jsonb_set(v_page,'{schemaVersion}','"portal.public-hybrid-candidate-page.v2"'::jsonb);
  v_page := (v_page - 'nextCursorPayload') || pg_catalog.jsonb_build_object(
    'nextCursor',case when nullif(v_page -> 'nextCursorPayload','null'::jsonb) is null then null
      else private.display_cursor_encode_v1(v_page -> 'nextCursorPayload') end
  );
  if v_page is null or pg_catalog.octet_length(pg_catalog.convert_to(v_page::text,'UTF8')) > 524288 then
    raise exception using errcode = '54000', message = 'portal hybrid response too large';
  end if;
  return v_page;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_api_hybrid_search_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_hybrid_search_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") FROM PUBLIC;




grant execute on function private.display_api_hybrid_search_v2("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") to portal_display_executor;

create function api.portal_hybrid_search_v3(p_allowed_brands text[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text" DEFAULT NULL::"text") returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='20s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,p_filters);
 result:=jsonb_set(private.portal_display_brand_decorate_v1(private.display_api_hybrid_search_v2(p_kind, p_query_terms, p_query_embedding, p_filters - 'brand', p_limit, p_cursor)),'{schemaVersion}',to_jsonb('portal.public-hybrid-candidate-page.v3'::text));
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_hybrid_search_v3(text[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") owner to portal_display_executor;
revoke all on function api.portal_hybrid_search_v3(text[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") from public;
grant execute on function api.portal_hybrid_search_v3(text[], "p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_sitemap_entries_v1"("p_kind" "text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 1000) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_filter_kind text;
  v_cursor jsonb;
  v_cursor_kind text;
  v_cursor_id uuid;
  v_items jsonb;
  v_next_cursor text;
begin
  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_filter_kind := lower(btrim(coalesce(p_kind, '')));
  if v_filter_kind not in ('process', 'flow', 'all')
     or p_limit is null
     or p_limit not between 1 and 1000 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 5
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'filterKind' <> v_filter_kind
       or v_cursor ->> 'kind' not in ('process', 'flow')
       or (v_filter_kind <> 'all' and v_cursor ->> 'kind' <> v_filter_kind)
       or coalesce(v_cursor ->> 'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_kind := v_cursor ->> 'kind';
    v_cursor_id := (v_cursor ->> 'id')::uuid;
  end if;

  with source_rows as materialized (
    select kinds.kind, source.*
    from (values ('process'::text), ('flow'::text)) as kinds(kind)
    cross join lateral private.display_catalog_rows_v1(kinds.kind) as source
    where v_filter_kind = 'all' or kinds.kind = v_filter_kind
  ), latest as materialized (
    select candidate.*
    from (
      select source_rows.*,
        row_number() over (
          partition by source_rows.kind, source_rows.id
          order by source_rows.version desc
        ) as version_rank
      from source_rows
    ) as candidate
    where candidate.version_rank = 1
  ), ordered as materialized (
    select latest.*,
      row_number() over (order by latest.kind, latest.id) as page_rank
    from latest
    where v_cursor is null or (latest.kind, latest.id) > (v_cursor_kind, v_cursor_id)
    order by latest.kind, latest.id
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'key', jsonb_build_object(
        'kind', ordered.kind,
        'id', ordered.id::text,
        'version', ordered.version
      ),
      'modifiedAt', private.display_timestamp_v1(ordered.modified_at)
    ) order by ordered.page_rank) filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit then private.display_cursor_encode_v1(
      (jsonb_agg(jsonb_build_object(
        'v', 1,
        'filterKind', v_filter_kind,
        'kind', ordered.kind,
        'id', ordered.id::text,
        'version', ordered.version
      ) order by ordered.page_rank) filter (where ordered.page_rank = p_limit)) -> 0
    ) else null end
  into v_items, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-page.v1',
    'items', v_items,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_sitemap_entries_v1"("p_kind" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_sitemap_entries_v1"("p_kind" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




grant execute on function private.display_api_sitemap_entries_v1("p_kind" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor;

create function api.portal_sitemap_entries_v2(p_allowed_brands text[], "p_kind" "text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 1000) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=private.display_api_sitemap_entries_v1(p_kind, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_sitemap_entries_v2(text[], "p_kind" "text", "p_cursor" "text", "p_limit" integer) owner to portal_display_executor;
revoke all on function api.portal_sitemap_entries_v2(text[], "p_kind" "text", "p_cursor" "text", "p_limit" integer) from public;
grant execute on function api.portal_sitemap_entries_v2(text[], "p_kind" "text", "p_cursor" "text", "p_limit" integer) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_sitemap_manifest_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '2s'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_shards jsonb;
begin
  perform private.display_assert_catalog_projection_contract_v1();
  perform private.display_assert_catalog_facet_contract_v1();
  perform private.display_assert_sitemap_projection_v1();

  select pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'shardCursor',
      private.display_cursor_encode_v1(pg_catalog.jsonb_build_object(
        'v', 1,
        'scope', 'sitemap-shard',
        'bucket', shard.bucket,
        'shardCount', 64
      )),
      'maxItems', 4096
    )
    order by shard.bucket
  )
  into v_shards
  from pg_catalog.generate_series(0, 63) as shard(bucket);

  return pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-manifest.v1',
    'shards', v_shards
  );
exception
  when query_canceled then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  when others then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
end
$$;

ALTER FUNCTION "private"."display_api_sitemap_manifest_v1"() OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_sitemap_manifest_v1"() FROM PUBLIC;




grant execute on function private.display_api_sitemap_manifest_v1() to portal_display_executor;

create function api.portal_sitemap_manifest_v2(p_allowed_brands text[]) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=private.display_api_sitemap_manifest_v1();
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_sitemap_manifest_v2(text[]) owner to portal_display_executor;
revoke all on function api.portal_sitemap_manifest_v2(text[]) from public;
grant execute on function api.portal_sitemap_manifest_v2(text[]) to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_sitemap_shard_v1"("p_shard_cursor" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '4s'
    SET "work_mem" TO '8MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $_$
declare
  v_cursor jsonb;
  v_expected_cursor jsonb;
  v_bucket integer;
  v_items jsonb;
  v_result jsonb;
begin
  if p_shard_cursor is null
     or pg_catalog.octet_length(p_shard_cursor) not between 1 and 4096
     or p_shard_cursor ~ '[[:space:]]' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  v_cursor := private.display_cursor_decode_v1(p_shard_cursor);
  if v_cursor is null
     or pg_catalog.jsonb_typeof(v_cursor) <> 'object'
     or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 4
     or coalesce(v_cursor ->> 'bucket', '') !~ '^([0-9]|[1-5][0-9]|6[0-3])$' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_bucket := (v_cursor ->> 'bucket')::integer;
  v_expected_cursor := pg_catalog.jsonb_build_object(
    'v', 1,
    'scope', 'sitemap-shard',
    'bucket', v_bucket,
    'shardCount', 64
  );

  if v_cursor is distinct from v_expected_cursor
     or private.display_cursor_encode_v1(v_expected_cursor) <>
       p_shard_cursor then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  perform private.display_assert_catalog_projection_contract_v1();
  perform private.display_assert_catalog_facet_contract_v1();
  perform private.display_assert_sitemap_projection_v1();

  with latest as materialized (
    select distinct on (projection.dataset_kind, projection.id)
      projection.dataset_kind,
      projection.id,
      projection.version,
      projection.modified_at
    from private.display_sitemap_rows_v1 as projection
    where projection.shard_no = v_bucket
      and projection.contract_version = 1
    order by projection.dataset_kind,
      projection.id,
      projection.version desc,
      projection.modified_at desc
    limit 4097
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'key', pg_catalog.jsonb_build_object(
      'kind', latest.dataset_kind,
      'id', latest.id::text,
      'version', latest.version
    ),
    'modifiedAt', private.display_timestamp_v1(latest.modified_at)
  ) order by latest.dataset_kind, latest.id), '[]'::jsonb)
  into v_items
  from latest;

  if pg_catalog.jsonb_array_length(v_items) > 4096 then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  end if;

  v_result := pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-shard.v1',
    'shardCursor', p_shard_cursor,
    'items', v_items
  );
  if pg_catalog.octet_length(v_result::text) > 2 * 1024 * 1024 then
    raise exception using
      errcode = '54000',
      message = 'portal sitemap response exceeded its budget';
  end if;
  return v_result;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  when others then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_sitemap_shard_v1"("p_shard_cursor" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_sitemap_shard_v1"("p_shard_cursor" "text") FROM PUBLIC;




grant execute on function private.display_api_sitemap_shard_v1("p_shard_cursor" "text") to portal_display_executor;

create function api.portal_sitemap_shard_v2(p_allowed_brands text[], "p_shard_cursor" "text") returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=private.display_api_sitemap_shard_v1(p_shard_cursor);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_sitemap_shard_v2(text[], "p_shard_cursor" "text") owner to portal_display_executor;
revoke all on function api.portal_sitemap_shard_v2(text[], "p_shard_cursor" "text") from public;
grant execute on function api.portal_sitemap_shard_v2(text[], "p_shard_cursor" "text") to anon,authenticated;

CREATE OR REPLACE FUNCTION "private"."display_api_get_published_lcia_values_v1"("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_mode text := btrim(coalesce(p_mode, ''));
  v_impact_ref text := nullif(btrim(coalesce(p_impact_ref, '')), '');
  v_limit integer := coalesce(p_limit, 50);
  v_ref_count integer;
  v_distinct_ref_count integer;
  v_impact_match_count integer;
  v_query_hash text;
  v_query_fields text[];
  v_cursor jsonb;
  v_cursor_request_order integer;
  v_cursor_ordinal bigint;
  v_cursor_sort_value text;
  v_cursor_sort_numeric numeric;
  v_binding record;
  v_projection record;
  v_rows jsonb := '[]'::jsonb;
  v_next_cursor text;
begin
  if v_mode not in (
       'process_all_impacts',
       'processes_one_impact',
       'ranked_processes_one_impact'
     )
     or v_limit not between 1 and 50
     or jsonb_typeof(p_process_refs) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_ref_count := jsonb_array_length(p_process_refs);
  if v_ref_count not between 1 and 50
     or (v_mode = 'process_all_impacts' and v_ref_count <> 1)
     or (v_mode = 'process_all_impacts' and v_impact_ref is not null)
     or (v_mode <> 'process_all_impacts'
         and (v_impact_ref is null or length(v_impact_ref) > 512))
     or exists (
       select 1
       from jsonb_array_elements(p_process_refs) as item(value)
       where private.display_lcia_json_object_has_keys_v1(
         item.value, array['id', 'version']
       ) is not true
         or jsonb_typeof(item.value -> 'id') <> 'string'
         or jsonb_typeof(item.value -> 'version') <> 'string'
         or coalesce(item.value ->> 'id', '')
              !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or coalesce(item.value ->> 'version', '')
              !~ '^\d{2}\.\d{2}\.\d{3}$'
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select count(distinct (item.value ->> 'id', item.value ->> 'version'))
  into v_distinct_ref_count
  from jsonb_array_elements(p_process_refs) as item(value);
  if v_distinct_ref_count <> v_ref_count then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  select
    binding.id,
    binding.projection_id,
    binding.lcia_result_publication_id,
    binding.package_id,
    binding.package_version,
    binding.projection_content_hash,
    binding.evidence_hash,
    binding.source_published_at,
    binding.status,
    binding.revoked_at
  into v_binding
  from private.display_read_lcia_projection_publications as binding
  where binding.status = 'finalized'
  order by binding.source_published_at desc, binding.id
  limit 1;
  if v_binding.id is null then
    return null;
  end if;
  select
    projection.id,
    projection.status,
    projection.process_count,
    projection.impact_count,
    projection.expected_value_count,
    projection.content_hash
  into v_projection
  from private.display_read_lcia_projection_headers as projection
  where projection.id = v_binding.projection_id;
  if v_projection.id is null then
    return null;
  end if;
  if v_mode <> 'process_all_impacts' then
    select count(*) into v_impact_match_count
    from private.display_read_lcia_projection_impact_axis as impact_row
    where impact_row.projection_id = v_projection.id
      and impact_row.impact_id = v_impact_ref;
    if v_impact_match_count > 1 then
      raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
    end if;
  end if;

  select array[
    'portal.published-lcia-query.v2',private.portal_display_scope_identity_v1(),
    'portal.lcia-projection.int32be-frame-sha256.v1',
    v_binding.lcia_result_publication_id::text,
    v_binding.projection_content_hash,
    v_mode,
    coalesce(v_impact_ref, ''),
    v_ref_count::text
  ] || array_agg(field.value order by ref.ordinality, field.position)
  into v_query_fields
  from jsonb_array_elements(p_process_refs)
    with ordinality as ref(value, ordinality)
  cross join lateral (
    values (1, ref.value ->> 'id'), (2, ref.value ->> 'version')
  ) as field(position, value);
  v_query_hash := private.display_lcia_projection_sha256_fields_v1(
    variadic v_query_fields
  );

  if p_cursor is not null then
    v_cursor := private.display_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 8
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'publicationId'
            <> v_binding.lcia_result_publication_id::text
       or v_cursor ->> 'contentHash' <> v_binding.projection_content_hash
       or v_cursor ->> 'mode' <> v_mode
       or v_cursor ->> 'queryHash' <> v_query_hash
       or coalesce(v_cursor ->> 'requestOrder', '') !~ '^\d+$'
       or coalesce(v_cursor ->> 'ordinal', '') !~ '^\d+$'
       or jsonb_typeof(v_cursor -> 'sortValue') <> 'string' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    begin
      v_cursor_request_order := (v_cursor ->> 'requestOrder')::integer;
      v_cursor_ordinal := (v_cursor ->> 'ordinal')::bigint;
    exception when others then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end;
    v_cursor_sort_value := v_cursor ->> 'sortValue';
    if v_mode = 'ranked_processes_one_impact' then
      if private.display_canonical_decimal_v1(v_cursor_sort_value)
           is distinct from v_cursor_sort_value then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
      v_cursor_sort_numeric := v_cursor_sort_value::numeric;
    elsif v_cursor_sort_value <> '' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;

  with refs as materialized (
    select
      ref.ordinality::integer as request_order,
      (ref.value ->> 'id')::uuid as process_id,
      ref.value ->> 'version' as process_version
    from jsonb_array_elements(p_process_refs)
      with ordinality as ref(value, ordinality)
  ), eligible as materialized (
    select
      refs.request_order,
      process_row.process_index,
      impact_row.impact_index,
      value_row.ordinal,
      value_row.value_text,
      value_row.value_numeric,
      process_row.process_id,
      process_row.process_version,
      process_row.functional_unit_amount,
      process_row.functional_unit_unit,
      process_row.functional_unit_description,
      process_row.geography_code,
      process_row.geography_precision,
      process_row.reference_year,
      impact_row.method_id,
      impact_row.method_version,
      impact_row.impact_id,
      impact_row.impact_name,
      impact_row.unit
    from refs
    join private.display_read_lcia_projection_process_axis as process_row
      on process_row.projection_id = v_projection.id
     and process_row.process_id = refs.process_id
     and process_row.process_version = refs.process_version
    join public.processes as public_process
      on public_process.id = process_row.process_id
     and public_process.version::text = process_row.process_version
     and private.portal_display_request_visible_v1('process',public_process.id,public_process.version::text)
     and (
       private.display_capabilities_v1(
         'process', public_process.state_code, public_process.json
       ) ->> 'exchangesVisible'
     )::boolean
    join private.display_read_lcia_projection_values as value_row
      on value_row.projection_id = process_row.projection_id
     and value_row.process_index = process_row.process_index
    join private.display_read_lcia_projection_impact_axis as impact_row
      on impact_row.projection_id = value_row.projection_id
     and impact_row.impact_index = value_row.impact_index
    where v_mode = 'process_all_impacts'
       or impact_row.impact_id = v_impact_ref
  ), after_cursor as materialized (
    select eligible.*
    from eligible
    where v_cursor is null
       or (
         v_mode = 'process_all_impacts'
         and eligible.ordinal > v_cursor_ordinal
       )
       or (
         v_mode = 'processes_one_impact'
         and (eligible.request_order, eligible.ordinal)
               > (v_cursor_request_order, v_cursor_ordinal)
       )
       or (
         v_mode = 'ranked_processes_one_impact'
         and (
           eligible.value_numeric < v_cursor_sort_numeric
           or (
             eligible.value_numeric = v_cursor_sort_numeric
             and eligible.ordinal > v_cursor_ordinal
           )
         )
       )
  ), ordered as materialized (
    select after_cursor.*,
      row_number() over (
        order by
          case when v_mode = 'ranked_processes_one_impact'
            then after_cursor.value_numeric end desc nulls last,
          case when v_mode = 'processes_one_impact'
            then after_cursor.request_order end asc nulls last,
          after_cursor.ordinal asc
      ) as page_rank
    from after_cursor
    order by
      case when v_mode = 'ranked_processes_one_impact'
        then after_cursor.value_numeric end desc nulls last,
      case when v_mode = 'processes_one_impact'
        then after_cursor.request_order end asc nulls last,
      after_cursor.ordinal asc
    limit v_limit + 1
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'process', jsonb_build_object(
            'id', ordered.process_id::text,
            'version', ordered.process_version
          ),
          'functionalUnit', jsonb_build_object(
            'amount', ordered.functional_unit_amount,
            'unit', ordered.functional_unit_unit,
            'description', ordered.functional_unit_description
          ),
          'geography', jsonb_build_object(
            'code', ordered.geography_code,
            'precision', ordered.geography_precision
          ),
          'referenceYear', ordered.reference_year,
          'method', jsonb_build_object(
            'id', ordered.method_id::text,
            'version', ordered.method_version
          ),
          'impact', jsonb_build_object(
            'id', ordered.impact_id,
            'name', ordered.impact_name
          ),
          'value', ordered.value_text,
          'unit', ordered.unit,
          'evidenceStatus', 'verified'
        )
        order by ordered.page_rank
      ) filter (where ordered.page_rank <= v_limit),
      '[]'::jsonb
    ),
    case
      when max(ordered.page_rank) > v_limit then
        private.display_cursor_encode_v1(
          (
            jsonb_agg(
              jsonb_build_object(
                'v', 1,
                'publicationId', v_binding.lcia_result_publication_id::text,
                'contentHash', v_binding.projection_content_hash,
                'mode', v_mode,
                'queryHash', v_query_hash,
                'requestOrder', ordered.request_order::text,
                'ordinal', ordered.ordinal::text,
                'sortValue', case
                  when v_mode = 'ranked_processes_one_impact'
                    then ordered.value_text
                  else ''
                end
              ) order by ordered.page_rank
            ) filter (where ordered.page_rank = v_limit)
          ) -> 0
        )
      else null
    end
  into v_rows, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.published-lcia-page.v1',
    'mode', v_mode,
    'publication', jsonb_build_object(
      'publicationId', v_binding.lcia_result_publication_id::text,
      'packageId', v_binding.package_id::text,
      'packageVersion', v_binding.package_version,
      'publishedAt', private.display_timestamp_v1(v_binding.source_published_at),
      'evidenceHash', v_binding.evidence_hash
    ),
    'rows', v_rows,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_get_published_lcia_values_v1"("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_get_published_lcia_values_v1"("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




grant execute on function private.display_api_get_published_lcia_values_v1("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) to portal_display_executor;

create function api.portal_get_published_lcia_values_v2(p_allowed_brands text[], "p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) returns jsonb
language plpgsql stable security definer set search_path='' set statement_timeout='8s'
as $$ declare result jsonb; old_brands text:=current_setting('portal.display_brands',true); old_global text:=current_setting('portal.display_global',true); old_filter text:=current_setting('portal.display_filter_brand',true); begin
 perform private.portal_display_begin_request_v1(p_allowed_brands,'{}'::jsonb);
 result:=private.display_api_get_published_lcia_values_v1(p_mode, p_process_refs, p_impact_ref, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end $$;
alter function api.portal_get_published_lcia_values_v2(text[], "p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) owner to portal_display_executor;
revoke all on function api.portal_get_published_lcia_values_v2(text[], "p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) from public;
grant execute on function api.portal_get_published_lcia_values_v2(text[], "p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) to anon,authenticated;

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_search_processes_v4' and g.routine_identity like 'api.portal_search_processes_v3(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_search_flows_v4' and g.routine_identity like 'api.portal_search_flows_v3(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_facets_v4' and g.routine_identity like 'api.portal_facets_v3(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_navigation_v2' and g.routine_identity like 'api.portal_navigation_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_get_dataset_v2' and g.routine_identity like 'api.portal_get_dataset_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_list_versions_v2' and g.routine_identity like 'api.portal_list_versions_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_list_process_exchanges_v2' and g.routine_identity like 'api.portal_list_process_exchanges_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_catalog_summary_v2' and g.routine_identity like 'api.portal_catalog_summary_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_hybrid_search_v3' and g.routine_identity like 'api.portal_hybrid_search_v2(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_sitemap_entries_v2' and g.routine_identity like 'api.portal_sitemap_entries_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_sitemap_manifest_v2' and g.routine_identity like 'api.portal_sitemap_manifest_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_sitemap_shard_v2' and g.routine_identity like 'api.portal_sitemap_shard_v1(%';

insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) select format('%I.%I(%s)',n.nspname,p.proname,pg_catalog.oidvectortypes(p.proargtypes)),g.capability_id,g.allow_anon,g.allow_authenticated,g.allow_service_role from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join private.api_capability_grants g where n.nspname='api' and p.proname='portal_get_published_lcia_values_v2' and g.routine_identity like 'api.portal_get_published_lcia_values_v1(%';

revoke create on schema private,api from portal_display_executor;



-- Database #807: fail-closed rollout, legacy-shape adapters and batch link eligibility.
set local lock_timeout='5s';
set local check_function_bodies=off;
grant portal_display_executor,portal_public_executor to postgres with set true;
grant create on schema private,api to portal_display_executor,portal_public_executor;

create function private.portal_display_brand_facets_v1(p_page jsonb,p_kind text,p_query text,p_filters jsonb)
returns jsonb language sql stable security definer set search_path='' set row_security=on as $$
 select jsonb_set(p_page,'{groups}',(p_page->'groups') || jsonb_build_array(jsonb_build_object(
  'id','brand','label',jsonb_build_array(jsonb_build_object('language','en','value','Database brand')),
  'hasMore',false,'values',coalesce((select jsonb_agg(jsonb_build_object(
   'value',brand,'label',jsonb_build_array(jsonb_build_object('language','en','value',private.portal_brand_v1(brand)->>'name')),
   'count',total) order by brand)
   from (select p.brand,count(*) as total
    from private.display_navigation_matched_versions_v1(lower(btrim(p_kind)),lower(btrim(coalesce(p_query,''))),private.display_normalize_filters_v1(p_filters)) k
    join private.display_catalog_search_rows_v1 p using(dataset_kind,id,version)
    group by p.brand) counted),'[]'::jsonb))))
$$;
alter function private.portal_display_brand_facets_v1(jsonb,text,text,jsonb) owner to portal_display_executor;
revoke all on function private.portal_display_brand_facets_v1(jsonb,text,text,jsonb) from public;
grant execute on function private.portal_brand_v1(text) to portal_display_executor;

create function api.portal_flow_link_eligibility_v1(p_allowed_brands text[],p_flow_refs jsonb)
returns jsonb language plpgsql stable security definer set search_path='' set statement_timeout='8s' as $$
declare b text[]:=private.portal_normalize_brand_scope_v1(p_allowed_brands); result jsonb;
begin
 if (select mode from private.portal_display_rollout where singleton) is distinct from 'display' then
  raise exception using errcode='P0001',message='portal catalog unavailable';
 end if;
 if jsonb_typeof(p_flow_refs) is distinct from 'array' or jsonb_array_length(p_flow_refs)>50
 or exists(select 1 from jsonb_array_elements(p_flow_refs) r where
  private.portal_lcia_json_object_has_keys_v1(r,array['id','version']) is not true
  or coalesce(r->>'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  or coalesce(r->>'version','') !~ '^\d{2}\.\d{2}\.\d{3}$') then
  raise exception using errcode='22023',message='invalid portal request';
 end if;
 perform private.portal_display_assert_contract_v1();
 select coalesce(jsonb_agg(jsonb_build_object('id',r->>'id','version',r->>'version','linkable',
  private.portal_dataset_in_brand_scope_v1('flow',(r->>'id')::uuid,r->>'version',b)
  and exists(select 1 from private.display_catalog_search_rows_v1 p
   where p.dataset_kind='flow' and p.id=(r->>'id')::uuid and p.version=r->>'version')) order by ord),'[]')
 into result from jsonb_array_elements(p_flow_refs) with ordinality x(r,ord);
 return result;
end $$;
revoke all on function api.portal_flow_link_eligibility_v1(text[],jsonb) from public;
grant execute on function api.portal_flow_link_eligibility_v1(text[],jsonb) to anon,authenticated;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role)
values('api.portal_flow_link_eligibility_v1(text[], jsonb)','PORTAL-CATALOG-01',true,true,false);

create function private.portal_display_mode_v1() returns text language sql stable security definer set search_path='' as $$
 select mode from private.portal_display_rollout where singleton
$$;
revoke all on function private.portal_display_mode_v1() from public;
grant execute on function private.portal_display_mode_v1() to portal_public_executor,portal_display_executor;

-- A bounded operator-only derivative repair; it never inserts/changes display settings.
create function private.portal_display_repair_batch_v1(p_after jsonb default null,p_limit integer default 500)
returns jsonb language plpgsql security definer set search_path='' as $$
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
revoke all on function private.portal_display_repair_batch_v1(jsonb,integer) from public;

-- Activation is an operator transaction, never a migration side effect. Once display
-- has been entered, only display/unavailable transitions are admitted.
create function private.portal_display_transition_v1(p_expected text,p_next text)
returns void language plpgsql security definer set search_path='' as $$
declare current_mode text;
begin
 select mode into current_mode from private.portal_display_rollout where singleton for update;
 if current_mode is distinct from p_expected or p_next is null or p_next not in ('display','unavailable') then
  raise exception using errcode='55000',message='invalid display rollout transition';
 end if;
 perform private.portal_display_assert_contract_v1();
 if p_next='display' and exists(
  select 1 from private.dataset_display_settings s
  join (select 'process'::text as kind,id,version::text as version,json,modified_at,state_code from public.processes
   union all select 'flow',id,version::text,json,modified_at,state_code from public.flows) r
   on (r.kind,r.id,r.version)=(s.dataset_kind,s.dataset_id,s.dataset_version::text)
  left join private.display_catalog_search_rows_v1 p on (p.dataset_kind,p.id,p.version)=(r.kind,r.id,r.version)
  where s.is_visible and jsonb_typeof(r.json->case r.kind when 'process' then 'processDataSet' else 'flowDataSet' end)='object'
   and (p.id is null or p.brand is distinct from s.brand or p.modified_at is distinct from r.modified_at
    or p.state_code is distinct from r.state_code
    or p.card is distinct from private.display_catalog_projection_payload_v1(r.kind,r.state_code,r.json)->'card'
    or (r.kind='process' and not exists(select 1 from private.display_catalog_search_rows_v2 c
     where c.dataset_kind=r.kind and c.id=r.id and c.version=r.version and c.brand is not distinct from s.brand
     and c.modified_at=r.modified_at and c.state_code=r.state_code
     and c.card=private.display_catalog_projection_payload_cn1(r.kind,r.state_code,r.json)->'card')))
 ) then raise exception using errcode='55000',message='display projection repair required'; end if;
 update private.portal_display_rollout set mode=p_next,changed_at=clock_timestamp() where singleton;
end $$;
revoke all on function private.portal_display_transition_v1(text,text) from public;




-- BEGIN GENERATED LEGACY ADAPTERS
-- All existing anonymous Portal readers share the same cutover; old shapes stay intact.

CREATE OR REPLACE FUNCTION "private"."display_legacy_catalog_summary_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '2s'
    SET "work_mem" TO '32MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $_$

declare
  v_diagnostic_message text;
  v_diagnostic_state text;
  v_counts jsonb;
  v_latest_modified_at text;
  v_uuid_example jsonb;
  v_cas_example jsonb;
  v_classification_example jsonb;
  v_result jsonb;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();
  perform private.assert_portal_catalog_facet_contract_v1();

  with latest as materialized (
    select distinct on (facet.dataset_kind, facet.id)
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.modified_at,
      facet.state_code
    from private.portal_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1
    order by facet.dataset_kind,
      facet.id,
      facet.version desc,
      facet.modified_at desc,
      facet.state_code desc
  ), counts as (
    select pg_catalog.jsonb_build_object(
        'process', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'process'
        ),
        'flow', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'flow'
        ),
        'total', pg_catalog.count(*)
      ) as value,
      private.portal_timestamp_v1(
        pg_catalog.max(latest.modified_at)
      ) as latest_modified_at
    from latest
  ), uuid_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v2 as candidate
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v1 as candidate
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
  ), uuid_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'uuid',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.id::text,
      'label', candidate.label
    ) as value
    from uuid_candidates as candidate
    order by candidate.preference
    limit 1
  ), cas_unique_values as materialized (
    select candidate.card ->> 'casNumber' as cas_number,
      pg_catalog.min(candidate.id::text)::uuid as id
    from private.portal_catalog_search_rows_v1 as candidate
    where candidate.dataset_kind = 'flow'
      and pg_catalog.jsonb_typeof(candidate.card -> 'casNumber') = 'string'
      and candidate.card ->> 'casNumber' ~
        '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(
        candidate.card ->> 'casNumber'
      ) between 7 and 12
      and private.portal_catalog_summary_valid_cas_v1(
        candidate.card ->> 'casNumber'
      )
    group by candidate.card ->> 'casNumber'
    having pg_catalog.count(*) = 1
    order by candidate.card ->> 'casNumber'
    limit 64
  ), cas_candidates as materialized (
    select candidate.dataset_kind,
      candidate.id,
      candidate.version,
      candidate.modified_at,
      candidate.state_code,
      unique_cas.cas_number,
      private.portal_catalog_summary_label_v1(candidate.card) as label
    from cas_unique_values as unique_cas
    join private.portal_catalog_search_rows_v1 as candidate
      on candidate.dataset_kind = 'flow'
     and candidate.id = unique_cas.id
     and candidate.card ->> 'casNumber' = unique_cas.cas_number
    where exists (
        select 1
        from latest
        where latest.dataset_kind = candidate.dataset_kind
          and latest.id = candidate.id
          and latest.version = candidate.version
      )
      and pg_catalog.jsonb_array_length(
      private.portal_catalog_summary_label_v1(candidate.card)
    ) > 0
    order by unique_cas.cas_number,
      candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), cas_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'cas',
      'datasetKind', 'flow',
      'query', candidate.cas_number,
      'label', candidate.label
    ) as value
    from cas_candidates as candidate
    order by candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), classification_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v2 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v1 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
  ), classification_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'classification',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.code,
      'label', candidate.label
    ) as value
    from classification_candidates as candidate
    order by candidate.preference
    limit 1
  )
  select counts.value,
    counts.latest_modified_at,
    uuid_example.value,
    cas_example.value,
    classification_example.value
  into v_counts,
    v_latest_modified_at,
    v_uuid_example,
    v_cas_example,
    v_classification_example
  from counts
  left join uuid_example on true
  left join cas_example on true
  left join classification_example on true;

  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-catalog-summary.v1',
    'counts', v_counts,
    'latestModifiedAt', v_latest_modified_at,
    'examples', coalesce(pg_catalog.jsonb_agg(
      example.value order by example.ordinality
    ) filter (where example.value is not null), '[]'::jsonb)
  )
  into v_result
  from (values
    (1, v_uuid_example),
    (2, v_cas_example),
    (3, v_classification_example)
  ) as example(ordinality, value);

  if pg_catalog.octet_length(v_result::text) > 16384 then
    raise exception using
      errcode = '54000',
      message = 'Portal catalog summary exceeded its response budget';
  end if;

  return v_result;
exception
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_catalog_summary_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_catalog_summary_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_legacy_catalog_summary_v1"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_catalog_summary_v1"() FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_catalog_summary_v1() to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_catalog_summary_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '2s'
    SET "work_mem" TO '32MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $_$

declare
  v_diagnostic_message text;
  v_diagnostic_state text;
  v_counts jsonb;
  v_latest_modified_at text;
  v_uuid_example jsonb;
  v_cas_example jsonb;
  v_classification_example jsonb;
  v_result jsonb;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_catalog_summary_v1();
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  perform private.assert_portal_catalog_projection_contract_cn1();
  perform private.assert_portal_catalog_facet_contract_v1();

  with latest as materialized (
    select distinct on (facet.dataset_kind, facet.id)
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.modified_at,
      facet.state_code
    from private.portal_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1
    order by facet.dataset_kind,
      facet.id,
      facet.version desc,
      facet.modified_at desc,
      facet.state_code desc
  ), counts as (
    select pg_catalog.jsonb_build_object(
        'process', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'process'
        ),
        'flow', pg_catalog.count(*) filter (
          where latest.dataset_kind = 'flow'
        ),
        'total', pg_catalog.count(*)
      ) as value,
      private.portal_timestamp_v1(
        pg_catalog.max(latest.modified_at)
      ) as latest_modified_at
    from latest
  ), uuid_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v2 as candidate
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v1 as candidate
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc
      limit 1
    )
  ), uuid_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'uuid',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.id::text,
      'label', candidate.label
    ) as value
    from uuid_candidates as candidate
    order by candidate.preference
    limit 1
  ), cas_unique_values as materialized (
    select candidate.card ->> 'casNumber' as cas_number,
      pg_catalog.min(candidate.id::text)::uuid as id
    from private.portal_catalog_search_rows_v1 as candidate
    where candidate.dataset_kind = 'flow'
      and pg_catalog.jsonb_typeof(candidate.card -> 'casNumber') = 'string'
      and candidate.card ->> 'casNumber' ~
        '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(
        candidate.card ->> 'casNumber'
      ) between 7 and 12
      and private.portal_catalog_summary_valid_cas_v1(
        candidate.card ->> 'casNumber'
      )
    group by candidate.card ->> 'casNumber'
    having pg_catalog.count(*) = 1
    order by candidate.card ->> 'casNumber'
    limit 64
  ), cas_candidates as materialized (
    select candidate.dataset_kind,
      candidate.id,
      candidate.version,
      candidate.modified_at,
      candidate.state_code,
      unique_cas.cas_number,
      private.portal_catalog_summary_label_v1(candidate.card) as label
    from cas_unique_values as unique_cas
    join private.portal_catalog_search_rows_v1 as candidate
      on candidate.dataset_kind = 'flow'
     and candidate.id = unique_cas.id
     and candidate.card ->> 'casNumber' = unique_cas.cas_number
    where exists (
        select 1
        from latest
        where latest.dataset_kind = candidate.dataset_kind
          and latest.id = candidate.id
          and latest.version = candidate.version
      )
      and pg_catalog.jsonb_array_length(
      private.portal_catalog_summary_label_v1(candidate.card)
    ) > 0
    order by unique_cas.cas_number,
      candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), cas_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'cas',
      'datasetKind', 'flow',
      'query', candidate.cas_number,
      'label', candidate.label
    ) as value
    from cas_candidates as candidate
    order by candidate.id,
      candidate.version desc,
      candidate.modified_at desc,
      candidate.state_code desc
    limit 1
  ), classification_candidates as materialized (
    (
      select 0 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v2 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'process'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
    union all
    (
      select 1 as preference,
        candidate.dataset_kind,
        candidate.id,
        candidate.version,
        candidate.modified_at,
        candidate.state_code,
        classification.ordinality,
        pg_catalog.btrim(classification.value ->> 'code') as code,
        private.portal_catalog_summary_label_v1(candidate.card) as label
      from private.portal_catalog_search_rows_v1 as candidate
      cross join lateral pg_catalog.jsonb_array_elements(
        candidate.card -> 'classifications'
      ) with ordinality as classification(value, ordinality)
      where candidate.dataset_kind = 'flow'
        and exists (
          select 1
          from latest
          where latest.dataset_kind = candidate.dataset_kind
            and latest.id = candidate.id
            and latest.version = candidate.version
        )
        and pg_catalog.jsonb_typeof(
          candidate.card -> 'classifications'
        ) = 'array'
        and pg_catalog.jsonb_array_length(
          candidate.card -> 'classifications'
        ) > 0
        and pg_catalog.jsonb_typeof(classification.value) = 'object'
        and pg_catalog.jsonb_typeof(classification.value -> 'code') = 'string'
        and pg_catalog.length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) between 4 and 128
        and pg_catalog.octet_length(
          pg_catalog.btrim(classification.value ->> 'code')
        ) <= 512
        and pg_catalog.btrim(
          classification.value ->> 'code'
        ) !~ '[[:cntrl:]]'
        and pg_catalog.jsonb_array_length(
          private.portal_catalog_summary_label_v1(candidate.card)
        ) > 0
      order by candidate.id,
        candidate.version desc,
        candidate.modified_at desc,
        candidate.state_code desc,
        classification.ordinality,
        pg_catalog.btrim(
          classification.value ->> 'code'
        ) collate pg_catalog."C"
      limit 1
    )
  ), classification_example as (
    select pg_catalog.jsonb_build_object(
      'queryKind', 'classification',
      'datasetKind', candidate.dataset_kind,
      'query', candidate.code,
      'label', candidate.label
    ) as value
    from classification_candidates as candidate
    order by candidate.preference
    limit 1
  )
  select counts.value,
    counts.latest_modified_at,
    uuid_example.value,
    cas_example.value,
    classification_example.value
  into v_counts,
    v_latest_modified_at,
    v_uuid_example,
    v_cas_example,
    v_classification_example
  from counts
  left join uuid_example on true
  left join cas_example on true
  left join classification_example on true;

  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-catalog-summary.v1',
    'counts', v_counts,
    'latestModifiedAt', v_latest_modified_at,
    'examples', coalesce(pg_catalog.jsonb_agg(
      example.value order by example.ordinality
    ) filter (where example.value is not null), '[]'::jsonb)
  )
  into v_result
  from (values
    (1, v_uuid_example),
    (2, v_cas_example),
    (3, v_classification_example)
  ) as example(ordinality, value);

  if pg_catalog.octet_length(v_result::text) > 16384 then
    raise exception using
      errcode = '54000',
      message = 'Portal catalog summary exceeded its response budget';
  end if;

  return v_result;
exception
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_catalog_summary_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_catalog_summary_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_facets_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v1(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v1_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.catalog_portal_facets_v1_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_legacy_facets_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_facets_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_api_facets_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.display_assert_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.display_validate_search_v1(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.display_normalize_filters_v1(p_filters);
  v_fingerprint := private.display_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.display_assert_catalog_facet_contract_v1();
    return private.display_catalog_facets_empty_v1_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.display_catalog_facets_v1_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_facets_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_facets_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_facets_v1("p_kind" "text", "p_query" "text", "p_filters" "jsonb") to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_facets_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_facets_v1(p_kind, p_query, p_filters);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v1(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v1_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.catalog_portal_facets_v1_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_facets_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v1(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v2:' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.catalog_portal_facets_v2_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_legacy_facets_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_facets_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_api_facets_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.display_assert_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.display_validate_search_v1(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.display_normalize_filters_v1(p_filters);
  v_fingerprint := private.display_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v2:' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.display_assert_catalog_facet_contract_v1();
    return private.display_catalog_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.display_catalog_facets_v2_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_api_facets_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_facets_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_facets_v2("p_kind" "text", "p_query" "text", "p_filters" "jsonb") to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_facets_v2"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_facets_v2(p_kind, p_query, p_filters);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v1(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v2:' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.catalog_portal_facets_v2_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v3(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v3:' || (select asset_sha256 from private.portal_navigation_contract_v1 where contract_version=1) || ':' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.catalog_portal_facets_v3_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_legacy_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_facets_v3("p_kind" "text", "p_query" "text", "p_filters" "jsonb") to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_facets_v3"("p_kind" "text", "p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
  v_kind text;
  v_query text;
  v_filters jsonb;
  v_fingerprint text;
  v_exact_id uuid;
  v_like_pattern text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_facets_v3(p_kind, p_query, p_filters);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  perform private.assert_portal_catalog_projection_contract_cn1();

  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := pg_catalog.lower(pg_catalog.btrim(coalesce(p_kind, '')));
  perform private.portal_validate_search_v3(
    v_kind,
    coalesce(p_query, ''),
    coalesce(p_filters, '{}'::jsonb),
    'relevance',
    1
  );
  v_query := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
  v_filters := private.portal_normalize_filters_v1(p_filters);
  v_fingerprint := private.portal_query_fingerprint_v1(
    v_kind,
    v_query,
    v_filters,
    'relevance'
  );

  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-search-versions-v3:' || (select asset_sha256 from private.portal_navigation_contract_v1 where contract_version=1) || ':' || v_fingerprint,'UTF8'),'sha256'),'hex');
  if v_query = '' and v_filters = '{}'::jsonb then
    perform private.assert_portal_catalog_facet_contract_v1();
    return private.catalog_portal_facets_empty_v2_impl(
      v_kind,
      v_fingerprint
    );
  end if;

  if v_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_exact_id := v_query::uuid;
  end if;
  if v_query <> '' then
    v_like_pattern := '%' || pg_catalog.replace(
      pg_catalog.replace(
        pg_catalog.replace(
          v_query,
          pg_catalog.chr(92),
          pg_catalog.chr(92) || pg_catalog.chr(92)
        ),
        '%',
        pg_catalog.chr(92) || '%'
      ),
      '_',
      pg_catalog.chr(92) || '_'
    ) || '%';
  end if;

  return private.catalog_portal_facets_v3_impl(
    v_kind,
    v_query,
    v_exact_id,
    v_like_pattern,
    v_filters,
    v_fingerprint
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_facets_v3',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
begin
  if p_kind not in ('process', 'flow')
     or p_id is null
     or p_version is null
     or p_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  return private.portal_lcia_decorate_dataset_v1(
    private.portal_dataset_projection_v1(p_kind, p_id, p_version)
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_legacy_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_get_dataset_v1("p_kind" "text", "p_id" "uuid", "p_version" "text") to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_get_dataset_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_diagnostic_message text;
  v_diagnostic_state text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_get_dataset_v1(p_kind, p_id, p_version);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  if p_kind not in ('process', 'flow')
     or p_id is null
     or p_version is null
     or p_version !~ '^\d{2}\.\d{2}\.\d{3}$' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  return private.portal_lcia_decorate_dataset_v1(
    private.portal_dataset_projection_v1(p_kind, p_id, p_version)
  );
exception
  when sqlstate '22023' then
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'validation', 'reason', 'input'
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_get_dataset_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_get_published_lcia_values_v1"("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_mode text := btrim(coalesce(p_mode, ''));
  v_impact_ref text := nullif(btrim(coalesce(p_impact_ref, '')), '');
  v_limit integer := coalesce(p_limit, 50);
  v_ref_count integer;
  v_distinct_ref_count integer;
  v_impact_match_count integer;
  v_query_hash text;
  v_query_fields text[];
  v_cursor jsonb;
  v_cursor_request_order integer;
  v_cursor_ordinal bigint;
  v_cursor_sort_value text;
  v_cursor_sort_numeric numeric;
  v_binding record;
  v_projection record;
  v_rows jsonb := '[]'::jsonb;
  v_next_cursor text;
begin
  if v_mode not in (
       'process_all_impacts',
       'processes_one_impact',
       'ranked_processes_one_impact'
     )
     or v_limit not between 1 and 50
     or jsonb_typeof(p_process_refs) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_ref_count := jsonb_array_length(p_process_refs);
  if v_ref_count not between 1 and 50
     or (v_mode = 'process_all_impacts' and v_ref_count <> 1)
     or (v_mode = 'process_all_impacts' and v_impact_ref is not null)
     or (v_mode <> 'process_all_impacts'
         and (v_impact_ref is null or length(v_impact_ref) > 512))
     or exists (
       select 1
       from jsonb_array_elements(p_process_refs) as item(value)
       where private.portal_lcia_json_object_has_keys_v1(
         item.value, array['id', 'version']
       ) is not true
         or jsonb_typeof(item.value -> 'id') <> 'string'
         or jsonb_typeof(item.value -> 'version') <> 'string'
         or coalesce(item.value ->> 'id', '')
              !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or coalesce(item.value ->> 'version', '')
              !~ '^\d{2}\.\d{2}\.\d{3}$'
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select count(distinct (item.value ->> 'id', item.value ->> 'version'))
  into v_distinct_ref_count
  from jsonb_array_elements(p_process_refs) as item(value);
  if v_distinct_ref_count <> v_ref_count then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  select
    binding.id,
    binding.projection_id,
    binding.lcia_result_publication_id,
    binding.package_id,
    binding.package_version,
    binding.projection_content_hash,
    binding.evidence_hash,
    binding.source_published_at,
    binding.status,
    binding.revoked_at
  into v_binding
  from private.portal_lcia_projection_publications as binding
  where binding.status = 'finalized'
  order by binding.source_published_at desc, binding.id
  limit 1;
  if v_binding.id is null then
    return null;
  end if;
  select
    projection.id,
    projection.status,
    projection.process_count,
    projection.impact_count,
    projection.expected_value_count,
    projection.content_hash
  into v_projection
  from private.portal_lcia_projection_headers as projection
  where projection.id = v_binding.projection_id;
  if v_projection.id is null then
    return null;
  end if;
  if v_mode <> 'process_all_impacts' then
    select count(*) into v_impact_match_count
    from private.portal_lcia_projection_impact_axis as impact_row
    where impact_row.projection_id = v_projection.id
      and impact_row.impact_id = v_impact_ref;
    if v_impact_match_count > 1 then
      raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
    end if;
  end if;

  select array[
    'portal.published-lcia-query.v1',
    'portal.lcia-projection.int32be-frame-sha256.v1',
    v_binding.lcia_result_publication_id::text,
    v_binding.projection_content_hash,
    v_mode,
    coalesce(v_impact_ref, ''),
    v_ref_count::text
  ] || array_agg(field.value order by ref.ordinality, field.position)
  into v_query_fields
  from jsonb_array_elements(p_process_refs)
    with ordinality as ref(value, ordinality)
  cross join lateral (
    values (1, ref.value ->> 'id'), (2, ref.value ->> 'version')
  ) as field(position, value);
  v_query_hash := private.portal_lcia_projection_sha256_fields_v1(
    variadic v_query_fields
  );

  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 8
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'publicationId'
            <> v_binding.lcia_result_publication_id::text
       or v_cursor ->> 'contentHash' <> v_binding.projection_content_hash
       or v_cursor ->> 'mode' <> v_mode
       or v_cursor ->> 'queryHash' <> v_query_hash
       or coalesce(v_cursor ->> 'requestOrder', '') !~ '^\d+$'
       or coalesce(v_cursor ->> 'ordinal', '') !~ '^\d+$'
       or jsonb_typeof(v_cursor -> 'sortValue') <> 'string' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    begin
      v_cursor_request_order := (v_cursor ->> 'requestOrder')::integer;
      v_cursor_ordinal := (v_cursor ->> 'ordinal')::bigint;
    exception when others then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end;
    v_cursor_sort_value := v_cursor ->> 'sortValue';
    if v_mode = 'ranked_processes_one_impact' then
      if private.portal_canonical_decimal_v1(v_cursor_sort_value)
           is distinct from v_cursor_sort_value then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
      v_cursor_sort_numeric := v_cursor_sort_value::numeric;
    elsif v_cursor_sort_value <> '' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;

  with refs as materialized (
    select
      ref.ordinality::integer as request_order,
      (ref.value ->> 'id')::uuid as process_id,
      ref.value ->> 'version' as process_version
    from jsonb_array_elements(p_process_refs)
      with ordinality as ref(value, ordinality)
  ), eligible as materialized (
    select
      refs.request_order,
      process_row.process_index,
      impact_row.impact_index,
      value_row.ordinal,
      value_row.value_text,
      value_row.value_numeric,
      process_row.process_id,
      process_row.process_version,
      process_row.functional_unit_amount,
      process_row.functional_unit_unit,
      process_row.functional_unit_description,
      process_row.geography_code,
      process_row.geography_precision,
      process_row.reference_year,
      impact_row.method_id,
      impact_row.method_version,
      impact_row.impact_id,
      impact_row.impact_name,
      impact_row.unit
    from refs
    join private.portal_lcia_projection_process_axis as process_row
      on process_row.projection_id = v_projection.id
     and process_row.process_id = refs.process_id
     and process_row.process_version = refs.process_version
    join public.processes as public_process
      on public_process.id = process_row.process_id
     and public_process.version::text = process_row.process_version
     and public_process.state_code = 100
     and (
       private.portal_capabilities_v1(
         'process', public_process.state_code, public_process.json
       ) ->> 'exchangesVisible'
     )::boolean
    join private.portal_lcia_projection_values as value_row
      on value_row.projection_id = process_row.projection_id
     and value_row.process_index = process_row.process_index
    join private.portal_lcia_projection_impact_axis as impact_row
      on impact_row.projection_id = value_row.projection_id
     and impact_row.impact_index = value_row.impact_index
    where v_mode = 'process_all_impacts'
       or impact_row.impact_id = v_impact_ref
  ), after_cursor as materialized (
    select eligible.*
    from eligible
    where v_cursor is null
       or (
         v_mode = 'process_all_impacts'
         and eligible.ordinal > v_cursor_ordinal
       )
       or (
         v_mode = 'processes_one_impact'
         and (eligible.request_order, eligible.ordinal)
               > (v_cursor_request_order, v_cursor_ordinal)
       )
       or (
         v_mode = 'ranked_processes_one_impact'
         and (
           eligible.value_numeric < v_cursor_sort_numeric
           or (
             eligible.value_numeric = v_cursor_sort_numeric
             and eligible.ordinal > v_cursor_ordinal
           )
         )
       )
  ), ordered as materialized (
    select after_cursor.*,
      row_number() over (
        order by
          case when v_mode = 'ranked_processes_one_impact'
            then after_cursor.value_numeric end desc nulls last,
          case when v_mode = 'processes_one_impact'
            then after_cursor.request_order end asc nulls last,
          after_cursor.ordinal asc
      ) as page_rank
    from after_cursor
    order by
      case when v_mode = 'ranked_processes_one_impact'
        then after_cursor.value_numeric end desc nulls last,
      case when v_mode = 'processes_one_impact'
        then after_cursor.request_order end asc nulls last,
      after_cursor.ordinal asc
    limit v_limit + 1
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'process', jsonb_build_object(
            'id', ordered.process_id::text,
            'version', ordered.process_version
          ),
          'functionalUnit', jsonb_build_object(
            'amount', ordered.functional_unit_amount,
            'unit', ordered.functional_unit_unit,
            'description', ordered.functional_unit_description
          ),
          'geography', jsonb_build_object(
            'code', ordered.geography_code,
            'precision', ordered.geography_precision
          ),
          'referenceYear', ordered.reference_year,
          'method', jsonb_build_object(
            'id', ordered.method_id::text,
            'version', ordered.method_version
          ),
          'impact', jsonb_build_object(
            'id', ordered.impact_id,
            'name', ordered.impact_name
          ),
          'value', ordered.value_text,
          'unit', ordered.unit,
          'evidenceStatus', 'verified'
        )
        order by ordered.page_rank
      ) filter (where ordered.page_rank <= v_limit),
      '[]'::jsonb
    ),
    case
      when max(ordered.page_rank) > v_limit then
        private.portal_cursor_encode_v1(
          (
            jsonb_agg(
              jsonb_build_object(
                'v', 1,
                'publicationId', v_binding.lcia_result_publication_id::text,
                'contentHash', v_binding.projection_content_hash,
                'mode', v_mode,
                'queryHash', v_query_hash,
                'requestOrder', ordered.request_order::text,
                'ordinal', ordered.ordinal::text,
                'sortValue', case
                  when v_mode = 'ranked_processes_one_impact'
                    then ordered.value_text
                  else ''
                end
              ) order by ordered.page_rank
            ) filter (where ordered.page_rank = v_limit)
          ) -> 0
        )
      else null
    end
  into v_rows, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.published-lcia-page.v1',
    'mode', v_mode,
    'publication', jsonb_build_object(
      'publicationId', v_binding.lcia_result_publication_id::text,
      'packageId', v_binding.package_id::text,
      'packageVersion', v_binding.package_version,
      'publishedAt', private.portal_timestamp_v1(v_binding.source_published_at),
      'evidenceHash', v_binding.evidence_hash
    ),
    'rows', v_rows,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
end
$_$;

ALTER FUNCTION "private"."display_legacy_get_published_lcia_values_v1"("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_get_published_lcia_values_v1"("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_get_published_lcia_values_v1("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_get_published_lcia_values_v1"("p_mode" "text", "p_process_refs" "jsonb", "p_impact_ref" "text", "p_cursor" "text", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_mode text := btrim(coalesce(p_mode, ''));
  v_impact_ref text := nullif(btrim(coalesce(p_impact_ref, '')), '');
  v_limit integer := coalesce(p_limit, 50);
  v_ref_count integer;
  v_distinct_ref_count integer;
  v_impact_match_count integer;
  v_query_hash text;
  v_query_fields text[];
  v_cursor jsonb;
  v_cursor_request_order integer;
  v_cursor_ordinal bigint;
  v_cursor_sort_value text;
  v_cursor_sort_numeric numeric;
  v_binding record;
  v_projection record;
  v_rows jsonb := '[]'::jsonb;
  v_next_cursor text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_get_published_lcia_values_v1(p_mode, p_process_refs, p_impact_ref, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  if v_mode not in (
       'process_all_impacts',
       'processes_one_impact',
       'ranked_processes_one_impact'
     )
     or v_limit not between 1 and 50
     or jsonb_typeof(p_process_refs) is distinct from 'array' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_ref_count := jsonb_array_length(p_process_refs);
  if v_ref_count not between 1 and 50
     or (v_mode = 'process_all_impacts' and v_ref_count <> 1)
     or (v_mode = 'process_all_impacts' and v_impact_ref is not null)
     or (v_mode <> 'process_all_impacts'
         and (v_impact_ref is null or length(v_impact_ref) > 512))
     or exists (
       select 1
       from jsonb_array_elements(p_process_refs) as item(value)
       where private.portal_lcia_json_object_has_keys_v1(
         item.value, array['id', 'version']
       ) is not true
         or jsonb_typeof(item.value -> 'id') <> 'string'
         or jsonb_typeof(item.value -> 'version') <> 'string'
         or coalesce(item.value ->> 'id', '')
              !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or coalesce(item.value ->> 'version', '')
              !~ '^\d{2}\.\d{2}\.\d{3}$'
     ) then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select count(distinct (item.value ->> 'id', item.value ->> 'version'))
  into v_distinct_ref_count
  from jsonb_array_elements(p_process_refs) as item(value);
  if v_distinct_ref_count <> v_ref_count then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  select
    binding.id,
    binding.projection_id,
    binding.lcia_result_publication_id,
    binding.package_id,
    binding.package_version,
    binding.projection_content_hash,
    binding.evidence_hash,
    binding.source_published_at,
    binding.status,
    binding.revoked_at
  into v_binding
  from private.portal_lcia_projection_publications as binding
  where binding.status = 'finalized'
  order by binding.source_published_at desc, binding.id
  limit 1;
  if v_binding.id is null then
    return null;
  end if;
  select
    projection.id,
    projection.status,
    projection.process_count,
    projection.impact_count,
    projection.expected_value_count,
    projection.content_hash
  into v_projection
  from private.portal_lcia_projection_headers as projection
  where projection.id = v_binding.projection_id;
  if v_projection.id is null then
    return null;
  end if;
  if v_mode <> 'process_all_impacts' then
    select count(*) into v_impact_match_count
    from private.portal_lcia_projection_impact_axis as impact_row
    where impact_row.projection_id = v_projection.id
      and impact_row.impact_id = v_impact_ref;
    if v_impact_match_count > 1 then
      raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
    end if;
  end if;

  select array[
    'portal.published-lcia-query.v1',
    'portal.lcia-projection.int32be-frame-sha256.v1',
    v_binding.lcia_result_publication_id::text,
    v_binding.projection_content_hash,
    v_mode,
    coalesce(v_impact_ref, ''),
    v_ref_count::text
  ] || array_agg(field.value order by ref.ordinality, field.position)
  into v_query_fields
  from jsonb_array_elements(p_process_refs)
    with ordinality as ref(value, ordinality)
  cross join lateral (
    values (1, ref.value ->> 'id'), (2, ref.value ->> 'version')
  ) as field(position, value);
  v_query_hash := private.portal_lcia_projection_sha256_fields_v1(
    variadic v_query_fields
  );

  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 8
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'publicationId'
            <> v_binding.lcia_result_publication_id::text
       or v_cursor ->> 'contentHash' <> v_binding.projection_content_hash
       or v_cursor ->> 'mode' <> v_mode
       or v_cursor ->> 'queryHash' <> v_query_hash
       or coalesce(v_cursor ->> 'requestOrder', '') !~ '^\d+$'
       or coalesce(v_cursor ->> 'ordinal', '') !~ '^\d+$'
       or jsonb_typeof(v_cursor -> 'sortValue') <> 'string' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    begin
      v_cursor_request_order := (v_cursor ->> 'requestOrder')::integer;
      v_cursor_ordinal := (v_cursor ->> 'ordinal')::bigint;
    exception when others then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end;
    v_cursor_sort_value := v_cursor ->> 'sortValue';
    if v_mode = 'ranked_processes_one_impact' then
      if private.portal_canonical_decimal_v1(v_cursor_sort_value)
           is distinct from v_cursor_sort_value then
        raise exception using errcode = '22023', message = 'invalid portal request';
      end if;
      v_cursor_sort_numeric := v_cursor_sort_value::numeric;
    elsif v_cursor_sort_value <> '' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;

  with refs as materialized (
    select
      ref.ordinality::integer as request_order,
      (ref.value ->> 'id')::uuid as process_id,
      ref.value ->> 'version' as process_version
    from jsonb_array_elements(p_process_refs)
      with ordinality as ref(value, ordinality)
  ), eligible as materialized (
    select
      refs.request_order,
      process_row.process_index,
      impact_row.impact_index,
      value_row.ordinal,
      value_row.value_text,
      value_row.value_numeric,
      process_row.process_id,
      process_row.process_version,
      process_row.functional_unit_amount,
      process_row.functional_unit_unit,
      process_row.functional_unit_description,
      process_row.geography_code,
      process_row.geography_precision,
      process_row.reference_year,
      impact_row.method_id,
      impact_row.method_version,
      impact_row.impact_id,
      impact_row.impact_name,
      impact_row.unit
    from refs
    join private.portal_lcia_projection_process_axis as process_row
      on process_row.projection_id = v_projection.id
     and process_row.process_id = refs.process_id
     and process_row.process_version = refs.process_version
    join public.processes as public_process
      on public_process.id = process_row.process_id
     and public_process.version::text = process_row.process_version
     and public_process.state_code = 100
     and (
       private.portal_capabilities_v1(
         'process', public_process.state_code, public_process.json
       ) ->> 'exchangesVisible'
     )::boolean
    join private.portal_lcia_projection_values as value_row
      on value_row.projection_id = process_row.projection_id
     and value_row.process_index = process_row.process_index
    join private.portal_lcia_projection_impact_axis as impact_row
      on impact_row.projection_id = value_row.projection_id
     and impact_row.impact_index = value_row.impact_index
    where v_mode = 'process_all_impacts'
       or impact_row.impact_id = v_impact_ref
  ), after_cursor as materialized (
    select eligible.*
    from eligible
    where v_cursor is null
       or (
         v_mode = 'process_all_impacts'
         and eligible.ordinal > v_cursor_ordinal
       )
       or (
         v_mode = 'processes_one_impact'
         and (eligible.request_order, eligible.ordinal)
               > (v_cursor_request_order, v_cursor_ordinal)
       )
       or (
         v_mode = 'ranked_processes_one_impact'
         and (
           eligible.value_numeric < v_cursor_sort_numeric
           or (
             eligible.value_numeric = v_cursor_sort_numeric
             and eligible.ordinal > v_cursor_ordinal
           )
         )
       )
  ), ordered as materialized (
    select after_cursor.*,
      row_number() over (
        order by
          case when v_mode = 'ranked_processes_one_impact'
            then after_cursor.value_numeric end desc nulls last,
          case when v_mode = 'processes_one_impact'
            then after_cursor.request_order end asc nulls last,
          after_cursor.ordinal asc
      ) as page_rank
    from after_cursor
    order by
      case when v_mode = 'ranked_processes_one_impact'
        then after_cursor.value_numeric end desc nulls last,
      case when v_mode = 'processes_one_impact'
        then after_cursor.request_order end asc nulls last,
      after_cursor.ordinal asc
    limit v_limit + 1
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'process', jsonb_build_object(
            'id', ordered.process_id::text,
            'version', ordered.process_version
          ),
          'functionalUnit', jsonb_build_object(
            'amount', ordered.functional_unit_amount,
            'unit', ordered.functional_unit_unit,
            'description', ordered.functional_unit_description
          ),
          'geography', jsonb_build_object(
            'code', ordered.geography_code,
            'precision', ordered.geography_precision
          ),
          'referenceYear', ordered.reference_year,
          'method', jsonb_build_object(
            'id', ordered.method_id::text,
            'version', ordered.method_version
          ),
          'impact', jsonb_build_object(
            'id', ordered.impact_id,
            'name', ordered.impact_name
          ),
          'value', ordered.value_text,
          'unit', ordered.unit,
          'evidenceStatus', 'verified'
        )
        order by ordered.page_rank
      ) filter (where ordered.page_rank <= v_limit),
      '[]'::jsonb
    ),
    case
      when max(ordered.page_rank) > v_limit then
        private.portal_cursor_encode_v1(
          (
            jsonb_agg(
              jsonb_build_object(
                'v', 1,
                'publicationId', v_binding.lcia_result_publication_id::text,
                'contentHash', v_binding.projection_content_hash,
                'mode', v_mode,
                'queryHash', v_query_hash,
                'requestOrder', ordered.request_order::text,
                'ordinal', ordered.ordinal::text,
                'sortValue', case
                  when v_mode = 'ranked_processes_one_impact'
                    then ordered.value_text
                  else ''
                end
              ) order by ordered.page_rank
            ) filter (where ordered.page_rank = v_limit)
          ) -> 0
        )
      else null
    end
  into v_rows, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.published-lcia-page.v1',
    'mode', v_mode,
    'publication', jsonb_build_object(
      'publicationId', v_binding.lcia_result_publication_id::text,
      'packageId', v_binding.package_id::text,
      'packageVersion', v_binding.package_version,
      'publishedAt', private.portal_timestamp_v1(v_binding.source_published_at),
      'evidenceHash', v_binding.evidence_hash
    ),
    'rows', v_rows,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal lcia unavailable';
end
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_hybrid_search_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $$
declare
  v_input jsonb;
  v_page jsonb;
begin
  v_input := private.portal_public_hybrid_input_v1(
    p_kind,
    p_query_terms,
    p_query_embedding,
    p_filters,
    p_limit
  );
  v_page := private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_projection_hybrid_search_v1_impl(
        v_input ->> 'kind',
        array(
          select term.value
          from pg_catalog.jsonb_array_elements_text(v_input -> 'queryTerms')
            with ordinality as term(value, ordinality)
          order by term.ordinality
        ),
        (v_input ->> 'queryEmbedding')::extensions.vector(1024),
        v_input -> 'filters',
        (v_input ->> 'limit')::integer,
        v_input ->> 'queryFingerprint'
      )
    )
  );
  if v_page is null
     or pg_catalog.octet_length(
       pg_catalog.convert_to(v_page::text, 'UTF8')
     ) > 524288 then
    raise exception using
      errcode = '54000',
      message = 'portal hybrid response too large';
  end if;
  return v_page;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
end
$$;

ALTER FUNCTION "private"."display_legacy_hybrid_search_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_hybrid_search_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_api_hybrid_search_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $$
declare
  v_input jsonb;
  v_page jsonb;
begin
  v_input := private.display_public_hybrid_input_v1(
    p_kind,
    p_query_terms,
    p_query_embedding,
    p_filters,
    p_limit
  );
  v_page := private.display_decorate_card_context_v1(
    private.display_lcia_decorate_item_page_v1(
      private.display_projection_hybrid_search_v1_impl(
        v_input ->> 'kind',
        array(
          select term.value
          from pg_catalog.jsonb_array_elements_text(v_input -> 'queryTerms')
            with ordinality as term(value, ordinality)
          order by term.ordinality
        ),
        (v_input ->> 'queryEmbedding')::extensions.vector(1024),
        v_input -> 'filters',
        (v_input ->> 'limit')::integer,
        v_input ->> 'queryFingerprint'
      )
    )
  );
  if v_page is null
     or pg_catalog.octet_length(
       pg_catalog.convert_to(v_page::text, 'UTF8')
     ) > 524288 then
    raise exception using
      errcode = '54000',
      message = 'portal hybrid response too large';
  end if;
  return v_page;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
end
$$;

ALTER FUNCTION "private"."display_api_hybrid_search_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_hybrid_search_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_hybrid_search_v1("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_hybrid_search_v1"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $$
declare
  v_input jsonb;
  v_page jsonb;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_hybrid_search_v1(p_kind, p_query_terms, p_query_embedding, p_filters, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  v_input := private.portal_public_hybrid_input_v1(
    p_kind,
    p_query_terms,
    p_query_embedding,
    p_filters,
    p_limit
  );
  v_page := private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_projection_hybrid_search_v1_impl(
        v_input ->> 'kind',
        array(
          select term.value
          from pg_catalog.jsonb_array_elements_text(v_input -> 'queryTerms')
            with ordinality as term(value, ordinality)
          order by term.ordinality
        ),
        (v_input ->> 'queryEmbedding')::extensions.vector(1024),
        v_input -> 'filters',
        (v_input ->> 'limit')::integer,
        v_input ->> 'queryFingerprint'
      )
    )
  );
  if v_page is null
     or pg_catalog.octet_length(
       pg_catalog.convert_to(v_page::text, 'UTF8')
     ) > 524288 then
    raise exception using
      errcode = '54000',
      message = 'portal hybrid response too large';
  end if;
  return v_page;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
end
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_hybrid_search_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $_$
declare
  v_input jsonb;
  v_fingerprint text;
  v_cursor jsonb;
  v_page jsonb;
begin
  v_input := private.portal_public_hybrid_input_v1(
    p_kind,p_query_terms,p_query_embedding,p_filters,p_limit);
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-hybrid-rank-v2:' || case when v_input ->> 'kind' = 'process' then 'composite-names-v2:' else '' end || (v_input ->> 'queryFingerprint'),'UTF8'),
    'sha256'),'hex');
  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
      or (select count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
      or not (v_cursor ?& array['v','fp','kind','rankKey','id','version'])
      or v_cursor ->> 'v' is distinct from '1'
      or v_cursor ->> 'fp' is distinct from v_fingerprint
      or v_cursor ->> 'kind' is distinct from p_kind
      or pg_catalog.jsonb_typeof(v_cursor -> 'rankKey') is distinct from 'string'
      or coalesce(v_cursor ->> 'rankKey','') !~ '^(0(\.\d{1,12})?|1(\.0{1,12})?)$'
      or coalesce(v_cursor ->> 'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(v_cursor ->> 'version','') !~ '^\d{2}\.\d{2}\.\d{3}$'
      or private.portal_cursor_encode_v1(v_cursor) is distinct from p_cursor then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;
  v_page := private.portal_decorate_card_context_v1(private.portal_lcia_decorate_item_page_v1(
    private.portal_projection_hybrid_search_v2_impl(
      p_kind,
      array(select term.value from pg_catalog.jsonb_array_elements_text(v_input -> 'queryTerms')
        with ordinality as term(value,ordinality) order by term.ordinality),
      (v_input ->> 'queryEmbedding')::extensions.vector(1024),
      v_input -> 'filters',p_limit,v_fingerprint,v_cursor
    )
  ));
  v_page := pg_catalog.jsonb_set(v_page,'{schemaVersion}','"portal.public-hybrid-candidate-page.v2"'::jsonb);
  v_page := (v_page - 'nextCursorPayload') || pg_catalog.jsonb_build_object(
    'nextCursor',case when nullif(v_page -> 'nextCursorPayload','null'::jsonb) is null then null
      else private.portal_cursor_encode_v1(v_page -> 'nextCursorPayload') end
  );
  if v_page is null or pg_catalog.octet_length(pg_catalog.convert_to(v_page::text,'UTF8')) > 524288 then
    raise exception using errcode = '54000', message = 'portal hybrid response too large';
  end if;
  return v_page;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
end;
$_$;

ALTER FUNCTION "private"."display_legacy_hybrid_search_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_hybrid_search_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_hybrid_search_v2("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text") to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_hybrid_search_v2"("p_kind" "text", "p_query_terms" "text"[], "p_query_embedding" "text", "p_filters" "jsonb", "p_limit" integer, "p_cursor" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $_$
declare
  v_input jsonb;
  v_fingerprint text;
  v_cursor jsonb;
  v_page jsonb;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_hybrid_search_v2(p_kind, p_query_terms, p_query_embedding, p_filters, p_limit, p_cursor);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  v_input := private.portal_public_hybrid_input_v1(
    p_kind,p_query_terms,p_query_embedding,p_filters,p_limit);
  v_fingerprint := pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to('portal-hybrid-rank-v2:' || case when v_input ->> 'kind' = 'process' then 'composite-names-v2:' else '' end || (v_input ->> 'queryFingerprint'),'UTF8'),
    'sha256'),'hex');
  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
      or (select count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 6
      or not (v_cursor ?& array['v','fp','kind','rankKey','id','version'])
      or v_cursor ->> 'v' is distinct from '1'
      or v_cursor ->> 'fp' is distinct from v_fingerprint
      or v_cursor ->> 'kind' is distinct from p_kind
      or pg_catalog.jsonb_typeof(v_cursor -> 'rankKey') is distinct from 'string'
      or coalesce(v_cursor ->> 'rankKey','') !~ '^(0(\.\d{1,12})?|1(\.0{1,12})?)$'
      or coalesce(v_cursor ->> 'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(v_cursor ->> 'version','') !~ '^\d{2}\.\d{2}\.\d{3}$'
      or private.portal_cursor_encode_v1(v_cursor) is distinct from p_cursor then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
  end if;
  v_page := private.portal_decorate_card_context_v1(private.portal_lcia_decorate_item_page_v1(
    private.portal_projection_hybrid_search_v2_impl(
      p_kind,
      array(select term.value from pg_catalog.jsonb_array_elements_text(v_input -> 'queryTerms')
        with ordinality as term(value,ordinality) order by term.ordinality),
      (v_input ->> 'queryEmbedding')::extensions.vector(1024),
      v_input -> 'filters',p_limit,v_fingerprint,v_cursor
    )
  ));
  v_page := pg_catalog.jsonb_set(v_page,'{schemaVersion}','"portal.public-hybrid-candidate-page.v2"'::jsonb);
  v_page := (v_page - 'nextCursorPayload') || pg_catalog.jsonb_build_object(
    'nextCursor',case when nullif(v_page -> 'nextCursorPayload','null'::jsonb) is null then null
      else private.portal_cursor_encode_v1(v_page -> 'nextCursorPayload') end
  );
  if v_page is null or pg_catalog.octet_length(pg_catalog.convert_to(v_page::text,'UTF8')) > 524288 then
    raise exception using errcode = '54000', message = 'portal hybrid response too large';
  end if;
  return v_page;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal hybrid unavailable';
end;
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text" DEFAULT 'all'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_process_json jsonb;
  v_process_state integer;
  v_functional_unit jsonb;
  v_cursor jsonb;
  v_cursor_internal integer;
  v_cursor_internal_text text;
  v_cursor_kind text;
  v_rows jsonb;
  v_next_cursor text;
begin
  if pg_catalog.octet_length(coalesce(p_exchange_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := lower(btrim(coalesce(p_exchange_kind, 'all')));
  if p_process_id is null
     or p_process_version is null
     or p_process_version !~ '^\d{2}\.\d{2}\.\d{3}$'
     or v_kind not in ('all', 'technosphere', 'elementary', 'waste')
     or p_limit is null
     or p_limit not between 1 and 50 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select row.json, row.state_code
  into v_process_json, v_process_state
  from public.processes as row
  where row.id = p_process_id
    and row.version::text = p_process_version
    and row.state_code in (100, 200)
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'processDataSet') = 'object'
  limit 1;
  if v_process_json is null then
    return null;
  end if;
  v_functional_unit := private.portal_process_functional_unit_v1(v_process_state, v_process_json);

  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'processId' <> p_process_id::text
       or v_cursor ->> 'processVersion' <> p_process_version
       or v_cursor ->> 'filterKind' <> v_kind
       or coalesce(v_cursor ->> 'internalId', '') !~ '^(0|[1-9][0-9]{0,5})$'
       or v_cursor ->> 'kind' not in ('technosphere', 'elementary', 'waste') then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_internal_text := v_cursor ->> 'internalId';
    v_cursor_internal := v_cursor_internal_text::integer;
    v_cursor_kind := v_cursor ->> 'kind';
  end if;

  with raw_exchanges as materialized (
    select exchange.item,
      exchange.item ->> '@dataSetInternalID' as internal_id,
      count(*) over (partition by exchange.item ->> '@dataSetInternalID') as identity_count
    from private.portal_json_items_v1(v_process_json #> '{processDataSet,exchanges,exchange}') as exchange(item)
  ), supported as materialized (
    select support -> 'row' as row_data
    from raw_exchanges
    cross join lateral private.portal_exchange_support_v1(v_process_state, v_process_json, raw_exchanges.item) as support
    where raw_exchanges.identity_count = 1
      and nullif(v_functional_unit ->> 'amount', '') is not null
      and nullif(v_functional_unit ->> 'unit', '') is not null
      and support is not null
  ), filtered as materialized (
    select supported.row_data,
      (supported.row_data ->> 'internalId')::integer as internal_number,
      supported.row_data ->> 'internalId' as internal_text,
      supported.row_data ->> 'kind' as row_kind
    from supported
    where v_kind = 'all' or supported.row_data ->> 'kind' = v_kind
  ), ordered as materialized (
    select filtered.*,
      row_number() over (order by filtered.internal_number, filtered.internal_text, filtered.row_kind) as page_rank
    from filtered
    where v_cursor is null
      or (filtered.internal_number, filtered.internal_text, filtered.row_kind) >
         (v_cursor_internal, v_cursor_internal_text, v_cursor_kind)
    order by filtered.internal_number, filtered.internal_text, filtered.row_kind
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(ordered.row_data order by ordered.page_rank)
      filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit then private.portal_cursor_encode_v1(
      (jsonb_agg(jsonb_build_object(
        'v', 1,
        'processId', p_process_id::text,
        'processVersion', p_process_version,
        'filterKind', v_kind,
        'internalId', ordered.internal_text,
        'kind', ordered.row_kind
      ) order by ordered.page_rank) filter (where ordered.page_rank = p_limit)) -> 0
    ) else null end
  into v_rows, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.public-exchange-page.v1',
    'process', jsonb_build_object('id', p_process_id::text, 'version', p_process_version),
    'processContext', jsonb_build_object(
      'functionalUnit', v_functional_unit,
      'capabilityPolicyVersion', 'portal-capability-policy.v1'
    ),
    'rows', v_rows,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_legacy_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_list_process_exchanges_v1("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_list_process_exchanges_v1"("p_process_id" "uuid", "p_process_version" "text", "p_exchange_kind" "text" DEFAULT 'all'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_kind text;
  v_process_json jsonb;
  v_process_state integer;
  v_functional_unit jsonb;
  v_cursor jsonb;
  v_cursor_internal integer;
  v_cursor_internal_text text;
  v_cursor_kind text;
  v_rows jsonb;
  v_next_cursor text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_list_process_exchanges_v1(p_process_id, p_process_version, p_exchange_kind, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  if pg_catalog.octet_length(coalesce(p_exchange_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_kind := lower(btrim(coalesce(p_exchange_kind, 'all')));
  if p_process_id is null
     or p_process_version is null
     or p_process_version !~ '^\d{2}\.\d{2}\.\d{3}$'
     or v_kind not in ('all', 'technosphere', 'elementary', 'waste')
     or p_limit is null
     or p_limit not between 1 and 50 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  select row.json, row.state_code
  into v_process_json, v_process_state
  from public.processes as row
  where row.id = p_process_id
    and row.version::text = p_process_version
    and row.state_code in (100, 200)
    and jsonb_typeof(row.json) = 'object'
    and jsonb_typeof(row.json -> 'processDataSet') = 'object'
  limit 1;
  if v_process_json is null then
    return null;
  end if;
  v_functional_unit := private.portal_process_functional_unit_v1(v_process_state, v_process_json);

  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 6
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'processId' <> p_process_id::text
       or v_cursor ->> 'processVersion' <> p_process_version
       or v_cursor ->> 'filterKind' <> v_kind
       or coalesce(v_cursor ->> 'internalId', '') !~ '^(0|[1-9][0-9]{0,5})$'
       or v_cursor ->> 'kind' not in ('technosphere', 'elementary', 'waste') then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_internal_text := v_cursor ->> 'internalId';
    v_cursor_internal := v_cursor_internal_text::integer;
    v_cursor_kind := v_cursor ->> 'kind';
  end if;

  with raw_exchanges as materialized (
    select exchange.item,
      exchange.item ->> '@dataSetInternalID' as internal_id,
      count(*) over (partition by exchange.item ->> '@dataSetInternalID') as identity_count
    from private.portal_json_items_v1(v_process_json #> '{processDataSet,exchanges,exchange}') as exchange(item)
  ), supported as materialized (
    select support -> 'row' as row_data
    from raw_exchanges
    cross join lateral private.portal_exchange_support_v1(v_process_state, v_process_json, raw_exchanges.item) as support
    where raw_exchanges.identity_count = 1
      and nullif(v_functional_unit ->> 'amount', '') is not null
      and nullif(v_functional_unit ->> 'unit', '') is not null
      and support is not null
  ), filtered as materialized (
    select supported.row_data,
      (supported.row_data ->> 'internalId')::integer as internal_number,
      supported.row_data ->> 'internalId' as internal_text,
      supported.row_data ->> 'kind' as row_kind
    from supported
    where v_kind = 'all' or supported.row_data ->> 'kind' = v_kind
  ), ordered as materialized (
    select filtered.*,
      row_number() over (order by filtered.internal_number, filtered.internal_text, filtered.row_kind) as page_rank
    from filtered
    where v_cursor is null
      or (filtered.internal_number, filtered.internal_text, filtered.row_kind) >
         (v_cursor_internal, v_cursor_internal_text, v_cursor_kind)
    order by filtered.internal_number, filtered.internal_text, filtered.row_kind
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(ordered.row_data order by ordered.page_rank)
      filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit then private.portal_cursor_encode_v1(
      (jsonb_agg(jsonb_build_object(
        'v', 1,
        'processId', p_process_id::text,
        'processVersion', p_process_version,
        'filterKind', v_kind,
        'internalId', ordered.internal_text,
        'kind', ordered.row_kind
      ) order by ordered.page_rank) filter (where ordered.page_rank = p_limit)) -> 0
    ) else null end
  into v_rows, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.public-exchange-page.v1',
    'process', jsonb_build_object('id', p_process_id::text, 'version', p_process_version),
    'processContext', jsonb_build_object(
      'functionalUnit', v_functional_unit,
      'capabilityPolicyVersion', 'portal-capability-policy.v1'
    ),
    'rows', v_rows,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_list_versions_v1"("p_kind" "text", "p_id" "uuid", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_cursor jsonb;
  v_cursor_version text;
  v_items jsonb;
  v_next_cursor text;
begin
  if p_kind not in ('process', 'flow')
     or p_id is null
     or p_limit is null
     or p_limit not between 1 and 50 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 4
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'kind' <> p_kind
       or v_cursor ->> 'id' <> p_id::text
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_version := v_cursor ->> 'version';
  end if;

  with all_versions as materialized (
    select source.*,
      row_number() over (order by source.version desc) = 1 as is_latest,
      private.portal_capabilities_v1(
        p_kind, source.state_code, source.json_data
      ) as capabilities
    from private.portal_dataset_rows_v1(p_kind, p_id) as source
  ), ordered as materialized (
    select all_versions.*,
      row_number() over (order by all_versions.version desc) as page_rank
    from all_versions
    where v_cursor_version is null or all_versions.version < v_cursor_version
    order by all_versions.version desc
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'key', jsonb_build_object(
        'kind', p_kind,
        'id', ordered.id::text,
        'version', ordered.version
      ),
      'accessLevel', case
        when (ordered.capabilities ->> 'exchangesVisible')::boolean
          then 'open'
        else 'metadata_only'
      end,
      'capabilities', ordered.capabilities,
      'modifiedAt', private.portal_timestamp_v1(ordered.modified_at),
      'isLatest', ordered.is_latest
    ) order by ordered.page_rank)
      filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit
      then private.portal_cursor_encode_v1(
        (jsonb_agg(jsonb_build_object(
          'v', 1,
          'kind', p_kind,
          'id', p_id::text,
          'version', ordered.version
        ) order by ordered.page_rank)
          filter (where ordered.page_rank = p_limit)) -> 0
      )
      else null
    end
  into v_items, v_next_cursor
  from ordered;

  return private.portal_lcia_decorate_item_page_v1(
    jsonb_build_object(
      'schemaVersion', 'portal.public-version-page.v1',
      'dataset', jsonb_build_object('kind', p_kind, 'id', p_id::text),
      'items', v_items,
      'nextCursor', v_next_cursor
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_legacy_list_versions_v1"("p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_list_versions_v1"("p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_list_versions_v1("p_kind" "text", "p_id" "uuid", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_list_versions_v1"("p_kind" "text", "p_id" "uuid", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_cursor jsonb;
  v_cursor_version text;
  v_items jsonb;
  v_next_cursor text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_list_versions_v1(p_kind, p_id, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  if p_kind not in ('process', 'flow')
     or p_id is null
     or p_limit is null
     or p_limit not between 1 and 50 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 4
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'kind' <> p_kind
       or v_cursor ->> 'id' <> p_id::text
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_version := v_cursor ->> 'version';
  end if;

  with all_versions as materialized (
    select source.*,
      row_number() over (order by source.version desc) = 1 as is_latest,
      private.portal_capabilities_v1(
        p_kind, source.state_code, source.json_data
      ) as capabilities
    from private.portal_dataset_rows_v1(p_kind, p_id) as source
  ), ordered as materialized (
    select all_versions.*,
      row_number() over (order by all_versions.version desc) as page_rank
    from all_versions
    where v_cursor_version is null or all_versions.version < v_cursor_version
    order by all_versions.version desc
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'key', jsonb_build_object(
        'kind', p_kind,
        'id', ordered.id::text,
        'version', ordered.version
      ),
      'accessLevel', case
        when (ordered.capabilities ->> 'exchangesVisible')::boolean
          then 'open'
        else 'metadata_only'
      end,
      'capabilities', ordered.capabilities,
      'modifiedAt', private.portal_timestamp_v1(ordered.modified_at),
      'isLatest', ordered.is_latest
    ) order by ordered.page_rank)
      filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit
      then private.portal_cursor_encode_v1(
        (jsonb_agg(jsonb_build_object(
          'v', 1,
          'kind', p_kind,
          'id', p_id::text,
          'version', ordered.version
        ) order by ordered.page_rank)
          filter (where ordered.page_rank = p_limit)) -> 0
      )
      else null
    end
  into v_items, v_next_cursor
  from ordered;

  return private.portal_lcia_decorate_item_page_v1(
    jsonb_build_object(
      'schemaVersion', 'portal.public-version-page.v1',
      'dataset', jsonb_build_object('kind', p_kind, 'id', p_id::text),
      'items', v_items,
      'nextCursor', v_next_cursor
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_navigation_v1"("p_kind" "text", "p_query" "text" DEFAULT ''::"text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_dimension" "text" DEFAULT 'classification'::"text", "p_parent_node_id" "text" DEFAULT NULL::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "row_security" TO 'on'
    AS $$
declare
  v_diagnostic_message text;
  v_diagnostic_context text;
  v_diagnostic_state text;
begin
  return private.portal_navigation_v1(p_kind,p_query,p_filters,p_dimension,p_parent_node_id,p_cursor,p_limit);
exception
  when sqlstate '22023' then
    get stacked diagnostics v_diagnostic_context = PG_EXCEPTION_CONTEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_navigation_v1',
        'category', 'validation', 'reason', case
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_validate_search_v1\(' then 'search_input'
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_validate_search_v3\(' then 'hierarchy_input'
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_navigation_impl_v1\(' then
            case when p_cursor is null then 'parent' else 'parent_or_cursor_node' end
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_navigation_v1\(' then
            case
              when p_dimension is null or p_dimension not in ('classification', 'geography')
                or coalesce(p_limit, 100) not between 1 and 500 then 'navigation_options'
              when p_cursor is not null then 'cursor_binding'
              else 'unknown'
            end
          else 'unknown'
        end
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_navigation_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_navigation_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;

ALTER FUNCTION "private"."display_legacy_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_navigation_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_navigation_v1("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_navigation_v1"("p_kind" "text", "p_query" "text" DEFAULT ''::"text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_dimension" "text" DEFAULT 'classification'::"text", "p_parent_node_id" "text" DEFAULT NULL::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "row_security" TO 'on'
    AS $$
declare
  v_diagnostic_message text;
  v_diagnostic_context text;
  v_diagnostic_state text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_navigation_v1(p_kind, p_query, p_filters, p_dimension, p_parent_node_id, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return private.portal_navigation_v1(p_kind,p_query,p_filters,p_dimension,p_parent_node_id,p_cursor,p_limit);
exception
  when sqlstate '22023' then
    get stacked diagnostics v_diagnostic_context = PG_EXCEPTION_CONTEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_navigation_v1',
        'category', 'validation', 'reason', case
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_validate_search_v1\(' then 'search_input'
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_validate_search_v3\(' then 'hierarchy_input'
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_navigation_impl_v1\(' then
            case when p_cursor is null then 'parent' else 'parent_or_cursor_node' end
          when v_diagnostic_context ~ '^PL/pgSQL function private\.portal_navigation_v1\(' then
            case
              when p_dimension is null or p_dimension not in ('classification', 'geography')
                or coalesce(p_limit, 100) not between 1 and 500 then 'navigation_options'
              when p_cursor is not null then 'cursor_binding'
              else 'unknown'
            end
          else 'unknown'
        end
      )::text;
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    get stacked diagnostics v_diagnostic_message = MESSAGE_TEXT;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_navigation_v1',
        'category', 'cancellation', 'reason', case v_diagnostic_message
          when 'canceling statement due to statement timeout' then 'statement_timeout'
          when 'canceling statement due to user request' then 'cancel_request'
          else 'unknown'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    get stacked diagnostics v_diagnostic_state = RETURNED_SQLSTATE;
    raise log using message = 'portal read failure diagnostic',
      detail = pg_catalog.jsonb_build_object(
        'schemaVersion', 'portal.read-failure.v1', 'rpc', 'portal_navigation_v1',
        'category', 'internal', 'reason', case v_diagnostic_state
          when '54000' then 'response_budget'
          when '55000' then 'contract_drift'
          else 'other'
        end
      )::text;
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_search_flows_v1"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return private.portal_decorate_card_context_v1(
    private.portal_search_v1(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_legacy_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_api_search_flows_v1"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return private.display_decorate_card_context_v1(
    private.display_search_v1(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_api_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_search_flows_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_search_flows_v1("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_search_flows_v1"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_search_flows_v1(p_query, p_filters, p_sort, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return private.portal_decorate_card_context_v1(
    private.portal_search_v1(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_search_flows_v2"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_search_v2(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_legacy_search_flows_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_search_flows_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_api_search_flows_v2"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.display_decorate_card_context_v1(
    private.display_search_v2(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_api_search_flows_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_search_flows_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_search_flows_v2("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_search_flows_v2"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_search_flows_v2(p_query, p_filters, p_sort, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_search_v2(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_search_flows_v3"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_search_v3(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;

ALTER FUNCTION "private"."display_legacy_search_flows_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_search_flows_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_search_flows_v3("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_search_flows_v3"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_search_flows_v3(p_query, p_filters, p_sort, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_search_v3(
      'flow', p_query, p_filters, p_sort, p_cursor, p_limit
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_search_processes_v1"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_search_v1(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_legacy_search_processes_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_search_processes_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_api_search_processes_v1"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return private.display_decorate_card_context_v1(
    private.display_lcia_decorate_item_page_v1(
      private.display_search_v1(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_api_search_processes_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_search_processes_v1"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_search_processes_v1("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_search_processes_v1"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_search_processes_v1(p_query, p_filters, p_sort, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_search_v1(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_search_processes_v2"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_search_v2(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_legacy_search_processes_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_search_processes_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




CREATE OR REPLACE FUNCTION "private"."display_api_search_processes_v2"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.display_decorate_card_context_v1(
    private.display_lcia_decorate_item_page_v1(
      private.display_search_v2(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;

ALTER FUNCTION "private"."display_api_search_processes_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_api_search_processes_v2"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_search_processes_v2("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_search_processes_v2"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_search_processes_v2(p_query, p_filters, p_sort, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_search_v2(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_search_processes_v3"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_search_v3(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;

ALTER FUNCTION "private"."display_legacy_search_processes_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_search_processes_v3"("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_search_processes_v3("p_query" "text", "p_filters" "jsonb", "p_sort" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_search_processes_v3"("p_query" "text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_sort" "text" DEFAULT 'relevance'::"text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $$
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_search_processes_v3(p_query, p_filters, p_sort, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  return pg_catalog.jsonb_set(private.portal_decorate_card_context_v1(
    private.portal_lcia_decorate_item_page_v1(
      private.portal_search_v3(
        'process', p_query, p_filters, p_sort, p_cursor, p_limit
      )
    )
  ), '{schemaVersion}', '"portal.public-search-page.v2"'::jsonb);
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end;
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_sitemap_entries_v1"("p_kind" "text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 1000) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_filter_kind text;
  v_cursor jsonb;
  v_cursor_kind text;
  v_cursor_id uuid;
  v_items jsonb;
  v_next_cursor text;
begin
  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_filter_kind := lower(btrim(coalesce(p_kind, '')));
  if v_filter_kind not in ('process', 'flow', 'all')
     or p_limit is null
     or p_limit not between 1 and 1000 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 5
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'filterKind' <> v_filter_kind
       or v_cursor ->> 'kind' not in ('process', 'flow')
       or (v_filter_kind <> 'all' and v_cursor ->> 'kind' <> v_filter_kind)
       or coalesce(v_cursor ->> 'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_kind := v_cursor ->> 'kind';
    v_cursor_id := (v_cursor ->> 'id')::uuid;
  end if;

  with source_rows as materialized (
    select kinds.kind, source.*
    from (values ('process'::text), ('flow'::text)) as kinds(kind)
    cross join lateral private.portal_catalog_rows_v1(kinds.kind) as source
    where v_filter_kind = 'all' or kinds.kind = v_filter_kind
  ), latest as materialized (
    select candidate.*
    from (
      select source_rows.*,
        row_number() over (
          partition by source_rows.kind, source_rows.id
          order by source_rows.version desc
        ) as version_rank
      from source_rows
    ) as candidate
    where candidate.version_rank = 1
  ), ordered as materialized (
    select latest.*,
      row_number() over (order by latest.kind, latest.id) as page_rank
    from latest
    where v_cursor is null or (latest.kind, latest.id) > (v_cursor_kind, v_cursor_id)
    order by latest.kind, latest.id
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'key', jsonb_build_object(
        'kind', ordered.kind,
        'id', ordered.id::text,
        'version', ordered.version
      ),
      'modifiedAt', private.portal_timestamp_v1(ordered.modified_at)
    ) order by ordered.page_rank) filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit then private.portal_cursor_encode_v1(
      (jsonb_agg(jsonb_build_object(
        'v', 1,
        'filterKind', v_filter_kind,
        'kind', ordered.kind,
        'id', ordered.id::text,
        'version', ordered.version
      ) order by ordered.page_rank) filter (where ordered.page_rank = p_limit)) -> 0
    ) else null end
  into v_items, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-page.v1',
    'items', v_items,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;

ALTER FUNCTION "private"."display_legacy_sitemap_entries_v1"("p_kind" "text", "p_cursor" "text", "p_limit" integer) OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_sitemap_entries_v1"("p_kind" "text", "p_cursor" "text", "p_limit" integer) FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_sitemap_entries_v1("p_kind" "text", "p_cursor" "text", "p_limit" integer) to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_sitemap_entries_v1"("p_kind" "text", "p_cursor" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 1000) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    AS $_$
declare
  v_filter_kind text;
  v_cursor jsonb;
  v_cursor_kind text;
  v_cursor_id uuid;
  v_items jsonb;
  v_next_cursor text;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_sitemap_entries_v1(p_kind, p_cursor, p_limit);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  if pg_catalog.octet_length(coalesce(p_kind, '')) > 32 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_filter_kind := lower(btrim(coalesce(p_kind, '')));
  if v_filter_kind not in ('process', 'flow', 'all')
     or p_limit is null
     or p_limit not between 1 and 1000 then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  if p_cursor is not null then
    v_cursor := private.portal_cursor_decode_v1(p_cursor);
    if v_cursor is null
       or (select count(*) from jsonb_object_keys(v_cursor)) <> 5
       or v_cursor ->> 'v' <> '1'
       or v_cursor ->> 'filterKind' <> v_filter_kind
       or v_cursor ->> 'kind' not in ('process', 'flow')
       or (v_filter_kind <> 'all' and v_cursor ->> 'kind' <> v_filter_kind)
       or coalesce(v_cursor ->> 'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(v_cursor ->> 'version', '') !~ '^\d{2}\.\d{2}\.\d{3}$' then
      raise exception using errcode = '22023', message = 'invalid portal request';
    end if;
    v_cursor_kind := v_cursor ->> 'kind';
    v_cursor_id := (v_cursor ->> 'id')::uuid;
  end if;

  with source_rows as materialized (
    select kinds.kind, source.*
    from (values ('process'::text), ('flow'::text)) as kinds(kind)
    cross join lateral private.portal_catalog_rows_v1(kinds.kind) as source
    where v_filter_kind = 'all' or kinds.kind = v_filter_kind
  ), latest as materialized (
    select candidate.*
    from (
      select source_rows.*,
        row_number() over (
          partition by source_rows.kind, source_rows.id
          order by source_rows.version desc
        ) as version_rank
      from source_rows
    ) as candidate
    where candidate.version_rank = 1
  ), ordered as materialized (
    select latest.*,
      row_number() over (order by latest.kind, latest.id) as page_rank
    from latest
    where v_cursor is null or (latest.kind, latest.id) > (v_cursor_kind, v_cursor_id)
    order by latest.kind, latest.id
    limit p_limit + 1
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'key', jsonb_build_object(
        'kind', ordered.kind,
        'id', ordered.id::text,
        'version', ordered.version
      ),
      'modifiedAt', private.portal_timestamp_v1(ordered.modified_at)
    ) order by ordered.page_rank) filter (where ordered.page_rank <= p_limit), '[]'::jsonb),
    case when max(ordered.page_rank) > p_limit then private.portal_cursor_encode_v1(
      (jsonb_agg(jsonb_build_object(
        'v', 1,
        'filterKind', v_filter_kind,
        'kind', ordered.kind,
        'id', ordered.id::text,
        'version', ordered.version
      ) order by ordered.page_rank) filter (where ordered.page_rank = p_limit)) -> 0
    ) else null end
  into v_items, v_next_cursor
  from ordered;

  return jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-page.v1',
    'items', v_items,
    'nextCursor', v_next_cursor
  );
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
  when others then
    raise exception using errcode = 'P0001', message = 'portal catalog unavailable';
end
$_$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_sitemap_manifest_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '2s'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_shards jsonb;
begin
  perform private.assert_portal_catalog_projection_contract_v1();
  perform private.assert_portal_catalog_facet_contract_v1();
  perform private.assert_portal_sitemap_projection_v1();

  select pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'shardCursor',
      private.portal_cursor_encode_v1(pg_catalog.jsonb_build_object(
        'v', 1,
        'scope', 'sitemap-shard',
        'bucket', shard.bucket,
        'shardCount', 64
      )),
      'maxItems', 4096
    )
    order by shard.bucket
  )
  into v_shards
  from pg_catalog.generate_series(0, 63) as shard(bucket);

  return pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-manifest.v1',
    'shards', v_shards
  );
exception
  when query_canceled then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  when others then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
end
$$;

ALTER FUNCTION "private"."display_legacy_sitemap_manifest_v1"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_sitemap_manifest_v1"() FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_sitemap_manifest_v1() to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_sitemap_manifest_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '2s'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $$
declare
  v_shards jsonb;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_sitemap_manifest_v1();
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  perform private.assert_portal_catalog_projection_contract_v1();
  perform private.assert_portal_catalog_facet_contract_v1();
  perform private.assert_portal_sitemap_projection_v1();

  select pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'shardCursor',
      private.portal_cursor_encode_v1(pg_catalog.jsonb_build_object(
        'v', 1,
        'scope', 'sitemap-shard',
        'bucket', shard.bucket,
        'shardCount', 64
      )),
      'maxItems', 4096
    )
    order by shard.bucket
  )
  into v_shards
  from pg_catalog.generate_series(0, 63) as shard(bucket);

  return pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-manifest.v1',
    'shards', v_shards
  );
exception
  when query_canceled then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  when others then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
end
$$;
reset role;

CREATE OR REPLACE FUNCTION "private"."display_legacy_sitemap_shard_v1"("p_shard_cursor" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '4s'
    SET "work_mem" TO '8MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $_$
declare
  v_cursor jsonb;
  v_expected_cursor jsonb;
  v_bucket integer;
  v_items jsonb;
  v_result jsonb;
begin
  if p_shard_cursor is null
     or pg_catalog.octet_length(p_shard_cursor) not between 1 and 4096
     or p_shard_cursor ~ '[[:space:]]' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  v_cursor := private.portal_cursor_decode_v1(p_shard_cursor);
  if v_cursor is null
     or pg_catalog.jsonb_typeof(v_cursor) <> 'object'
     or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 4
     or coalesce(v_cursor ->> 'bucket', '') !~ '^([0-9]|[1-5][0-9]|6[0-3])$' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_bucket := (v_cursor ->> 'bucket')::integer;
  v_expected_cursor := pg_catalog.jsonb_build_object(
    'v', 1,
    'scope', 'sitemap-shard',
    'bucket', v_bucket,
    'shardCount', 64
  );

  if v_cursor is distinct from v_expected_cursor
     or private.portal_cursor_encode_v1(v_expected_cursor) <>
       p_shard_cursor then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  perform private.assert_portal_catalog_projection_contract_v1();
  perform private.assert_portal_catalog_facet_contract_v1();
  perform private.assert_portal_sitemap_projection_v1();

  with latest as materialized (
    select distinct on (projection.dataset_kind, projection.id)
      projection.dataset_kind,
      projection.id,
      projection.version,
      projection.modified_at
    from private.portal_sitemap_rows_v1 as projection
    where projection.shard_no = v_bucket
      and projection.contract_version = 1
    order by projection.dataset_kind,
      projection.id,
      projection.version desc,
      projection.modified_at desc
    limit 4097
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'key', pg_catalog.jsonb_build_object(
      'kind', latest.dataset_kind,
      'id', latest.id::text,
      'version', latest.version
    ),
    'modifiedAt', private.portal_timestamp_v1(latest.modified_at)
  ) order by latest.dataset_kind, latest.id), '[]'::jsonb)
  into v_items
  from latest;

  if pg_catalog.jsonb_array_length(v_items) > 4096 then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  end if;

  v_result := pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-shard.v1',
    'shardCursor', p_shard_cursor,
    'items', v_items
  );
  if pg_catalog.octet_length(v_result::text) > 2 * 1024 * 1024 then
    raise exception using
      errcode = '54000',
      message = 'portal sitemap response exceeded its budget';
  end if;
  return v_result;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  when others then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
end
$_$;

ALTER FUNCTION "private"."display_legacy_sitemap_shard_v1"("p_shard_cursor" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_legacy_sitemap_shard_v1"("p_shard_cursor" "text") FROM PUBLIC;




set local role portal_display_executor; grant execute on function private.display_api_sitemap_shard_v1("p_shard_cursor" "text") to portal_public_executor; reset role;

set local role portal_public_executor;
CREATE OR REPLACE FUNCTION "api"."portal_sitemap_shard_v1"("p_shard_cursor" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '4s'
    SET "work_mem" TO '8MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "max_parallel_workers_per_gather" TO '0'
    SET "jit" TO 'off'
    SET "row_security" TO 'on'
    AS $_$
declare
  v_cursor jsonb;
  v_expected_cursor jsonb;
  v_bucket integer;
  v_items jsonb;
  v_result jsonb;
begin

 if private.portal_display_mode_v1() is distinct from 'legacy' then
  declare m text:=private.portal_display_mode_v1(); result jsonb;
 old_brands text:=current_setting('portal.display_brands',true);
 old_global text:=current_setting('portal.display_global',true);
 old_filter text:=current_setting('portal.display_filter_brand',true);
begin
 if m is distinct from 'display' then raise exception using errcode='P0001',message='portal catalog unavailable'; end if;
 perform private.portal_display_assert_contract_v1();
 perform set_config('portal.display_brands','',true);
 perform set_config('portal.display_global','true',true);
 perform set_config('portal.display_filter_brand','',true);
 result:=private.display_api_sitemap_shard_v1(p_shard_cursor);
 perform set_config('portal.display_brands',coalesce(old_brands,''),true);
 perform set_config('portal.display_global',coalesce(old_global,''),true);
 perform set_config('portal.display_filter_brand',coalesce(old_filter,''),true);
 return result;
end;
 end if;
  if p_shard_cursor is null
     or pg_catalog.octet_length(p_shard_cursor) not between 1 and 4096
     or p_shard_cursor ~ '[[:space:]]' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  v_cursor := private.portal_cursor_decode_v1(p_shard_cursor);
  if v_cursor is null
     or pg_catalog.jsonb_typeof(v_cursor) <> 'object'
     or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(v_cursor)) <> 4
     or coalesce(v_cursor ->> 'bucket', '') !~ '^([0-9]|[1-5][0-9]|6[0-3])$' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
  v_bucket := (v_cursor ->> 'bucket')::integer;
  v_expected_cursor := pg_catalog.jsonb_build_object(
    'v', 1,
    'scope', 'sitemap-shard',
    'bucket', v_bucket,
    'shardCount', 64
  );

  if v_cursor is distinct from v_expected_cursor
     or private.portal_cursor_encode_v1(v_expected_cursor) <>
       p_shard_cursor then
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;

  perform private.assert_portal_catalog_projection_contract_v1();
  perform private.assert_portal_catalog_facet_contract_v1();
  perform private.assert_portal_sitemap_projection_v1();

  with latest as materialized (
    select distinct on (projection.dataset_kind, projection.id)
      projection.dataset_kind,
      projection.id,
      projection.version,
      projection.modified_at
    from private.portal_sitemap_rows_v1 as projection
    where projection.shard_no = v_bucket
      and projection.contract_version = 1
    order by projection.dataset_kind,
      projection.id,
      projection.version desc,
      projection.modified_at desc
    limit 4097
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'key', pg_catalog.jsonb_build_object(
      'kind', latest.dataset_kind,
      'id', latest.id::text,
      'version', latest.version
    ),
    'modifiedAt', private.portal_timestamp_v1(latest.modified_at)
  ) order by latest.dataset_kind, latest.id), '[]'::jsonb)
  into v_items
  from latest;

  if pg_catalog.jsonb_array_length(v_items) > 4096 then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  end if;

  v_result := pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-sitemap-shard.v1',
    'shardCursor', p_shard_cursor,
    'items', v_items
  );
  if pg_catalog.octet_length(v_result::text) > 2 * 1024 * 1024 then
    raise exception using
      errcode = '54000',
      message = 'portal sitemap response exceeded its budget';
  end if;
  return v_result;
exception
  when sqlstate '22023' then
    raise exception using errcode = '22023', message = 'invalid portal request';
  when query_canceled then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
  when others then
    raise exception using
      errcode = 'P0001',
      message = 'portal sitemap unavailable';
end
$_$;
reset role;

revoke create on schema private,api from portal_display_executor;
notify pgrst, 'reload schema';

-- The view owner selects the RLS policy, but policy functions execute in the
-- querying context. Narrow definer row readers preserve the legacy function ACLs.
do $lcia_read_views$
declare r record; columns_sql text; column_names text; function_name text;
begin
 for r in select c.oid,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='private' and c.relkind='v' and c.relname like 'display_read_lcia_%' loop
  select string_agg(format('%I %s',a.attname,format_type(a.atttypid,a.atttypmod)),',' order by a.attnum),
   string_agg(format('%I',a.attname),',' order by a.attnum) into columns_sql,column_names
  from pg_attribute a where a.attrelid=r.oid and a.attnum>0 and not a.attisdropped;
  function_name:=r.relname||'_rows';
  execute format('create function private.%I() returns table(%s) language sql stable security definer set search_path='''' as %L',
   function_name,columns_sql,format('select %s from private.%I',column_names,replace(r.relname,'display_read_lcia_','portal_lcia_')));
  execute format('alter function private.%I() owner to portal_public_executor',function_name);
  execute format('revoke all on function private.%I() from public',function_name);
  execute format('grant execute on function private.%I() to portal_display_executor',function_name);
  execute format('create or replace view private.%I as select * from private.%I()',r.relname,function_name);
 end loop;
end $lcia_read_views$;

-- Independent derivation/read-closure identity. No legacy manifest is relabelled.
create table private.portal_display_contract_manifest(singleton boolean primary key check(singleton), identity text not null);
revoke all on private.portal_display_contract_manifest from public,anon,authenticated,service_role;
create function private.portal_display_contract_identity_v1() returns text
language sql stable security definer set search_path='' as $$
 select md5(jsonb_build_object(
 'routines',(select jsonb_agg(jsonb_build_array(p.oid::regprocedure::text,pg_get_functiondef(p.oid),p.proowner::regrole::text,p.proacl::text) order by p.oid::regprocedure::text)
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='private' and (p.proname like 'display_%' or p.proname like 'portal_display_%')) or (n.nspname='api' and p.proname like 'portal_%')),
 'relations',(select jsonb_agg(jsonb_build_array(c.relname,c.relrowsecurity,c.relforcerowsecurity,c.relowner::regrole::text,c.relacl::text,case when c.relkind='v' then pg_get_viewdef(c.oid) else null end,
 (select jsonb_agg(jsonb_build_array(a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,a.attacl::text) order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped),
 (select jsonb_agg(pg_get_constraintdef(x.oid) order by x.conname) from pg_constraint x where x.conrelid=c.oid),
 (select jsonb_agg(jsonb_build_array(pg_get_indexdef(i.indexrelid),i.indisvalid,i.indisready) order by i.indexrelid::regclass::text) from pg_index i where i.indrelid=c.oid),
 (select jsonb_agg(jsonb_build_array(p.polname,p.polcmd,p.polpermissive,p.polroles::text,pg_get_expr(p.polqual,p.polrelid),pg_get_expr(p.polwithcheck,p.polrelid)) order by p.polname) from pg_policy p where p.polrelid=c.oid)) order by c.relname)
 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private' and c.relkind in ('r','v') and (c.relname like 'display_%' or c.relname='portal_display_derivation_contract')),
 'writers',(select jsonb_agg(jsonb_build_array(t.tgrelid::regclass::text,pg_get_triggerdef(t.oid),t.tgenabled) order by t.tgrelid::regclass::text,t.tgname) from pg_trigger t where t.tgname like 'portal_display_%' or t.tgrelid in (select c.oid from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private' and c.relname like 'display_%'))
 )::text)
$$;
revoke all on function private.portal_display_contract_identity_v1() from public;
create function private.portal_display_assert_contract_v1() returns void
language plpgsql stable security definer set search_path='' as $$
begin
 if (select identity from private.portal_display_contract_manifest where singleton) is distinct from private.portal_display_contract_identity_v1() then
  raise exception using errcode='P0001',message='portal catalog unavailable';
 end if;
end $$;
revoke all on function private.portal_display_assert_contract_v1() from public;
grant execute on function private.portal_display_assert_contract_v1() to portal_display_executor,portal_public_executor;
-- Restore the pre-existing owner's own grant and schema privileges exactly.
do $acl_end$
declare saved jsonb;
begin
 if not current_setting('display_cutover.private_create')::boolean then revoke create on schema private from portal_public_executor; end if;
 if not current_setting('display_cutover.api_create')::boolean then revoke create on schema api from portal_public_executor; end if;
 saved:=current_setting('display_cutover.postgres_grant')::jsonb;
 if saved='null'::jsonb then revoke portal_public_executor from postgres;
 else execute format('grant portal_public_executor to postgres with admin %s, inherit %s, set %s',saved->>'admin',saved->>'inherit',saved->>'set'); end if;
end $acl_end$;
insert into private.portal_display_contract_manifest values(true,private.portal_display_contract_identity_v1());
notify pgrst, 'reload schema';
commit;
