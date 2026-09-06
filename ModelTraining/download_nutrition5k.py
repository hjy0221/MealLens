"""Download official Nutrition5k overhead RGB + labels, with MD5 verification.

No 181 GB video archive is needed. Original captures never enter git.
"""
import argparse
import base64
import concurrent.futures
import hashlib
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request

BUCKET = 'https://storage.googleapis.com/nutrition5k_dataset/'

def listing(prefix):
    token = None
    result = []
    while True:
        query = dict(prefix='nutrition5k_dataset/' + prefix, maxResults=1000,
                     fields='nextPageToken,items(name,size,md5Hash)')
        if token:
            query['pageToken'] = token
        url = 'https://storage.googleapis.com/storage/v1/b/nutrition5k_dataset/o?' + urllib.parse.urlencode(query)
        with urllib.request.urlopen(url, timeout=60) as response:
            page = json.load(response)
        result.extend(page.get('items', []))
        token = page.get('nextPageToken')
        if not token:
            return result

def download(item, root):
    path = root / item['name'].split('/', 1)[1]
    expected = item['md5Hash']
    for attempt in range(4):
        try:
            data = path.read_bytes() if path.exists() else urllib.request.urlopen(
                BUCKET + urllib.parse.quote(item['name']), timeout=60).read()
            digest = base64.b64encode(hashlib.md5(data).digest()).decode()
            if digest != expected or len(data) != int(item['size']):
                if path.exists():
                    # Preserve a corrupt cached copy for inspection, then
                    # allow the next attempt to fetch the official object.
                    path.replace(path.with_name(path.name + '.invalid-' + str(time.time_ns())))
                raise ValueError('Download checksum mismatch: ' + item['name'])
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                partial = path.with_suffix(path.suffix + '.part')
                partial.write_bytes(data)
                partial.replace(path)
            return dict(item, sha256=hashlib.sha256(data).hexdigest())
        except Exception:
            if attempt == 3:
                raise
            time.sleep(attempt + 1)

def main(root):
    root.mkdir(parents=True, exist_ok=True)
    items = listing('metadata/') + listing('dish_ids/')
    items += [x for x in listing('imagery/realsense_overhead/') if x['name'].endswith('/rgb.png')]
    print(f'Downloading {len(items)} objects, {sum(int(x["size"]) for x in items)/1e9:.2f} GB', flush=True)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(download, x, root) for x in items]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
            if len(results) % 250 == 0:
                print(f'Verified {len(results)}/{len(items)}', flush=True)
    report = {'source': 'https://github.com/google-research-datasets/Nutrition5k',
              'purpose': 'Local RGB portion/nutrition regression experiment',
              'objects': sorted(results, key=lambda x: x['name'])}
    (root / 'download-manifest.json').write_text(json.dumps(report, indent=2))
    print('All objects verified', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    main(parser.parse_args().destination)
