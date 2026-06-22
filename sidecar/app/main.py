from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routers import health, fetch, scrape

app = FastAPI(
    title="Hiraeth Sidecar",
    description="Scrapling-powered ingestion sidecar for Hiraeth catalog imports",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(fetch.router)
app.include_router(scrape.router)
