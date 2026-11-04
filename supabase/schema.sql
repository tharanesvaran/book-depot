-- =====================================================================
-- College Book Depot: Supabase schema
-- Run this whole file once in Supabase -> SQL Editor -> New query -> Run.
-- It is safe to re-run: tables use IF NOT EXISTS and functions use
-- CREATE OR REPLACE.
-- =====================================================================

-- ---------- Tables ----------

create table if not exists public.admins (
  email text primary key check (email = lower(email))
);

create table if not exists public.products (
  id         bigint generated always as identity primary key,
  name       text not null check (length(trim(name)) > 0),
  price      numeric(10,2) not null check (price >= 0),
  stock      integer not null default 0 check (stock >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  name       text not null check (length(trim(name)) > 0),
  roll       text not null unique check (roll ~ '^[A-Z0-9-]+$'),
  course     text not null check (length(trim(course)) > 0),
  year       smallint not null check (year between 1 and 5),
  phone      text not null unique check (phone ~ '^[0-9]{10}$'),
  balance    numeric(10,2) not null default 0 check (balance >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id         bigint generated always as identity primary key,
  student_id uuid references public.students(id) on delete set null,
  roll       text not null,
  status     text not null default 'pending' check (status in ('pending','billed','rejected')),
  total      numeric(10,2) not null default 0 check (total >= 0),
  walk       boolean not null default false,
  pay        text check (pay in ('bal','cash')),
  created_at timestamptz not null default now(),
  billed_at  timestamptz
);
create index if not exists orders_student_idx on public.orders(student_id);
create index if not exists orders_status_idx  on public.orders(status);
create index if not exists orders_created_idx on public.orders(created_at);

create table if not exists public.order_items (
  id         bigint generated always as identity primary key,
  order_id   bigint not null references public.orders(id) on delete cascade,
  product_id bigint references public.products(id) on delete set null,
  name       text not null,
  qty        integer not null check (qty > 0),
  price      numeric(10,2) not null check (price >= 0)
);
create index if not exists order_items_order_idx on public.order_items(order_id);

create table if not exists public.restocks (
  id         bigint generated always as identity primary key,
  product_id bigint not null references public.products(id) on delete cascade,
  qty        integer not null check (qty > 0),
  created_at timestamptz not null default now()
);
create index if not exists restocks_created_idx on public.restocks(created_at);

-- ---------- Helper: is the signed-in user an admin? ----------

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.admins
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- ---------- Row Level Security ----------
-- Browsers can only READ what they are allowed to see. Every change to
-- stock, prices, balances and orders goes through the functions below.

alter table public.admins      enable row level security;
alter table public.products    enable row level security;
alter table public.students    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;
alter table public.restocks    enable row level security;

drop policy if exists products_read    on public.products;
drop policy if exists students_read    on public.students;
drop policy if exists students_insert  on public.students;
drop policy if exists orders_read      on public.orders;
drop policy if exists order_items_read on public.order_items;
drop policy if exists restocks_read    on public.restocks;

create policy products_read on public.products
  for select to authenticated using (true);

create policy students_read on public.students
  for select to authenticated using (id = auth.uid() or public.is_admin());

-- A student may create ONLY their own row, with a zero balance.
create policy students_insert on public.students
  for insert to authenticated
  with check (
    id = auth.uid()
    and balance = 0
    and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

create policy orders_read on public.orders
  for select to authenticated using (student_id = auth.uid() or public.is_admin());

create policy order_items_read on public.order_items
  for select to authenticated using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and (o.student_id = auth.uid() or public.is_admin())
    )
  );

create policy restocks_read on public.restocks
  for select to authenticated using (public.is_admin());

-- Defence in depth: remove direct write access everywhere except the
-- student registration insert.
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant select on public.products, public.students, public.orders,
                public.order_items, public.restocks to authenticated;
grant insert on public.students to authenticated;

-- ---------- Functions (the only way to change data) ----------

-- Student: submit an order request. Items: [{"pid":1,"qty":2}, ...]
create or replace function public.place_order(p_items jsonb)
returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  s   public.students;
  pr  public.products;
  it  jsonb;
  q   integer;
  oid bigint;
  tot numeric := 0;
begin
  select * into s from public.students where id = auth.uid();
  if not found then raise exception 'Register as a student first.'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item.';
  end if;

  if (select count(*) from public.orders where student_id = s.id and status = 'pending') >= 10 then
    raise exception 'You already have 10 pending requests. Collect or wait for them first.';
  end if;

  insert into public.orders(student_id, roll, status, total)
  values (s.id, s.roll, 'pending', 0) returning id into oid;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it ->> 'qty')::integer;
    if q is null or q <= 0 then raise exception 'Invalid quantity.'; end if;
    select * into pr from public.products where id = (it ->> 'pid')::bigint;
    if not found then raise exception 'Product not found.'; end if;
    if pr.stock < q then raise exception 'Only % left of %.', pr.stock, pr.name; end if;
    insert into public.order_items(order_id, product_id, name, qty, price)
    values (oid, pr.id, pr.name, q, pr.price);
    tot := tot + q * pr.price;
  end loop;

  update public.orders set total = tot where id = oid;
  return oid;
end;
$$;

-- Admin: bill a pending request (checks ID scan, balance and stock).
create or replace function public.bill_order(p_order bigint, p_scan text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  o  public.orders;
  s  public.students;
  it record;
  pr public.products;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;

  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Request not found.'; end if;
  if o.status <> 'pending' then raise exception 'This request is already %.', o.status; end if;
  if upper(trim(coalesce(p_scan, ''))) <> o.roll then
    raise exception 'Scanned ID does not match this student.';
  end if;

  select * into s from public.students where id = o.student_id for update;
  if not found then raise exception 'Student account not found.'; end if;
  if s.balance < o.total then raise exception 'Insufficient balance. Top up first.'; end if;

  for it in select * from public.order_items where order_id = o.id order by product_id loop
    select * into pr from public.products where id = it.product_id for update;
    if not found or pr.stock < it.qty then
      raise exception 'Not enough stock for %.', it.name;
    end if;
    update public.products set stock = stock - it.qty where id = pr.id;
  end loop;

  update public.students set balance = balance - o.total where id = s.id;
  update public.orders set status = 'billed', billed_at = now() where id = o.id;
end;
$$;

-- Admin: reject a pending request.
create or replace function public.reject_order(p_order bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.orders set status = 'rejected' where id = p_order and status = 'pending';
  if not found then raise exception 'Only pending requests can be rejected.'; end if;
end;
$$;

-- Admin: counter sale with no student request.
-- p_pay = 'bal' (charge the student's balance, p_roll required) or 'cash'.
create or replace function public.walkin_sale(p_items jsonb, p_pay text, p_roll text)
returns bigint
language plpgsql security definer set search_path = public
as $$
declare
  s   public.students;
  pr  public.products;
  it  jsonb;
  q   integer;
  oid bigint;
  tot numeric := 0;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_pay not in ('bal', 'cash') then raise exception 'Invalid payment method.'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item.';
  end if;

  if p_pay = 'bal' then
    select * into s from public.students
    where roll = upper(regexp_replace(coalesce(p_roll, ''), '\s+', '', 'g')) for update;
    if not found then raise exception 'No student found with this roll number.'; end if;
  end if;

  insert into public.orders(student_id, roll, status, total, walk, pay, billed_at)
  values (s.id, coalesce(s.roll, 'WALK-IN'), 'billed', 0, true, p_pay, now())
  returning id into oid;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it ->> 'qty')::integer;
    if q is null or q <= 0 then raise exception 'Invalid quantity.'; end if;
    select * into pr from public.products where id = (it ->> 'pid')::bigint for update;
    if not found then raise exception 'Product not found.'; end if;
    if pr.stock < q then raise exception 'Not enough stock for %.', pr.name; end if;
    update public.products set stock = stock - q where id = pr.id;
    insert into public.order_items(order_id, product_id, name, qty, price)
    values (oid, pr.id, pr.name, q, pr.price);
    tot := tot + q * pr.price;
  end loop;

  if p_pay = 'bal' then
    if s.balance < tot then raise exception 'Insufficient balance. Top up first.'; end if;
    update public.students set balance = balance - tot where id = s.id;
  end if;

  update public.orders set total = tot where id = oid;
  return oid;
end;
$$;

-- Admin: add stock to an existing product (also logged for monthly reports).
create or replace function public.restock_product(p_product bigint, p_qty integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Quantity must be at least 1.'; end if;
  update public.products set stock = stock + p_qty where id = p_product;
  if not found then raise exception 'Product not found.'; end if;
  insert into public.restocks(product_id, qty) values (p_product, p_qty);
end;
$$;

-- Admin: create a new product (initial stock is logged as a restock).
create or replace function public.add_product(p_name text, p_price numeric, p_stock integer)
returns bigint
language plpgsql security definer set search_path = public
as $$
declare pid bigint;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'Item name is required.'; end if;
  if p_price is null or p_price < 0 then raise exception 'Price must be 0 or more.'; end if;
  if p_stock is null or p_stock < 0 then raise exception 'Stock must be 0 or more.'; end if;
  insert into public.products(name, price, stock) values (trim(p_name), p_price, p_stock)
  returning id into pid;
  if p_stock > 0 then
    insert into public.restocks(product_id, qty) values (pid, p_stock);
  end if;
  return pid;
end;
$$;

-- Admin: change a product's price.
create or replace function public.set_price(p_product bigint, p_price numeric)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_price is null or p_price < 0 then raise exception 'Price must be 0 or more.'; end if;
  update public.products set price = p_price where id = p_product;
  if not found then raise exception 'Product not found.'; end if;
end;
$$;

-- Admin: top up (positive) or deduct (negative) a student's balance.
create or replace function public.adjust_balance(p_student uuid, p_amount numeric)
returns void
language plpgsql security definer set search_path = public
as $$
declare s public.students;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_amount is null or p_amount = 0 then raise exception 'Enter an amount.'; end if;
  select * into s from public.students where id = p_student for update;
  if not found then raise exception 'Student not found.'; end if;
  if s.balance + p_amount < 0 then raise exception 'Cannot deduct more than the balance.'; end if;
  update public.students set balance = balance + p_amount where id = p_student;
end;
$$;

-- Only signed-in users may call these (never anonymous visitors).
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.is_admin(),
  public.place_order(jsonb),
  public.bill_order(bigint, text),
  public.reject_order(bigint),
  public.walkin_sale(jsonb, text, text),
  public.restock_product(bigint, integer),
  public.add_product(text, numeric, integer),
  public.set_price(bigint, numeric),
  public.adjust_balance(uuid, numeric)
to authenticated;

-- ---------- Starter products (only if the table is empty) ----------

insert into public.products(name, price, stock)
select v.name, v.price, v.stock
from (values
  ('Notebook 200 pages', 60, 50),
  ('Ball pen (blue)', 10, 120),
  ('Record book', 120, 8),
  ('Graph sheets (pack)', 25, 0),
  ('Pencil', 5, 40),
  ('Geometry box', 90, 6),
  ('Scientific calculator', 450, 15),
  ('Highlighter', 30, 25)
) as v(name, price, stock)
where not exists (select 1 from public.products);

-- ---------- Make yourself an admin ----------
-- Replace with the Google email you will sign in with (lowercase), then run:
--
--   insert into public.admins(email) values ('you@gmail.com');
