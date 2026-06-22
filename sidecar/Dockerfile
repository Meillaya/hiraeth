FROM ghcr.io/d4vinci/scrapling:latest

WORKDIR /app

# Install FastAPI + uvicorn using uv (pre-installed in Scrapling image)
COPY pyproject.toml ./
RUN uv pip install --system -e ".[dev]"

# Copy application code
COPY app/ ./app/
COPY tests/ ./tests/

EXPOSE 8000

ENTRYPOINT []
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
