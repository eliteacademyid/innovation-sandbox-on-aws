# Kiro Enterprise Login Guide

## For CendekiAwan APU Finalist Team Leaders

This guide explains how to sign in to Kiro IDE using your organization's enterprise account (IAM Identity Center).

---

## Prerequisites

- You must be a registered team leader in the CendekiAwan APU Finalist program
- Your email (TPxxxxxx@mail.apu.edu.my) has been added to the Kiro enterprise subscription
- You have set your password via the password reset email

---

## Step 1: Download Kiro

Download Kiro IDE from: **https://kiro.dev/downloads/**

Available for:
- macOS (Apple Silicon / Intel)
- Windows
- Linux

Install and open Kiro.

---

## Step 2: Sign In with Organizational Identity

When Kiro opens for the first time, you'll see a sign-in screen.

1. Click **"Sign in with organizational identity"** (NOT "Sign in with Builder ID" or social login)

   ```
   ┌─────────────────────────────────────────┐
   │                                         │
   │         Welcome to Kiro                 │
   │                                         │
   │  [ Sign in with Builder ID       ]      │
   │  [ Sign in with social login     ]      │
   │                                         │
   │  ──────── OR ────────                   │
   │                                         │
   │  [ Sign in with organizational   ] ← ✅ │
   │  [        identity               ]      │
   │                                         │
   └─────────────────────────────────────────┘
   ```

2. Enter the **Start URL**:
   ```
   https://eliteacademy.awsapps.com/start
   ```

3. Enter the **Region**:
   ```
   ap-southeast-1
   ```

4. Click **"Continue"**

---

## Step 3: Authenticate in Browser

A browser window will open automatically.

1. Sign in with your APU email:
   - **Username:** `TPxxxxxx@mail.apu.edu.my`
   - **Password:** (the password you set from the reset email)

2. You may be asked to **Allow** Kiro to access your account — click **Allow**

3. After successful authentication, you'll see a confirmation page. You can close the browser and return to Kiro.

---

## Step 4: Verify Your Subscription

Once signed in, verify your plan is active:

1. In Kiro, click on your profile icon (bottom-left)
2. You should see:
   - **Plan:** Kiro Pro (1,000 credits/month)
   - **Organization:** Elite Academy

If you see "Free" instead, sign out and sign in again using the organizational identity method.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Start URL not found" | Make sure you entered `https://eliteacademy.awsapps.com/start` exactly |
| "User not found" | Contact your admin — your email may not be registered yet |
| "Invalid password" | Use the password reset link from your email, or ask admin to resend |
| Still on Free plan after sign-in | Sign out completely → close Kiro → reopen → sign in with organizational identity |
| "Subscription pending" | Your subscription is being provisioned — wait a few minutes and restart Kiro |
| Browser doesn't open | Copy the URL shown in Kiro and paste it in your browser manually |

---

## Important Notes

⚠️ **Do NOT sign in with Builder ID or social login** — this will create a separate individual account and you won't get the enterprise subscription.

⚠️ **If you previously had a personal Kiro account**, sign out of it first, then sign in with organizational identity.

⚠️ **Credits are shared** — your Kiro Pro plan gives you 1,000 credits/month. Use them wisely for your competition project.

---

## Quick Reference

| Setting | Value |
|---------|-------|
| Start URL | `https://eliteacademy.awsapps.com/start` |
| Region | `ap-southeast-1` |
| Your username | `TPxxxxxx@mail.apu.edu.my` |
| Plan | Kiro Pro (1,000 credits/month) |
| Organization | Elite Academy |

---

## What Can You Do with Kiro?

With Kiro Pro, you can:
- 🤖 Use AI-powered coding assistance (Claude Sonnet, Auto mode)
- 📋 Create specs for structured development
- 🔧 Use MCP tools for AWS integration
- 💡 Get intelligent code suggestions and completions
- 🏗️ Build your competition project faster

---

## Need Help?

- **Technical issues:** Contact your technical coach (Elitery team)
- **Password reset:** Ask your admin to resend from IAM Identity Center
- **Kiro bugs:** Report at https://github.com/kirodotdev/Kiro/issues
- **Community:** Join https://discord.gg/kirodotdev
