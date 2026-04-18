-- pgque_uninstall.sql -- Remove pgque from database
-- Copyright 2026 Nikolay Samokhvalov. Apache-2.0 license.

do $$ begin
    perform pgque.stop();
exception when others then
    null;
end $$;

-- `drop schema ... cascade` removes all relations including the view
-- named pgque.subscription / pgque.tick, their three child tables
-- (pgque.subscription_0/1/2, pgque.tick_0/1/2), the instead-of trigger
-- functions, and the pgque.meta_rotation singleton.
drop schema if exists pgque cascade;

-- Roles are database-global and may be shared across databases.
-- Do not drop them automatically here.
