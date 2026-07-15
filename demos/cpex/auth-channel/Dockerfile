# CIBA authentication channel — the approver's "phone": a small Flask app
# that receives Keycloak's decoupled-auth POST (via the custom SPI) and
# shows a web approval UI. Approve/Deny calls back to Keycloak.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
EXPOSE 5001
CMD ["python", "server.py"]
