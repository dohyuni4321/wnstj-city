-- v21 경매장 (방 코드 UUUUU)
-- 무기(강화·인첸트 포함, 기본 무기 제외) / 수류탄 / TNT / 박수치기 가이아나 원자폭탄을 올리고 사고팔 수 있어요.
-- 거래는 전부 서버 함수(SECURITY DEFINER)가 처리해서 무기 복제·돈 복사가 안 되게 했어요.
-- 계정 변경은 기존 관리자 수정 방식(adm_seq / adm)을 그대로 써서, 접속 중인 클라이언트가 2초 안에 반영해요.

create table if not exists public.cc_auctions (
  id         bigserial primary key,
  seller     text not null,
  kind       text not null default 'weapon' check (kind in ('weapon', 'gren', 'tnt', 'ab')),
  weapon     int,
  lv         int not null default 0,
  ench       jsonb,
  qty        int not null default 1 check (qty between 1 and 1000000),
  price      bigint not null check (price >= 100 and price <= 1000000000000),
  status     text not null default 'open' check (status in ('open', 'sold', 'cancelled')),
  buyer      text,
  created_at timestamptz not null default now(),
  sold_at    timestamptz,
  constraint cc_auctions_weapon_chk check (kind <> 'weapon' or (weapon between 6 and 60 and lv between 1 and 99))
);
create index if not exists cc_auctions_open_idx   on public.cc_auctions (status, created_at desc);
create index if not exists cc_auctions_seller_idx on public.cc_auctions (seller, status);

alter table public.cc_auctions enable row level security;
drop policy if exists "cc_auctions read" on public.cc_auctions;
create policy "cc_auctions read" on public.cc_auctions for select to anon, authenticated using (true);
-- insert / update / delete 정책이 없으므로 아래 함수로만 바뀝니다.

-- jsonb 값을 안전하게 정수로 (없거나 이상하면 0)
create or replace function public.cc_int(j jsonb) returns int
language sql immutable set search_path to 'public' as $$
  select case
    when j is null then 0
    when jsonb_typeof(j) = 'number' then least(2000000000, greatest(0, floor((j #>> '{}')::numeric)))::int
    when jsonb_typeof(j) = 'boolean' and j = 'true'::jsonb then 1
    else 0 end
$$;

-- 계정 반영 (내부 전용): 돈·own을 쓰고 adm_seq를 올려서 접속 중인 클라이언트가 바로 받게 함
create or replace function public.cc_auc_apply(p_name text, p_money bigint, p_own jsonb, p_note text)
returns void language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform set_config('cc.admin', '1', true);
  update public.cc_profiles
     set money = p_money, own = p_own, adm_seq = adm_seq + 1,
         adm = jsonb_build_object('money', p_money, 'own', p_own, 'at', extract(epoch from now()), 'src', 'auction', 'note', p_note),
         updated_at = now()
   where name = p_name;
end $$;
revoke all on function public.cc_auc_apply(text, bigint, jsonb, text) from public, anon, authenticated;

-- 등록: 서버가 판매자 계정을 직접 읽어서 무기/레벨/인첸트/수량을 확인하고 즉시 계정에서 뺌
create or replace function public.cc_auction_list(p_seller text, p_kind text, p_weapon int, p_qty int, p_price bigint)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare r public.cc_profiles%rowtype; o jsonb; wk text; lv int := 0; en jsonb := null; have int; n int; nid bigint; note text;
begin
  if p_kind is null or p_kind not in ('weapon', 'gren', 'tnt', 'ab') then return jsonb_build_object('ok', false, 'err', 'bad_kind'); end if;
  if p_price is null or p_price < 100 or p_price > 1000000000000 then return jsonb_build_object('ok', false, 'err', 'bad_price'); end if;
  select * into r from public.cc_profiles where name = p_seller for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'no_profile'); end if;
  select count(*) into n from public.cc_auctions where seller = p_seller and status = 'open';
  if n >= 8 then return jsonb_build_object('ok', false, 'err', 'too_many'); end if;
  o := coalesce(r.own, '{}'::jsonb);
  if p_kind = 'weapon' then
    if p_weapon is null or p_weapon < 6 or p_weapon > 60 then return jsonb_build_object('ok', false, 'err', 'base_weapon'); end if;   -- 기본 무기(0~5)는 판매 불가
    wk := p_weapon::text;
    if public.cc_int(o -> wk) = 0 then return jsonb_build_object('ok', false, 'err', 'not_owned'); end if;
    lv := public.cc_int(o -> 'wu' -> wk);
    if lv < 1 then return jsonb_build_object('ok', false, 'err', 'not_enhanced'); end if;                                            -- 강화한 무기만
    en := o -> 'en' -> wk;
    o := o - wk;
    o := jsonb_set(o, '{wu}', coalesce(o -> 'wu', '{}'::jsonb) - wk, true);
    o := jsonb_set(o, '{en}', coalesce(o -> 'en', '{}'::jsonb) - wk, true);
    insert into public.cc_auctions (seller, kind, weapon, lv, ench, qty, price) values (p_seller, 'weapon', p_weapon, lv, en, 1, p_price) returning id into nid;
    note := '경매에 등록했어요 (무기 +' || lv || ')';
  else
    if p_qty is null or p_qty < 1 or p_qty > 1000000 then return jsonb_build_object('ok', false, 'err', 'bad_qty'); end if;
    have := public.cc_int(o -> p_kind);
    if have < p_qty then return jsonb_build_object('ok', false, 'err', 'not_enough', 'have', have); end if;
    o := jsonb_set(o, array[p_kind], to_jsonb(have - p_qty), true);
    insert into public.cc_auctions (seller, kind, qty, price) values (p_seller, p_kind, p_qty, p_price) returning id into nid;
    note := '경매에 등록했어요 (' || p_kind || ' ×' || p_qty || ')';
  end if;
  perform public.cc_auc_apply(p_seller, r.money, o, note);
  return jsonb_build_object('ok', true, 'id', nid);
end $$;

-- 취소: 물건을 판매자 계정으로 돌려줌 (같은 무기를 이미 갖고 있으면 덮어쓰지 않고 거절)
create or replace function public.cc_auction_cancel(p_id bigint, p_seller text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a public.cc_auctions%rowtype; r public.cc_profiles%rowtype; o jsonb; wk text;
begin
  select * into a from public.cc_auctions where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'not_found'); end if;
  if a.seller <> p_seller then return jsonb_build_object('ok', false, 'err', 'not_yours'); end if;
  if a.status <> 'open' then return jsonb_build_object('ok', false, 'err', 'not_open'); end if;
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
  update public.cc_auctions set status = 'cancelled' where id = a.id;
  perform public.cc_auc_apply(a.seller, r.money, o, '경매 등록을 취소하고 물건을 돌려받았어요');
  return jsonb_build_object('ok', true);
end $$;

-- 구매: 구매자 DB 잔액 확인 → 차감 + 물건 지급 + 판매자에게 대금 지급 (전부 한 트랜잭션, 행 잠금)
create or replace function public.cc_auction_buy(p_id bigint, p_buyer text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a public.cc_auctions%rowtype; b public.cc_profiles%rowtype; s public.cc_profiles%rowtype; bo jsonb; wk text; label text;
begin
  select * into a from public.cc_auctions where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'not_found'); end if;
  if a.status <> 'open' then return jsonb_build_object('ok', false, 'err', 'gone'); end if;
  if a.seller = p_buyer then return jsonb_build_object('ok', false, 'err', 'own_listing'); end if;
  perform 1 from public.cc_profiles where name in (a.seller, p_buyer) order by name for update;
  select * into b from public.cc_profiles where name = p_buyer;
  if not found then return jsonb_build_object('ok', false, 'err', 'no_profile'); end if;
  select * into s from public.cc_profiles where name = a.seller;
  if not found then
    update public.cc_auctions set status = 'cancelled' where id = a.id;
    return jsonb_build_object('ok', false, 'err', 'seller_gone');
  end if;
  if b.money < a.price then return jsonb_build_object('ok', false, 'err', 'no_money', 'need', a.price - b.money); end if;
  bo := coalesce(b.own, '{}'::jsonb);
  if a.kind = 'weapon' then
    wk := a.weapon::text;
    if public.cc_int(bo -> wk) > 0 then return jsonb_build_object('ok', false, 'err', 'owned'); end if;   -- 같은 무기가 이미 있으면 덮어써서 잃지 않게 거절
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
  perform public.cc_auc_apply(a.seller, s.money + a.price, coalesce(s.own, '{}'::jsonb), '판매 완료! ' || label || ' +$' || a.price || ' (' || p_buyer || ' 님)');
  return jsonb_build_object('ok', true, 'price', a.price);
end $$;

grant execute on function public.cc_auction_list(text, text, int, int, bigint) to anon, authenticated;
grant execute on function public.cc_auction_cancel(bigint, text) to anon, authenticated;
grant execute on function public.cc_auction_buy(bigint, text) to anon, authenticated;
