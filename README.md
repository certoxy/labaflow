# LabaFlow

LabaFlow is a multi-tenant laundry business management application for Philippine laundry shops and similar service businesses.

## Initial scope

- Supabase authentication
- Organizations and branches
- Staff roles and branch assignments
- Organization-level feature settings
- Customer profiles with unique customer IDs
- Secure customer QR identity
- Loyalty points and transaction history
- Laundry services and pricing
- Laundry order workflow
- Payments and receipts
- Inventory, expenses, reporting, and pickup/delivery in later phases

## Technology

- React 19 + TypeScript
- Vinext/Vite
- Supabase Postgres, Authentication, Row-Level Security, and RPC functions

## Local setup

1. Copy `.env.example` to `.env.local`.
2. Add the LabaFlow Supabase project URL and publishable key.
3. Install dependencies with `npm install`.
4. Run database migrations in numeric order.
5. Start the app with `npm run dev`.

Never commit `.env.local`, database passwords, service-role keys, or other secrets.

## Status

Version 0.1 foundation is being established with multi-tenant isolation from the first migration.
