#!/usr/bin/env python3
"""
CIBA Authentication Channel Provider - Web-based Approval
Simulates push notifications via web interface
"""

from flask import Flask, request, jsonify, render_template_string, redirect
from datetime import datetime
import threading
import time
import jwt
import base64
import json
import requests

app = Flask(__name__)

# Store pending authentication requests
pending_requests = {}
approved_requests = set()
denied_requests = set()

# HTML template for approval interface
APPROVAL_PAGE = """
<!DOCTYPE html>
<html>
<head>
    <title>CIBA Authentication</title>
    <meta http-equiv="refresh" content="3">
    <style>
        body { 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
            margin: 0; padding: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }
        .container { 
            max-width: 600px; margin: 0 auto; background: white; 
            padding: 30px; border-radius: 12px; 
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
        }
        h1 { color: #333; margin-top: 0; display: flex; align-items: center; }
        h1::before { content: '🔐'; margin-right: 10px; font-size: 32px; }
        .request { 
            border: 2px solid #e0e0e0; padding: 20px; margin: 15px 0; 
            border-radius: 8px; background: #fafafa;
            animation: slideIn 0.3s ease-out;
        }
        @keyframes slideIn {
            from { opacity: 0; transform: translateY(-10px); }
            to { opacity: 1; transform: translateY(0); }
        }
        .request.pending { border-left: 5px solid #ff9800; background: #fff8e1; }
        .request.approved { border-left: 5px solid #4caf50; background: #e8f5e9; }
        .request.denied { border-left: 5px solid #f44336; background: #ffebee; }
        .user { font-size: 20px; font-weight: bold; color: #333; margin: 10px 0; }
        .message { 
            background: #e3f2fd; padding: 12px; border-radius: 6px; 
            margin: 10px 0; font-style: italic; color: #1976d2;
        }
        .info { color: #666; font-size: 14px; margin: 5px 0; }
        .timestamp { color: #999; font-size: 12px; margin-top: 10px; }
        button { 
            padding: 12px 24px; margin: 10px 5px 0 0; border: none; 
            border-radius: 6px; cursor: pointer; font-size: 16px;
            font-weight: bold; transition: all 0.2s;
        }
        button:hover { transform: translateY(-2px); box-shadow: 0 4px 8px rgba(0,0,0,0.2); }
        .approve { background: #4caf50; color: white; }
        .approve:hover { background: #45a049; }
        .deny { background: #f44336; color: white; }
        .deny:hover { background: #da190b; }
        .empty { 
            text-align: center; color: #999; padding: 60px 20px;
            background: #f5f5f5; border-radius: 8px; margin: 20px 0;
        }
        .empty::before { content: '⏳'; font-size: 48px; display: block; margin-bottom: 20px; }
        .status-badge {
            display: inline-block; padding: 4px 12px; border-radius: 12px;
            font-size: 12px; font-weight: bold; text-transform: uppercase;
        }
        .status-pending { background: #ff9800; color: white; }
        .status-approved { background: #4caf50; color: white; }
        .status-denied { background: #f44336; color: white; }
        .header-info {
            background: #e3f2fd; padding: 15px; border-radius: 8px;
            margin-bottom: 20px; font-size: 14px; color: #1976d2;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Authentication Requests</h1>
        
        <div class="header-info">
            📱 This simulates push notifications on your phone<br>
            🔄 Page auto-refreshes every 3 seconds<br>
            ⚡ Approve or deny requests below
        </div>
        
        {% if requests %}
            {% for req_id, req in requests.items() %}
            <div class="request {{ req.status }}">
                <span class="status-badge status-{{ req.status }}">{{ req.status }}</span>
                
                <div class="user">👤 {{ req.login_hint }}</div>
                
                {% if req.binding_message %}
                <div class="message">
                    💬 "{{ req.binding_message }}"
                </div>
                {% endif %}
                
                <div class="info">
                    <strong>Request ID:</strong> {{ req_id[:16] }}...<br>
                    <strong>Scope:</strong> {{ req.scope or 'openid' }}
                </div>
                
                <div class="timestamp">⏰ {{ req.timestamp }}</div>
                
                {% if req.status == 'pending' %}
                <form method="POST" action="/approve/{{ req_id }}" style="display: inline;">
                    <button type="submit" class="approve">✓ Approve</button>
                </form>
                <form method="POST" action="/deny/{{ req_id }}" style="display: inline;">
                    <button type="submit" class="deny">✗ Deny</button>
                </form>
                {% endif %}
            </div>
            {% endfor %}
        {% else %}
            <div class="empty">
                <p><strong>No authentication requests</strong></p>
                <p>Waiting for CIBA requests from AI agents...</p>
            </div>
        {% endif %}
    </div>
</body>
</html>
"""

@app.route('/')
def index():
    """Show authentication requests (simulates push notification UI)"""
    return render_template_string(APPROVAL_PAGE, requests=pending_requests)

@app.route('/ciba/auth', methods=['POST'])
def ciba_auth_request():
    """
    Receive CIBA authentication request from Keycloak
    This endpoint is configured as the Authentication Channel
    """
    try:
        # Extract request details from JSON body
        data = request.json or {}
        
        # Get auth_req_id from the request data
        auth_req_id = data.get('authReqId')
        if not auth_req_id:
            print("✗ Error: Missing authReqId in request")
            return jsonify({'error': 'missing_auth_req_id'}), 400
        print(f"\n{'='*60}")
        print(f"📱 NEW AUTHENTICATION REQUEST")
        print(f"{'='*60}")
        
        login_hint = data.get('loginHint')
        binding_message = data.get('bindingMessage')
        scope = data.get('scope')
        consent_required = data.get('consentRequired', False)
        
        print(f"Request ID: {auth_req_id}")
        print(f"User: {login_hint}")
        print(f"Message: {binding_message}")
        print(f"Scope: {scope}")
        print(f"Consent Required: {consent_required}")
        print(f"FULL PAYLOAD KEYS: {list(data.keys())}")
        print(f"FULL PAYLOAD: {data}", flush=True)
        
        if not auth_req_id:
            print("✗ Error: Missing auth_req_id in token")
            return jsonify({'error': 'missing_auth_req_id'}), 400
        
        # Store the request (simulates sending push notification)
        pending_requests[auth_req_id] = {
            'login_hint': login_hint or 'Unknown User',
            'binding_message': binding_message,
            'scope': scope,
            'status': 'pending',
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'data': data
        }
        
        print(f"\n✓ Request stored and 'notification sent'")
        print(f"👉 View at: http://localhost:5001")
        print(f"{'='*60}\n")
        
        # Keycloak expects 201 CREATED status
        return jsonify({'status': 'accepted'}), 201
        
    except Exception as e:
        print(f"✗ Error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/approve/<auth_req_id>', methods=['POST'])
def approve_request(auth_req_id):
    """User approves the authentication request"""
    if auth_req_id in pending_requests:
        req_data = pending_requests[auth_req_id]
        login_hint = req_data.get('login_hint', 'alice')
        
        print(f"\n{'='*60}")
        print(f"✅ USER APPROVED REQUEST")
        print(f"{'='*60}")
        print(f"User: {login_hint}")
        print(f"Request ID: {auth_req_id}")
        
        # Mark as approved
        req_data['status'] = 'approved'
        approved_requests.add(auth_req_id)
        
        # Notify Keycloak via the bearer_token (serialized JWT from the CIBA request)
        try:
            bearer_token = req_data['data'].get('bearer_token')
            print(f"Bearer token present: {bool(bearer_token)}", flush=True)
            if bearer_token:
                # Where to POST the CIBA approval callback. Configurable so
                # the same channel works against any Keycloak/realm. The
                # demo points this at its own gateway (keycloak:8081 inside
                # compose, realm cpex-demo).
                import os as _os
                kc_base = _os.environ.get("KEYCLOAK_BASE", "http://localhost:8080")
                kc_realm = _os.environ.get("KEYCLOAK_REALM", "agent-realm")
                callback_url = f"{kc_base}/realms/{kc_realm}/protocol/openid-connect/ext/ciba/auth/callback"
                callback_response = requests.post(
                    callback_url,
                    headers={
                        'Authorization': f'Bearer {bearer_token}',
                        'Content-Type': 'application/json'
                    },
                    json={'status': 'SUCCEED'}
                )
                print(f"Callback to Keycloak: {callback_response.status_code} {callback_response.text[:120]}", flush=True)
                if callback_response.status_code == 200:
                    print("✓ Keycloak notified — next poll will return access token", flush=True)
                else:
                    print(f"✗ Callback failed: {callback_response.text}", flush=True)
            else:
                print("✗ No bearer_token in payload — SPI needs to be rebuilt", flush=True)
                
        except Exception as e:
            print(f"✗ Error completing authentication: {e}")
        
        print(f"{'='*60}\n")

    # POST-redirect-GET: send the browser back to the list (a GET-safe URL)
    # so the page's 3s auto-refresh doesn't re-hit this POST-only route (405).
    return redirect('/')

@app.route('/deny/<auth_req_id>', methods=['POST'])
def deny_request(auth_req_id):
    """User denies the authentication request"""
    if auth_req_id in pending_requests:
        pending_requests[auth_req_id]['status'] = 'denied'
        denied_requests.add(auth_req_id)
        
        print(f"\n{'='*60}")
        print(f"❌ REQUEST DENIED")
        print(f"{'='*60}")
        print(f"User: {pending_requests[auth_req_id]['login_hint']}")
        print(f"Request ID: {auth_req_id}")
        print(f"{'='*60}\n")

    return redirect('/')

@app.route('/pending', methods=['GET'])
def list_pending():
    """List pending requests with their FULL ids (dev/testing only).

    The HTML UI truncates the request id, so a script can't drive an
    approval from it. This returns the full ids so a scenario can
    auto-approve without a human clicking — see
    scenarios/11-bob-adjust-approval.sh (AUTO_APPROVE=1). Optional
    `?login_hint=<user>` filters to one approver.

    Unauthenticated, like every route in this mock — including the
    `/approve` and `/deny` POSTs that actually grant/refuse the approval,
    and the `/` page that already lists these same requests. This whole
    service simulates a phone-based approval UI for a localhost demo; it
    is NOT a production authorization surface. Do not deploy it, or copy
    this open-endpoint pattern, outside the demo. A real approval channel
    would authenticate the approver (the human) and every API caller.
    """
    want = request.args.get('login_hint')
    out = [
        {
            'auth_req_id': rid,
            'login_hint': r.get('login_hint'),
            'binding_message': r.get('binding_message'),
            'scope': r.get('scope'),
            'status': r.get('status'),
            'timestamp': r.get('timestamp'),
        }
        for rid, r in pending_requests.items()
        if r.get('status') == 'pending' and (want is None or r.get('login_hint') == want)
    ]
    return jsonify(out), 200

@app.route('/status/<auth_req_id>', methods=['GET'])
def check_status(auth_req_id):
    """Check if request was approved or denied"""
    if auth_req_id in approved_requests:
        return jsonify({'status': 'approved'}), 200
    elif auth_req_id in denied_requests:
        return jsonify({'status': 'denied'}), 200
    elif auth_req_id in pending_requests:
        return jsonify({'status': 'pending'}), 200
    return jsonify({'error': 'not_found'}), 404

@app.route('/health', methods=['GET'])
def health():
    """Health check"""
    return jsonify({
        'status': 'healthy',
        'pending': len([r for r in pending_requests.values() if r['status'] == 'pending']),
        'approved': len(approved_requests),
        'denied': len(denied_requests)
    }), 200

if __name__ == '__main__':
    import os
    port = int(os.environ.get('PORT', 5001))
    
    print("\n" + "="*60)
    print("🔐 CIBA Authentication Channel Provider")
    print("="*60)
    print("\n📱 Simulates push notifications via web interface")
    print(f"\nServer: http://localhost:{port}")
    print(f"Webhook: http://localhost:{port}/ciba/auth")
    print(f"\n✨ Open http://localhost:{port} in your browser")
    print("   This simulates the notification UI on a phone")
    print("\n⏳ Waiting for authentication requests...")
    print("="*60 + "\n")
    
    app.run(host='0.0.0.0', port=port, debug=False, use_reloader=False)

# Made with Bob
