# Privacy

AgentChime's mobile mode forwards a small status message to the configured ntfy server.

## v0.1 payload policy

Allowed by default:

- notification status
- project folder name
- generic state text
- API error category on `StopFailure`
- elapsed turn time

The `detailLevel` setting can narrow that list further; it can never widen it.

Not sent:

- user prompt
- source code
- environment variables
- secrets
- transcript content
- full assistant output
- session or prompt identifiers

## Elapsed turn time

AgentChime measures how long a turn took, from the moment you submit a prompt
to the moment Claude stops. It appends that figure to the notification body,
for example `my-project - Claude finished the task. (18m 42s)`.

This is telemetry about your working pace, so decide deliberately where it goes:

| Destination | Carries elapsed time | Controlled by |
| --- | --- | --- |
| Windows desktop notification | yes | `privacy.sendDuration` |
| ntfy mobile push | yes | `privacy.sendDuration` |

There is no separate switch per destination. Set `privacy.sendDuration` to
`false` in `~/.agentchime/config.json`, or install with `-DisableDuration`, and
notifications go back to exactly the v0.1 wording. Nothing is measured or
stored while it is off.

### What the measurement stores

To measure a turn, AgentChime writes one small record per session under
`~/.agentchime/turns/`. That record holds a clock reading and two one-way
digests, nothing else. It never contains a prompt, source code, assistant
output, a transcript path, an absolute project path, or a readable session or
prompt id. Records are consumed when their turn ends, and any record left
behind by a crashed session is deleted once it is older than 24 hours.

Uninstalling removes `~/.agentchime/turns/` entirely, including with
`-KeepConfig`.

## Notification detail level

`detailLevel` in `~/.agentchime/config.json` decides how much of the allowed
context actually reaches a notification.

| Level | Project label | API error type | Elapsed time |
| --- | --- | --- | --- |
| `standard` (default) | if `privacy.sendProjectName` | yes | if `privacy.sendDuration` |
| `minimal` | never | never | never |

Privacy overrides detail. The level only chooses among information the privacy
preferences have already authorized, so it can subtract and never add: with
`sendProjectName` set to `false` the folder name is absent at every level, and
with `sendDuration` set to `false` so is the elapsed time. No detail level can
reach back for something a privacy preference suppressed.

A configuration with no `detailLevel` key renders exactly the notifications it
rendered before the key existed, and an unrecognised value degrades to
`standard` rather than failing the notification.

Detail level changes nothing about what is measured or stored. Turn state is
still governed by `privacy.sendDuration` alone.

## Public ntfy topics

A long random topic reduces accidental discovery, but it is not the same thing as authenticated authorization. Do not treat the topic as appropriate protection for sensitive payloads.

If your threat model requires stronger controls:

- disable mobile, or
- use an authenticated/self-hosted ntfy server when AgentChime adds first-class auth support.

AgentChime stores its local configuration at `~/.agentchime/config.json`.
