-- supplier_product_cache
-- Cache for the article lookup (Edge Function lookup-article): supplier + article number -> product title.
-- Only the Edge Function (service role) reads and writes it. Signed-in users and anon get no access.
-- found = false is a "not found" answer, kept for a short time (the function decides how long).
-- The product image is not stored: its link is built from the article number.

create table public.supplier_product_cache (
  supplier_key text not null check (supplier_key ~ '^[a-z0-9_-]{2,30}$'),
  article_no text not null check (char_length(article_no) between 1 and 30),
  found boolean not null,
  name text check (name is null or char_length(name) between 1 and 200),
  fetched_at timestamptz not null default now(),
  primary key (supplier_key, article_no),
  check (found = (name is not null))
);

alter table public.supplier_product_cache enable row level security;
revoke all on public.supplier_product_cache from anon, authenticated;
-- no policies on purpose: the service role bypasses row level security
