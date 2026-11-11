import os, json, base64, re, urllib.request, urllib.error, urllib.parse

# Credentials and config come from environment variables,
# which Kubernetes populates from the ghost-backup-creds Secret.
ghost_url    = "https://blog.mattjarrett.dev"  # Ghost redirects in-cluster HTTP to this URL anyway
content_key  = os.environ["GHOST_CONTENT_KEY"]        # Ghost Content API key (read-only)
github_token = os.environ["GITHUB_TOKEN"]             # GitHub PAT with contents: write
github_repo  = os.environ["GITHUB_REPO"]              # e.g. cujarrett/blog-backups


def github_request(path, method="GET", body=None):
    # Thin wrapper around the GitHub Contents API.
    # path is relative to /repos/{owner}/{repo}/, e.g. "contents/posts/my-slug/index.md"
    url = f"https://api.github.com/repos/{github_repo}/{path}"
    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def github_commit(file_path, encoded_content, message):
    # Create or update a file in the repo. GitHub requires the existing file's
    # SHA when updating - without it the request is rejected. A 404 means new file.
    sha = None
    try:
        existing = github_request(f"contents/{file_path}")
        sha = existing.get("sha")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise

    body = {
        "message": message,
        "content": encoded_content,
        "committer": {"name": "blog-backup", "email": "blog-backup@homelab"},
    }
    if sha:
        body["sha"] = sha  # required by GitHub to confirm we're updating the right version

    github_request(f"contents/{file_path}", method="PUT", body=body)
    print(f"  {'updated' if sha else 'created'} {file_path}")


failed_images = []


def fetch_images(srcs, dest_dir):
    # Download each Ghost-hosted image in srcs.
    # Returns a dict mapping original src → (repo path under dest_dir, raw bytes).
    images = {}

    for src in srcs:
        if not src or "/content/images/" not in src:
            continue  # skip external images (e.g. embedded from other sites)

        # Ghost serves resized variants at /content/images/size/w{n}/...
        # Strip the size prefix so we download the original file.
        img_path = re.sub(r"/content/images/size/w\d+/", "/content/images/", src)
        img_path = urllib.parse.urlparse(img_path).path  # strip any host/scheme

        fetch_url = f"{ghost_url}{img_path}"
        try:
            img_req = urllib.request.Request(fetch_url, headers={"User-Agent": "blog-backup/1.0"})
            with urllib.request.urlopen(img_req) as r:
                img_bytes = r.read()
        except Exception as e:
            print(f"  warning: could not fetch {src}: {e}")
            failed_images.append(src)
            continue

        # Keep Ghost's YYYY/MM path, so names can't collide across months.
        rel_path = img_path.replace("/content/images/", "")  # e.g. 2024/01/photo.jpg
        repo_path = f"{dest_dir}/images/{rel_path}"
        images[src] = (repo_path, img_bytes)

    return images


def ghost_get(resource, query=""):
    # Cloudflare blocks Python's default user agent - use a neutral one.
    url = f"{ghost_url}/ghost/api/content/{resource}/?key={content_key}{query}"
    req = urllib.request.Request(url, headers={"User-Agent": "blog-backup/1.0"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)[resource]


def commit_images(images, message):
    for repo_path, img_bytes in images.values():
        github_commit(
            file_path=repo_path,
            encoded_content=base64.b64encode(img_bytes).decode(),
            message=message,
        )


# Site-wide setup that lives only in Ghost Admin, outside any post.
# The theme is stock Casper from the pinned ghost image, so it needs no copy.
settings = ghost_get("settings")
github_commit(
    file_path="site/settings.json",
    encoded_content=base64.b64encode(json.dumps(settings, indent=2).encode()).decode(),
    message="backup: site settings",
)
for name in ("codeinjection_head", "codeinjection_foot"):
    github_commit(
        file_path=f"site/{name}.html",
        encoded_content=base64.b64encode((settings.get(name) or "").encode()).decode(),
        message="backup: site code injection",
    )
site_srcs = [settings.get(k) for k in ("logo", "icon", "cover_image", "og_image", "twitter_image")]
site_srcs += [a.get(k) for a in ghost_get("authors") for k in ("profile_image", "cover_image")]
commit_images(fetch_images(site_srcs, "site"), "backup: site images")

# Fetch every published post from Ghost in one request.
# formats=html gives us the rendered post body (Ghost stores content internally
# as Lexical JSON, not markdown - html is the closest human-readable export).
# include=tags pulls tag names into the same response so we can write them to frontmatter.
posts = ghost_get("posts", "&formats=html&limit=all&include=tags")

print(f"Found {len(posts)} published posts")

for post in posts:
    slug         = post["slug"]          # URL-safe identifier, e.g. "my-first-post"
    title        = post["title"]
    published_at = post["published_at"]  # ISO 8601 timestamp
    updated_at   = post["updated_at"]
    url_val      = post.get("url", "")   # full public URL on blog.mattjarrett.dev
    tags         = [t["name"] for t in post.get("tags", [])]
    html         = post.get("html") or ""
    feature      = post.get("feature_image") or ""  # the cover photo, outside the html

    print(f"Processing: {slug}")

    # Download images and rewrite their src attributes in the HTML to relative paths
    # so the backed-up index.md links to the images sitting next to it in the repo.
    srcs = re.findall(r'<img[^>]+src=["\']([^"\']+)["\']', html) + [feature]
    images = fetch_images(srcs, f"posts/{slug}")
    for original_src, (repo_path, _) in images.items():
        # rel_path is relative from posts/{slug}/ to the image, e.g. ./images/2024/01/photo.jpg
        rel_path = repo_path.replace(f"posts/{slug}/", "./")
        html = html.replace(original_src, rel_path)
        if original_src == feature:
            feature = rel_path

    # Build the file: YAML frontmatter block followed by the post HTML.
    # The "---" delimiters are the standard frontmatter convention (used by Jekyll,
    # Hugo, etc.) so the file is readable by any static site tool if needed later.
    content = (
        f"---\n"
        f"title: {json.dumps(title)}\n"
        f"date: {published_at}\n"
        f"updated: {updated_at}\n"
        f"slug: {slug}\n"
        f"url: {url_val}\n"
        f"tags: {json.dumps(tags)}\n"
        f"feature_image: {feature}\n"
        f"---\n\n"
        f"{html}\n"
    )

    # Commit the post markdown - GitHub API requires base64-encoded content.
    github_commit(
        file_path=f"posts/{slug}/index.md",
        encoded_content=base64.b64encode(content.encode()).decode(),
        message=f"backup: {slug}",
    )

    commit_images(images, f"backup: {slug} images")

# Fail the Job, so a missing image shows up in ArgoCD and alerts, not only in logs.
if failed_images:
    raise SystemExit(f"{len(failed_images)} image(s) failed to download")
