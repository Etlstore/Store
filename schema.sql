-- ============================================================
-- E-TRIMS STORE MANAGEMENT SYSTEM - SUPABASE SCHEMA
-- Run this entire file in Supabase SQL Editor (one project)
-- ============================================================

-- 1. STORES (Raw Material, WIP, Finished Goods, Consumables, Rejected, etc.)
create table if not exists stores (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text unique not null,           -- e.g. RM, WIP, FG, CONS, REJ
  type text not null,                  -- raw_material | wip | finished_goods | consumables | rejected
  is_active boolean default true,
  created_at timestamptz default now()
);

-- 2. ITEMS (master item catalog)
create table if not exists items (
  id uuid primary key default gen_random_uuid(),
  item_code text unique not null,
  item_name text not null,
  category text,                       -- e.g. Woven Label, Care Label, Adhesive, Patch, Packaging, Heat Transfer, Thermal
  uom text not null,                   -- unit of measure: pcs, roll, meter, kg, etc.
  reorder_level numeric default 0,
  standard_cost numeric default 0,
  is_active boolean default true,
  created_at timestamptz default now()
);

-- 3. SUPPLIERS
create table if not exists suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  contact text,
  created_at timestamptz default now()
);

-- 4. USERS (simple role-based auth, matches your existing pattern)
create table if not exists app_users (
  id uuid primary key default gen_random_uuid(),
  username text unique not null,
  password_hash text not null,
  full_name text not null,
  role text not null,                  -- admin | store_keeper | viewer
  is_active boolean default true,
  created_at timestamptz default now()
);

-- 5. GRN (Goods Received Note) - stock IN, creates a batch
create table if not exists grn (
  id uuid primary key default gen_random_uuid(),
  grn_no text unique not null,
  grn_date date not null default current_date,
  store_id uuid references stores(id) not null,
  item_id uuid references items(id) not null,
  batch_no text not null,
  qty numeric not null check (qty > 0),
  unit_cost numeric default 0,
  supplier_id uuid references suppliers(id),
  po_ref text,
  remarks text,
  created_by uuid references app_users(id),
  created_at timestamptz default now()
);

-- 6. ISSUES - stock OUT, consumes from a batch
create table if not exists issues (
  id uuid primary key default gen_random_uuid(),
  issue_no text unique not null,
  issue_date date not null default current_date,
  store_id uuid references stores(id) not null,
  item_id uuid references items(id) not null,
  batch_no text not null,
  qty numeric not null check (qty > 0),
  issued_to text,                      -- department / buyer-order reference
  order_ref text,                      -- buyer PO / job card ref
  remarks text,
  created_by uuid references app_users(id),
  created_at timestamptz default now()
);

-- 7. TRANSFERS - move stock between stores (e.g. WIP -> Finished Goods)
create table if not exists transfers (
  id uuid primary key default gen_random_uuid(),
  transfer_no text unique not null,
  transfer_date date not null default current_date,
  item_id uuid references items(id) not null,
  batch_no text not null,
  qty numeric not null check (qty > 0),
  from_store_id uuid references stores(id) not null,
  to_store_id uuid references stores(id) not null,
  remarks text,
  created_by uuid references app_users(id),
  created_at timestamptz default now()
);

-- ============================================================
-- VIEW: current batch-wise stock balance per store
-- (GRN + Transfers-in) - (Issues + Transfers-out)
-- ============================================================
create or replace view v_stock_balance as
select
  s.id as store_id, s.name as store_name, s.code as store_code,
  i.id as item_id, i.item_code, i.item_name, i.uom, i.reorder_level,
  b.batch_no,
  coalesce(sum(b.in_qty),0) - coalesce(sum(b.out_qty),0) as balance_qty
from stores s
cross join items i
left join (
  select store_id, item_id, batch_no, qty as in_qty, 0 as out_qty from grn
  union all
  select to_store_id as store_id, item_id, batch_no, qty as in_qty, 0 as out_qty from transfers
  union all
  select store_id, item_id, batch_no, 0 as in_qty, qty as out_qty from issues
  union all
  select from_store_id as store_id, item_id, batch_no, 0 as in_qty, qty as out_qty from transfers
) b on b.store_id = s.id and b.item_id = i.id
group by s.id, s.name, s.code, i.id, i.item_code, i.item_name, i.uom, i.reorder_level, b.batch_no
having coalesce(sum(b.in_qty),0) - coalesce(sum(b.out_qty),0) <> 0
   or b.batch_no is not null;

-- ============================================================
-- VIEW: daily ledger (opening / in / out / closing) per item per store
-- Use with a date filter in the app: where ledger_date = '2026-08-17'
-- ============================================================
create or replace view v_daily_movement as
select grn_date as move_date, store_id, item_id, batch_no, qty as in_qty, 0 as out_qty, 'GRN' as move_type, grn_no as ref_no
from grn
union all
select issue_date, store_id, item_id, batch_no, 0, qty, 'ISSUE', issue_no
from issues
union all
select transfer_date, to_store_id, item_id, batch_no, qty, 0, 'TRANSFER_IN', transfer_no
from transfers
union all
select transfer_date, from_store_id, item_id, batch_no, 0, qty, 'TRANSFER_OUT', transfer_no
from transfers;

-- Enable Row Level Security (open policies for anon key access;
-- access control is enforced in the app layer via app_users/roles,
-- matching your existing CS/CRM system pattern)
alter table stores enable row level security;
alter table items enable row level security;
alter table suppliers enable row level security;
alter table app_users enable row level security;
alter table grn enable row level security;
alter table issues enable row level security;
alter table transfers enable row level security;

create policy "allow all - stores" on stores for all using (true) with check (true);
create policy "allow all - items" on items for all using (true) with check (true);
create policy "allow all - suppliers" on suppliers for all using (true) with check (true);
create policy "allow all - app_users" on app_users for all using (true) with check (true);
create policy "allow all - grn" on grn for all using (true) with check (true);
create policy "allow all - issues" on issues for all using (true) with check (true);
create policy "allow all - transfers" on transfers for all using (true) with check (true);

-- ============================================================
-- SEED DATA
-- ============================================================
insert into stores (name, code, type) values
  ('Raw Material Store', 'RM', 'raw_material'),
  ('WIP Store', 'WIP', 'wip'),
  ('Finished Goods Store', 'FG', 'finished_goods'),
  ('Consumables Store', 'CONS', 'consumables'),
  ('Rejected / Quarantine Store', 'REJ', 'rejected')
on conflict (code) do nothing;

-- Default admin login: username = admin, password = admin123
-- (change this immediately after first login)
insert into app_users (username, password_hash, full_name, role) values
  ('admin', 'admin123', 'Administrator', 'admin')
on conflict (username) do nothing;
