# Praxis Configuration

This directory owns the identity, consumer-gateway, and provider-gateway Praxis
configuration used by the distributed token-quota topology.

Consumer configuration must contain the Grid-managed routing overlay mount and
must not contain provider credentials. Provider configuration must enforce
mTLS peer identity, provider-route authorization, and final-hop credential
injection before forwarding to a private inference endpoint.

The public identity gateway validates the three demo principals with Basic Auth
and projects a subject and quota group over an authenticated private hop. The
west consumers trust those projected fields only after peer authentication and
apply either independent application rules or the shared research rule. A
client-supplied quota-group header is not an authority boundary.

Site-specific addresses and identities are rendered from structured inputs.
