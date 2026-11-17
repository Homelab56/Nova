-- tv_pair_codes: kortlevende koppelcodes voor inloggen op de tv via QR-code
-- (zie supabase/functions/tv-pair-create, tv-pair-login, tv-pair-poll).
-- RLS staat aan ZONDER policies: de tabel is onbereikbaar via de publieke API;
-- alleen de Edge Functions (service-role sleutel, server-side) gebruiken hem.
create table if not exists public.tv_pair_codes (
  code          text primary key,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  status        text not null default 'pending' check (status in ('pending', 'claimed')),
  refresh_token text
);
alter table public.tv_pair_codes enable row level security;
