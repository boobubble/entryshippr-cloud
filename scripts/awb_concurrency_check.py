#!/usr/bin/env python3
"""
EntrySetu — REAL two-session concurrency checks for AWB numbering and charge locks.

Opens two separate PostgreSQL connections (two backends, two transactions) and
interleaves them so one really waits on the other's row/index lock.

THROWAWAY DATABASES ONLY. It commits test users, a client and shipments, and the
charge-audit history it produces is immutable by design, so it cannot clean up
fully. It refuses Supabase hosts. Requires the full EntrySetu migration chain
(including migration_2026_10_15_awb_series_manual_charges.sql) and a superuser DSN.

  pip install psycopg2-binary
  python3 scripts/awb_concurrency_check.py "host=/tmp/pg port=55432 dbname=t3 user=postgres"
"""
import sys, threading, time, uuid, json
import psycopg2

DSN = sys.argv[1] if len(sys.argv) > 1 else ""
if not DSN or "supabase" in DSN.lower():
    sys.exit("Refusing: pass a throwaway local PostgreSQL DSN (Supabase hosts are refused).")

SELLER = str(uuid.uuid4())
TAG = SELLER[:6].upper()
results = []

def check(cond, label):
    results.append((bool(cond), label))
    print(("PASS " if cond else "FAIL ") + label)

def admin():
    c = psycopg2.connect(DSN); c.autocommit = True; return c

def seller_session():
    c = psycopg2.connect(DSN); c.autocommit = False
    cur = c.cursor()
    cur.execute("set role authenticated")
    cur.execute("select set_config('request.jwt.claims', %s, false), set_config('request.jwt.claim.sub', %s, false)",
                (json.dumps({"sub": SELLER, "role": "authenticated"}), SELLER))
    c.commit()
    return c

def run_bg(fn):
    out = {}
    def wrap():
        try: out["value"] = fn()
        except Exception as e: out["error"] = e
    t = threading.Thread(target=wrap); t.start(); return t, out

def is_waiting(a, pid):
    cur = a.cursor()
    cur.execute("select wait_event_type from pg_stat_activity where pid = %s", (pid,))
    r = cur.fetchone(); return bool(r) and r[0] == "Lock"

def wait_until_blocked(a, pid, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        if is_waiting(a, pid): return True
        time.sleep(0.05)
    return False

a = admin(); ac = a.cursor()
ac.execute("""insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', %s, 'authenticated', 'authenticated', %s, '', now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now())""", (SELLER, f"conc-{TAG}@test.local"))
ac.execute("update public.profiles set state = 'Maharashtra' where id = %s", (SELLER,))

s1 = seller_session(); s2 = seller_session()
c1 = s1.cursor(); c2 = s2.cursor()
pid2 = s2.get_backend_pid(); pid1 = s1.get_backend_pid()
c1.execute("insert into public.clients (name, state, is_gst) values (%s, 'Maharashtra', false) returning id", (f"CONC {TAG}",))
client = c1.fetchone()[0]
c1.execute("insert into public.awb_series (prefix, start_number, digits) values ('CC', 1, 6)")
s1.commit()

def suggest(cur):
    cur.execute("select awb from public.next_awb(%s)", (client,)); return cur.fetchone()[0]

def insert_awb(cur, awb):
    cur.execute("insert into public.shipments (client_id, awb, destination, weight, amount) values (%s, %s, 'MUMBAI', 1, 50)", (client, awb))

# 1. Same suggestion in both sessions, both save: second waits on the unique index, then fails.
a1 = suggest(c1); s1.commit(); a2 = suggest(c2); s2.commit()
check(a1 == a2 == "CC000001", f"both sessions get the same suggestion ({a1}, {a2})")
insert_awb(c1, a1)                                   # s1 holds the uncommitted index entry
t, out = run_bg(lambda: insert_awb(c2, a2))
check(wait_until_blocked(a, pid2), "session 2 really waits on session 1's uncommitted AWB")
s1.commit(); t.join(5)
err = out.get("error")
check(err is not None and getattr(err, "pgcode", None) == "23505", f"session 2 rejected with unique violation ({getattr(err, 'pgcode', None)})")
s2.rollback()
ac.execute("select count(*) from public.shipments where owner_id = %s and awb = %s", (SELLER, a1))
check(ac.fetchone()[0] == 1, "exactly one shipment stored for the contested AWB")

# 2. First session fails (rolls back): the waiting session gets the number — nothing consumed.
a1 = suggest(c1); s1.commit(); a2 = suggest(c2); s2.commit()
check(a1 == a2 == "CC000002", "both sessions get the next suggestion")
insert_awb(c1, a1)
t, out = run_bg(lambda: insert_awb(c2, a2))
check(wait_until_blocked(a, pid2), "session 2 waits while session 1's save is undecided")
s1.rollback(); t.join(5)
check("error" not in out, "session 1's failed save consumed nothing; session 2's save succeeds")
s2.commit()
check(suggest(c1) == "CC000003", "next suggestion moves only past committed saves"); s1.commit()

# 3. Lock race A: manual-charge edit in flight, draft reservation waits, then sees the new amount.
c1.execute("insert into public.shipments (client_id, awb, destination, weight, amount, charge_mode, manual_amount) values (%s, 'CC-R1', 'MUMBAI', 1, 0, 'manual', 100) returning id", (client,))
r1 = c1.fetchone()[0]; s1.commit()
c1.execute("update public.shipments set manual_amount = 140 where id = %s", (r1,))
t, out = run_bg(lambda: c2.execute("select public.create_invoice_draft(%s, current_date - 30, current_date, array[%s]::uuid[])", (client, r1)))
check(wait_until_blocked(a, pid2), "draft reservation waits for the in-flight manual edit")
s1.commit(); t.join(5)
check("error" not in out, f"draft created after the edit commits ({out.get('error')})")
draft = c2.fetchone()[0] if "error" not in out else None
s2.commit()
ac.execute("select amount from public.invoice_lines where invoice_id = %s", (draft,))
check(ac.fetchone()[0] == 140, "draft line uses the committed manual amount (140)")

# 4. Lock race B: draft reservation in flight, manual edit waits, then is refused by the lock.
c2.execute("select public.discard_invoice_draft(%s)", (draft,)); s2.commit()
c2.execute("select public.create_invoice_draft(%s, current_date - 30, current_date, array[%s]::uuid[])", (client, r1))
draft2 = c2.fetchone()[0]                            # uncommitted reservation
t, out = run_bg(lambda: c1.execute("update public.shipments set manual_amount = 999 where id = %s", (r1,)))
check(wait_until_blocked(a, pid1), "manual edit waits for the in-flight draft reservation")
s2.commit(); t.join(5)
err = out.get("error")
check(err is not None and getattr(err, "pgcode", None) == "P0001", f"manual edit refused once the draft commits ({getattr(err, 'pgcode', None)})")
s1.rollback()
ac.execute("select amount, manual_amount from public.shipments where id = %s", (r1,))
check(ac.fetchone() == (140, 140), "reserved shipment kept amount 140")

c2.execute("select public.discard_invoice_draft(%s)", (draft2,)); s2.commit()
s1.close(); s2.close(); a.close()
failed = [l for ok, l in results if not ok]
if failed:
    sys.exit(f"{len(failed)} of {len(results)} concurrency checks FAILED")
print(f"ALL {len(results)} AWB/CHARGE CONCURRENCY CHECKS PASSED (two separate sessions)")
