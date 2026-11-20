-- SKYBAR V2: Run after 20261120_001_foundation.sql
-- Supabase generally installs pgcrypto into the extensions schema.
-- The login_staff function uses crypt() and needs that schema in its search path.
ALTER FUNCTION public.login_staff(text, text)
  SET search_path = public, extensions;

-- Diagnostic: pgcrypto functions must resolve in the database.
SELECT
  to_regprocedure('extensions.crypt(text,text)') IS NOT NULL
  AS has_extensions_crypt,
  to_regprocedure('extensions.gen_salt(text,integer)') IS NOT NULL
  AS has_extensions_gen_salt;
