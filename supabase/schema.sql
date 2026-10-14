-- =====================================================================
-- Petit Bonbon — schéma de la base Supabase
-- À coller tel quel dans Supabase › SQL Editor › New query › Run.
-- Peut être relancé sans risque (il ne recrée que ce qui manque).
--
-- Principe de sécurité : aucune table n'est lisible directement depuis
-- l'application. Tout passe par des fonctions (RPC) qui vérifient qui
-- appelle et ne renvoient que le strict nécessaire. Les identifiants des
-- autres utilisateurs ne quittent jamais la base.
-- =====================================================================

-- ---------- Réglages globaux --------------------------------------------
create table if not exists public.app_settings (
  id               int primary key default 1 check (id = 1),
  paywall_enabled  boolean not null default false,  -- true = accès payant pour entrer (désactivé : l'app de base est gratuite)
  daily_send_limit int     not null default 10       -- bonbons envoyés max par 24 h
);
insert into public.app_settings (id) values (1) on conflict do nothing;

-- ---------- Comptes ------------------------------------------------------
create table if not exists public.profiles (
  id                  uuid primary key references auth.users(id) on delete cascade,
  adult_confirmed_at  timestamptz,
  paid_at             timestamptz,
  receive_on          boolean not null default true,
  same_city_only      boolean not null default false,
  banned              boolean not null default false,
  created_at          timestamptz not null default now()
);

-- ---------- Identité du jour (une seule active par compte) ---------------
create table if not exists public.sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null unique references public.profiles(id) on delete cascade,
  pseudo        text not null check (char_length(pseudo) between 1 and 20),
  moods         text[] not null default '{}' check (cardinality(moods) <= 3),
  bio           text check (bio is null or char_length(bio) <= 80),
  current_city  text not null check (char_length(current_city) between 1 and 60),
  home_city     text not null check (char_length(home_city) between 1 and 60),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '12 hours'
);

-- ---------- Bonbons (compliments envoyés) --------------------------------
create table if not exists public.bonbons (
  id                   uuid primary key default gen_random_uuid(),
  sender_id            uuid not null references public.profiles(id) on delete cascade,
  recipient_id         uuid not null references public.profiles(id) on delete cascade,
  sender_pseudo        text not null,
  sender_home_city     text not null,
  sender_current_city  text not null,
  recipient_pseudo     text not null,
  compliment_id        int  not null check (compliment_id between 0 and 11),
  status               text not null default 'open' check (status in ('open', 'thanked', 'reported')),
  created_at           timestamptz not null default now()
);
create index if not exists bonbons_recipient_idx on public.bonbons (recipient_id, created_at desc);
create index if not exists bonbons_sender_idx    on public.bonbons (sender_id, created_at desc);

-- ---------- Blocages et signalements -------------------------------------
create table if not exists public.blocks (
  blocker_id  uuid not null references public.profiles(id) on delete cascade,
  blocked_id  uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

create table if not exists public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null references public.profiles(id) on delete cascade,
  reported_id  uuid not null references public.profiles(id) on delete cascade,
  bonbon_id    uuid references public.bonbons(id) on delete set null,
  pseudo_seen  text,
  bio_seen     text,
  reason       text not null check (char_length(reason) <= 100),
  handled      boolean not null default false,
  created_at   timestamptz not null default now()
);

-- ---------- Verrouillage : aucun accès direct aux tables -----------------
alter table public.app_settings enable row level security;
alter table public.profiles     enable row level security;
alter table public.sessions     enable row level security;
alter table public.bonbons      enable row level security;
alter table public.blocks       enable row level security;
alter table public.reports      enable row level security;
revoke all on public.app_settings, public.profiles, public.sessions,
              public.bonbons, public.blocks, public.reports
  from anon, authenticated;

-- ---------- Outils internes ----------------------------------------------
create or replace function public.norm_city(t text)
returns text language sql immutable as $$
  select regexp_replace(
           translate(lower(trim(coalesce(t, ''))),
                     'àâäáãéèêëíìîïóòôöõúùûüçñ-''',
                     'aaaaaeeeeiiiiooooouuuucn  '),
           '\s+', ' ', 'g')
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Renvoie NULL si l'utilisateur peut utiliser l'app, sinon un code d'erreur.
create or replace function public.access_problem(uid uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when uid is null                         then 'AUTH'
    when p.id is null                        then 'AUTH'
    when p.banned                            then 'BANNED'
    when p.adult_confirmed_at is null        then 'ADULT'
    when s.paywall_enabled and p.paid_at is null then 'PAYWALL'
    else null end
  from public.app_settings s
  left join public.profiles p on p.id = uid
  where s.id = 1
$$;

create or replace function public.blocked_between(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks
                 where (blocker_id = a and blocked_id = b)
                    or (blocker_id = b and blocked_id = a))
$$;

-- =====================================================================
-- Fonctions appelées par l'application
-- =====================================================================

-- État du compte et identité du jour en cours
create or replace function public.my_status()
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); res json;
begin
  if uid is null then raise exception 'AUTH'; end if;
  insert into public.profiles (id) values (uid) on conflict do nothing;
  select json_build_object(
    'adult',          p.adult_confirmed_at is not null,
    'paid',           p.paid_at is not null,
    'paywall',        st.paywall_enabled,
    'banned',         p.banned,
    'receive_on',     p.receive_on,
    'same_city_only', p.same_city_only,
    'daily_limit',    st.daily_send_limit,
    'sent_today',     (select count(*) from public.bonbons
                        where sender_id = uid and created_at > now() - interval '24 hours'),
    'session', (select row_to_json(x) from (
                  select id, pseudo, moods, bio, current_city, home_city, expires_at
                  from public.sessions
                  where user_id = uid and expires_at > now()) x)
  ) into res
  from public.profiles p cross join public.app_settings st
  where p.id = uid and st.id = 1;
  return res;
end $$;

create or replace function public.confirm_adult()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  update public.profiles set adult_confirmed_at = now()
  where id = auth.uid() and adult_confirmed_at is null;
end $$;

create or replace function public.start_session(
  p_pseudo text, p_moods text[], p_bio text, p_current_city text, p_home_city text)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); problem text;
  allowed text[] := array['Joyeux·se','Rêveur·se','Curieux·se','Calme','De passage','Fatigué·e mais là',
                          'Bavard·e','Timide','En balade'];
begin
  problem := public.access_problem(uid);
  if problem is not null then raise exception '%', problem; end if;
  if not (coalesce(p_moods, '{}') <@ allowed) then raise exception 'BAD_MOOD'; end if;

  delete from public.sessions where user_id = uid;
  insert into public.sessions (user_id, pseudo, moods, bio, current_city, home_city)
  values (uid,
          coalesce(nullif(trim(p_pseudo), ''), 'Quelqu''un de passage'),
          coalesce(p_moods, '{}'),
          nullif(trim(p_bio), ''),
          trim(p_current_city),
          coalesce(nullif(trim(p_home_city), ''), trim(p_current_city)));
  return public.my_status();
end $$;

create or replace function public.end_session()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.sessions where user_id = auth.uid();
end $$;

-- Personnes présentes dans la même ville que moi
create or replace function public.discover()
returns table (session_id uuid, pseudo text, moods text[], bio text,
               home_city text, local boolean, already_sent boolean)
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); me public.sessions%rowtype;
begin
  if public.access_problem(uid) is not null then return; end if;
  select * into me from public.sessions where user_id = uid and expires_at > now();
  if not found then return; end if;

  return query
  select s.id, s.pseudo, s.moods, s.bio, s.home_city,
         public.norm_city(s.home_city) = public.norm_city(me.current_city),
         exists (select 1 from public.bonbons b
                 where b.sender_id = uid and b.recipient_id = s.user_id
                   and b.created_at > now() - interval '24 hours')
  from public.sessions s
  join public.profiles p on p.id = s.user_id
  where s.user_id <> uid
    and s.expires_at > now()
    and public.norm_city(s.current_city) = public.norm_city(me.current_city)
    and not p.banned
    and p.receive_on
    and (not p.same_city_only or public.norm_city(me.home_city) = public.norm_city(s.current_city))
    and not public.blocked_between(uid, s.user_id)
  order by s.created_at desc
  limit 60;
end $$;

create or replace function public.send_bonbon(p_session_id uuid, p_compliment int)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); problem text;
  me public.sessions%rowtype; them public.sessions%rowtype; tp public.profiles%rowtype;
  lim int;
begin
  problem := public.access_problem(uid);
  if problem is not null then raise exception '%', problem; end if;
  select * into me from public.sessions where user_id = uid and expires_at > now();
  if not found then raise exception 'NO_SESSION'; end if;
  select * into them from public.sessions where id = p_session_id and expires_at > now();
  if not found or them.user_id = uid then raise exception 'GONE'; end if;
  select * into tp from public.profiles where id = them.user_id;
  if tp.banned or not tp.receive_on
     or public.norm_city(them.current_city) <> public.norm_city(me.current_city)
     or (tp.same_city_only and public.norm_city(me.home_city) <> public.norm_city(them.current_city))
     or public.blocked_between(uid, them.user_id)
  then raise exception 'GONE'; end if;

  select daily_send_limit into lim from public.app_settings where id = 1;
  if (select count(*) from public.bonbons
      where sender_id = uid and created_at > now() - interval '24 hours') >= lim
  then raise exception 'LIMIT'; end if;
  if exists (select 1 from public.bonbons
             where sender_id = uid and recipient_id = them.user_id
               and created_at > now() - interval '24 hours')
  then raise exception 'ALREADY'; end if;

  insert into public.bonbons (sender_id, recipient_id, sender_pseudo, sender_home_city,
                              sender_current_city, recipient_pseudo, compliment_id)
  values (uid, them.user_id, me.pseudo, me.home_city, me.current_city, them.pseudo, p_compliment);
end $$;

-- Bonbons reçus (30 derniers jours)
create or replace function public.inbox()
returns table (id uuid, sender_pseudo text, sender_home_city text, local boolean,
               compliment_id int, status text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return; end if;
  return query
  select b.id, b.sender_pseudo, b.sender_home_city,
         public.norm_city(b.sender_home_city) = public.norm_city(b.sender_current_city),
         b.compliment_id, b.status, b.created_at
  from public.bonbons b
  where b.recipient_id = uid
    and b.created_at > now() - interval '30 days'
    and (b.status = 'reported'
         or not exists (select 1 from public.blocks k
                        where k.blocker_id = uid and k.blocked_id = b.sender_id))
  order by b.created_at desc
  limit 100;
end $$;

-- Bonbons envoyés (pour voir les « merci »)
create or replace function public.sent()
returns table (id uuid, recipient_pseudo text, compliment_id int, thanked boolean, created_at timestamptz)
language sql security definer set search_path = public as $$
  select b.id, b.recipient_pseudo, b.compliment_id, b.status = 'thanked', b.created_at
  from public.bonbons b
  where b.sender_id = auth.uid() and b.created_at > now() - interval '30 days'
  order by b.created_at desc
  limit 100
$$;

create or replace function public.thank_bonbon(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.bonbons set status = 'thanked'
  where id = p_id and recipient_id = auth.uid() and status = 'open';
end $$;

-- Signaler = bloquer définitivement. 3 signalements distincts en 30 jours = compte suspendu.
create or replace function public.report(p_reason text, p_bonbon_id uuid default null, p_session_id uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); target uuid; seen_pseudo text; seen_bio text;
begin
  if uid is null then raise exception 'AUTH'; end if;
  if p_bonbon_id is not null then
    select sender_id, sender_pseudo into target, seen_pseudo
    from public.bonbons where id = p_bonbon_id and recipient_id = uid;
  elsif p_session_id is not null then
    select user_id, pseudo, bio into target, seen_pseudo, seen_bio
    from public.sessions where id = p_session_id;
  end if;
  if target is null or target = uid then raise exception 'GONE'; end if;

  insert into public.reports (reporter_id, reported_id, bonbon_id, pseudo_seen, bio_seen, reason)
  values (uid, target, p_bonbon_id, seen_pseudo, seen_bio, left(coalesce(p_reason, 'Autre'), 100));
  insert into public.blocks (blocker_id, blocked_id) values (uid, target) on conflict do nothing;
  if p_bonbon_id is not null then
    update public.bonbons set status = 'reported' where id = p_bonbon_id;
  end if;

  if (select count(distinct reporter_id) from public.reports
      where reported_id = target and created_at > now() - interval '30 days') >= 3 then
    update public.profiles set banned = true where id = target;
    delete from public.sessions where user_id = target;
  end if;
end $$;

create or replace function public.update_settings(p_receive_on boolean, p_same_city_only boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
  set receive_on = coalesce(p_receive_on, receive_on),
      same_city_only = coalesce(p_same_city_only, same_city_only)
  where id = auth.uid();
end $$;

-- Droit à l'effacement (RGPD) : supprime le compte et toutes ses données
create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ---------- Droits d'exécution -------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.my_status(), public.confirm_adult(),
  public.start_session(text, text[], text, text, text), public.end_session(),
  public.discover(), public.send_bonbon(uuid, int),
  public.inbox(), public.sent(), public.thank_bonbon(uuid),
  public.report(text, uuid, uuid), public.update_settings(boolean, boolean),
  public.delete_account()
to authenticated;
revoke execute on function public.handle_new_user(), public.access_problem(uuid),
  public.blocked_between(uuid, uuid) from authenticated;
