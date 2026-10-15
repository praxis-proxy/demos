# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

FROM python:3.12.12-alpine3.21

WORKDIR /app
COPY server.py /app/server.py

USER 65532:65532
EXPOSE 9100
ENTRYPOINT ["python", "/app/server.py"]
