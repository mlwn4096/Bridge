# Download onboarding and one-time email delivery

Mac build 22 and Android version code 13 (both version 1.0) add a download step before pairing.

On a fresh unpaired Mac, Bridge opens a Welcome window automatically. Its QR opens the GitHub Releases page on the phone. The download button opens the same page. Choose the APK under Assets. “Already installed? Connect your phone” advances to the existing pairing screen. The menu-bar panel and main setup page share the same persisted step.

On fresh Android, Bridge first offers the Mac release page and an email option. “Already installed? Pair your Mac” stays at the bottom and advances to the existing scanner/manual pairing flow. Closing/reopening the app does not repeat the download step after it is skipped. Existing paired users bypass this step. Unpairing keeps the installation step completed. A valid pairing intent also bypasses it.

Download URLs use `/releases`, which includes prereleases; GitHub's `/releases/latest` does not. Upload the APK and DMG to a published GitHub Release for these buttons to lead to installers. A draft release is invisible to normal users.

## What works in this build

Direct downloads and the skip-to-pairing flow work without n8n. The email option opens a dialog for the user's email address and then a prewritten Gmail/email-app draft. The user must tap Send. It never claims an automatic email was sent. The address is not saved in Bridge preferences or sent to a backend.

Automatic delivery is prepared in `automation/n8n/bridge-download-email.json`. It requires your own running n8n account, Gmail credential and published form. The current binary has no production form URL because no account exists yet.

Once configured, Android's email button opens n8n's form in the browser. The form asks for the address and automatically sends the fixed message from your connected Gmail account after submission. It accepts other email domains too. No address is put in a URL query; no Gmail password, OAuth token or n8n API key goes in the app. The optional email service uses the cloud; Bridge's device connection stays local.

## Set up n8n Cloud

1. Create an account at [n8n Cloud](https://n8n.io/cloud/) and open your workspace. Cloud is the simplest route because Gmail has managed Google sign-in.
2. Create a workflow. From its menu choose **Import from File**, selecting `automation/n8n/bridge-download-email.json`. [Import instructions](https://docs.n8n.io/workflows/export-import/).
3. Open **Send Bridge download email**, create/select a Gmail credential, and click **Sign in with Google**. Sign into the Gmail account you want the message to come from and authorize it. The recipient does not connect their Gmail. [Managed Google OAuth](https://docs.n8n.io/integrations/builtin/credentials/google/oauth-single-service/).
4. In **Request Mac download**, execute the workflow and open the **Test URL**. Submit your own address; confirm receipt and the correct GitHub release link. The form waits for the workflow result, so a Gmail failure does not show a success message.
5. Save and **Publish** the workflow (older n8n versions call this Activate). Copy the **Production URL**, not the Test URL. [Production forms](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.formtrigger/).
6. Test that production URL in a separate browser. Submitting should send exactly the prepared message. Check Inbox/Spam and the sender account's Sent folder.
7. In this source repo run:

```sh
python3 scripts/configure-download-email.py 'https://YOUR-WORKSPACE.app.n8n.cloud/form/bridge-mac-download'
./scripts/build-android.sh
```

Use the actual copied URL, not the example. Rebuild using the same Android signing key to update existing installations. Send me the **public Production Form URL** after setup and I can configure and rebuild the app here. This URL is public and contains no API key.

To disable automatic delivery later:

```sh
python3 scripts/configure-download-email.py ''
./scripts/build-android.sh
```

## Let the assistant finish setup

The simplest connection is to sign into n8n in Safari and provide your n8n workspace URL. I can use the signed-in browser to import/configure the prepared workflow. You complete Google sign-in yourself. Do not send account passwords or tokens in chat.

For API-based workflow import, create an n8n API key in **Settings → n8n API** with workflow-create access where scopes are available. Configure it only in your own terminal:

```sh
export N8N_BASE_URL='https://YOUR-WORKSPACE.app.n8n.cloud'
read -s 'N8N_API_KEY?Paste your n8n API key locally: '
export N8N_API_KEY
python3 scripts/import-n8n-workflow.py
unset N8N_API_KEY
```

The script imports an inactive workflow; it does not connect Gmail or publish it. You still complete sign-in, test and publish through n8n. API availability depends on your n8n account/plan. [n8n API authentication](https://docs.n8n.io/api/authentication/).

## Deployment and privacy

The workflow sends a fixed download email to one validated address. It has no CC/BCC, user-controlled subject/body, attachment or mailing-list subscription. Successful/error execution storage is disabled in the template; the sender's Gmail Sent folder still retains the message. n8n/provider operational logs may exist. There is no production execution test yet, because no n8n/Gmail account is connected.

The form is public. **Ignore Bots** reduces crawler submissions but is not a CAPTCHA or rate limiter. Watch sender quotas and executions; for larger public traffic add rate limits at your hosting/proxy or a protected form front end. Failed submissions must not be advertised as delivered emails.

## Acceptance checks

- Fresh Mac: Welcome opens, QR resolves to the release page, skip shows the existing pairing QR.
- Fresh Android: download opens Releases; draft flow asks for one email and opens Gmail/email app; cancel sends nothing.
- Both: skip survives a restart; existing paired installations open their usual UI; unpair goes directly to pairing.
- Automatic mode: production form submission sends one prepared message; a failed Gmail send shows an error; the app itself never stores the address.
- Physical Mac/Android pairing still needs a device check after installing these builds. Compilation is not a substitute for that check.

The fixed Mac download QR is bundled as `mac/Resources/AndroidDownloadQR.png`; it is decoded and verified when generated. To change the destination, update `BridgeDownloads.releases`, `DownloadLinks.RELEASES`, the workflow template and `scripts/GenerateDownloadQR.java`, then regenerate using the ZXing core JAR from Android's dependency cache:

```sh
java -Djava.awt.headless=true -cp /path/to/core-3.4.1.jar scripts/GenerateDownloadQR.java mac/Resources/AndroidDownloadQR.png
```

The pairing QR stays dynamic and continues using the existing pairing implementation.
