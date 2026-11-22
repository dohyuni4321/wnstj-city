-- v21 관리자 확장: 접속자·방 코드 실시간 목록, 경매 물품 관리, 유저 제어(메시지·이동·강퇴·차단)
-- 게임 클라이언트가 4초마다 cc_ping 으로 "나 접속 중" 신호를 보내고, 관리자가 내린 명령(cmd)·전체 공지·차단 여부를 응답으로 받아요.

create table if not exists public.cc_presence (
  id text primary key, name text not null, room text not null default '', money bigint not null default 0, info text,
  seen timestamptz not null default now(), cmd_seq int not null default 0, cmd jsonb
);
alter table public.cc_presence enable row level security;   -- 정책 없음 = 직접 접근 불가, 함수로만
create table if not exists public.cc_bans (name text primary key, reason text, at timestamptz not null default now());
alter table public.cc_bans enable row level security;
create table if not exists public.cc_notice (id int primary key default 1, seq int not null default 0, text text, at timestamptz);
alter table public.cc_notice enable row level security;
insert into public.cc_notice (id, seq) values (1, 0) on conflict do nothing;

create or replace function public.cc_ping(p_id text, p_name text, p_room text, p_money bigint, p_info text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare r public.cc_presence%rowtype; n public.cc_notice%rowtype; b public.cc_bans%rowtype;
begin
  if p_id is null or length(p_id) < 4 or length(p_id) > 40 then return jsonb_build_object('ok', false); end if;
  insert into public.cc_presence (id, name, room, money, info, seen)
  values (p_id, left(coalesce(p_name, ''), 24), left(coalesce(p_room, ''), 8), greatest(0, coalesce(p_money, 0)), left(p_info, 40), now())
  on conflict (id) do update set name = excluded.name, room = excluded.room, money = excluded.money, info = excluded.info, seen = now();
  if random() < 0.05 then delete from public.cc_presence where seen < now() - interval '10 minutes'; end if;
  select * into r from public.cc_presence where id = p_id;
  select * into n from public.cc_notice where id = 1;
  select * into b from public.cc_bans where name = left(coalesce(p_name, ''), 24);
  return jsonb_build_object('ok', true, 'cmd_seq', r.cmd_seq, 'cmd', r.cmd, 'notice_seq', n.seq, 'notice', n.text, 'ban', b.name is not null, 'reason', b.reason);
end $$;
grant execute on function public.cc_ping(text, text, text, bigint, text) to anon, authenticated;

-- ---- 관리자 전용 (비밀번호 확인)
create or replace function public.cc_admin_online(pw text) returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform public.cc_admin_check(pw);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'room', room, 'money', money, 'info', info, 'age', round(extract(epoch from now() - seen)::numeric, 1)) order by room, name)
                   from public.cc_presence where seen > now() - interval '25 seconds'), '[]'::jsonb);
end $$;

create or replace function public.cc_admin_cmd(pw text, p_id text, p_cmd jsonb) returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare n int;
begin
  perform public.cc_admin_check(pw);
  update public.cc_presence set cmd = p_cmd, cmd_seq = cmd_seq + 1 where id = p_id; get diagnostics n = row_count; return n;
end $$;
create or replace function public.cc_admin_cmd_room(pw text, p_room text, p_cmd jsonb) returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare n int;
begin
  perform public.cc_admin_check(pw);
  update public.cc_presence set cmd = p_cmd, cmd_seq = cmd_seq + 1 where (p_room is null or room = p_room) and seen > now() - interval '25 seconds'; get diagnostics n = row_count; return n;
end $$;
create or replace function public.cc_admin_notice(pw text, p_text text) returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare s int;
begin
  perform public.cc_admin_check(pw);
  update public.cc_notice set seq = seq + 1, text = left(p_text, 200), at = now() where id = 1 returning seq into s; return s;
end $$;
create or replace function public.cc_admin_ban(pw text, p_name text, p_reason text, p_on boolean) returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform public.cc_admin_check(pw);
  if p_on then insert into public.cc_bans (name, reason) values (p_name, left(p_reason, 100)) on conflict (name) do update set reason = excluded.reason, at = now();
  else delete from public.cc_bans where name = p_name; end if;
  return (select count(*) from public.cc_bans);
end $$;
create or replace function public.cc_admin_bans(pw text) returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform public.cc_admin_check(pw);
  return coalesce((select jsonb_agg(jsonb_build_object('name', name, 'reason', reason, 'at', at) order by at desc) from public.cc_bans), '[]'::jsonb);
end $$;

-- ---- 경매 관리
create or replace function public.cc_admin_auctions(pw text, p_status text default 'open') returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform public.cc_admin_check(pw);
  return coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc) from (select * from public.cc_auctions where p_status = 'all' or status = p_status order by id desc limit 300) a), '[]'::jsonb);
end $$;

create or replace function public.cc_admin_auction_price(pw text, p_id bigint, p_price bigint) returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare n int;
begin
  perform public.cc_admin_check(pw);
  if p_price < 0 or p_price > 1000000000000 then raise exception 'bad price'; end if;
  update public.cc_auctions set price = greatest(p_price, 0) where id = p_id and status = 'open'; get diagnostics n = row_count; return n;
end $$;

-- 관리자가 직접 올리는 경매 (판매자 '[관리자]' · 사 가도 판매자 대금 지급 없음)
create or replace function public.cc_admin_auction_add(pw text, p_kind text, p_weapon int, p_lv int, p_ench jsonb, p_qty int, p_price bigint) returns bigint language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare nid bigint;
begin
  perform public.cc_admin_check(pw);
  if p_kind = 'weapon' then
    insert into public.cc_auctions (seller, kind, weapon, lv, ench, qty, price) values ('[관리자]', 'weapon', p_weapon, p_lv, p_ench, 1, p_price) returning id into nid;
  else
    insert into public.cc_auctions (seller, kind, qty, price) values ('[관리자]', p_kind, p_qty, p_price) returning id into nid;
  end if;
  return nid;
end $$;

-- 내리기: 'return' = 물건을 판매자에게 돌려주고 내림 / 'delete' = 그냥 삭제(물건 사라짐)
create or replace function public.cc_admin_auction_remove(pw text, p_id bigint, p_mode text) returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a public.cc_auctions%rowtype; r public.cc_profiles%rowtype; o jsonb; wk text;
begin
  perform public.cc_admin_check(pw);
  select * into a from public.cc_auctions where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'not_found'); end if;
  if a.status <> 'open' then return jsonb_build_object('ok', false, 'err', 'not_open'); end if;
  if p_mode = 'return' and a.seller <> '[관리자]' then
    select * into r from public.cc_profiles where name = a.seller for update;
    if not found then return jsonb_build_object('ok', false, 'err', 'no_profile'); end if;
    o := coalesce(r.own, '{}'::jsonb);
    if a.kind = 'weapon' then
      wk := a.weapon::text;
      if public.cc_int(o -> wk) > 0 then return jsonb_build_object('ok', false, 'err', 'already_owned'); end if;
      o := jsonb_set(o, array[wk], '1'::jsonb, true);
      o := jsonb_set(o, '{wu}', coalesce(o -> 'wu', '{}'::jsonb) || jsonb_build_object(wk, a.lv), true);
      if a.ench is not null and jsonb_typeof(a.ench) = 'array' then o := jsonb_set(o, '{en}', coalesce(o -> 'en', '{}'::jsonb) || jsonb_build_object(wk, a.ench), true); end if;
    else
      o := jsonb_set(o, array[a.kind], to_jsonb(public.cc_int(o -> a.kind) + a.qty), true);
    end if;
    perform public.cc_auc_apply(a.seller, r.money, o, '관리자가 경매를 내리고 물건을 돌려줬어요');
  end if;
  update public.cc_auctions set status = 'cancelled' where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

-- 구매: 판매자가 '[관리자]'면 대금 지급 단계 건너뜀
create or replace function public.cc_auction_buy(p_id bigint, p_buyer text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a public.cc_auctions%rowtype; b public.cc_profiles%rowtype; s public.cc_profiles%rowtype; bo jsonb; wk text; label text; adm boolean;
begin
  select * into a from public.cc_auctions where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'not_found'); end if;
  if a.status <> 'open' then return jsonb_build_object('ok', false, 'err', 'gone'); end if;
  if a.seller = p_buyer then return jsonb_build_object('ok', false, 'err', 'own_listing'); end if;
  adm := a.seller = '[관리자]';
  perform 1 from public.cc_profiles where name in (a.seller, p_buyer) order by name for update;
  select * into b from public.cc_profiles where name = p_buyer;
  if not found then return jsonb_build_object('ok', false, 'err', 'no_profile'); end if;
  if not adm then
    select * into s from public.cc_profiles where name = a.seller;
    if not found then
      update public.cc_auctions set status = 'cancelled' where id = a.id;
      return jsonb_build_object('ok', false, 'err', 'seller_gone');
    end if;
  end if;
  if b.money < a.price then return jsonb_build_object('ok', false, 'err', 'no_money', 'need', a.price - b.money); end if;
  bo := coalesce(b.own, '{}'::jsonb);
  if a.kind = 'weapon' then
    wk := a.weapon::text;
    if public.cc_int(bo -> wk) > 0 then return jsonb_build_object('ok', false, 'err', 'owned'); end if;
    bo := jsonb_set(bo, array[wk], '1'::jsonb, true);
    bo := jsonb_set(bo, '{wu}', coalesce(bo -> 'wu', '{}'::jsonb) || jsonb_build_object(wk, a.lv), true);
    if a.ench is not null and jsonb_typeof(a.ench) = 'array' then bo := jsonb_set(bo, '{en}', coalesce(bo -> 'en', '{}'::jsonb) || jsonb_build_object(wk, a.ench), true); end if;
    label := '무기 +' || a.lv;
  else
    bo := jsonb_set(bo, array[a.kind], to_jsonb(public.cc_int(bo -> a.kind) + a.qty), true);
    label := a.kind || ' ×' || a.qty;
  end if;
  update public.cc_auctions set status = 'sold', buyer = p_buyer, sold_at = now() where id = a.id;
  perform public.cc_auc_apply(p_buyer, b.money - a.price, bo, '낙찰! ' || label || ' 구매 -$' || a.price);
  if not adm then perform public.cc_auc_apply(a.seller, s.money + a.price, coalesce(s.own, '{}'::jsonb), '판매 완료! ' || label || ' +$' || a.price || ' (' || p_buyer || ' 님)'); end if;
  return jsonb_build_object('ok', true, 'price', a.price);
end $$;

grant execute on function public.cc_admin_online(text), public.cc_admin_cmd(text, text, jsonb), public.cc_admin_cmd_room(text, text, jsonb), public.cc_admin_notice(text, text),
  public.cc_admin_ban(text, text, text, boolean), public.cc_admin_bans(text), public.cc_admin_auctions(text, text), public.cc_admin_auction_price(text, bigint, bigint),
  public.cc_admin_auction_add(text, text, int, int, jsonb, int, bigint), public.cc_admin_auction_remove(text, bigint, text) to anon, authenticated;
