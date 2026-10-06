-- Database #785: qualified node-only Navigation read/FK path.
-- Sole top-level concurrent build; preserve writes, RLS and existing indexes.
create index concurrently portal_navigation_node_parent_only_v1_idx on private.portal_navigation_node_v1(parent_node_id) where parent_node_id is not null;
