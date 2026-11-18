-- HOOTAN CLUB database schema. Run this in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text default '',
  category text default 'عمومی',
  price bigint not null check (price >= 0),
  available boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  customer_phone text not null,
  note text default '',
  payment_method text not null default 'cash' check (payment_method = 'cash'),
  status text not null default 'new' check (status in ('new','preparing','ready','done','cancelled')),
  total_amount bigint not null check (total_amount >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price bigint not null check (unit_price >= 0),
  line_total bigint not null check (line_total >= 0)
);

-- Admin identity must be set in Supabase Auth app_metadata, never user_metadata.
create or replace function public.is_hootan_admin()
returns boolean language sql stable as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

drop policy if exists "Public can view available products" on public.products;
create policy "Public can view available products" on public.products for select using (available = true or public.is_hootan_admin());
drop policy if exists "Admins manage products" on public.products;
create policy "Admins manage products" on public.products for all to authenticated using (public.is_hootan_admin()) with check (public.is_hootan_admin());

drop policy if exists "Customers can create cash orders" on public.orders;
create policy "Customers can create cash orders" on public.orders for insert to anon, authenticated with check (payment_method = 'cash' and status = 'new' and total_amount >= 0 and discount_amount >= 0);
drop policy if exists "Admins read and update orders" on public.orders;
create policy "Admins read and update orders" on public.orders for all to authenticated using (public.is_hootan_admin()) with check (public.is_hootan_admin());

drop policy if exists "Customers create order items" on public.order_items;
create policy "Customers create order items" on public.order_items for insert to anon, authenticated with check (quantity > 0 and unit_price >= 0 and line_total = quantity * unit_price);
drop policy if exists "Admins manage order items" on public.order_items;
create policy "Admins manage order items" on public.order_items for all to authenticated using (public.is_hootan_admin()) with check (public.is_hootan_admin());

-- Starter menu
insert into public.products(name,description,category,price) values
('سیب‌زمینی آب‌پز کوچک','تازه و مناسب میان‌وعده','غذای سالم',35000),
('سیب‌زمینی آب‌پز متوسط','حجم متوسط و سیرکننده','غذای سالم',55000),
('سیب‌زمینی آب‌پز بزرگ','وعده کامل‌تر بعد تمرین','غذای سالم',70000),
('تخم‌مرغ','میان‌وعده پروتئینی','پروتئینی',20000),
('ماکارونی','وعده انرژی‌بخش','غذای گرم',65000)
on conflict do nothing;

-- Atomic, server-side order creation: prices and totals are read from the database,
-- not trusted from the customer's browser.
create or replace function public.place_order(payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_order_id uuid;
  item jsonb;
  product_row public.products%rowtype;
  qty integer;
  calculated_total bigint := 0;
  discount_value bigint := 0;
  final_total bigint;
begin
  if coalesce(trim(payload->>'customer_name'),'') = '' then
    raise exception 'نام مشتری الزامی است';
  end if;
  if coalesce(trim(payload->>'customer_phone'),'') = '' then
    raise exception 'شماره تماس الزامی است';
  end if;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then
    raise exception 'سبد خرید خالی است';
  end if;

  for item in select * from jsonb_array_elements(payload->'items') loop
    qty := (item->>'quantity')::integer;
    if qty < 1 or qty > 30 then raise exception 'تعداد محصول نامعتبر است'; end if;
    select * into product_row from public.products
      where id = (item->>'product_id')::uuid and available = true;
    if not found then raise exception 'یکی از محصولات موجود نیست'; end if;
    calculated_total := calculated_total + product_row.price * qty;
  end loop;

  if upper(coalesce(payload->>'coupon_code','')) = 'HOOTAN10' then
    discount_value := floor(calculated_total * 0.10);
  end if;
  final_total := calculated_total - discount_value;

  insert into public.orders(customer_name,customer_phone,note,payment_method,status,total_amount,discount_amount)
  values(trim(payload->>'customer_name'),trim(payload->>'customer_phone'),coalesce(payload->>'note',''),'cash','new',final_total,discount_value)
  returning id into new_order_id;

  for item in select * from jsonb_array_elements(payload->'items') loop
    qty := (item->>'quantity')::integer;
    select * into product_row from public.products
      where id = (item->>'product_id')::uuid and available = true;
    insert into public.order_items(order_id,product_id,product_name,quantity,unit_price,line_total)
    values(new_order_id,product_row.id,product_row.name,qty,product_row.price,product_row.price*qty);
  end loop;
  return new_order_id;
end;
$$;

revoke all on function public.place_order(jsonb) from public;
grant execute on function public.place_order(jsonb) to anon, authenticated;
