# Privacy

AgentChime's mobile mode forwards a small status message to the configured ntfy server.

## v0.1 payload policy

Allowed by default:

- notification status
- project folder name
- generic state text
- API error category on `StopFailure`

Not sent:

- user prompt
- source code
- environment variables
- secrets
- transcript content
- full assistant output

## Public ntfy topics

A long random topic reduces accidental discovery, but it is not the same thing as authenticated authorization. Do not treat the topic as appropriate protection for sensitive payloads.

If your threat model requires stronger controls:

- disable mobile, or
- use an authenticated/self-hosted ntfy server when AgentChime adds first-class auth support.

AgentChime stores its local configuration at `~/.agentchime/config.json`.
