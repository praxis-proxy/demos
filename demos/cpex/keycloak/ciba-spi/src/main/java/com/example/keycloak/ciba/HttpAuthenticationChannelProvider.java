// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Praxis Contributors
package com.example.keycloak.ciba;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.hc.client5.http.classic.methods.HttpPost;
import org.apache.hc.client5.http.impl.classic.CloseableHttpClient;
import org.apache.hc.client5.http.impl.classic.HttpClients;
import org.apache.hc.core5.http.ContentType;
import org.apache.hc.core5.http.io.entity.StringEntity;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.representations.AccessToken;
import org.keycloak.protocol.oidc.grants.ciba.channel.AuthenticationChannelProvider;
import org.keycloak.protocol.oidc.grants.ciba.channel.CIBAAuthenticationRequest;
import org.keycloak.util.TokenUtil;
import org.jboss.logging.Logger;

import java.util.HashMap;
import java.util.Map;

/**
 * HTTP-based Authentication Channel Provider for Keycloak CIBA.
 * Sends each pending authentication request to an external HTTP endpoint
 * (the demo's auth-channel approval UI).
 */
public class HttpAuthenticationChannelProvider implements AuthenticationChannelProvider {

    private static final Logger logger = Logger.getLogger(HttpAuthenticationChannelProvider.class);
    private static final String AUTH_CHANNEL_URL = System.getenv().getOrDefault(
        "CIBA_AUTH_CHANNEL_URL",
        "http://host.docker.internal:5001/ciba/auth"
    );

    private final KeycloakSession session;
    private final ObjectMapper objectMapper;
    private final CloseableHttpClient httpClient;

    public HttpAuthenticationChannelProvider(KeycloakSession session) {
        this.session = session;
        this.objectMapper = new ObjectMapper();
        this.httpClient = HttpClients.createDefault();
    }

    @Override
    public boolean requestAuthentication(CIBAAuthenticationRequest request, String infoUsedByAuthentication) {
        try {
            logger.infof("CIBA: Sending authentication request to %s", AUTH_CHANNEL_URL);
            logger.infof("CIBA: Auth Request ID: %s", request.getId());
            logger.infof("CIBA: User: %s", infoUsedByAuthentication);
            logger.infof("CIBA: Binding Message: %s", request.getBindingMessage());

            // Get client model
            ClientModel client = session.getContext().getClient();

            // Create bearer token for authentication channel
            String bearerToken = createBearerToken(request, client);

            // Prepare request payload
            Map<String, Object> payload = new HashMap<>();
            payload.put("auth_req_id", request.getId());
            payload.put("authReqId", request.getId());
            payload.put("login_hint", infoUsedByAuthentication);
            payload.put("loginHint", infoUsedByAuthentication);
            payload.put("binding_message", request.getBindingMessage());
            payload.put("bindingMessage", request.getBindingMessage());
            payload.put("scope", request.getScope());
            payload.put("client_notification_token", request.getClientNotificationToken());
            payload.put("bearer_token", bearerToken);

            String jsonPayload = objectMapper.writeValueAsString(payload);

            // Send HTTP POST request
            HttpPost httpPost = new HttpPost(AUTH_CHANNEL_URL);
            httpPost.setHeader("Content-Type", "application/json");
            httpPost.setHeader("Authorization", "Bearer " + bearerToken);
            httpPost.setEntity(new StringEntity(jsonPayload, ContentType.APPLICATION_JSON));

            httpClient.execute(httpPost, response -> {
                int statusCode = response.getCode();
                logger.infof("CIBA: Auth channel responded with status: %d", statusCode);

                if (statusCode >= 200 && statusCode < 300) {
                    logger.info("CIBA: Authentication request sent successfully");
                } else {
                    logger.warnf("CIBA: Auth channel returned non-success status: %d", statusCode);
                }

                return null;
            });

            return true;

        } catch (Exception e) {
            logger.errorf(e, "CIBA: Failed to send authentication request to %s", AUTH_CHANNEL_URL);
            return false;
        }
    }

    private String createBearerToken(CIBAAuthenticationRequest request, ClientModel client) {
        AccessToken bearerToken = new AccessToken();

        bearerToken.type(TokenUtil.TOKEN_TYPE_BEARER);
        bearerToken.issuer(request.getIssuer());
        bearerToken.id(request.getAuthResultId());
        bearerToken.issuedFor(client.getClientId());
        bearerToken.audience(request.getIssuer());
        bearerToken.iat(request.getIat());
        bearerToken.exp(request.getExp());
        bearerToken.subject(request.getSubject());

        return session.tokens().encode(bearerToken);
    }

    @Override
    public void close() {
        try {
            if (httpClient != null) {
                httpClient.close();
            }
        } catch (Exception e) {
            logger.error("CIBA: Error closing HTTP client", e);
        }
    }
}
