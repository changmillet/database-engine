CREATE INDEX "d807_portal_navigation_versions_geography_v1_idx" ON "private"."display_navigation_versions_v1" USING "btree" ("geography_code", "dataset_kind", "id", "version");
