CREATE OR REPLACE TRIGGER "result_query_sources_immutable" BEFORE DELETE OR UPDATE ON "private"."result_query_sources" FOR EACH ROW EXECUTE FUNCTION "private"."result_query_immutable_guard"();
