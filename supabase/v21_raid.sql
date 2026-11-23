-- v21 레이드 보상 설정 + 이벤트 레이드 (관리자 패널에서 관리)
-- 보상 JSON: {"money":N, "gren":N, "tnt":N, "ab":N, "weapons":[{"w":무기번호,"lv":강화,"en":인첸트 또는 null}, ...]}

create table if not exists public.cc_raid_rewards (idx int primary key check (idx between 0 and 2), reward jsonb not null default '{}'::jsonb);
alter table public.cc_raid_rewards enable row level security;   -- 정책 없음 = 함수로만 접근
insert into public.cc_raid_rewards (idx, reward) values (0, '{"money":1000000}'), (1, '{"money":2500000}'), (2, '{"money":6000000}') on conflict do nothing;

create table if not exists public.cc_events (
  id bigserial primary key, name text not null, start_at timestamptz not null, end_at timestamptz,
  pol int not null default 30, cars int not null default 8, heli int not null default 2, tank int not null default 0,
  speed numeric not null default 1, steal int not null default 2, reward jsonb not null default '{}'::jsonb,
  enabled boolean not null default true, winner text, won_at timestamptz, created_at timestamptz not null default now());
alter table public.cc_events enable row level security;

create table if not exists public.cc_raid_claims (name text not null, kind text not null, at timestamptz not null default now(), primary key (name, kind));
alter table public.cc_raid_claims enable row level security;

create or replace function public.cc_reward_clean(r jsonb) returns jsonb
language plpgsql immutable set search_path to 'public' as $$
declare w jsonb := '[]'::jsonb; x jsonb; n int := 0;
begin
  if r is null or jsonb_typeof(r) <> 'object' then r := '{}'::jsonb; end if;
  if jsonb_typeof(r -> 'weapons') = 'array' then
    for x in select * from jsonb_array_elements(r -> 'weapons') loop
      exit when n >= 10;
      if jsonb_typeof(x) = 'object' and public.cc_int(x -> 'w') between 6 and 99 then
        w := w || jsonb_build_array(jsonb_build_object('w', public.cc_int(x -> 'w'), 'lv', least(99, public.cc_int(x -> 'lv')), 'en', case when jsonb_typeof(x -> 'en') = 'array' then x -> 'en' else null end));
        n := n + 1;
      end if;
    end loop;
  end if;
  return jsonb_build_object('money', public.cc_int(r -> 'money'), 'gren', least(9999, public.cc_int(r -> 'gren')), 'tnt', least(9999, public.cc_int(r -> 'tnt')), 'ab', least(99, public.cc_int(r -> 'ab')), 'weapons', w);
end $$;

-- 내부: 보상을 계정에 넣기 (돈·폭탄·무기 / 이미 가진 무기는 인벤토리로)
create or replace function public.cc_raid_reward_apply(p_name text, p_reward jsonb, p_note text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare b public.cc_profiles%rowtype; bo jsonb; r jsonb := public.cc_reward_clean(p_reward); x jsonb; wk text; o2 jsonb; nw int := 0; ni int := 0; ns int := 0; k text;
begin
  select * into b from public.cc_profiles where name = p_name for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'no_profile'); end if;
  bo := coalesce(b.own, '{}'::jsonb);
  foreach k in array array['gren', 'tnt', 'ab'] loop
    if public.cc_int(r -> k) > 0 then bo := jsonb_set(bo, array[k], to_jsonb(public.cc_int(bo -> k) + public.cc_int(r -> k)), true); end if;
  end loop;
  for x in select * from jsonb_array_elements(r -> 'weapons') loop
    wk := (x ->> 'w');
    if public.cc_int(bo -> wk) > 0 then
      o2 := public.cc_inv_push(bo, (x ->> 'w')::int, (x ->> 'lv')::int, x -> 'en');
      if o2 is null then ns := ns + 1; else bo := o2; ni := ni + 1; end if;
    else
      bo := jsonb_set(bo, array[wk], '1'::jsonb, true);
      bo := jsonb_set(bo, '{wu}', coalesce(bo -> 'wu', '{}'::jsonb) || jsonb_build_object(wk, (x ->> 'lv')::int), true);
      if jsonb_typeof(x -> 'en') = 'array' then bo := jsonb_set(bo, '{en}', coalesce(bo -> 'en', '{}'::jsonb) || jsonb_build_object(wk, x -> 'en'), true); end if;
      nw := nw + 1;
    end if;
  end loop;
  perform public.cc_auc_apply(p_name, b.money + public.cc_int(r -> 'money'), bo, p_note);
  return jsonb_build_object('ok', true, 'reward', r, 'equipped', nw, 'inv', ni, 'skipped', ns);
end $$;
revoke all on function public.cc_raid_reward_apply(text, jsonb, text) from public, anon, authenticated;

-- 공개: 난이도 보상 + 이벤트 목록 (로비에서 표시)
create or replace function public.cc_raid_info() returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  return jsonb_build_object('now', extract(epoch from now()),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('idx', idx, 'reward', reward) order by idx) from public.cc_raid_rewards), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'start', extract(epoch from start_at), 'end', extract(epoch from end_at), 'pol', pol, 'cars', cars, 'heli', heli, 'tank', tank, 'speed', speed, 'steal', steal, 'reward', reward, 'winner', winner) order by start_at)
      from public.cc_events where enabled and (end_at is null or end_at > now() - interval '10 minutes') and (winner is null or won_at > now() - interval '30 minutes')), '[]'::jsonb));
end $$;

-- 클리어 보상 수령 (난이도: p_event null / 이벤트: 선착순 1명)
create or replace function public.cc_raid_claim(p_name text, p_diff int, p_event bigint default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare e public.cc_events%rowtype; r jsonb; rew jsonb; last timestamptz;
begin
  if p_event is not null then
    select * into e from public.cc_events where id = p_event for update;
    if not found or not e.enabled then return jsonb_build_object('ok', false, 'err', 'no_event'); end if;
    if now() < e.start_at or (e.end_at is not null and now() > e.end_at + interval '15 minutes') then return jsonb_build_object('ok', false, 'err', 'closed'); end if;
    if e.winner is not null then return jsonb_build_object('ok', false, 'err', 'taken', 'winner', e.winner); end if;
    r := public.cc_raid_reward_apply(p_name, e.reward, '🏆 이벤트 레이드 [' || e.name || '] 선착순 1등 보상!');
    if (r ->> 'ok') <> 'true' then return r; end if;
    update public.cc_events set winner = p_name, won_at = now() where id = e.id;
    return r || jsonb_build_object('ev', true, 'name', e.name);
  end if;
  if p_diff not between 0 and 2 then return jsonb_build_object('ok', false, 'err', 'bad_diff'); end if;
  select at into last from public.cc_raid_claims where name = p_name and kind = 'd' || p_diff;
  if last is not null and last > now() - interval '90 seconds' then return jsonb_build_object('ok', false, 'err', 'too_fast'); end if;
  select reward into rew from public.cc_raid_rewards where idx = p_diff;
  r := public.cc_raid_reward_apply(p_name, coalesce(rew, '{}'::jsonb), '🏆 레이드 클리어 보상!');
  if (r ->> 'ok') = 'true' then insert into public.cc_raid_claims (name, kind, at) values (p_name, 'd' || p_diff, now()) on conflict (name, kind) do update set at = now(); end if;
  return r;
end $$;

-- 관리자
create or replace function public.cc_admin_raid(pw text) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform public.cc_admin_check(pw);
  return jsonb_build_object('now', extract(epoch from now()),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('idx', idx, 'reward', reward) order by idx) from public.cc_raid_rewards), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'start', extract(epoch from start_at), 'end', extract(epoch from end_at), 'pol', pol, 'cars', cars, 'heli', heli, 'tank', tank, 'speed', speed, 'steal', steal, 'reward', reward, 'enabled', enabled, 'winner', winner, 'won', extract(epoch from won_at)) order by start_at desc) from public.cc_events), '[]'::jsonb));
end $$;

create or replace function public.cc_admin_raid_reward(pw text, p_idx int, p_reward jsonb) returns int
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform public.cc_admin_check(pw);
  if p_idx not between 0 and 2 then raise exception 'bad idx'; end if;
  insert into public.cc_raid_rewards (idx, reward) values (p_idx, public.cc_reward_clean(p_reward)) on conflict (idx) do update set reward = excluded.reward;
  return p_idx;
end $$;

create or replace function public.cc_admin_event_save(pw text, p_id bigint, p_name text, p_start timestamptz, p_end timestamptz, p_pol int, p_cars int, p_heli int, p_tank int, p_speed numeric, p_steal int, p_reward jsonb, p_enabled boolean) returns bigint
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare nid bigint; nm text := left(btrim(coalesce(p_name, '')), 30);
begin
  perform public.cc_admin_check(pw);
  if nm = '' then raise exception '이벤트 이름을 입력하세요'; end if;
  if p_start is null then raise exception '시작 시각이 필요해요'; end if;
  if p_end is not null and p_end <= p_start then raise exception '종료 시각은 시작보다 늦어야 해요'; end if;
  if p_id is null then
    insert into public.cc_events (name, start_at, end_at, pol, cars, heli, tank, speed, steal, reward, enabled)
    values (nm, p_start, p_end, greatest(1, least(300, p_pol)), greatest(1, least(30, p_cars)), greatest(0, least(15, p_heli)), greatest(0, least(10, p_tank)), greatest(0.5, least(2.5, p_speed)), greatest(0, least(20, p_steal)), public.cc_reward_clean(p_reward), coalesce(p_enabled, true)) returning id into nid;
  else
    update public.cc_events set name = nm, start_at = p_start, end_at = p_end, pol = greatest(1, least(300, p_pol)), cars = greatest(1, least(30, p_cars)), heli = greatest(0, least(15, p_heli)), tank = greatest(0, least(10, p_tank)),
      speed = greatest(0.5, least(2.5, p_speed)), steal = greatest(0, least(20, p_steal)), reward = public.cc_reward_clean(p_reward), enabled = coalesce(p_enabled, true) where id = p_id returning id into nid;
    if nid is null then raise exception '이벤트를 찾을 수 없어요'; end if;
  end if;
  return nid;
end $$;

create or replace function public.cc_admin_event_delete(pw text, p_id bigint) returns int
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin perform public.cc_admin_check(pw); delete from public.cc_events where id = p_id; return 1; end $$;

create or replace function public.cc_admin_event_reset(pw text, p_id bigint) returns int
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin perform public.cc_admin_check(pw); update public.cc_events set winner = null, won_at = null where id = p_id; return 1; end $$;
