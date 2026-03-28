

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pgsodium";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "postgis" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."apply_promo_to_cart"("p_code" "text", "p_user_id" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_unit_prices" numeric[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_discount    numeric;
  v_brand_id    int;
  v_min_order   numeric;
  v_pu          record;
  v_eligible    int[] := '{}';
  v_excluded    int[] := '{}';
  v_total       numeric := 0;
  v_eligible_total numeric := 0;
  v_discount_amount numeric := 0;
  i             int;
  v_product     record;
  v_promo       record;
BEGIN
  -- Validate array lengths
  IF array_length(p_product_ids, 1) IS DISTINCT FROM array_length(p_quantities, 1)
     OR array_length(p_product_ids, 1) IS DISTINCT FROM array_length(p_unit_prices, 1)
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Array lengths do not match'
    );
  END IF;

  -- 1. Validate the promo code (dry run — no increment)
  SELECT * INTO v_promo
  FROM promos
  WHERE lower(nume) = lower(p_code)
  LIMIT 1;

  IF v_promo IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_found', 'message', 'Promo code not found');
  END IF;

  IF v_promo.start_date IS NOT NULL AND v_promo.start_date > now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_started', 'message', 'Promo has not started yet');
  END IF;

  IF v_promo.end_date IS NOT NULL AND v_promo.end_date <= now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'expired', 'message', 'Promo code has expired');
  END IF;

  IF v_promo.max_uses IS NOT NULL AND v_promo.current_uses >= v_promo.max_uses THEN
    RETURN jsonb_build_object('success', false, 'error', 'max_uses_reached', 'message', 'Promo code has been fully used');
  END IF;

  IF v_promo.visibility = 'private' THEN
    SELECT * INTO v_pu
    FROM promo_users pu
    WHERE pu.promo_id = v_promo.id
      AND (pu.user_id = p_user_id OR pu.phone_number = p_user_id)
    LIMIT 1;

    IF v_pu IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'not_authorized', 'message', 'Not authorized');
    END IF;

    IF v_pu.max_uses_per_person IS NOT NULL AND v_pu.uses_count >= v_pu.max_uses_per_person THEN
      RETURN jsonb_build_object('success', false, 'error', 'per_user_limit_reached', 'message', 'Personal limit reached');
    END IF;
  END IF;

  v_discount := COALESCE(v_promo.sale, 0);
  v_brand_id := v_promo.brand_id;
  v_min_order := COALESCE(v_promo.min_order_value, 0);

  -- 2. Classify products: eligible vs excluded (already on sale)
  FOR i IN 1..array_length(p_product_ids, 1) LOOP
    SELECT * INTO v_product FROM products WHERE id = p_product_ids[i];

    v_total := v_total + (p_unit_prices[i] * p_quantities[i]);

    IF v_product.sale IS NOT NULL AND v_product.sale > 0 THEN
      v_excluded := array_append(v_excluded, p_product_ids[i]);
    ELSIF v_brand_id IS NOT NULL AND v_product.brand_id IS DISTINCT FROM v_brand_id THEN
      v_excluded := array_append(v_excluded, p_product_ids[i]);
    ELSE
      v_eligible := array_append(v_eligible, p_product_ids[i]);
      v_eligible_total := v_eligible_total + (p_unit_prices[i] * p_quantities[i]);
    END IF;
  END LOOP;

  -- 3. Check minimum order amount
  DECLARE
    v_effective_min numeric;
  BEGIN
    v_effective_min := v_min_order;
    IF v_pu IS NOT NULL AND v_pu.min_order_amount IS NOT NULL AND v_pu.min_order_amount > 0 THEN
      v_effective_min := v_pu.min_order_amount;
    END IF;

    IF v_total < v_effective_min THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'min_order_not_met',
        'message', 'Order total does not meet minimum requirement',
        'min_order_amount', v_effective_min,
        'current_total', v_total
      );
    END IF;
  END;

  -- 4. Calculate discount on eligible items only
  v_discount_amount := ROUND(v_eligible_total * v_discount / 100, 2);

  -- 5. Return result without incrementing (caller decides to confirm)
  RETURN jsonb_build_object(
    'success', true,
    'promo_id', v_promo.id,
    'code', v_promo.nume,
    'discount_percent', v_discount,
    'eligible_product_ids', to_jsonb(v_eligible),
    'excluded_product_ids', to_jsonb(v_excluded),
    'cart_total', v_total,
    'eligible_total', v_eligible_total,
    'discount_amount', v_discount_amount,
    'final_total', v_total - v_discount_amount
  );
END;
$$;


ALTER FUNCTION "public"."apply_promo_to_cart"("p_code" "text", "p_user_id" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_unit_prices" numeric[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_decrement_stock"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE products
  SET stock_quantity = stock_quantity - NEW.quantity
  WHERE id = NEW.product_id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_decrement_stock"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_expire_products"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE products
  SET stock_quantity = 0
  WHERE end_date IS NOT NULL
    AND end_date < now()
    AND stock_quantity > 0;
END;
$$;


ALTER FUNCTION "public"."fn_expire_products"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_validate_order_products"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_invalid int[];
BEGIN
  IF NEW.product_list IS NOT NULL THEN
    SELECT array_agg(pid) INTO v_invalid
    FROM unnest(NEW.product_list) AS pid
    WHERE NOT EXISTS (SELECT 1 FROM products WHERE id = pid);

    IF v_invalid IS NOT NULL THEN
      RAISE EXCEPTION 'Invalid product IDs: %', v_invalid;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_validate_order_products"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_order_products"("p_order_id" integer, "p_order_type" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_product_list int[];
  v_value_list   int[];
  v_price_list   numeric[];
  v_items        jsonb := '[]'::jsonb;
  i              int;
  v_product      record;
BEGIN
  -- Fetch the arrays from the correct order table
  IF p_order_type = 'livrare' THEN
    SELECT product_list, value_list, price_list
    INTO v_product_list, v_value_list, v_price_list
    FROM "comenzile(livrare)"
    WHERE id = p_order_id;
  ELSIF p_order_type = 'ridicare' THEN
    SELECT product_list, value_list, price_list
    INTO v_product_list, v_value_list, v_price_list
    FROM "comenzile(ridicare)"
    WHERE id = p_order_id;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'Invalid order type');
  END IF;

  IF v_product_list IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Order not found');
  END IF;

  -- Build product details array
  FOR i IN 1..COALESCE(array_length(v_product_list, 1), 0) LOOP
    SELECT * INTO v_product FROM products WHERE id = v_product_list[i];

    v_items := v_items || jsonb_build_object(
      'product_id',   v_product_list[i],
      'quantity',     v_value_list[i],
      'unit_price',   v_price_list[i],
      'name',         v_product.nume,
      'name_ru',      v_product.nume_ru,
      'image',        v_product.imagine,
      'grupa',        v_product.grupa,
      'stock',        v_product.stock
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'order_type', p_order_type,
    'items', v_items,
    'items_count', COALESCE(array_length(v_product_list, 1), 0)
  );
END;
$$;


ALTER FUNCTION "public"."get_order_products"("p_order_id" integer, "p_order_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."place_order_items"("p_order_id" integer, "p_order_type" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_prices" numeric[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  i              int;
  v_stock        int;
  v_out_of_stock int[] := '{}';
BEGIN
  -- Validate array lengths match
  IF array_length(p_product_ids, 1) IS DISTINCT FROM array_length(p_quantities, 1)
     OR array_length(p_product_ids, 1) IS DISTINCT FROM array_length(p_prices, 1)
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'error',   'Array lengths do not match'
    );
  END IF;

  -- Lock product rows to prevent race conditions
  PERFORM id FROM products
  WHERE id = ANY(p_product_ids)
  ORDER BY id
  FOR UPDATE;

  -- Check stock for each item
  FOR i IN 1..array_length(p_product_ids, 1) LOOP
    SELECT stock_quantity INTO v_stock
    FROM products
    WHERE id = p_product_ids[i];

    IF v_stock IS NULL OR v_stock < p_quantities[i] THEN
      v_out_of_stock := array_append(v_out_of_stock, p_product_ids[i]);
    END IF;
  END LOOP;

  -- If any items are out of stock, abort
  IF array_length(v_out_of_stock, 1) > 0 THEN
    RETURN jsonb_build_object(
      'success',      false,
      'error',        'Insufficient stock',
      'out_of_stock', to_jsonb(v_out_of_stock)
    );
  END IF;

  -- Decrement stock directly (no order_items table needed)
  FOR i IN 1..array_length(p_product_ids, 1) LOOP
    UPDATE products
    SET stock_quantity = stock_quantity - p_quantities[i],
        stock = CASE
                  WHEN stock_quantity - p_quantities[i] <= 0 THEN false
                  ELSE stock
                END
    WHERE id = p_product_ids[i];
  END LOOP;

  RETURN jsonb_build_object(
    'success',     true,
    'items_count', array_length(p_product_ids, 1)
  );
END;
$$;


ALTER FUNCTION "public"."place_order_items"("p_order_id" integer, "p_order_type" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_prices" numeric[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trimite_comanda_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  response json;
begin
  -- Trimite cererea HTTP POST către webhook-ul de la Make
  select
    http_post(
      'https://hook.eu2.make.com/e08uckm5vq2osua9jy71t26ql8g5llbp',
      row_to_json(NEW)::text,
      'application/json'
    )
  into response;

  return NEW;
end;
$$;


ALTER FUNCTION "public"."trimite_comanda_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_promo_code"("p_code" "text", "p_user_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_promo     record;
  v_pu        record;
  v_remaining int;
BEGIN
  -- 1. Look up promo by code (case-insensitive)
  SELECT * INTO v_promo
  FROM promos
  WHERE lower(nume) = lower(p_code)
  LIMIT 1;

  IF v_promo IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'not_found',
      'message', 'Promo code not found'
    );
  END IF;

  -- 2. Check if promo hasn't started yet
  IF v_promo.start_date IS NOT NULL AND v_promo.start_date > now() THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'not_started',
      'message', 'Promo has not started yet'
    );
  END IF;

  -- 3. Check if promo is expired (using end_date only)
  IF v_promo.end_date IS NOT NULL AND v_promo.end_date <= now() THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'expired',
      'message', 'Promo code has expired'
    );
  END IF;

  -- 4. Check global max uses
  IF v_promo.max_uses IS NOT NULL AND v_promo.current_uses >= v_promo.max_uses THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'max_uses_reached',
      'message', 'Promo code has been fully used'
    );
  END IF;

  -- 5. Check visibility: if private, verify user is allowed
  IF v_promo.visibility = 'private' THEN
    SELECT * INTO v_pu
    FROM promo_users pu
    WHERE pu.promo_id = v_promo.id
      AND (pu.user_id = p_user_id OR pu.phone_number = p_user_id)
    LIMIT 1;

    IF v_pu IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'not_authorized',
        'message', 'You are not authorized to use this promo'
      );
    END IF;

    -- 5b. Check per-user usage limit
    IF v_pu.max_uses_per_person IS NOT NULL AND v_pu.uses_count >= v_pu.max_uses_per_person THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'per_user_limit_reached',
        'message', 'You have reached your personal usage limit for this promo'
      );
    END IF;
  END IF;

  -- 6. Atomically increment current_uses
  UPDATE promos
  SET current_uses = COALESCE(current_uses, 0) + 1
  WHERE id = v_promo.id;

  -- Increment per-user uses_count if applicable
  IF v_pu IS NOT NULL THEN
    UPDATE promo_users
    SET uses_count = COALESCE(uses_count, 0) + 1
    WHERE id = v_pu.id;
  END IF;

  -- Calculate remaining
  v_remaining := CASE
    WHEN v_promo.max_uses IS NOT NULL
    THEN v_promo.max_uses - (COALESCE(v_promo.current_uses, 0) + 1)
    ELSE NULL
  END;

  -- 7. Return success with promo details
  RETURN jsonb_build_object(
    'success', true,
    'promo_id', v_promo.id,
    'code', v_promo.nume,
    'discount', COALESCE(v_promo.sale, 0),
    'type', COALESCE(v_promo.type, 'public'),
    'visibility', COALESCE(v_promo.visibility, 'public'),
    'min_order_value', COALESCE(v_promo.min_order_value, 0),
    'brand_id', v_promo.brand_id,
    'max_uses', v_promo.max_uses,
    'remaining_uses', v_remaining
  );
END;
$$;


ALTER FUNCTION "public"."validate_promo_code"("p_code" "text", "p_user_id" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."reclama" (
    "id" bigint NOT NULL,
    "name" "text",
    "images" "text",
    "shown_at" "text",
    "promo_start" "date",
    "head" "text",
    "description" "text",
    "head_ru" "text",
    "description_ru" "text",
    "share_link" "text",
    "ordered_able" boolean DEFAULT false,
    "order_link" "text",
    "name_ru" "text",
    "active_until" timestamp with time zone,
    "brand_id" integer
);


ALTER TABLE "public"."reclama" OWNER TO "postgres";


COMMENT ON COLUMN "public"."reclama"."name" IS 'Această denumire de la reclamă apare doar la secțiunea Acțiuni și este folosită pentru toate reclamele.';



COMMENT ON COLUMN "public"."reclama"."images" IS 'Imaginea care prezintă reclama se indică împreună cu dimensiunea acesteia.';



COMMENT ON COLUMN "public"."reclama"."shown_at" IS 'Locurile unde poate fi plasată reclama vor fi numite categoriile de mărfuri.(;)';



COMMENT ON COLUMN "public"."reclama"."promo_start" IS 'Promo start indică începutul promoției, afișat în reclamă atunci când utilizatorul apasă pe ea.';



COMMENT ON COLUMN "public"."reclama"."head" IS 'Este textul care apare atunci când utilizatorul apasă pe reclamă.';



COMMENT ON COLUMN "public"."reclama"."description" IS 'Descrierea promoției apare atunci când utilizatorul apasă pe reclamă.';



COMMENT ON COLUMN "public"."reclama"."head_ru" IS 'Este textul care apare atunci când utilizatorul apasă pe reclamă dar textul trebuie indicat in rusa';



COMMENT ON COLUMN "public"."reclama"."description_ru" IS 'Descrierea promoției apare atunci când utilizatorul apasă pe reclamă doar ca textul trebuie indicat in rusa';



COMMENT ON COLUMN "public"."reclama"."share_link" IS 'Share link este locul unde se indică linkul, astfel încât reclama să poată fi distribuită altor persoane.';



COMMENT ON COLUMN "public"."reclama"."ordered_able" IS 'Atunci când utilizatorul apasă pe reclamă, un buton poate apărea sau dispărea. Se setează astfel: true pentru a apărea și false pentru a dispărea.';



COMMENT ON COLUMN "public"."reclama"."order_link" IS 'linkul care este legat de buton';



COMMENT ON COLUMN "public"."reclama"."name_ru" IS 'Această denumire de la reclamă apare doar la secțiunea Acțiuni și este folosită pentru toate reclamele doar ca trebuie sa fie indicat in rusa';



COMMENT ON COLUMN "public"."reclama"."active_until" IS 'Active until arată până când reclama este valabilă.';



COMMENT ON COLUMN "public"."reclama"."brand_id" IS 'Brand ID se folosește pentru a face reclama nu la un serviciu, ci la un grup specific de produse. Dacă indici Brand ID-ul mărfurilor, reclama poate fi direcționată către produsele cu reducere, produsele noi sau alte categorii similare.';



CREATE OR REPLACE VIEW "public"."active_ads" AS
 SELECT "reclama"."id",
    "reclama"."name",
    "reclama"."images",
    "reclama"."shown_at",
    "reclama"."promo_start",
    "reclama"."head",
    "reclama"."description",
    "reclama"."head_ru",
    "reclama"."description_ru",
    "reclama"."share_link",
    "reclama"."ordered_able",
    "reclama"."order_link",
    "reclama"."name_ru",
    "reclama"."active_until",
    "reclama"."brand_id"
   FROM "public"."reclama"
  WHERE ((("reclama"."active_until" IS NULL) OR ("reclama"."active_until" > "now"())) AND (("reclama"."promo_start" IS NULL) OR ("reclama"."promo_start" <= "now"())));


ALTER TABLE "public"."active_ads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."promos" (
    "id" bigint NOT NULL,
    "nume" "text",
    "sale" numeric,
    "type" "text",
    "start_date" timestamp with time zone,
    "end_date" timestamp with time zone,
    "min_order_value" numeric DEFAULT 0,
    "max_uses" integer,
    "current_uses" integer DEFAULT 0,
    "brand_id" integer,
    "visibility" "text" DEFAULT 'public'::"text",
    CONSTRAINT "chk_promos_uses" CHECK ((("max_uses" IS NULL) OR ("current_uses" <= "max_uses"))),
    CONSTRAINT "chk_promos_visibility" CHECK (("visibility" = ANY (ARRAY['public'::"text", 'private'::"text"])))
);


ALTER TABLE "public"."promos" OWNER TO "postgres";


COMMENT ON COLUMN "public"."promos"."nume" IS 'Nume la promo este denumirea pe care oamenii o vor folosi pentru a putea aplica promo-codul.';



COMMENT ON COLUMN "public"."promos"."sale" IS 'Sale numeric indică procentul de reducere (1–100%) aplicat pentru acest promo-cod.';



COMMENT ON COLUMN "public"."promos"."type" IS 'Type promo-codului poate fi privat sau public; privat este vizibil doar pentru o persoană, iar public este vizibil pentru toți.';



COMMENT ON COLUMN "public"."promos"."start_date" IS 'Explicație scurtă: **Start date** indică data de început a promo-codului.';



COMMENT ON COLUMN "public"."promos"."end_date" IS 'End indică data de sfârșit a promo-codului.';



COMMENT ON COLUMN "public"."promos"."min_order_value" IS 'Min order value indică suma minimă a comenzii necesară pentru a putea folosi promo-codul.';



COMMENT ON COLUMN "public"."promos"."max_uses" IS 'Max uses indică numărul maxim de utilizări ale promo-codului.';



COMMENT ON COLUMN "public"."promos"."current_uses" IS 'Current uses indică numărul actual de utilizări ale promo-codului.';



COMMENT ON COLUMN "public"."promos"."visibility" IS 'Visibility indică dacă promo-codul este privat sau public.';



CREATE OR REPLACE VIEW "public"."active_promos" AS
 SELECT "promos"."id",
    "promos"."nume",
    "promos"."sale",
    "promos"."type",
    "promos"."start_date",
    "promos"."end_date",
    "promos"."min_order_value",
    "promos"."max_uses",
    "promos"."current_uses",
    "promos"."brand_id",
    "promos"."visibility"
   FROM "public"."promos"
  WHERE ((("promos"."start_date" IS NULL) OR ("promos"."start_date" <= "now"())) AND (("promos"."end_date" IS NULL) OR ("promos"."end_date" > "now"())) AND (("promos"."max_uses" IS NULL) OR ("promos"."current_uses" < "promos"."max_uses")));


ALTER TABLE "public"."active_promos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."brands" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "name_ru" "text",
    "slug" "text" NOT NULL,
    "image_url" "text",
    "is_active" boolean DEFAULT true,
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "category_id" integer
);


ALTER TABLE "public"."brands" OWNER TO "postgres";


COMMENT ON COLUMN "public"."brands"."name" IS 'Nume la brands este locul unde se adună toate grupele de mărfuri și produsele care aparțin acestei categorii.';



COMMENT ON COLUMN "public"."brands"."name_ru" IS 'Nume la brands este locul unde se adună toate grupele de mărfuri și produsele care aparțin acestei categorii.Doar ca textul se indica in rusa';



COMMENT ON COLUMN "public"."brands"."image_url" IS 'Image URL este imaginea care va fi afișată pe cartonașul brandurilor.';



COMMENT ON COLUMN "public"."brands"."is_active" IS 'Is active indică dacă categoria este activă; dacă este activă valoarea este true, iar dacă nu este activă este false.';



COMMENT ON COLUMN "public"."brands"."sort_order" IS 'Sort order indică ordinea cartonașelor în aplicație.';



CREATE SEQUENCE IF NOT EXISTS "public"."brands_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."brands_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."brands_id_seq" OWNED BY "public"."brands"."id";



CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "name_ru" "text",
    "image_url" "text",
    "is_active" boolean DEFAULT true,
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."categories" OWNER TO "postgres";


COMMENT ON COLUMN "public"."categories"."name" IS 'Este numele atribuit categoriei de mărfuri.';



COMMENT ON COLUMN "public"."categories"."name_ru" IS 'Este numele atribuit categoriei de mărfuri.Doar ca in rusa';



COMMENT ON COLUMN "public"."categories"."image_url" IS 'Image URL este linkul imaginii folosite pentru a afișa grupa de marfă; aici trebuie indicată și dimensiunea imaginii.';



COMMENT ON COLUMN "public"."categories"."is_active" IS 'Is active arată dacă grupa de mărfuri este activă; dacă este activă valoarea este true, iar dacă nu este activă este false.';



COMMENT ON COLUMN "public"."categories"."sort_order" IS 'Sort order stabilește ordinea grupelor de mărfuri; 1 este primul, 2 al doilea etc.';



CREATE SEQUENCE IF NOT EXISTS "public"."categories_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."categories_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."categories_id_seq" OWNED BY "public"."categories"."id";



CREATE TABLE IF NOT EXISTS "public"."comenzile(livrare)" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid",
    "price_list" double precision[],
    "product_list" bigint[],
    "value_list" bigint[],
    "summ" double precision,
    "adress" "text",
    "phone" "text",
    "comment" "text",
    "apartamentul" "text",
    "scara" "text",
    "etajul" "text",
    "timpul" "text",
    "data" "date",
    "promo" "text",
    "payment" "text",
    "address_type" "text" DEFAULT 'apartment'::"text"
);


ALTER TABLE "public"."comenzile(livrare)" OWNER TO "postgres";


COMMENT ON COLUMN "public"."comenzile(livrare)"."price_list" IS 'preturile la  produse';



CREATE TABLE IF NOT EXISTS "public"."comenzile(ridicare)" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid",
    "price_list" double precision[],
    "product_list" bigint[],
    "value_list" bigint[],
    "summ" double precision,
    "phone" "text",
    "comment" "text",
    "timpul" "text",
    "data" "date",
    "promo" "text",
    "payment" "text",
    "locatia" "text"
);


ALTER TABLE "public"."comenzile(ridicare)" OWNER TO "postgres";


ALTER TABLE "public"."comenzile(ridicare)" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."comenzile(ridicare)_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."comenzile(livrare)" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."comenzile_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."fizic" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nume" "text",
    "telefon" "text",
    "email" "text",
    "adress" "text",
    "scara" "text",
    "etaj" "text",
    "apartament" "text",
    "adress2" "text",
    "scara2" "text",
    "etaj2" "text",
    "apartament2" "text",
    "adress3" "text",
    "scara3" "text",
    "etaj3" "text",
    "apartament3" "text",
    "sector1" "text",
    "sector2" "text",
    "sector3" "text",
    "strikes" bigint,
    "banned" boolean DEFAULT false,
    "favoriteItems" bigint[],
    "juridic" boolean DEFAULT false,
    "cod_fiscal" "text",
    "adresa_juridică" "text",
    "iban" "text",
    "filiala_bancii" "text",
    "address_type" "text" DEFAULT 'apartment'::"text",
    "address_type2" "text" DEFAULT 'apartment'::"text",
    "address_type3" "text" DEFAULT 'apartment'::"text",
    "office" "text",
    "office2" "text",
    "office3" "text",
    "bloc" "text",
    "bloc2" "text",
    "bloc3" "text",
    CONSTRAINT "chk_fizic_address_type" CHECK ((("address_type" IS NULL) OR ("address_type" = ANY (ARRAY['apartment'::"text", 'house'::"text", 'office'::"text"])))),
    CONSTRAINT "chk_fizic_address_type2" CHECK ((("address_type2" IS NULL) OR ("address_type2" = ANY (ARRAY['apartment'::"text", 'house'::"text", 'office'::"text"])))),
    CONSTRAINT "chk_fizic_address_type3" CHECK ((("address_type3" IS NULL) OR ("address_type3" = ANY (ARRAY['apartment'::"text", 'house'::"text", 'office'::"text"]))))
);


ALTER TABLE "public"."fizic" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."smm_team" (
    "id" bigint NOT NULL,
    "name" "text",
    "image" "text",
    "description" "text",
    "type" "text",
    "name_ro" "text",
    "name_ru" "text",
    "description_ro" "text",
    "description_ru" "text",
    "type_ro" "text",
    "type_ru" "text",
    "telegram" "text",
    "instagram" "text",
    "tiktok" "text"
);


ALTER TABLE "public"."smm_team" OWNER TO "postgres";


COMMENT ON COLUMN "public"."smm_team"."name" IS 'Numele se indică în locul unde este vizibil pe cartonașul din echipa SMM și apare ca denumire unică pentru a putea fi identificat ușor.';



COMMENT ON COLUMN "public"."smm_team"."image" IS 'Imaginea se indică în cartonaș și în profilul bloggerului, iar dimensiunile trebuie de asemenea specificate.';



COMMENT ON COLUMN "public"."smm_team"."description" IS 'Descrierea este locul unde persoana spune despre sine în 2–3 propoziții. Aceasta este indicată în profilul lui din echipa SMM.';



COMMENT ON COLUMN "public"."smm_team"."type" IS 'Type este indicat în cartonașul lui din echipa SMM și arată în ce categorie sau tip este încadrat.';



ALTER TABLE "public"."smm_team" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."hmm_team_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."parteneri" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "imagine_companie" "text",
    "nume" "text",
    "adresa" "text",
    "sector" "text",
    "program_de_lucru" "text",
    "telefon" "text",
    "instagram" "text",
    "telegram" "text",
    "whatsapp" "text",
    "email" "text"
);


ALTER TABLE "public"."parteneri" OWNER TO "postgres";


COMMENT ON COLUMN "public"."parteneri"."nume" IS 'numele companiei care va fi indicat in aplicatie';



COMMENT ON COLUMN "public"."parteneri"."adresa" IS 'adresa unde se afla partenerul si de unde poti prelua comanda';



COMMENT ON COLUMN "public"."parteneri"."sector" IS 'sectorul in care se afla partenerul';



COMMENT ON COLUMN "public"."parteneri"."program_de_lucru" IS 'program de lucru in care lucreaza partenerul';



COMMENT ON COLUMN "public"."parteneri"."telefon" IS 'telefonul partenerului pe care poate telefona clientul';



COMMENT ON COLUMN "public"."parteneri"."instagram" IS 'linkul care te trimite pe instagramul partenerului';



COMMENT ON COLUMN "public"."parteneri"."telegram" IS 'linkul care te trimite pe telegramul partenerului';



COMMENT ON COLUMN "public"."parteneri"."whatsapp" IS 'linkul care te trimite pe whatsappul partenerului';



COMMENT ON COLUMN "public"."parteneri"."email" IS 'email partenerului in  care va fi indicat in aplicatie';



ALTER TABLE "public"."parteneri" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."parteneri_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nume" "text",
    "imagine" "text",
    "cantitate" bigint,
    "pret" numeric,
    "compozitie" "text",
    "marca_comerciala" "text",
    "producatorul" "text",
    "cantitatea" "text",
    "tara_de_origine" "text",
    "sum_else" boolean DEFAULT false,
    "compozitie_ru" "text",
    "marca_comerciala_ru" "text",
    "producatorul_ru" "text",
    "cantitatea_ru" "text",
    "tara_de_origine_ru" "text" DEFAULT 'Турция'::"text",
    "nume_ru" "text",
    "recommend" boolean DEFAULT false,
    "sale" integer DEFAULT 0 NOT NULL,
    "brand_id" integer,
    "category_id" integer,
    "stock_quantity" integer DEFAULT 0,
    "start_date" timestamp with time zone,
    "end_date" timestamp with time zone,
    "barcode" "text",
    "gallery_images" "text"[] DEFAULT '{}'::"text"[],
    "nou_start" timestamp with time zone,
    "nou_end" timestamp with time zone,
    CONSTRAINT "chk_stock_quantity_non_negative" CHECK (("stock_quantity" >= 0)),
    CONSTRAINT "products_sale_range" CHECK ((("sale" >= 0) AND ("sale" <= 100)))
);


ALTER TABLE "public"."products" OWNER TO "postgres";


COMMENT ON COLUMN "public"."products"."nume" IS 'Este numele produsului așa cum este indicat în aplicație.';



COMMENT ON COLUMN "public"."products"."imagine" IS 'Este imaginea produsului, arătând cum arată acesta.';



COMMENT ON COLUMN "public"."products"."cantitate" IS 'Numărul de bucăți arată câte unități ale produsului se vând în aplicație, de exemplu 12 buc, 35 buc etc.';



COMMENT ON COLUMN "public"."products"."pret" IS 'Prețul produsului este cel indicat în aplicație.';



COMMENT ON COLUMN "public"."products"."compozitie" IS 'Compoziție este descrierea produsului.';



COMMENT ON COLUMN "public"."products"."marca_comerciala" IS 'Marca comercială este locul unde se indică informații suplimentare despre marfă.';



COMMENT ON COLUMN "public"."products"."producatorul" IS 'Producătorul indică cine este producătorul sau importatorul produsului.';



COMMENT ON COLUMN "public"."products"."cantitatea" IS 'Cantitatea arată volumul produsului în kg, litri, grame etc.';



COMMENT ON COLUMN "public"."products"."tara_de_origine" IS 'Țara de origine indică proveniența produsului.';



COMMENT ON COLUMN "public"."products"."sum_else" IS 'arata locul in aplicatie (inca ceva?)';



COMMENT ON COLUMN "public"."products"."compozitie_ru" IS 'Compoziție este descrierea produsului. dar indicat in rusa';



COMMENT ON COLUMN "public"."products"."marca_comerciala_ru" IS 'Marca comercială este locul unde se indică informații suplimentare despre marfă.dar care este indicata in rusa';



COMMENT ON COLUMN "public"."products"."producatorul_ru" IS 'Producătorul indică cine este producătorul sau importatorul produsului.dar care este indicata in rusa';



COMMENT ON COLUMN "public"."products"."cantitatea_ru" IS 'Numărul de bucăți arată câte unități ale produsului se vând în aplicație, de exemplu 12 buc, 35 buc etc.Dar care este indicat in rusa';



COMMENT ON COLUMN "public"."products"."tara_de_origine_ru" IS 'Țara de origine indică proveniența produsului.Dar care este indicat in rusa';



COMMENT ON COLUMN "public"."products"."nume_ru" IS 'Este numele produsului așa cum este indicat în aplicație. dar indicat in rusa';



COMMENT ON COLUMN "public"."products"."recommend" IS 'arata in recomandari ori la Hamidiye ori la beypazari';



COMMENT ON COLUMN "public"."products"."sale" IS 'arata reducerea la produs de la 1-100%';



COMMENT ON COLUMN "public"."products"."stock_quantity" IS 'se indica cantitatea de marfa prezenta in depozit 1,2,3 si este important de mentionat ca apoi se face X cu buc de ex 3Xbuc de produs';



COMMENT ON COLUMN "public"."products"."start_date" IS 'se indica termenul de valabilitate a produsului cind a fost produs';



COMMENT ON COLUMN "public"."products"."end_date" IS 'se indica termenul de valabilitate a produsului cind va fi expirat';



COMMENT ON COLUMN "public"."products"."barcode" IS 'barcode indica numarul de pe marfa pentru  putea fi cautat in cautare in aplicatie sau in baza cu date';



COMMENT ON COLUMN "public"."products"."nou_start" IS 'se indica din ce data va fi indicat ca produsul estte nou';



COMMENT ON COLUMN "public"."products"."nou_end" IS 'se indica pina la ce data va fi indicat ca produsul este nou';



ALTER TABLE "public"."products" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."products_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."promo_users" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "promo_id" integer NOT NULL,
    "user_id" "text",
    "phone_number" "text",
    "min_order_amount" numeric DEFAULT 0,
    "max_uses_per_person" integer,
    "uses_count" integer DEFAULT 0,
    CONSTRAINT "chk_promo_users_per_person" CHECK ((("max_uses_per_person" IS NULL) OR ("uses_count" <= "max_uses_per_person")))
);


ALTER TABLE "public"."promo_users" OWNER TO "postgres";


COMMENT ON TABLE "public"."promo_users" IS 'Tabelul PromoUsers indică persoanele care dețin în prezent un promo-cod privat.';



COMMENT ON COLUMN "public"."promo_users"."promo_id" IS 'Promo ID este identificatorul promo-codului, legat de persoana respectivă din tabelul Promos.';



COMMENT ON COLUMN "public"."promo_users"."user_id" IS 'User ID se folosește pentru a lega promo-codul de ID-ul utilizatorului din aplicație.';



COMMENT ON COLUMN "public"."promo_users"."phone_number" IS 'Phone number indică numărul de telefon pentru a lega promo-codul de utilizator.';



ALTER TABLE "public"."promo_users" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."promo_users_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."promos" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."promos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."reclama" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."reclama_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."time_slots" (
    "id" integer NOT NULL,
    "date" "date" NOT NULL,
    "time_slot" character varying(10) NOT NULL,
    "booked_count" integer DEFAULT 0,
    "max_capacity" integer DEFAULT 3,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."time_slots" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."time_slots_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."time_slots_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."time_slots_id_seq" OWNED BY "public"."time_slots"."id";



ALTER TABLE ONLY "public"."brands" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."brands_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."categories" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."categories_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."time_slots" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."time_slots_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comenzile(ridicare)"
    ADD CONSTRAINT "comenzile(ridicare)_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comenzile(livrare)"
    ADD CONSTRAINT "comenzile_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fizic"
    ADD CONSTRAINT "fizic_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."smm_team"
    ADD CONSTRAINT "hmm_team_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."parteneri"
    ADD CONSTRAINT "parteneri_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promo_users"
    ADD CONSTRAINT "promo_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promo_users"
    ADD CONSTRAINT "promo_users_promo_id_user_id_key" UNIQUE ("promo_id", "user_id");



ALTER TABLE ONLY "public"."promos"
    ADD CONSTRAINT "promos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reclama"
    ADD CONSTRAINT "reclama_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."time_slots"
    ADD CONSTRAINT "time_slots_date_time_slot_key" UNIQUE ("date", "time_slot");



ALTER TABLE ONLY "public"."time_slots"
    ADD CONSTRAINT "time_slots_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_brands_category_id" ON "public"."brands" USING "btree" ("category_id");



CREATE INDEX "idx_products_barcode" ON "public"."products" USING "btree" ("barcode");



CREATE INDEX "idx_products_brand_id" ON "public"."products" USING "btree" ("brand_id");



CREATE INDEX "idx_products_category_id" ON "public"."products" USING "btree" ("category_id");



CREATE INDEX "idx_products_dates" ON "public"."products" USING "btree" ("start_date", "end_date");



CREATE INDEX "idx_promo_users_promo_id" ON "public"."promo_users" USING "btree" ("promo_id");



CREATE INDEX "idx_promo_users_user_id" ON "public"."promo_users" USING "btree" ("user_id");



CREATE INDEX "idx_promos_brand_id" ON "public"."promos" USING "btree" ("brand_id");



CREATE INDEX "idx_promos_dates" ON "public"."promos" USING "btree" ("start_date", "end_date");



CREATE INDEX "idx_reclama_active_until" ON "public"."reclama" USING "btree" ("active_until");



CREATE INDEX "idx_reclama_brand_id" ON "public"."reclama" USING "btree" ("brand_id");



CREATE OR REPLACE TRIGGER "trg_validate_products_livrare" BEFORE INSERT OR UPDATE ON "public"."comenzile(livrare)" FOR EACH ROW EXECUTE FUNCTION "public"."fn_validate_order_products"();



CREATE OR REPLACE TRIGGER "trg_validate_products_ridicare" BEFORE INSERT OR UPDATE ON "public"."comenzile(ridicare)" FOR EACH ROW EXECUTE FUNCTION "public"."fn_validate_order_products"();



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id");



ALTER TABLE ONLY "public"."fizic"
    ADD CONSTRAINT "fizic_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id");



ALTER TABLE ONLY "public"."promo_users"
    ADD CONSTRAINT "promo_users_promo_id_fkey" FOREIGN KEY ("promo_id") REFERENCES "public"."promos"("id") ON DELETE CASCADE;



CREATE POLICY "Anyone can read active brands" ON "public"."brands" FOR SELECT TO "authenticated", "anon" USING (("is_active" = true));



CREATE POLICY "Anyone can read active categories" ON "public"."categories" FOR SELECT TO "authenticated", "anon" USING (("is_active" = true));



CREATE POLICY "Users can increment promo uses" ON "public"."promos" FOR UPDATE TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "Users can only see active ads" ON "public"."reclama" FOR SELECT TO "authenticated", "anon" USING (((("active_until" IS NULL) OR ("active_until" > "now"())) AND (("promo_start" IS NULL) OR ("promo_start" <= "now"()))));



CREATE POLICY "Users can see active promos" ON "public"."promos" FOR SELECT TO "authenticated", "anon" USING (((("start_date" IS NULL) OR ("start_date" <= "now"())) AND (("end_date" IS NULL) OR ("end_date" > "now"())) AND (("max_uses" IS NULL) OR ("current_uses" < "max_uses")) AND (("visibility" = 'public'::"text") OR (("visibility" = 'private'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."promo_users" "pu"
  WHERE (("pu"."promo_id" = "promos"."id") AND ("pu"."user_id" = ("auth"."uid"())::"text"))))))));



CREATE POLICY "Users can see their own promo assignments" ON "public"."promo_users" FOR SELECT TO "authenticated", "anon" USING (("user_id" = ("auth"."uid"())::"text"));



ALTER TABLE "public"."promo_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."promos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reclama" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";













































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































GRANT ALL ON FUNCTION "public"."apply_promo_to_cart"("p_code" "text", "p_user_id" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_unit_prices" numeric[]) TO "anon";
GRANT ALL ON FUNCTION "public"."apply_promo_to_cart"("p_code" "text", "p_user_id" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_unit_prices" numeric[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_promo_to_cart"("p_code" "text", "p_user_id" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_unit_prices" numeric[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_decrement_stock"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_decrement_stock"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_decrement_stock"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_expire_products"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_expire_products"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_expire_products"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_validate_order_products"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_validate_order_products"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_validate_order_products"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_order_products"("p_order_id" integer, "p_order_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_order_products"("p_order_id" integer, "p_order_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_order_products"("p_order_id" integer, "p_order_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."place_order_items"("p_order_id" integer, "p_order_type" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_prices" numeric[]) TO "anon";
GRANT ALL ON FUNCTION "public"."place_order_items"("p_order_id" integer, "p_order_type" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_prices" numeric[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."place_order_items"("p_order_id" integer, "p_order_type" "text", "p_product_ids" integer[], "p_quantities" integer[], "p_prices" numeric[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."trimite_comanda_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."trimite_comanda_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trimite_comanda_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_promo_code"("p_code" "text", "p_user_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."validate_promo_code"("p_code" "text", "p_user_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_promo_code"("p_code" "text", "p_user_id" "text") TO "service_role";


























































































GRANT ALL ON TABLE "public"."reclama" TO "anon";
GRANT ALL ON TABLE "public"."reclama" TO "authenticated";
GRANT ALL ON TABLE "public"."reclama" TO "service_role";



GRANT ALL ON TABLE "public"."active_ads" TO "anon";
GRANT ALL ON TABLE "public"."active_ads" TO "authenticated";
GRANT ALL ON TABLE "public"."active_ads" TO "service_role";



GRANT ALL ON TABLE "public"."promos" TO "anon";
GRANT ALL ON TABLE "public"."promos" TO "authenticated";
GRANT ALL ON TABLE "public"."promos" TO "service_role";



GRANT ALL ON TABLE "public"."active_promos" TO "anon";
GRANT ALL ON TABLE "public"."active_promos" TO "authenticated";
GRANT ALL ON TABLE "public"."active_promos" TO "service_role";



GRANT ALL ON TABLE "public"."brands" TO "anon";
GRANT ALL ON TABLE "public"."brands" TO "authenticated";
GRANT ALL ON TABLE "public"."brands" TO "service_role";



GRANT ALL ON SEQUENCE "public"."brands_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."brands_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."brands_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."comenzile(livrare)" TO "anon";
GRANT ALL ON TABLE "public"."comenzile(livrare)" TO "authenticated";
GRANT ALL ON TABLE "public"."comenzile(livrare)" TO "service_role";



GRANT ALL ON TABLE "public"."comenzile(ridicare)" TO "anon";
GRANT ALL ON TABLE "public"."comenzile(ridicare)" TO "authenticated";
GRANT ALL ON TABLE "public"."comenzile(ridicare)" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comenzile(ridicare)_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comenzile(ridicare)_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comenzile(ridicare)_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comenzile_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comenzile_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comenzile_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."fizic" TO "anon";
GRANT ALL ON TABLE "public"."fizic" TO "authenticated";
GRANT ALL ON TABLE "public"."fizic" TO "service_role";



GRANT ALL ON TABLE "public"."smm_team" TO "anon";
GRANT ALL ON TABLE "public"."smm_team" TO "authenticated";
GRANT ALL ON TABLE "public"."smm_team" TO "service_role";



GRANT ALL ON SEQUENCE "public"."hmm_team_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."hmm_team_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."hmm_team_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."parteneri" TO "anon";
GRANT ALL ON TABLE "public"."parteneri" TO "authenticated";
GRANT ALL ON TABLE "public"."parteneri" TO "service_role";



GRANT ALL ON SEQUENCE "public"."parteneri_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."parteneri_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."parteneri_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."promo_users" TO "anon";
GRANT ALL ON TABLE "public"."promo_users" TO "authenticated";
GRANT ALL ON TABLE "public"."promo_users" TO "service_role";



GRANT ALL ON SEQUENCE "public"."promo_users_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."promo_users_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."promo_users_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."promos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."promos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."promos_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."reclama_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."reclama_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."reclama_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."time_slots" TO "anon";
GRANT ALL ON TABLE "public"."time_slots" TO "authenticated";
GRANT ALL ON TABLE "public"."time_slots" TO "service_role";



GRANT ALL ON SEQUENCE "public"."time_slots_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."time_slots_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."time_slots_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";






























