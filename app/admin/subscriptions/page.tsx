"use client";

import { useEffect, useMemo, useState } from "react";
import { supabase } from "../../../lib/supabase";

type Plan = {
  plan_key: string;
  display_name: string;
  monthly_price: number | null;
  branch_limit: number | null;
  staff_limit: number | null;
  transaction_limit: number | null;
  customer_limit: number | null;
  capabilities: Record<string, boolean | string>;
  active: boolean;
  sort_order: number;
};
type Payment = {
  id: string;
  organization_id: string;
  plan_key: string;
  billing_cycle: string;
  product_inventory_addon: boolean;
  amount: number;
  checkout_url: string | null;
  status: string;
  paid_at: string | null;
  created_at: string;
};
type SubscriptionOrg = {
  id: string;
  name: string;
  slug: string;
  active: boolean;
  created_at: string;
  trial_started_at: string;
  trial_ends_at: string;
  trial_days_remaining: number;
  in_trial: boolean;
  status: string;
  billing_started_at: string | null;
  next_billing_at: string | null;
  notes: string | null;
  plan_key: string;
  plan_name: string;
  plan_monthly_price: number | null;
  custom_monthly_price: number | null;
  discount_percent: number;
  promo_code: string | null;
  referral_name: string | null;
  referral_email: string | null;
  base_monthly_price: number;
  net_monthly_price: number;
  branch_limit: number | null;
  staff_limit: number | null;
  transaction_limit: number | null;
  customer_limit: number | null;
  branches_used: number;
  staff_used: number;
  transactions_used: number;
  customers_used: number;
  capabilities: Record<string, boolean | string>;
  feature_grants: Record<string, boolean>;
  latest_payment?: Payment;
};
type Context = {
  summary: {
    organizations: number;
    trialing: number;
    billable: number;
    past_due: number;
    estimated_mrr: number;
  };
  plans: Plan[];
  organizations: SubscriptionOrg[];
};

type Draft = {
  status: string;
  plan_key: string;
  custom_monthly_price: string;
  discount_percent: string;
  promo_code: string;
  referral_name: string;
  referral_email: string;
  trial_ends_at: string;
  next_billing_at: string;
  notes: string;
};
type LinkDraft = {
  billing_cycle: "monthly" | "yearly";
  product_inventory_addon: boolean;
  billing_contact: string;
  billing_email: string;
};

const money = new Intl.NumberFormat("en-PH", {
  style: "currency",
  currency: "PHP",
  maximumFractionDigits: 2,
});
const statusLabel = (s: string) =>
  s.replaceAll("_", " ").replace(/\b\w/g, (c) => c.toUpperCase());
const limit = (n: number | null) =>
  n == null ? "Unlimited" : n.toLocaleString();
const usage = (used: number, max: number | null) =>
  max == null
    ? `${used.toLocaleString()} / Unlimited`
    : `${used.toLocaleString()} / ${max.toLocaleString()}`;
const featureKeys = [
  "customer_loyalty",
  "pickup_delivery",
  "inventory",
  "expenses",
  "order_workflow",
  "qr_customer_id",
];
const featureLabel = (key: string) =>
  key === "inventory" ? "Product & Inventory" : statusLabel(key);
function paymentState(o: SubscriptionOrg) {
  if (o.in_trial)
    return { key: "trial", label: `Trial · ${o.trial_days_remaining}d left` };
  if (
    o.latest_payment?.status === "awaiting_payment" ||
    o.latest_payment?.status === "creating"
  )
    return { key: "pending", label: "Payment Pending" };
  if (o.status === "cancelled" || o.status === "suspended")
    return { key: "overdue", label: statusLabel(o.status) };
  const due = o.next_billing_at ? new Date(o.next_billing_at).getTime() : 0,
    days = due ? Math.ceil((due - Date.now()) / 86400000) : null;
  if (o.status === "past_due" || (days !== null && days < 0))
    return { key: "overdue", label: "Past Due" };
  if (o.status === "active" && days !== null && days <= 7)
    return { key: "due", label: `Due in ${Math.max(0, days)}d` };
  if (o.status === "active" && days !== null)
    return { key: "paid", label: "Up to Date" };
  return { key: "neutral", label: statusLabel(o.status) };
}
function Toggle({
  checked,
  onChange,
  label,
}: {
  checked: boolean;
  onChange: () => void;
  label: string;
}) {
  return (
    <label className="toggleControl">
      <input
        type="checkbox"
        checked={checked}
        onChange={onChange}
        aria-label={label}
      />
      <span className="toggleTrack" />
      <span className="toggleLabel">{checked ? "On" : "Off"}</span>
    </label>
  );
}

export default function PlatformSubscriptionsPage() {
  const [data, setData] = useState<Context | null>(null),
    [message, setMessage] = useState(""),
    [loading, setLoading] = useState(true),
    [search, setSearch] = useState("");
  const [editing, setEditing] = useState<string | null>(null),
    [busy, setBusy] = useState(false),
    [linkDraft, setLinkDraft] = useState<LinkDraft>({
      billing_cycle: "monthly",
      product_inventory_addon: false,
      billing_contact: "",
      billing_email: "",
    }),
    [draft, setDraft] = useState<Draft>({
      status: "trialing",
      plan_key: "starter",
      custom_monthly_price: "",
      discount_percent: "0",
      promo_code: "",
      referral_name: "",
      referral_email: "",
      trial_ends_at: "",
      next_billing_at: "",
      notes: "",
    });
  useEffect(() => {
    load();
  }, []);
  async function load() {
    setLoading(true);
    const [
      { data: d, error },
      { data: admin, error: adminError },
      { data: payments, error: paymentError },
    ] = await Promise.all([
      supabase.rpc("get_platform_subscription_context"),
      supabase.rpc("get_platform_admin_context"),
      supabase
        .from("subscription_payment_transactions")
        .select(
          "id,organization_id,plan_key,billing_cycle,product_inventory_addon,amount,checkout_url,status,paid_at,created_at",
        )
        .order("created_at", { ascending: false }),
    ]);
    if (error || adminError || paymentError) {
      setMessage(
        error?.message || adminError?.message || paymentError?.message || "",
      );
      setLoading(false);
      return;
    }
    const grants = new Map(
        (admin?.organizations ?? []).map((o: any) => [
          o.id,
          o.feature_grants ?? {},
        ]),
      ),
      latest = new Map<string, Payment>();
    for (const p of payments ?? [])
      if (!latest.has(p.organization_id))
        latest.set(p.organization_id, p as Payment);
    setData({
      ...d,
      organizations: (d?.organizations ?? []).map((o: SubscriptionOrg) => ({
        ...o,
        feature_grants: grants.get(o.id) ?? {},
        latest_payment: latest.get(o.id),
      })),
    } as Context);
    setLoading(false);
  }
  function editOrg(o: SubscriptionOrg) {
    setEditing(o.id);
    setLinkDraft({
      billing_cycle: "monthly",
      product_inventory_addon: o.feature_grants.inventory === true,
      billing_contact: "",
      billing_email: "",
    });
    setDraft({
      status: o.status,
      plan_key: o.plan_key,
      custom_monthly_price:
        o.custom_monthly_price == null ? "" : String(o.custom_monthly_price),
      discount_percent: String(o.discount_percent ?? 0),
      promo_code: o.promo_code ?? "",
      referral_name: o.referral_name ?? "",
      referral_email: o.referral_email ?? "",
      trial_ends_at: o.trial_ends_at ? o.trial_ends_at.slice(0, 10) : "",
      next_billing_at: o.next_billing_at ? o.next_billing_at.slice(0, 10) : "",
      notes: o.notes ?? "",
    });
  }
  async function copyLink(url: string) {
    try {
      await navigator.clipboard.writeText(url);
      setMessage("Payment link copied.");
    } catch {
      setMessage(
        "Unable to copy automatically. Open the link and copy it from the address bar.",
      );
    }
  }
  async function generateLink(o: SubscriptionOrg) {
    setBusy(true);
    setMessage("");
    const { data: session } = await supabase.auth.getSession();
    const token = session.session?.access_token;
    if (!token) {
      setBusy(false);
      setMessage("Please sign in again.");
      return;
    }
    try {
      const response = await fetch("/api/subscriptions/paymongo/checkout", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          organization_id: o.id,
          plan_key: draft.plan_key,
          billing_cycle: linkDraft.billing_cycle,
          product_inventory_addon: linkDraft.product_inventory_addon,
          billing_contact: linkDraft.billing_contact || null,
          billing_email: linkDraft.billing_email || null,
          notes: `Platform Admin payment link for ${o.name}`,
        }),
      });
      const result = await response.json();
      if (!response.ok)
        throw new Error(result.error || "Unable to generate payment link");
      await copyLink(result.checkout_url);
      setMessage(
        result.reused
          ? `Existing payment link copied for ${o.name}.`
          : `New payment link created and copied for ${o.name}.`,
      );
      await load();
    } catch (error) {
      setMessage(
        error instanceof Error
          ? error.message
          : "Unable to generate payment link",
      );
    } finally {
      setBusy(false);
    }
  }
  async function saveOrg(o: SubscriptionOrg) {
    const discount = Number(draft.discount_percent || 0),
      custom =
        draft.custom_monthly_price === ""
          ? null
          : Number(draft.custom_monthly_price);
    if (Number.isNaN(discount) || discount < 0 || discount > 100) {
      setMessage("Discount must be between 0 and 100%.");
      return;
    }
    if (custom !== null && (Number.isNaN(custom) || custom < 0)) {
      setMessage("Custom monthly price must be zero or greater.");
      return;
    }
    const trial = draft.trial_ends_at
      ? new Date(`${draft.trial_ends_at}T23:59:59`).toISOString()
      : null;
    const next = draft.next_billing_at
      ? new Date(`${draft.next_billing_at}T09:00:00`).toISOString()
      : null;
    const { error } = await supabase.rpc("set_organization_subscription", {
      p_organization_id: o.id,
      p_status: draft.status,
      p_trial_ends_at: trial,
      p_next_billing_at: next,
      p_notes: draft.notes || null,
      p_plan_key: draft.plan_key,
      p_custom_monthly_price: custom,
      p_discount_percent: discount,
      p_promo_code: draft.promo_code || null,
      p_referral_name: draft.referral_name || null,
      p_referral_email: draft.referral_email || null,
    });
    setMessage(error ? error.message : `${o.name} subscription updated.`);
    if (!error) {
      setEditing(null);
      await load();
    }
  }
  async function toggleFeatureGrant(o: SubscriptionOrg, key: string) {
    const current = o.feature_grants[key] ?? key !== "inventory";
    const { error } = await supabase.rpc(
      "set_platform_organization_feature_grant",
      { p_organization_id: o.id, p_feature_key: key, p_granted: !current },
    );
    setMessage(
      error
        ? error.message
        : `${featureLabel(key)} turned ${current ? "off" : "on"} for ${o.name}.`,
    );
    if (!error) await load();
  }
  const rows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (data?.organizations ?? []).filter(
      (o) =>
        !q ||
        o.name.toLowerCase().includes(q) ||
        o.slug.toLowerCase().includes(q) ||
        o.status.toLowerCase().includes(q) ||
        o.plan_name.toLowerCase().includes(q) ||
        (o.promo_code ?? "").toLowerCase().includes(q) ||
        (o.referral_name ?? "").toLowerCase().includes(q),
    );
  }, [data, search]);
  if (loading)
    return (
      <main className="workspace">
        <p className="eyebrow">PLATFORM ADMINISTRATION</p>
        <h1>Organization Subscriptions</h1>
        <p className="muted">Loading subscription data…</p>
      </main>
    );
  if (!data)
    return (
      <main className="workspace">
        <p className="eyebrow">PLATFORM ADMINISTRATION</p>
        <h1>Organization Subscriptions</h1>
        {message && <p className="notice">{message}</p>}
      </main>
    );
  return (
    <main className="workspace subscriptionAdminPage">
      <div className="panelHead">
        <div>
          <p className="eyebrow">PLATFORM ADMINISTRATION</p>
          <h1>Organization Subscriptions</h1>
          <p className="muted">
            30-day free trials with Starter, Business, Pro, and Enterprise
            plans.
          </p>
        </div>
        <div className="headerActions">
          <button
            className="secondary"
            onClick={() => (location.href = "/admin")}
          >
            Back to Tenants
          </button>
        </div>
      </div>
      {message && <p className="notice">{message}</p>}
      <section className="stats subscriptionStats">
        <article>
          <small>ORGANIZATIONS</small>
          <strong>{data.summary.organizations}</strong>
          <span>Total tenants</span>
        </article>
        <article>
          <small>FREE TRIAL</small>
          <strong>{data.summary.trialing}</strong>
          <span>Within 30 days</span>
        </article>
        <article>
          <small>BILLABLE</small>
          <strong>{data.summary.billable}</strong>
          <span>Trial ended</span>
        </article>
        <article>
          <small>EST. MRR</small>
          <strong>
            {money.format(Number(data.summary.estimated_mrr || 0))}
          </strong>
          <span>After discounts</span>
        </article>
      </section>

      <section className="panel">
        <div className="panelHead">
          <div>
            <h2>Subscription Plans</h2>
            <p className="muted">
              Business features are available during the 30-day trial. Plan
              limits are monitored here and can later be enforced in-app.
            </p>
          </div>
        </div>
        <div className="subscriptionPlanGrid">
          {data.plans.map((p) => (
            <article className="subscriptionPlanCard" key={p.plan_key}>
              <div>
                <small>{p.plan_key.toUpperCase()}</small>
                <h3>{p.display_name}</h3>
                <strong>
                  {p.monthly_price == null
                    ? "Custom"
                    : `${money.format(Number(p.monthly_price))}/mo`}
                </strong>
              </div>
              <div className="subscriptionPlanLimits">
                <span>
                  Branches <b>{limit(p.branch_limit)}</b>
                </span>
                <span>
                  Staff <b>{limit(p.staff_limit)}</b>
                </span>
                <span>
                  Transactions/mo <b>{limit(p.transaction_limit)}</b>
                </span>
                <span>
                  Customers <b>{limit(p.customer_limit)}</b>
                </span>
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="panel">
        <div className="panelHead">
          <div>
            <h2>Organization Subscription Monitor</h2>
            <p className="muted">
              Manage plan, trial, discount, promo attribution, referral source,
              and billing status for each organization.
            </p>
          </div>
          <div className="scanBar">
            <input
              placeholder="Search org, plan, promo, referral"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
        </div>
        <div className="subscriptionOrgList">
          {rows.map((o) => {
            const open = editing === o.id,
              payment = paymentState(o);
            return (
              <article
                className={`subscriptionOrgCard ${open ? "editing" : ""}`}
                key={o.id}
              >
                <div className="subscriptionOrgHead">
                  <div>
                    <strong>{o.name}</strong>
                    <small>
                      {o.slug} · {o.plan_name} · created{" "}
                      {new Date(o.created_at).toLocaleDateString()}
                    </small>
                  </div>
                  <span className={`paymentStatus ${payment.key}`}>
                    {payment.label}
                  </span>
                  <div className="subscriptionAmount">
                    <small>MONTHLY</small>
                    <b>
                      {o.in_trial
                        ? "Free trial"
                        : money.format(Number(o.net_monthly_price || 0))}
                    </b>
                    {!o.in_trial && Number(o.discount_percent) > 0 && (
                      <small>{o.discount_percent}% discount</small>
                    )}
                  </div>
                  <button
                    className="miniBtn"
                    onClick={() => (open ? setEditing(null) : editOrg(o))}
                  >
                    {open ? "Close" : "Manage"}
                  </button>
                </div>
                <div className="subscriptionMeta">
                  <span>
                    <b>Trial:</b>{" "}
                    {new Date(o.trial_started_at).toLocaleDateString()} –{" "}
                    {new Date(o.trial_ends_at).toLocaleDateString()}
                  </span>
                  <span>
                    <b>Plan:</b> {o.plan_name}
                  </span>
                  {o.promo_code && (
                    <span>
                      <b>Promo:</b> {o.promo_code}
                    </span>
                  )}
                  {o.referral_name && (
                    <span>
                      <b>Referral:</b> {o.referral_name}
                      {o.referral_email ? ` · ${o.referral_email}` : ""}
                    </span>
                  )}
                  {o.next_billing_at && (
                    <span>
                      <b>Next billing:</b>{" "}
                      {new Date(o.next_billing_at).toLocaleDateString()}
                    </span>
                  )}
                </div>
                <div className="subscriptionUsageGrid">
                  <span>
                    <small>BRANCHES</small>
                    <b>{usage(Number(o.branches_used || 0), o.branch_limit)}</b>
                  </span>
                  <span>
                    <small>STAFF</small>
                    <b>{usage(Number(o.staff_used || 0), o.staff_limit)}</b>
                  </span>
                  <span>
                    <small>TRANSACTIONS THIS MONTH</small>
                    <b>
                      {usage(
                        Number(o.transactions_used || 0),
                        o.transaction_limit,
                      )}
                    </b>
                  </span>
                  <span>
                    <small>CUSTOMERS</small>
                    <b>
                      {usage(Number(o.customers_used || 0), o.customer_limit)}
                    </b>
                  </span>
                </div>
                {open && (
                  <div className="subscriptionEditor">
                    <section className="panel paymentLinkPanel">
                      <div>
                        <h3>Organization Payment Link</h3>
                        <p className="muted">
                          Create one secure PayMongo checkout for this
                          organization. An existing unpaid link is reused.
                        </p>
                      </div>
                      {o.latest_payment?.status === "awaiting_payment" &&
                        o.latest_payment.checkout_url && (
                          <div className="existingPaymentLink">
                            <span>
                              <b>Payment pending</b>
                              <small>
                                {money.format(Number(o.latest_payment.amount))} ·
                                created {" "}
                                {new Date(
                                  o.latest_payment.created_at,
                                ).toLocaleString("en-PH")}
                              </small>
                            </span>
                            <button
                              className="secondary"
                              onClick={() =>
                                copyLink(o.latest_payment!.checkout_url!)
                              }
                            >
                              Copy Link
                            </button>
                            <button
                              className="secondary"
                              onClick={() =>
                                window.open(
                                  o.latest_payment!.checkout_url!,
                                  "_blank",
                                  "noopener,noreferrer",
                                )
                              }
                            >
                              Open
                            </button>
                          </div>
                        )}
                      <div className="gridForm paymentLinkFields">
                        <label>
                          Billing cycle
                          <select
                            value={linkDraft.billing_cycle}
                            onChange={(e) =>
                              setLinkDraft({
                                ...linkDraft,
                                billing_cycle: e.target.value as
                                  | "monthly"
                                  | "yearly",
                              })
                            }
                          >
                            <option value="monthly">Monthly</option>
                            <option value="yearly">
                              Yearly · 10% discount
                            </option>
                          </select>
                        </label>
                        <label>
                          Billing contact
                          <input
                            value={linkDraft.billing_contact}
                            onChange={(e) =>
                              setLinkDraft({
                                ...linkDraft,
                                billing_contact: e.target.value,
                              })
                            }
                            placeholder="Optional contact name"
                          />
                        </label>
                        <label>
                          Billing email
                          <input
                            type="email"
                            value={linkDraft.billing_email}
                            onChange={(e) =>
                              setLinkDraft({
                                ...linkDraft,
                                billing_email: e.target.value,
                              })
                            }
                            placeholder="Optional receipt email"
                          />
                        </label>
                        <label className="paymentAddon">
                          <input
                            type="checkbox"
                            checked={linkDraft.product_inventory_addon}
                            onChange={(e) =>
                              setLinkDraft({
                                ...linkDraft,
                                product_inventory_addon: e.target.checked,
                              })
                            }
                          />
                          Product &amp; Inventory add-on
                        </label>
                      </div>
                      <div className="branchEditActions">
                        <button
                          className="primary"
                          disabled={
                            busy ||
                            o.latest_payment?.status === "awaiting_payment"
                          }
                          onClick={() => generateLink(o)}
                        >
                          {busy
                            ? "Generating…"
                            : o.latest_payment?.status === "awaiting_payment"
                              ? "Payment Link Pending"
                              : "Generate & Copy Link"}
                        </button>
                      </div>
                    </section>
                    <section className="panel platformFeatureControls">
                      <div>
                        <h3>Feature Controls</h3>
                        <p className="muted">
                          Control the modules available to this organization.
                        </p>
                      </div>
                      <div className="featureList">
                        {featureKeys.map((key) => {
                          const checked =
                            o.feature_grants[key] ?? key !== "inventory";
                          return (
                            <div key={key}>
                              <span>{featureLabel(key)}</span>
                              <Toggle
                                checked={checked}
                                onChange={() => toggleFeatureGrant(o, key)}
                                label={featureLabel(key)}
                              />
                            </div>
                          );
                        })}
                      </div>
                    </section>
                    <div className="gridForm">
                      <label>
                        Plan
                        <select
                          value={draft.plan_key}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              plan_key: e.target.value,
                              custom_monthly_price:
                                e.target.value === "enterprise"
                                  ? draft.custom_monthly_price
                                  : "",
                            })
                          }
                        >
                          {data.plans.map((p) => (
                            <option key={p.plan_key} value={p.plan_key}>
                              {p.display_name}
                              {p.monthly_price == null
                                ? " — Custom"
                                : ` — ${money.format(Number(p.monthly_price))}/mo`}
                            </option>
                          ))}
                        </select>
                      </label>
                      <label>
                        Status
                        <select
                          value={draft.status}
                          onChange={(e) =>
                            setDraft({ ...draft, status: e.target.value })
                          }
                        >
                          <option value="trialing">Trialing</option>
                          <option value="active">Active</option>
                          <option value="past_due">Past Due</option>
                          <option value="suspended">Suspended</option>
                          <option value="cancelled">Cancelled</option>
                        </select>
                      </label>
                      <label>
                        Custom monthly price
                        <input
                          type="number"
                          min="0"
                          step="1"
                          value={draft.custom_monthly_price}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              custom_monthly_price: e.target.value,
                            })
                          }
                          placeholder={
                            draft.plan_key === "enterprise"
                              ? "Required for Enterprise"
                              : "Optional override"
                          }
                        />
                      </label>
                      <label>
                        Discount %
                        <input
                          type="number"
                          min="0"
                          max="100"
                          step="0.01"
                          value={draft.discount_percent}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              discount_percent: e.target.value,
                            })
                          }
                        />
                      </label>
                      <label>
                        Promo code
                        <input
                          value={draft.promo_code}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              promo_code: e.target.value.toUpperCase(),
                            })
                          }
                          placeholder="e.g. LAUNCH20"
                        />
                      </label>
                      <label>
                        Referral name
                        <input
                          value={draft.referral_name}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              referral_name: e.target.value,
                            })
                          }
                          placeholder="Person or business"
                        />
                      </label>
                      <label>
                        Referral email
                        <input
                          type="email"
                          value={draft.referral_email}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              referral_email: e.target.value,
                            })
                          }
                          placeholder="name@example.com"
                        />
                      </label>
                      <label>
                        Trial ends
                        <input
                          type="date"
                          value={draft.trial_ends_at}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              trial_ends_at: e.target.value,
                            })
                          }
                        />
                      </label>
                      <label>
                        Next billing
                        <input
                          type="date"
                          value={draft.next_billing_at}
                          onChange={(e) =>
                            setDraft({
                              ...draft,
                              next_billing_at: e.target.value,
                            })
                          }
                        />
                      </label>
                      <label>
                        Notes
                        <input
                          value={draft.notes}
                          onChange={(e) =>
                            setDraft({ ...draft, notes: e.target.value })
                          }
                          placeholder="Optional billing note"
                        />
                      </label>
                    </div>
                    <div className="branchEditActions">
                      <button
                        className="secondary"
                        onClick={() => setEditing(null)}
                      >
                        Cancel
                      </button>
                      <button className="primary" onClick={() => saveOrg(o)}>
                        Save Subscription
                      </button>
                    </div>
                  </div>
                )}
              </article>
            );
          })}
          {rows.length === 0 && (
            <p className="muted">No organizations match your search.</p>
          )}
        </div>
      </section>
    </main>
  );
}
