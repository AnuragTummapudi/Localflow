# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's **Report a vulnerability** button on the Security tab of this repository. Don't open a public issue.

Include steps to reproduce and the affected version. You'll get a reply within 7 days.

## Scope

Of particular interest:

- API keys leaving the Keychain, or being logged or shown.
- Audio, transcripts, or selected text sent anywhere other than the provider the user chose.
- Requests that bypass the Privacy network block.
- Model downloads written outside the app's model folder, or loaded without verification.
