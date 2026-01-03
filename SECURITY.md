# Security Policy

## Supported Versions

Currently, only the latest version of Streamix receives security updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.2.x   | :white_check_mark: |
| < 1.2   | :x:                |

## Reporting a Vulnerability

Security is taken seriously at Streamix. If you discover a security vulnerability, please follow this responsible disclosure process.

### How to Report

**DO NOT** open a public issue for security vulnerabilities.

Instead, send an email to:

📧 **gabrielmaialva33@gmail.com**

### What to include in the report

Please include as much information as possible:

1. **Vulnerability Type** (e.g., XSS, SQL Injection, CSRF, etc.)
2. **Location** of the vulnerable code (file, line, function)
3. **Steps to reproduce** the issue
4. **Potential Impact** of the vulnerability
5. **Suggested Fix** (if available)
6. **Proof of Concept** (if possible)

### Example Report

```
Subject: [SECURITY] XSS Vulnerability in search module

Type: Reflected Cross-Site Scripting (XSS)
Severity: High
Location: lib/streamix_web/live/search_live.ex:45

Description:
The search parameter is not being properly sanitized,
allowing for malicious script injection.

Steps to reproduce:
1. Access /search?q=<script>alert('xss')</script>
2. The script executes in the browser

Impact:
An attacker can execute arbitrary JavaScript in the user's context,
potentially stealing sessions.

Suggested Fix:
Use Phoenix.HTML.html_escape/1 on the parameter before rendering.
```

## Response Process

### Timeline

| Stage | Timeframe |
|-------|-----------|
| Acknowledgement of receipt | 24-48 hours |
| Initial Assessment | 72 hours |
| Status Update | Weekly |
| Fix (Critical severity) | 7 days |
| Fix (High severity) | 14 days |
| Fix (Medium/Low severity) | 30 days |

### What to expect

1. **Acknowledgement**: You will receive a confirmation of receipt within 48 hours
2. **Assessment**: We will assess the vulnerability and determine its severity
3. **Communication**: We will keep you informed about the progress
4. **Fix**: We will develop and test a fix
5. **Disclosure**: We will coordinate public disclosure after the fix

### Acknowledgement

We thank everyone who reports vulnerabilities responsibly. With your permission, we will acknowledge your contribution in:

- Release notes of the patched version
- Acknowledgements section in the README (if desired)

## Scope

### In Scope

- Streamix Application (source code)
- Public APIs
- Authentication and authorization
- User data protection
- Security configurations

### Out of Scope

- Vulnerabilities in third-party dependencies (report directly to maintainers)
- Social engineering attacks
- Denial of Service (DoS) attacks
- Vulnerabilities requiring physical access to the server
- Vulnerabilities in development/staging environments

## Security Best Practices

### For Users

- Keep Streamix updated
- Use strong and unique passwords
- Configure HTTPS in production
- Do not expose credentials in logs or code
- Configure environment variables correctly

### For Developers

- Never commit credentials or secrets
- Use `mix phx.gen.secret` to generate secrets
- Validate and sanitize all inputs
- Use prepared statements (Ecto does this by default)
- Follow the principle of least privilege
- Keep dependencies updated

## Security Configurations

### Sensitive Environment Variables

These variables must **NEVER** be committed:

```
SECRET_KEY_BASE
DATABASE_URL
REDIS_URL
TMDB_API_TOKEN
```

### Recommended Security Headers

Streamix automatically configures security headers via Plug, including:

- `X-Frame-Options: SAMEORIGIN`
- `X-Content-Type-Options: nosniff`
- `X-XSS-Protection: 1; mode=block`
- `Content-Security-Policy`

## Contact

For security questions:
- 📧 Email: gabrielmaialva33@gmail.com
- 🔐 For sensitive communications, request our PGP key

---

Thank you for helping keep Streamix secure!