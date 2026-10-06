CREATE INDEX "portal_navigation_node_parent_only_v1_idx" ON "private"."portal_navigation_node_v1" USING "btree" ("parent_node_id") WHERE ("parent_node_id" IS NOT NULL);
