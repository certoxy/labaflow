"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type OrgOwner = {
  user_id: string;
  email: string;
  full_name: string | null;
  active: boolean;
  membership_created_at: string;
};

type Org = {
  id: string;
  name: string;
  slug: string;
  active: boolean;
  created_at: string;
  inventory_granted: boolean;
  owners: OrgOwner[];
  contact_person: string | null;
  phone: string | null;
  email: string | null;
  address: string | null;
  website: string | null;
};

type Admin = {
  user_id: string;
  email: string;
  full_name: string | null;
  active: boolean;
  granted_at: string;
};

type BootstrapStatus = {
  bootstrap_available: boolean;
  is_platform_admin: boolean;
};

export default function PlatformAdminPage() {
  const [orgs, setOrgs] = useState<Org[]>([]);
  const [admins, setAdmins] = useState<Admin[]>([]);
  const [message, setMessage] = useState("");
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<BootstrapStatus | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadStatus();
  }, []);

  async function loadStatus() {
    setLoading(true);
    setMessage("");
    const { data, error } = await supabase.rpc("get_platform_admin_bootstrap_status");

    if (error) {
      setMessage(error.message);
      setLoading(false);
      return;
    }

    const next = data as BootstrapStatus;
    setStatus(next);
    if (next.is_platform_admin) await loadContext();
    setLoading(false);
  }

  async function loadContext() {
    const { data, error } = await supabase.rpc("get_platform_admin_context");

    if (error) {
      setMessage(error.message);
      return;
    }

    setOrgs(data?.organizations ?? []);
    setAdmins(data?.platform_admins ?? []);
  }

  async function bootstrap() {
    const { error } = await supabase.rpc("bootstrap_first_platform_admin");
    setMessage(error ? error.message : "Platform administrator enabled.");
    if (!error) await loadStatus();
  }

  async function toggle(org: Org) {
    const { error } = await supabase.rpc("set_organization_active", {
      p_organization_id: org.id,
      p_active: !org.active,
    });

    if (error) setMessage(error.message);
    else await loadContext();
  }

  async function toggleInventoryGrant(org: Org) {
    const { error } = await supabase.rpc("set_platform_organization_feature_grant", {
      p_organization_id: org.id,
      p_feature_key: "inventory",
      p_granted: !org.inventory_granted,
    });

    if (error) {
      setMessage(error.message);
    } else {
      setMessage(`Product & Inventory ${org.inventory_granted ? "revoked from" : "granted to"} ${org.name}.`);
      await loadContext();
    }
  }

  async function support(org: Org) {
    if (!confirm(`Enter read-only Support Mode for ${org.name}? The session expires after 30 minutes and all page access is audited.`)) return;

    const { error } = await supabase.rpc("start_platform_support_session", {
      p_organization_id: org.id,
    });

    if (error) setMessage(error.message);
    else location.href = "/dashboard";
  }

  async function grant() {
    const { error } = await supabase.rpc("grant_platform_admin", { p_email: email });
    setMessage(error ? error.message : "Platform administrator added.");

    if (!error) {
      setEmail("");
      await loadContext();
    }
  }

  if (loading) {
    return (
      <main className="center">
        <div className="loader">Loading platform administration…</div>
      </main>
    );
  }

  if (status?.bootstrap_available && !status.is_platform_admin) {
    return (
      <main className="center">
        <section className="onboardCard">
          <p className="eyebrow">PLATFORM SETUP</p>
          <h1>Enable the first platform administrator</h1>
          <p className="muted">Only use this on the initial trusted administrator account.</p>
          <button className="primary" onClick={bootstrap}>Enable Platform Admin</button>
          {message && <p className="notice">{message}</p>}
        </section>
      </main>
    );
  }

  if (!status?.is_platform_admin) {
    return (
      <main className="center">
        <section className="onboardCard">
          <p className="eyebrow">ACCESS DENIED</p>
          <h1>Platform administrator access required</h1>
          {message && <p className="notice">{message}</p>}
        </section>
      </main>
    );
  }

  return (
    <main className="workspace">
      <div className="panelHead">
        <div>
          <p className="eyebrow">PLATFORM ADMINISTRATION</p>
          <h1>LabaFlow Tenants</h1>
        </div>
        <div className="headerActions">
          <button className="primary" onClick={() => { location.href = "/admin/subscriptions"; }}>
            Subscription Monitor
          </button>
        </div>
      </div>

      {message && <p className="notice">{message}</p>}

      <div className="adminToolbar">
        <div className="scanBar">
          <input
            placeholder="Existing LabaFlow user email"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
          />
          <button className="primary" onClick={grant}>Add Platform Admin</button>
        </div>
      </div>

      <section className="panel">
        <h2>Organizations</h2>
        {orgs.map((org) => (
          <div className="adminRow" key={org.id}>
            <div>
              <strong>{org.name}</strong>
              <small>{org.slug}</small>
              <div className="orgContactDetails">
                <div>
                  <span>Organization owner</span>
                  {(org.owners ?? []).length > 0 ? (
                    org.owners.map((owner) => (
                      <div className="orgOwnerEntry" key={owner.user_id}>
                        <b>{owner.full_name || "Name not provided"}</b>
                        <a href={`mailto:${owner.email}`}>{owner.email}</a>
                        <small>{owner.active ? "Active account" : "Inactive account"}</small>
                      </div>
                    ))
                  ) : (
                    <b>Not assigned</b>
                  )}
                </div>
                <div>
                  <span>Business contact</span>
                  <b>{org.contact_person || "Not provided"}</b>
                  <a href={org.phone ? `tel:${org.phone}` : undefined}>
                    {org.phone || "Phone not provided"}
                  </a>
                  <a href={org.email ? `mailto:${org.email}` : undefined}>
                    {org.email || "Email not provided"}
                  </a>
                </div>
                <div>
                  <span>Address & website</span>
                  <b>{org.address || "Address not provided"}</b>
                  {org.website ? (
                    <a href={org.website} target="_blank" rel="noreferrer">{org.website}</a>
                  ) : (
                    <small>Website not provided</small>
                  )}
                </div>
              </div>
            </div>
            <button className="miniBtn" disabled={!org.active} onClick={() => support(org)}>Support Mode</button>
            <span className={org.inventory_granted ? "status active" : "status inactive"}>
              Product &amp; Inventory: {org.inventory_granted ? "Granted" : "Not granted"}
            </span>
            <button className="miniBtn" onClick={() => toggleInventoryGrant(org)}>
              {org.inventory_granted ? "Revoke Feature" : "Grant Feature"}
            </button>
            <span className={org.active ? "status active" : "status inactive"}>
              {org.active ? "Active" : "Suspended"}
            </span>
            <button className="miniBtn" onClick={() => toggle(org)}>
              {org.active ? "Suspend" : "Activate"}
            </button>
          </div>
        ))}
      </section>

      <section className="panel">
        <h2>Platform Administrators</h2>
        {admins.map((admin) => (
          <div className="adminRow" key={admin.user_id}>
            <div>
              <strong>{admin.full_name || admin.email}</strong>
              <small>{admin.email}</small>
            </div>
            <span className={admin.active ? "status active" : "status inactive"}>
              {admin.active ? "Active" : "Inactive"}
            </span>
          </div>
        ))}
      </section>
    </main>
  );
}
