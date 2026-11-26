"""Make MP4 copies of the collection's WebM videos, which Apple TV can't play.

Runs on a GitHub Actions runner. Writes media/<name>.mp4 and media/index.json,
which maps each WebM's token URI to its MP4 copy. Already converted files are kept.
"""
import json, os, re, subprocess, sys, tempfile, urllib.request

ACCOUNT = "tz1VoGn5XyDDbTQ5J2dEeWTMszA9H2xsQUrt"
GATEWAYS = ["https://cache.teia.rocks", "https://ipfs.io", "https://gateway.pinata.cloud", "https://dweb.link", "https://w3s.link"]
MAX_BYTES = 95 * 1024 * 1024  # GitHub refuses files over 100 MB
OUT = "media"


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "nft-catalog-media/1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def webm_uris():
    found, off = {}, 0
    while True:
        page = get_json(f"https://api.tzkt.io/v1/tokens/balances?account={ACCOUNT}&balance.gt=0&token.standard=fa2"
                        f"&limit=500&offset={off}&sort.asc=id&select=token")
        for t in page:
            m = (t or {}).get("metadata") or {}
            name = m.get("name") or "#" + str(t.get("tokenId"))
            art = m.get("artifactUri") or ""
            fmts = [f for f in (m.get("formats") or []) if isinstance(f, dict) and f.get("uri")]
            for f in fmts:
                if "webm" in str(f.get("mimeType") or "").lower():
                    found[f["uri"]] = name
            if art and "webm" in str(m.get("mime") or "").lower():
                found[art] = name
        if len(page) < 500:
            return found
        off += 500


def urls(uri):
    if uri.startswith("ipfs://"):
        rest = uri[7:]
        rest = rest[5:] if rest.startswith("ipfs/") else rest
        gws = GATEWAYS[1:] if "/" in rest.split("?")[0] else GATEWAYS
        return [f"{g}/ipfs/{rest}" for g in gws]
    if uri.startswith("https://"):
        return [uri]
    return []


def fetch(uri, dest):
    for u in urls(uri):
        r = subprocess.run(["curl", "-fsSL", "--retry", "2", "--max-time", "600", "-A", "nft-catalog-media/1", "-o", dest, u])
        if r.returncode == 0 and os.path.getsize(dest) > 0:
            probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", dest],
                                   capture_output=True, text=True)
            if "video" in probe.stdout:
                return True
    return False


def convert(src, dest):
    attempts = [("20", 3840), ("24", 2560), ("28", 1920)]
    for crf, side in attempts:
        vf = f"scale='min({side},iw)':'min({side},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
        r = subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", src, "-vf", vf, "-c:v", "libx264", "-preset", "slow",
                            "-crf", crf, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
                            "-movflags", "+faststart", dest])
        if r.returncode == 0 and 0 < os.path.getsize(dest) <= MAX_BYTES:
            return True
    return False


def main():
    os.makedirs(OUT, exist_ok=True)
    index_path = os.path.join(OUT, "index.json")
    index = json.load(open(index_path)) if os.path.exists(index_path) else {}
    todo = webm_uris()
    print(f"{len(todo)} WebM files in the collection, {len(index)} already converted")
    failed = {}
    for uri, name in sorted(todo.items()):
        if uri in index and os.path.exists(index[uri]):
            continue
        base = re.sub(r"[^A-Za-z0-9._-]+", "_", uri.split("://", 1)[-1])[:120]
        dest = os.path.join(OUT, base + ".mp4")
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "in.webm")
            if not fetch(uri, src):
                failed[uri] = f"{name}: couldn't download from any gateway"
                print("skip (download):", name, uri); continue
            if not convert(src, dest):
                failed[uri] = f"{name}: conversion failed or the MP4 was over 95 MB"
                print("skip (convert):", name, uri)
                if os.path.exists(dest): os.remove(dest)
                continue
        index[uri] = dest
        print(f"ok: {name} -> {dest} ({os.path.getsize(dest) / 1048576:.1f} MB)")
    json.dump(dict(sorted(index.items())), open(index_path, "w"), indent=1)
    json.dump(failed, open(os.path.join(OUT, "not-converted.json"), "w"), indent=1)
    print(f"done: {len(index)} converted, {len(failed)} not converted")


if __name__ == "__main__":
    sys.exit(main())
