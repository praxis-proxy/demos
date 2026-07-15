// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Praxis Contributors
package com.example.keycloak.ciba;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.grants.ciba.channel.AuthenticationChannelProvider;
import org.keycloak.protocol.oidc.grants.ciba.channel.AuthenticationChannelProviderFactory;
import org.jboss.logging.Logger;

/**
 * Factory for the HTTP Authentication Channel Provider. Registered under the
 * provider id {@code http-authentication-channel} (see
 * {@code META-INF/services}).
 */
public class HttpAuthenticationChannelProviderFactory implements AuthenticationChannelProviderFactory {

    private static final Logger logger = Logger.getLogger(HttpAuthenticationChannelProviderFactory.class);
    public static final String PROVIDER_ID = "http-authentication-channel";

    @Override
    public AuthenticationChannelProvider create(KeycloakSession session) {
        logger.info("CIBA: Creating HTTP Authentication Channel Provider");
        return new HttpAuthenticationChannelProvider(session);
    }

    @Override
    public void init(Config.Scope config) {
        logger.info("CIBA: Initializing HTTP Authentication Channel Provider Factory");
        String authChannelUrl = System.getenv().getOrDefault(
            "CIBA_AUTH_CHANNEL_URL",
            "http://host.docker.internal:5001/ciba/auth"
        );
        logger.infof("CIBA: Authentication Channel URL: %s", authChannelUrl);
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        logger.info("CIBA: Post-initializing HTTP Authentication Channel Provider Factory");
    }

    @Override
    public void close() {
        logger.info("CIBA: Closing HTTP Authentication Channel Provider Factory");
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }
}
