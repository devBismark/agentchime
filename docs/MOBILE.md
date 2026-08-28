# Mobile notifications

AgentChime v0.1 uses ntfy as the default mobile provider because publishing can be done with a single HTTP request and the phone apps are open source.

## Setup

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile
```

AgentChime generates a random topic similar to:

```text
agentchime-3d3de03e1c3b4e3c9a7e7c785e2554a1
```

Subscribe to the exact topic in the ntfy app, then test:

```powershell
.\agentchime.ps1 test finished
```

## Existing topic

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile -NtfyTopic "your-topic"
```

## Custom/self-hosted ntfy server

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -EnableMobile -NtfyServer "https://ntfy.example.com" -NtfyTopic "agentchime"
```

If the server requires authentication, v0.1 does not yet provide a credential-management UX. Use the roadmap/authenticated-provider work before using AgentChime with protected production infrastructure.

## Privacy rule

Do not put prompts, code, secrets, customer data, or full Claude output into public ntfy payloads. AgentChime v0.1 intentionally avoids those fields.

Official ntfy phone documentation: https://docs.ntfy.sh/subscribe/phone/
