-- Database #785: qualified node-only Navigation read/FK path.
-- Sole top-level concurrent build; preserve writes, RLS and existing indexes.
create index concurrently portal_navigation_membership_node_v1_idx on private.portal_navigation_membership_v1(node_id);
