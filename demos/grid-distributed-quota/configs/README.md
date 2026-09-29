# Praxis Configuration

This directory contains consumer and provider Praxis configuration for the
distributed per-application quota demo.

Both consumer configs expose one endpoint, authenticate all three demo
applications, and use the verified `AuthenticatedIdentity` subject to key one
shared Valkey-backed quota rule. They include the Grid-managed routing-overlay
mount and contain no provider credentials.

The provider config enforces mTLS peer identity, provider-route authorization,
and final-hop credential injection before forwarding to a private inference
endpoint. Site-specific addresses and identities are rendered by Forge.
