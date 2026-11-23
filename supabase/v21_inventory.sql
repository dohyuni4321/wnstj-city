-- v21 인벤토리: 같은 무기를 또 사거나 받으면 덮어쓰지 않고 own.inv(인벤토리)에 보관해요.
-- own.inv = [{"w":무기번호,"lv":강화,"en":[인첸트종류,레벨] 또는 null}, ...]  (최대 80칸)
-- 경매: 이미 같은 무기를 갖고 있어도 구매 가능(인벤토리로 들어감) · 취소/관리자 반환도 인벤토리로 · 인벤토리 무기도 경매에 올릴 수 있음.

create or replace function public.cc_inv_push(o jsonb, p_w int, p_lv int, p_en jsonb) returns jsonb
language plpgsql immutable set search_path to 'public' as $$
declare inv jsonb := coalesce(o -> 'inv', '[]'::jsonb);
begin
  if jsonb_typeof(inv) <> 'array' then inv := '[]'::jsonb; end if;
  if jsonb_array_length(inv) >= 80 then return null; end if;
  return jsonb_set(o, '{inv}', inv || jsonb_build_array(jsonb_build_object('w', p_w, 'lv', p_lv, 'en', case when p_en is not null and jsonb_typeof(p_en) = 'array' then p_en else null end)), true);
end $$;

drop function if exists public.cc_auction_list(text, text, int, int, bigint);
create or replace function public.cc_auction_list(p_seller text, p_kind text, p_weapon int, p_qty int, p_price bigint, p_inv int default -1)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare r public.cc_profiles%rowtype; o jsonb; wk text; lv int := 0; en jsonb := null; have int; n int; nid bigint; note text; inv jsonb; it jsonb; w int;
begin
  if p_kind is null or p_kind not in ('weapon', 'gren', 'tnt', 'ab') then return jsonb_build_object('ok', false, 'err', 'bad_kind'); end if;
  if p_price is null or p_price < 100 or p_price > 1000000000000 then return jsonb_build_object('ok', false, 'err', 'bad_price'); end if;
  select * into r from public.cc_profiles where name = p_seller for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'no_profile'); end if;
  select count(*) into n from public.cc_auctions where seller = p_seller and status = 'open';
  if n >= 8 then return jsonb_build_object('ok', false, 'err', 'too_many'); end if;
  o := coalesce(r.own, '{}'::jsonb);
  if p_kind = 'weapon' then
    if p_inv is not null and p_inv >= 0 then
      -- 인벤토리에 보관 중인 무기
      inv := coalesce(o -> 'inv', '[]'::jsonb);
      if jsonb_typeof(inv) <> 'array' or p_inv >= jsonb_array_length(inv) then return jsonb_build_object('ok', false, 'err', 'not_owned'); end if;
      it := inv -> p_inv; w := public.cc_int(it -> 'w'); lv := public.cc_int(it -> 'lv');
      if w < 6 or w > 60 then return jsonb_build_object('ok', false, 'err', 'base_weapon'); end if;
      if lv < 1 then return jsonb_build_object('ok', false, 'err', 'not_enhanced'); end if;
      en := case when jsonb_typeof(it -> 'en') = 'array' then it -> 'en' else null end;
      o := jsonb_set(o, '{inv}', inv - p_inv, true);
      insert into public.cc_auctions (seller, kind, weapon, lv, ench, qty, price) values (p_seller, 'weapon', w, lv, en, 1, p_price) returning id into nid;
    else
      if p_weapon is null or p_weapon < 6 or p_weapon > 60 then return jsonb_build_object('ok', false, 'err', 'base_weapon'); end if;   -- 기본 무기(0~5)는 판매 불가
      wk := p_weapon::text;
      if public.cc_int(o -> wk) = 0 then return jsonb_build_object('ok', false, 'err', 'not_owned'); end if;
      lv := public.cc_int(o -> 'wu' -> wk);
      if lv < 1 then return jsonb_build_object('ok', false, 'err', 'not_enhanced'); end if;
      en := o -> 'en' -> wk;
      o := o - wk;
      o := jsonb_set(o, '{wu}', coalesce(o -> 'wu', '{}'::jsonb) - wk, true);
      o := jsonb_set(o, '{en}', coalesce(o -> 'en', '{}'::jsonb) - wk, true);
      insert into public.cc_auctions (seller, kind, weapon, lv, ench, qty, price) values (p_seller, 'weapon', p_weapon, lv, en, 1, p_price) returning id into nid;
    end if;
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
grant execute on function public.cc_auction_list(text, text, int, int, bigint, int) to anon, authenticated;

-- 취소: 같은 무기를 이미 갖고 있으면 인벤토리로 돌려줌
create or replace function public.cc_auction_cancel(p_id bigint, p_seller text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a public.cc_auctions%rowtype; r public.cc_profiles%rowtype; o jsonb; wk text; o2 jsonb;
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
    if public.cc_int(o -> wk) > 0 then
      o2 := public.cc_inv_push(o, a.weapon, a.lv, a.ench);
      if o2 is null then return jsonb_build_object('ok', false, 'err', 'inv_full'); end if;
      o := o2;
    else
      o := jsonb_set(o, array[wk], '1'::jsonb, true);
      o := jsonb_set(o, '{wu}', coalesce(o -> 'wu', '{}'::jsonb) || jsonb_build_object(wk, a.lv), true);
      if a.ench is not null and jsonb_typeof(a.ench) = 'array' then o := jsonb_set(o, '{en}', coalesce(o -> 'en', '{}'::jsonb) || jsonb_build_object(wk, a.ench), true); end if;
    end if;
  else
    o := jsonb_set(o, array[a.kind], to_jsonb(public.cc_int(o -> a.kind) + a.qty), true);
  end if;
  update public.cc_auctions set status = 'cancelled' where id = a.id;
  perform public.cc_auc_apply(a.seller, r.money, o, '경매 등록을 취소하고 물건을 돌려받았어요');
  return jsonb_build_object('ok', true);
end $$;

-- 구매: 같은 무기가 이미 있으면 인벤토리에 보관 (핫바 장착은 I 키 인벤토리에서 고름)
create or replace function public.cc_auction_buy(p_id bigint, p_buyer text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a public.cc_auctions%rowtype; b public.cc_profiles%rowtype; s public.cc_profiles%rowtype; bo jsonb; wk text; label text; adm boolean; o2 jsonb; toinv boolean := false;
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
    if public.cc_int(bo -> wk) > 0 then
      o2 := public.cc_inv_push(bo, a.weapon, a.lv, a.ench);
      if o2 is null then return jsonb_build_object('ok', false, 'err', 'inv_full'); end if;
      bo := o2; toinv := true;
    else
      bo := jsonb_set(bo, array[wk], '1'::jsonb, true);
      bo := jsonb_set(bo, '{wu}', coalesce(bo -> 'wu', '{}'::jsonb) || jsonb_build_object(wk, a.lv), true);
      if a.ench is not null and jsonb_typeof(a.ench) = 'array' then bo := jsonb_set(bo, '{en}', coalesce(bo -> 'en', '{}'::jsonb) || jsonb_build_object(wk, a.ench), true); end if;
    end if;
    label := '무기 +' || a.lv || case when toinv then ' (인벤토리에 보관)' else '' end;
  else
    bo := jsonb_set(bo, array[a.kind], to_jsonb(public.cc_int(bo -> a.kind) + a.qty), true);
    label := a.kind || ' ×' || a.qty;
  end if;
  update public.cc_auctions set status = 'sold', buyer = p_buyer, sold_at = now() where id = a.id;
  perform public.cc_auc_apply(p_buyer, b.money - a.price, bo, '낙찰! ' || label || ' 구매 -$' || a.price);
  if not adm then perform public.cc_auc_apply(a.seller, s.money + a.price, coalesce(s.own, '{}'::jsonb), '판매 완료! ' || label || ' +$' || a.price || ' (' || p_buyer || ' 님)'); end if;
  return jsonb_build_object('ok', true, 'price', a.price, 'inv', toinv);
end $$;

-- 관리자 내리기(돌려주기)도 인벤토리 방식
create or replace function public.cc_admin_auction_remove(pw text, p_id bigint, p_mode text) returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a public.cc_auctions%rowtype; r public.cc_profiles%rowtype; o jsonb; wk text; o2 jsonb;
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
      if public.cc_int(o -> wk) > 0 then
        o2 := public.cc_inv_push(o, a.weapon, a.lv, a.ench);
        if o2 is null then return jsonb_build_object('ok', false, 'err', 'inv_full'); end if;
        o := o2;
      else
        o := jsonb_set(o, array[wk], '1'::jsonb, true);
        o := jsonb_set(o, '{wu}', coalesce(o -> 'wu', '{}'::jsonb) || jsonb_build_object(wk, a.lv), true);
        if a.ench is not null and jsonb_typeof(a.ench) = 'array' then o := jsonb_set(o, '{en}', coalesce(o -> 'en', '{}'::jsonb) || jsonb_build_object(wk, a.ench), true); end if;
      end if;
    else
      o := jsonb_set(o, array[a.kind], to_jsonb(public.cc_int(o -> a.kind) + a.qty), true);
    end if;
    perform public.cc_auc_apply(a.seller, r.money, o, '관리자가 경매를 내리고 물건을 돌려줬어요');
  end if;
  update public.cc_auctions set status = 'cancelled' where id = a.id;
  return jsonb_build_object('ok', true);
end $$;
