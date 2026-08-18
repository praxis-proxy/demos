# Keycloak CIBA HTTP Authentication Channel SPI

A small Keycloak SPI that implements the CIBA (Client-Initiated Backchannel
Authentication) **decoupled authentication channel** over HTTP: for each pending
CIBA request, Keycloak POSTs the request (auth_req_id, login hint, binding
message, a signed bearer token, …) to an external endpoint — the demo's
`auth-channel` approval UI — where a human approves or denies it.

It implements the public Keycloak interfaces
`AuthenticationChannelProvider` / `AuthenticationChannelProviderFactory` and
registers under the provider id **`http-authentication-channel`**
(`META-INF/services/…`). The target URL comes from the
`CIBA_AUTH_CHANNEL_URL` env var (the demo sets it via
`KC_SPI_CIBA_AUTH_CHANNEL_HTTP_AUTHENTICATION_CHANNEL_HTTP_AUTHENTICATION_CHANNEL_URI`).

## Build

Built automatically by `../Dockerfile` (multi-stage: Maven builds the jar, then
it's dropped into the Keycloak image under `/opt/keycloak/providers/`). To build
the jar standalone:

```bash
mvn clean package     # → target/keycloak-ciba-http-channel.jar
```

Requires JDK 17+ and Maven 3.6+. Runtime deps (httpclient5, jackson) are shaded
into the jar; Keycloak SPI deps are `provided`.

## License

MIT — covered by the repository's root `LICENSE`. Contributed to this demo with
the author's permission.
