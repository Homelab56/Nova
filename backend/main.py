from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from routers import search, debrid, stream, settings, userdata, library, seerr

app = FastAPI(title="Nova API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(search.router, prefix="/search", tags=["search"])
app.include_router(debrid.router, prefix="/debrid", tags=["debrid"])
app.include_router(stream.router, prefix="/stream", tags=["stream"])
app.include_router(settings.router, prefix="/settings", tags=["settings"])
app.include_router(userdata.router, prefix="/user", tags=["user"])
app.include_router(library.router, prefix="/library", tags=["library"])
app.include_router(seerr.router, prefix="/seerr", tags=["seerr"])

@app.get("/")
def root():
    return {"status": "Nova is running"}
