CREATE POLICY "display_scope" ON "private"."display_sitemap_rows_v1" FOR SELECT TO "portal_display_executor" USING ("private"."portal_display_request_visible_v1"("dataset_kind", "id", "version"));
