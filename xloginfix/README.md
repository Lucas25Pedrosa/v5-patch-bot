# XLoginFix 1.0.0

This directory is intentionally vendor-based so the login fix remains byte-for-byte identical to the validated dylib from X 12.27.1.

Expected input:

`xloginfix/vendor/FahdTwitterLoginBypass.dylib`

Canonical properties:

- Size: 442368 bytes
- Architectures: arm64 + arm64e
- SHA-256: `d6a3994fbc78cb41d95e281a230419105bc3ea3d4c55aba646b94ea51dee5a0a`
- Source IPA bundle: `com.atebits.Tweetie2`
- Validated app version: X 12.27.1

The workflow refuses a mismatched binary. When the canonical dylib is present, it publishes the same bytes as `XLoginFix.dylib` together with `SHA256SUMS.txt`.

The binary itself is not reconstructed here. This avoids silently omitting compatibility hooks or account/session behavior that are necessary for the sideload login flow.
