-- Database #766: evaluate actor-visible Review sets once per Source statement.
-- The former correlated scans applied private.reviews RLS for each state-20
-- Source, including every nonmatching Review. Preserve the same JSON targets,
-- exact versions, assignment containment, Review RLS and Source-hint authority.
-- Other Source policies, including the restrictive OAuth guard, are unchanged.
alter policy "Enable read access for authenticated users" on public.sources
using (
  state_code >= 100
  or (select auth.uid()) = user_id
  or exists (
    select 1 from private.roles
    where roles.team_id = sources.team_id
      and roles.role::text = any (array['admin', 'member', 'owner']::text[])
      and roles.user_id = (select auth.uid())
  )
  or (
    state_code = 20
    and (
      exists (
        select 1 from private.roles
        where roles.team_id = '00000000-0000-0000-0000-000000000000'::uuid
          and roles.role::text = 'review-admin'
          and roles.user_id = (select auth.uid())
      )
      or (sources.id, sources.version::text) in (
        select (r.json -> 'data' ->> 'id')::uuid,
               r.json -> 'data' ->> 'version'
        from private.reviews r
        where r.state_code > 0
          and r.reviewer_id @> jsonb_build_array((select auth.uid())::text)
      )
      -- Preserve lazy hint validation when Review RLS yields no assignments.
      -- Without CASE, malformed hints would newly fail unrelated reads.
      or case when exists (
        select 1
        from private.reviews r
        where r.reviewer_id @> jsonb_build_array((select auth.uid())::text)
      ) then (
        jsonb_array_length(sources.reviews) > 0
        and array(
          select (review_item.value ->> 'id')::uuid
          from jsonb_array_elements(sources.reviews) review_item(value)
        ) && (
          select array_agg(r.id)
          from private.reviews r
          where r.reviewer_id @> jsonb_build_array((select auth.uid())::text)
        )
      ) else false end
    )
  )
);
