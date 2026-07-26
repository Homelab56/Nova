#!/usr/bin/env python3
import re

with open('backend/routers/debrid.py', 'r') as f:
    content = f.read()

# Verander de stream_url regel
old_pattern = r'"stream_url": f"/api/stream/play?url=\{urllib\.parse\.quote\(stream_url\)\}",'
new_text = '"stream_url": stream_url,'
content = re.sub(old_pattern, new_text, content)

with open('backend/routers/debrid.py', 'w') as f:
    f.write(content)

print("Wijziging toegepast")
