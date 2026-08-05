# Pin the base image to a specific digest (NOT :latest) for reproducible builds.
# Resolved 2026-08-05: ghcr.io/d4vinci/scrapling:latest ->
#   sha256:1add316e8f347aee3290ee448eff5c7591cbf12341bf160261cdd9a0c3965524
FROM ghcr.io/d4vinci/scrapling@sha256:1add316e8f347aee3290ee448eff5c7591cbf12341bf160261cdd9a0c3965524

WORKDIR /app

# Install FastAPI + uvicorn using uv (pre-installed in Scrapling image).
# Production image: no [dev] extras (no pytest/ruff/pyright).
COPY pyproject.toml ./
RUN uv pip install --system .

# Copy application code only (tests are not shipped in the image)
COPY app/ ./app/

# Run as a non-root user
RUN useradd -m appuser
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/')"

ENTRYPOINT []
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
