#!/usr/bin/env python3
"""
Post-deployment configuration for ISB migration to ap-southeast-1.
1. Update IdP certificate in Secrets Manager
2. Deploy AppConfig with new SAML URLs and settings
3. Deploy nuke config
"""
import boto3, time

HUB_PROFILE  = "eta-isb-andrian"
HUB_REGION   = "ap-southeast-1"
APP_ID       = "wcolo49"
ENV_ID       = "1oi8hnh"
GLOBAL_PROFILE_ID = "dt315tf"
NUKE_PROFILE_ID   = "8mewn28"
IDP_CERT_ARN = "arn:aws:secretsmanager:ap-southeast-1:147826551593:secret:/InnovationSandbox/myisb/Auth/IdpCert-U1GDDt"

session = boto3.Session(profile_name=HUB_PROFILE, region_name=HUB_REGION)
sm      = session.client("secretsmanager")
appconf = session.client("appconfig")

# ── 1. Update IdP Certificate ─────────────────────────────────────────────────
print("1. Updating IdP certificate...")
with open("backup/idp-cert-new.pem") as f:
    cert = f.read().strip()

sm.put_secret_value(SecretId=IDP_CERT_ARN, SecretString=cert)
print("  ✅ IdP certificate updated")

# ── 2. Deploy Global Config ───────────────────────────────────────────────────
print("\n2. Deploying global AppConfig...")
global_config = """# Flag to enable maintenance mode
maintenanceMode: false

# Terms of Service
termsOfService: |
  Users, who use a leased AWS account for their sandbox experiments, should NOT,

  * Attempt to access data that they are not authorized to use or access.
  * Use content for a sandbox use case that has not been approved by an admin.
  * Perform any unauthorized changes or store unapproved company data within the leased AWS account.
  * Provide static passwords, such as default or actual passwords.
  * Change or modify quotas/limits out of band for accounts.
  * Transfer data or software to any person or organization not authorized to use the leased AWS account.
  * Use any material or information from the leased AWS accounts, including images, logos, or photographs in any manner that violates copyright, trademark, or intellectual property laws.

# global controls on leases
leases:
  requireMaxBudget: true
  maxBudget: 1000
  requireMaxDuration: true
  maxDurationHours: 720
  maxLeasesPerUser: 10
  ttl: 30

# Account Cleanup controls
cleanup:
  numberOfFailedAttemptsToCancelCleanup: 3
  waitBeforeRetryFailedAttemptSeconds: 5
  numberOfSuccessfulAttemptsToFinishCleanup: 2
  waitBeforeRerunSuccessfulAttemptSeconds: 30

# Authentication Configuration
auth:
  idpSignInUrl: "https://portal.sso.ap-southeast-1.amazonaws.com/saml/assertion/ODYyMDk5Nzk0MTgwX2lucy04MjEwMmRmY2QxNjM5ZjVm"
  idpSignOutUrl: "https://portal.sso.ap-southeast-1.amazonaws.com/saml/logout/ODYyMDk5Nzk0MTgwX2lucy04MjEwMmRmY2QxNjM5ZjVm"
  idpAudience: "Isb-myisb-Audience"
  webAppUrl: "https://aws-sandbox.eliteacademy.id"
  awsAccessPortalUrl: "https://d-9667a833b5.awsapps.com/start"
  sessionDurationInMinutes: 60

# Email Notification controls
notification:
  emailFrom: "helpdesk@eliteacademy.id"
"""

appconf.create_hosted_configuration_version(
    ApplicationId=APP_ID,
    ConfigurationProfileId=GLOBAL_PROFILE_ID,
    ContentType="application/x-yaml",
    Content=global_config.encode(),
    Description="Initial config: SAML, lease limits, email"
)

# Wait for any in-progress deployment to finish
print("  Waiting for environment to be ready...")
for _ in range(12):
    env = appconf.get_environment(ApplicationId=APP_ID, EnvironmentId=ENV_ID)
    if env["State"] == "READY_FOR_DEPLOYMENT":
        break
    time.sleep(10)

appconf.start_deployment(
    ApplicationId=APP_ID,
    EnvironmentId=ENV_ID,
    ConfigurationProfileId=GLOBAL_PROFILE_ID,
    ConfigurationVersion="2",
    DeploymentStrategyId="AppConfig.AllAtOnce",
    Description="Deploy global config"
)
print("  ✅ Global config deployed")

# ── 3. Deploy Nuke Config ─────────────────────────────────────────────────────
print("\n3. Deploying nuke config...")
with open("nuke-config-updated.yaml") as f:
    nuke_config = f.read()

appconf.create_hosted_configuration_version(
    ApplicationId=APP_ID,
    ConfigurationProfileId=NUKE_PROFILE_ID,
    ContentType="application/x-yaml",
    Content=nuke_config.encode(),
    Description="Nuke config with trail-yow filter"
)

appconf.start_deployment(
    ApplicationId=APP_ID,
    EnvironmentId=ENV_ID,
    ConfigurationProfileId=NUKE_PROFILE_ID,
    ConfigurationVersion="2",
    DeploymentStrategyId="AppConfig.AllAtOnce",
    Description="Deploy nuke config"
)
print("  ✅ Nuke config deployed")

print("\n✅ Post-deployment configuration complete!")
print("\nNext steps:")
print("  1. Update DNS in Cloudflare: aws-sandbox CNAME → dd3kj1ggdvsy3.cloudfront.net")
print("  2. Test login at https://aws-sandbox.eliteacademy.id")
print("  3. Move 100 accounts to Entry OU and register in ISB")
